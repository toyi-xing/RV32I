# v3.0 最小 memory map 与 MMIO 执行计划

当前五级流水线核已经完成 RV32I 主路径、CSR/trap、C runtime trap 入口和 256 KiB IMEM/DMEM 地址图。本计划根据 `docs/08xx/0832 最小memory map与MMIO外设规划.md` 编写，把第二阶段拆成可直接施工的 RTL/工程步骤。

本计划前半部分写 RTL/工程实现拆分；从第 7 章开始补 SoC-level 定向测试入口，作为 0832 当前验证以及后续 0833 interrupt、0834 wait-state/backpressure 验证的共同基础。

## 0. 实现边界

本阶段目标：

- 保持 `rtl/core/core.sv` 中的 `core` 模块作为 CPU core，不在 core 内部实例化 RAM 或外设。
- 新增 `rtl/common/soc_pkg.sv`，把 MMIO 总窗口、外设窗口和外设寄存器 offset 从 `core_pkg.sv` 迁出；`RESET_PC/MTVEC_RESET/IMEM/DMEM/XLEN` 等仍保留在 `core_pkg.sv`。
- 新增最小平台 wrapper `rv32i_soc.sv`，把 core、IMEM、DMEM、MMIO 外设和地址译码连接起来。
- 在现有 IMEM/DMEM 地址图后新增 MMIO window。
- 支持 UART0 MMIO 寄存器，当前只实现发送方向，软件写寄存器后 testbench 能观察字符。
- 支持 GPIO0 MMIO 寄存器，软件能写 OUT/OE、读 IN。
- 支持未映射 load/store access fault，进入现有 trap 路径：
  - load access fault: `mcause = 5`
  - store/AMO access fault: `mcause = 7`
  - `mtval = faulting address`
- 保持当前固定响应 memory/MMIO 模型，不引入 ready/valid 或 MEM stall。
- 保持既有 PASS/FAIL 状态字机制：`DMEM_BASE + 0x100` 仍作为仿真结束标志。

本阶段不做：

- timer 寄存器、`mtime/mtimecmp`、interrupt pending/enable。
- external interrupt、machine timer interrupt。
- APB/AHB/AXI-Lite 总线协议。
- memory/MMIO wait state、ready/valid/backpressure。
- DMA 或 accelerator 真实计算逻辑。
- UVM、coverage、系统化验证计划。

`rv32i_soc` 的定位：

- 它不是复杂 SoC，也不引入新总线协议。
- 它只是当前教学平台顶层，用来把 CPU core、ROM、RAM、MMIO decode、UART/GPIO 组合成一个可仿真的最小平台。
- 后续 0833/0834 增加 timer/interrupt/wait-state 时，优先在这个平台层扩展，不污染 `core` 的 CPU 微架构边界。

目标结构：

```text
core-level regression:

tb_core_pipeline5
    |-> core
    |-> simple_rom
    |-> simple_ram

soc-level directed test:

tb_rv32i_soc
    |
    v
rv32i_soc
    |-> core
    |-> simple_rom
    |-> data_subsystem
            |-> simple_ram
            |-> mmio_uart
            |-> mmio_gpio
            |-> access fault
```

说明：

- `core` 仍暴露 `imem_*` 取指接口。
- `core` 的数据访问接口改名为 `lsu_*`，表示 Load/Store Unit 发出的 data access request；它可能访问 DMEM，也可能访问 MMIO，不能再继续用 `dmem_*` 命名。
- `data_subsystem` 根据 `lsu_*` 请求地址决定访问 DMEM、UART、GPIO，或返回 access fault。
- `tb_core_pipeline5` 暂时保留为 core-only 回归入口，用于证明 core 主路径没有被 SoC 集成改动破坏。
- `tb_rv32i_soc` 作为新的 SoC-level 定向测试入口，用于观察 UART/GPIO/MMIO/access fault，以及后续 interrupt/backpressure 行为。
- `rv32i_soc` 和 SoC testbench 对外观察口仍可使用 `data_*`，表示“当前 core 的数据侧访问”，不特指 RAM 或 MMIO。

## 1. 公共类型和地址常量 `已完成`

### 1.1 修改 `rtl/common/core_pkg.sv`

当前地址图应保持：

| 区域 | 起始地址 | 结束地址 | 大小 |
|---|---:|---:|---:|
| IMEM | `0x0000_0000` | `0x0003_FFFF` | 256 KiB |
| DMEM | `0x0004_0000` | `0x0007_FFFF` | 256 KiB |
| MMIO | `0x0008_0000` | `0x0008_FFFF` | 64 KiB |

`core_pkg.sv` 保留 core/ISA/流水线公共定义，以及已有基础存储空间和 trap 默认入口：

- `XLEN/ILEN`
- `RESET_PC/MTVEC_RESET`
- `IMEM_BASE/IMEM_SIZE_BYTES/IMEM_ADDR_WIDTH`
- `DMEM_BASE/DMEM_SIZE_BYTES/DMEM_ADDR_WIDTH`
- opcode、`instr_id_e`、ALU/branch/WB/load/store/CSR/trap 枚举
- CSR 地址、pipeline struct、trap cause

MMIO 总窗口、外设窗口和外设寄存器 offset 在第 3 章迁移到 `soc_pkg.sv`，不继续放在 `core_pkg.sv`。

MMIO 子地址图：

| 区域 | 起始地址 | 结束地址 | 规划容量 |
|---|---:|---:|---:|
| GPIO window | `0x0008_0000` | `0x0008_03FF` | 4 个 GPIO，每个 `0x100` |
| reserved | `0x0008_0400` | `0x0008_0FFF` | GPIO 页内预留 |
| TIMER window | `0x0008_1000` | `0x0008_15FF` | 6 个 timer，每个 `0x100` |
| UART window | `0x0008_2000` | `0x0008_25FF` | 6 个 UART，每个 `0x100` |
| reserved | `0x0008_3000` | `0x0008_7FFF` | 后续普通外设扩展 |
| ACCEL window | `0x0008_8000` | `0x0008_BFFF` | 4 个 accelerator，每个 `0x1000` |
| reserved | `0x0008_C000` | `0x0008_FFFF` | 后续大块扩展 |

本阶段只实例化 UART0/GPIO0。GPIO1-3、UART1-5、TIMER0-5、ACCEL0-3 等地址先作为预留；在对应模块未实现前，访问这些窗口应视为未映射地址并产生 access fault。

新增 access fault trap cause：

```systemverilog
TRAP_CAUSE_LOAD_ACCESS_FAULT  = 5'd5,
TRAP_CAUSE_STORE_ACCESS_FAULT = 5'd7,
```

放置位置建议：

- `trap_cause_e` 中按 RISC-V exception code 顺序放在 load/store misaligned 附近。
- 注释说明这是 unmapped/illegal data address 的同步异常，当前没有 instruction access fault。

### 1.2 不修改 `pipeline_pkg.sv`

本阶段不需要新增流水线寄存器字段。

原因：

- access fault 在 MEM 边界由 data subsystem 组合返回给 `mem_stage`。
- `mem_stage` 当拍合并已有 exception、misaligned 和 access fault。
- exception 信息仍然走现有 `mem_exception_* -> trap_ctrl` 路径。

## 2. 新增 MMIO 外设模块 `已完成`

### 2.1 新建 `rtl/periph/mmio_uart.sv` `已完成`

模块职责：

- 提供 UART0 最小 MMIO 寄存器块。
- 当前只实现发送方向；后续增加 UART RX 和中断时，继续在本模块内扩展寄存器和端口，不改外设模块名。
- 真正 TX event：`CTRL.enable=1` 时，对 `TXDATA` 发起有效 store，且 `be_i[0]=1`。
- TX event 在时钟沿后表现为 `tx_valid_o` 拉高一拍，`tx_data_o` 为 `TXDATA[7:0]`。
- `STATUS.tx_ready` 固定为 1。
- `CTRL.enable` 是 RW 寄存器，复位后为 0，软件需要先开启再发送。
- offset 不存在时输出 `access_fault_o`。

建议端口：

```systemverilog
module mmio_uart #(
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR = soc_pkg::UART0_BASE
) (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      valid_i,
    input  logic                      we_i,
    input  logic [3:0]                be_i,
    input  logic [core_pkg::XLEN-1:0] addr_i,
    input  logic [core_pkg::XLEN-1:0] wdata_i,
    output logic [core_pkg::XLEN-1:0] rdata_o,
    output logic                      access_fault_o,

    output logic                      tx_valid_o,
    output logic [7:0]                tx_data_o
);
```

端口说明：

- `addr_i` 建议传完整 byte address，模块内部用 `addr_i - BASE_ADDR` 得到 offset。
- `valid_i` 表示地址已经命中 UART0 窗口。
- `we_i` 表示本拍是对 UART0 的 store。
- `be_i` 是 core store byte enable。
- UART0 窗口大小由上层 `data_subsystem` 判断，本模块只根据窗口内 offset 判断是否为已定义寄存器。

寄存器规划：

| offset | 名称 | 属性 | 行为 |
|---:|---|---|---|
| `0x00` | `TXDATA` | WO | `enable=1` 且写 byte0 时触发 TX event；读返回 0 |
| `0x04` | `STATUS` | RO | bit0 固定为 1，表示 ready |
| `0x08` | `CTRL` | RW | bit0 enable，复位为 0 |

写行为：

- `valid_i && we_i && offset == TXDATA && be_i[0] && ctrl_enable` 时，输出 TX event。
- `TXDATA` 保存最近一次写入值；`tx_data_o` 连到该寄存器低 8 bit。
- 写 `TXDATA` 但 `be_i[0] == 0` 时只更新被使能的 byte lane，不触发 TX event。
- 写 `STATUS` 忽略。
- 写 `CTRL` 根据 `be_i` 更新对应 byte lane，第一版只使用 bit0。
- 未知 offset 不更新任何寄存器，`access_fault_o` 拉高。

读行为：

```text
TXDATA -> 32'h0000_0000
STATUS -> 32'h0000_0001
CTRL   -> ctrl 寄存器值
其他   -> 0 且 access_fault_o=1
```

### 2.2 新建 `rtl/periph/mmio_gpio.sv` `已完成`

模块职责：

- 提供 GPIO0 最小 MMIO 寄存器块。
- `OUT/OE` 是 RW。
- `IN` 是 RO，来自 SoC/testbench 输入。
- offset 不存在时输出 `access_fault_o`。

建议端口：

```systemverilog
module mmio_gpio #(
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = soc_pkg::GPIO0_BASE,
    parameter int unsigned               GPIO_WIDTH = 32
) (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      valid_i,
    input  logic                      we_i,
    input  logic [3:0]                be_i,
    input  logic [core_pkg::XLEN-1:0] addr_i,
    input  logic [core_pkg::XLEN-1:0] wdata_i,
    output logic [core_pkg::XLEN-1:0] rdata_o,
    output logic                      access_fault_o,

    input  logic [GPIO_WIDTH-1:0]     gpio_in_i,
    output logic [GPIO_WIDTH-1:0]     gpio_out_o,
    output logic [GPIO_WIDTH-1:0]     gpio_oe_o
);
```

`GPIO_WIDTH` 表示这个 GPIO block 的引脚数，当前 `data_subsystem` 实例化 GPIO0 时使用 32。

寄存器规划：

| offset | 名称 | 属性 | 行为 |
|---:|---|---|---|
| `0x00` | `OUT` | RW | 保存 GPIO 输出值 |
| `0x04` | `IN` | RO | 返回 `gpio_in_i` |
| `0x08` | `OE` | RW | 保存 GPIO 输出使能 |

写行为：

- 写 `OUT/OE` 时按 `be_i` 更新 byte lane。
- 写 `IN` 忽略，不产生 access fault。
- 未知 offset 不更新任何寄存器，`access_fault_o` 拉高。

byte lane 更新建议封装成局部函数或局部 `always_comb`，避免重复写四段逻辑也可以；如果直接展开，也要和 `simple_ram` 的 byte lane 风格保持一致。

### 2.3 外设模块注释口径 `已完成`

文件头注释要说明：

- 当前是固定响应 MMIO register block。
- 没有 ready/valid backpressure。
- `valid_i` 表示地址已经命中该外设窗口。
- `access_fault_o` 只表示外设窗口内 offset 不存在，不负责判断整个地址是否命中外设。
- 真正未映射地址由 `data_subsystem` 汇总判断。

## 3. 新增 `rtl/common/soc_pkg.sv` `已完成`

### 3.1 模块职责

`soc_pkg.sv` 只放当前 SoC/platform 级地址图，不放 CPU core 机制本身。

放入 `soc_pkg.sv`：

- MMIO 总窗口：`MMIO_BASE/MMIO_SIZE_BYTES/MMIO_ADDR_WIDTH`
- GPIO/UART/TIMER/ACCEL 的 base、size、stride、num
- GPIO0/UART0/TIMER0/ACCEL0 的 base、size
- GPIO/UART 寄存器 offset

继续留在 `core_pkg.sv`：

- `XLEN/ILEN`
- `RESET_PC/MTVEC_RESET`
- `IMEM_BASE/IMEM_SIZE_BYTES/IMEM_ADDR_WIDTH`
- `DMEM_BASE/DMEM_SIZE_BYTES/DMEM_ADDR_WIDTH`
- ISA、CSR、trap、流水线类型

这样做的原因：

- IMEM/DMEM/RESET_PC/MTVEC_RESET 当前已有较多 RTL 直接依赖，继续留在 `core_pkg` 可以减少无意义改动。
- MMIO 和外设地址图属于 SoC 集成层，后续 timer、interrupt、accelerator 继续扩展时不应污染 core 公共包。

### 3.2 `soc_pkg.sv` 常量内容

新增 MMIO 总窗口常量：

```systemverilog
parameter logic [core_pkg::XLEN-1:0] MMIO_BASE       = 32'h0008_0000;
parameter logic [core_pkg::XLEN-1:0] MMIO_SIZE_BYTES = 32'h0001_0000;
parameter int unsigned               MMIO_ADDR_WIDTH = 14;
```

新增外设窗口常量：

```systemverilog
parameter logic [core_pkg::XLEN-1:0] GPIO_BASE         = 32'h0008_0000;
parameter logic [core_pkg::XLEN-1:0] GPIO_SIZE_BYTES   = 32'h0000_0400;
parameter logic [core_pkg::XLEN-1:0] GPIO_STRIDE       = 32'h0000_0100;
parameter int unsigned               GPIO_NUM          = 4;

parameter logic [core_pkg::XLEN-1:0] TIMER_BASE        = 32'h0008_1000;
parameter logic [core_pkg::XLEN-1:0] TIMER_SIZE_BYTES  = 32'h0000_0600;
parameter logic [core_pkg::XLEN-1:0] TIMER_STRIDE      = 32'h0000_0100;
parameter int unsigned               TIMER_NUM         = 6;

parameter logic [core_pkg::XLEN-1:0] UART_BASE         = 32'h0008_2000;
parameter logic [core_pkg::XLEN-1:0] UART_SIZE_BYTES   = 32'h0000_0600;
parameter logic [core_pkg::XLEN-1:0] UART_STRIDE       = 32'h0000_0100;
parameter int unsigned               UART_NUM          = 6;

parameter logic [core_pkg::XLEN-1:0] ACCEL_BASE        = 32'h0008_8000;
parameter logic [core_pkg::XLEN-1:0] ACCEL_SIZE_BYTES  = 32'h0000_4000;
parameter logic [core_pkg::XLEN-1:0] ACCEL_STRIDE      = 32'h0000_1000;
parameter int unsigned               ACCEL_NUM         = 4;

parameter logic [core_pkg::XLEN-1:0] GPIO0_BASE        = GPIO_BASE;
parameter logic [core_pkg::XLEN-1:0] GPIO0_SIZE_BYTES  = GPIO_STRIDE;

parameter logic [core_pkg::XLEN-1:0] TIMER0_BASE       = TIMER_BASE;
parameter logic [core_pkg::XLEN-1:0] TIMER0_SIZE_BYTES = TIMER_STRIDE;

parameter logic [core_pkg::XLEN-1:0] UART0_BASE        = UART_BASE;
parameter logic [core_pkg::XLEN-1:0] UART0_SIZE_BYTES  = UART_STRIDE;

parameter logic [core_pkg::XLEN-1:0] ACCEL0_BASE       = ACCEL_BASE;
parameter logic [core_pkg::XLEN-1:0] ACCEL0_SIZE_BYTES = ACCEL_STRIDE;
```

新增 UART0 offset 常量：

```systemverilog
parameter logic [core_pkg::XLEN-1:0] UART_TXDATA_OFFSET = 32'h000;
parameter logic [core_pkg::XLEN-1:0] UART_STATUS_OFFSET = 32'h004;
parameter logic [core_pkg::XLEN-1:0] UART_CTRL_OFFSET   = 32'h008;
```

新增 GPIO0 offset 常量：

```systemverilog
parameter logic [core_pkg::XLEN-1:0] GPIO_OUT_OFFSET = 32'h000;
parameter logic [core_pkg::XLEN-1:0] GPIO_IN_OFFSET  = 32'h004;
parameter logic [core_pkg::XLEN-1:0] GPIO_OE_OFFSET  = 32'h008;
```

### 3.3 同步已有 MMIO 外设模块

`mmio_uart.sv` 和 `mmio_gpio.sv` 的参数默认值、offset 判断改用 `soc_pkg::`：

```systemverilog
parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = soc_pkg::UART0_BASE
```

```systemverilog
parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = soc_pkg::GPIO0_BASE
```

寄存器 offset 同理：

```systemverilog
soc_pkg::UART_TXDATA_OFFSET
soc_pkg::UART_STATUS_OFFSET
soc_pkg::UART_CTRL_OFFSET
soc_pkg::GPIO_OUT_OFFSET
soc_pkg::GPIO_IN_OFFSET
soc_pkg::GPIO_OE_OFFSET
```

### 3.4 编译顺序

`soc_pkg.sv` 依赖 `core_pkg::XLEN`，因此 RTL 文件列表中需要保证：

```text
rtl/common/core_pkg.sv
rtl/common/soc_pkg.sv
rtl/common/pipeline_pkg.sv
其他 RTL
```

## 4. 新增 `rtl/soc/data_subsystem.sv` `已完成`

### 4.1 模块职责

`data_subsystem` 是 core LSU data access 和具体数据设备之间的固定响应译码层。

职责：

- 接收 `core` 的 `lsu_*` request。
- 判断地址命中 DMEM、UART0、GPIO0，还是未映射。
- 实例化 `simple_ram`、`mmio_uart`、`mmio_gpio`。
- 对 store，只把写使能送到命中的设备。
- 对 load，返回命中设备的 32-bit `rdata`。
- 对未映射 load/store，返回 `access_fault_o = 1`，读数据返回 0。
- 暴露 UART/GPIO 观察信号给 SoC/testbench。

### 4.2 建议端口

```systemverilog
module data_subsystem (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      core_re_i,
    input  logic                      core_we_i,
    input  logic [3:0]                core_be_i,
    input  logic [core_pkg::XLEN-1:0] core_addr_i,
    input  logic [core_pkg::XLEN-1:0] core_wdata_i,
    output logic [core_pkg::XLEN-1:0] core_rdata_o,
    output logic                      core_access_fault_o,

    input  logic [31:0]               gpio0_in_i,
    output logic [31:0]               gpio0_out_o,
    output logic [31:0]               gpio0_oe_o,

    output logic                      uart0_tx_valid_o,
    output logic [7:0]                uart0_tx_data_o,

    output logic                      dmem_access_o,
    output logic                      mmio_access_o
);
```

说明：

- `core_re_i/core_we_i` 来自 `core.lsu_re_o/lsu_we_o`。
- `core_access_fault_o` 接回 `core.lsu_access_fault_i`。
- `dmem_access_o/mmio_access_o` 只是观察信号，给 testbench 做统计或波形 debug。

### 4.3 地址命中判断

建议把地址命中和真实访问拆开写：

```systemverilog
wire access_valid = core_re_i | core_we_i;

wire dmem_hit, gpio0_hit, uart0_hit;
wire mapped_hit;

assign dmem_hit   = (core_addr_i >= core_pkg::DMEM_BASE)
                  & (core_addr_i <  core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES);

assign gpio0_hit  = (core_addr_i >= soc_pkg::GPIO0_BASE)
                  & (core_addr_i <  soc_pkg::GPIO0_BASE + soc_pkg::GPIO0_SIZE_BYTES);

assign uart0_hit  = (core_addr_i >= soc_pkg::UART0_BASE)
                  & (core_addr_i <  soc_pkg::UART0_BASE + soc_pkg::UART0_SIZE_BYTES);

assign mapped_hit = dmem_hit | gpio0_hit | uart0_hit;

wire dmem_valid, gpio0_valid, uart0_valid;
assign dmem_valid  = dmem_hit  & access_valid;
assign gpio0_valid = gpio0_hit & access_valid;
assign uart0_valid = uart0_hit & access_valid;
```

说明：

- `*_hit` 只表示地址落入已实现设备窗口，不带本拍是否真的访存。
- `*_valid` 表示本拍对该设备有真实 load/store 访问。
- `mapped_hit` 表示地址命中当前已实现的 data region，用于 unmapped access fault 判断。

`GPIO1-3/UART1-5/TIMER0-5/ACCEL0-3` 本阶段不作为 hit：

- 地址常量可以存在。
- 不实例化对应外设。
- 命中预留窗口仍视为未映射，产生 access fault。

### 4.4 simple_ram 安全地址

`simple_ram` 内部会根据 `addr_i - DMEM_BASE` 计算 word index。为了避免 MMIO/未映射地址让 RAM 内部出现无意义索引，建议给 RAM 一个安全地址：

```systemverilog
wire [core_pkg::XLEN-1:0] dmem_addr = dmem_hit ? core_addr_i : core_pkg::DMEM_BASE;
wire                      dmem_we   = core_we_i & dmem_valid;
```

实例化：

```systemverilog
simple_ram u_simple_ram (
    .clk_i   (clk_i),
    .we_i    (dmem_we),
    .be_i    (core_be_i),
    .addr_i  (dmem_addr),
    .wdata_i (core_wdata_i),
    .rdata_o (dmem_rdata)
);
```

说明：

- `simple_ram` 仍用 `+dmem=<path>` 初始化。
- RAM read 没有读使能，未命中时给安全地址即可。
- DMEM 访问统计不要依赖 RAM 内部读口，应在 testbench 用 `dmem_access_o` 或地址范围判断。

### 4.5 外设 access fault 合并

UART0/GPIO0 模块各自输出 offset 是否非法：

```systemverilog
wire gpio0_access_fault;
wire uart0_access_fault;
```

最终 fault：

```systemverilog
assign core_access_fault_o = (access_valid & !mapped_hit)
                           | gpio0_access_fault
                           | uart0_access_fault;
```

说明：

- 地址未命中任何已实现设备：fault。
- 命中 UART/GPIO 窗口但 offset 不存在：fault。
- 命中 RO 寄存器并执行 store 是否 fault 由外设模块决定；本计划建议 RO 写忽略，不产生 fault，先保持 MMIO 语义简单。
- 当前直接 OR 外设 `access_fault`，前提是外设模块自身用 `valid_i` 做了门控；若后续外设 fault 语义变化，可以在本层恢复成 `gpio0_valid & gpio0_access_fault` 这类更防御的写法。

### 4.6 读数据 mux

```systemverilog
always_comb begin
    core_rdata_o = '0;
    if (dmem_valid) begin
        core_rdata_o = dmem_rdata;
    end else if (gpio0_valid) begin
        core_rdata_o = gpio0_rdata;
    end else if (uart0_valid) begin
        core_rdata_o = uart0_rdata;
    end
end
```

未映射地址读返回 0，同时 `core_access_fault_o = 1`。最终不会正常写回 GPR，因为 access fault 会在 MEM 边界被 trap 接受，`kill_mem_wb` 会阻止 faulting load 进入普通 WB。

## 5. 扩展 core 数据访问错误通路 `已完成`

### 5.1 整理 core 顶层命名与数据访问端口 `已完成`

本步只做 core 边界命名整理和最小兼容连接，不改变 core 内部数据通路功能。做完后，在没有触发 access fault 的既有程序上，现有 pipeline5 仿真应仍可通过。

#### 5.1.1 文件名和模块名从 `core_pipeline5` 改为 `core`

`rtl/core/core_pipeline5.sv` 改名为 `rtl/core/core.sv`，模块名同步改成更稳定的：

```systemverilog
module core (
    ...
);
```

原因：

- `core_pipeline5` 描述的是当前微架构形态，作为模块名会把后续 SoC/testbench 都绑死在“五级流水”这个实现细节上。
- `core` 更适合作为 CPU core 的稳定集成边界；后续即使内部继续扩展 CSR、interrupt、wait-state，外部 wrapper 不需要反复改模块名。
- 当前仿真脚本按 `rtl/core/*.sv` 收集 RTL 文件，文件名改成 `core.sv` 不需要单独修改脚本；若后续脚本改为显式文件列表，需要同步更新。

同步修改：

- `tb/sv/tb_core_pipeline5.sv` 中 DUT 实例化从 `core_pipeline5 u_core` 改为 `core u_core`。
- 第 6 章新增 `rv32i_soc.sv` 时，也应实例化 `core u_core`。
- 脚本目前按目录收集 `rtl/core/*.sv`，本步不需要改脚本；若有显式 top/module 名检查，需要同步成 `core`。
- testbench 模块名 `tb_core_pipeline5` 暂时可以保留，因为它表示“pipeline5 阶段使用的测试平台”，不是 DUT 模块名。

#### 5.1.2 数据访问端口从 `dmem_*` 改为 `lsu_*`

把 core 边界原有 `dmem_*` 端口改名为 `lsu_*`：

```systemverilog
output logic                      lsu_re_o,
output logic                      lsu_we_o,
output logic [3:0]                lsu_be_o,
output logic [core_pkg::XLEN-1:0] lsu_addr_o,
output logic [core_pkg::XLEN-1:0] lsu_wdata_o,
input  logic [core_pkg::XLEN-1:0] lsu_rdata_i,
```

新增 data access fault 输入：

```systemverilog
input logic lsu_access_fault_i,  // 当前 LSU data access 命中未映射或非法 data 地址。
```

命名口径：

- `lsu_*` 表示 core 的 Load/Store Unit 数据访问请求。
- `lsu_*` 地址尚未解码，可能命中 DMEM、MMIO，也可能命中未映射区域。
- 外部可以把它接到 RAM，也可以接到包含 RAM/MMIO 的 data subsystem。
- `lsu_access_fault_i` 只表示 data load/store 访问错误，不表示指令取指错误。

同步修改：

- `tb/sv/tb_core_pipeline5.sv` 里的局部信号可从 `dmem_*` 改为 `lsu_*`，也可以暂时保留 `dmem_*` 局部名但注释必须说明其含义已是 core data access；推荐本步直接改成 `lsu_*`，避免和后续 `data_subsystem.dmem_access_o` 混淆。
- `tb/sv/tb_core_pipeline5.sv` 里的 DUT 端口连接必须从 `.dmem_*` 改为 `.lsu_*`。
- 在 `rv32i_soc.sv` 尚未接入前，现有 core 直连 testbench 仍直接把 `lsu_*` 接到 `simple_ram`，并临时给 `lsu_access_fault_i` 接 `1'b0`，这样既有无异常程序仿真应保持通过。
- PASS/FAIL、DMEM range、stack 统计逻辑在 core-only TB 中可继续用 `lsu_we/lsu_addr/lsu_wdata` 判断；SoC-level TB 另用 `rv32i_soc.data_*` 和 `dmem_access_o/mmio_access_o` 观察。

### 5.2 修改 `rtl/core/mem_stage.sv` 端口 `已完成`

本步进入 MEM 阶段内部，把对外 data access 端口也统一成 `lsu_*` 口径。`mem_stage` 仍然负责 load/store 地址、byte enable、写数据对齐和 load 数据扩展；只是这些请求已经不再特指 DMEM，而是发往 core 外部的 LSU data side。

原 `dmem_*` 端口统一改名 `已完成`：

```systemverilog
input  logic [core_pkg::XLEN-1:0] lsu_rdata_i,  // LSU load 返回的 32 bit 原始 word 数据。

output logic                      lsu_re_o,     // LSU load 读请求；地址不对齐或前级已有 exception 时不发起访问。
output logic                      lsu_we_o,     // LSU store 写请求；地址不对齐或前级已有 exception 时不发起访问。
output logic [3:0]                lsu_be_o,     // LSU store byte enable。
output logic [core_pkg::XLEN-1:0] lsu_addr_o,   // LSU load/store 地址。
output logic [core_pkg::XLEN-1:0] lsu_wdata_o,  // LSU 按 byte lane 对齐后的 store 数据。
```

同步修改 `mem_stage` 头注释：

- “dmem 固定响应”改成“LSU 数据侧固定响应”。
- “生成 dmem 读/写使能”改成“生成 LSU load/store 请求”。
- “从 dmem_rdata_i 选出数据”改成“从 lsu_rdata_i 选出数据”。
- 不对齐访问屏蔽的是 `lsu_re_o/lsu_we_o`，不是特定 RAM 写使能。

新增输入：

```systemverilog
input logic lsu_access_fault_i, // 当前有效 load/store 地址没有命中已实现 data region。
```

新增观察输出，方便波形和后续 testbench：

```systemverilog
output logic mem_access_fault_o,
output logic load_access_fault_o,
output logic store_access_fault_o,
```

这些端口可在 `rtl/core/core.sv` 里接到内部观察 wire，也可以在当前阶段留空；它们不参与 core 顶层功能逻辑，当前实现选择留空。

### 5.3 修改 `core` 中 `mem_stage` 实例连接 `已完成`

`u_mem_stage` 新增连接：

```systemverilog
.lsu_rdata_i         (lsu_rdata_i),
.lsu_re_o            (lsu_re_o),
.lsu_we_o            (lsu_we_o),
.lsu_be_o            (lsu_be_o),
.lsu_addr_o          (lsu_addr_o),
.lsu_wdata_o         (lsu_wdata_o),
.lsu_access_fault_i  (lsu_access_fault_i),
.mem_access_fault_o  (),
.load_access_fault_o (),
.store_access_fault_o(),
```

同时删除/替换原来的 `.dmem_rdata_i/.dmem_re_o/.dmem_we_o/.dmem_be_o/.dmem_addr_o/.dmem_wdata_o` 连接。5.2 做完后，`core.sv` 内部不应再出现 `mem_stage` 的 `dmem_*` 端口连接。

这些 observation 输出当前留空，后续如需波形或 testbench 观察，可再接到内部 wire；暂时不导出 `core` 顶层。

### 5.4 `mem_stage` access fault 判断 `已完成`

新增组合信号：

```systemverilog
assign load_access_fault_o  = valid_i & lsu_access_fault_i & mem_re_i;
assign store_access_fault_o = valid_i & lsu_access_fault_i & mem_we_i;
assign mem_access_fault_o   = load_access_fault_o | store_access_fault_o;
```

实际 exception 合并时要遵守优先级：

```text
已有前级 exception > load/store misaligned > load/store access fault
```

> RISC-V 对 misaligned 与 access fault 的具体优先级允许实现选择，教学核保持固定规则即可。

建议写法：

```systemverilog
assign exception_valid_o = exception_valid_i
                         | mem_misaligned_o
                         | mem_access_fault_o;

assign exception_cause_o = exception_valid_i      ? exception_cause_i                  :
                           load_misaligned_o      ? TRAP_CAUSE_LOAD_ADDR_MISALIGNED    :
                           store_misaligned_o     ? TRAP_CAUSE_STORE_ADDR_MISALIGNED   :
                           load_access_fault_o    ? TRAP_CAUSE_LOAD_ACCESS_FAULT       :
                           store_access_fault_o   ? TRAP_CAUSE_STORE_ACCESS_FAULT      :
                                                     TRAP_CAUSE_ILLEGAL_INSTR;

assign exception_tval_o  = exception_valid_i ? exception_tval_i :
                           mem_misaligned_o  ? alu_result_i     :
                           mem_access_fault_o ? alu_result_i    : '0;
```

注意：

- `lsu_re_o/lsu_we_o` 不建议反向被 `lsu_access_fault_i` 门控，否则容易形成 `mem_stage -> data_subsystem -> mem_stage` 的组合闭环。
- 未映射 store 的实际副作用由 `data_subsystem` 地址命中信号屏蔽，而不是由 `mem_stage` 关掉 `lsu_we_o`。
- `mem_stage` 只负责把 access fault 变成 precise trap。

### 5.5 `lsu_re_o/lsu_we_o` 保持现有门控 `已完成`

保持当前门控条件：

```systemverilog
assign lsu_re_o = valid_i & ~exception_valid_i & ~mem_misaligned_o & mem_re_i;
assign lsu_we_o = valid_i & ~exception_valid_i & ~mem_misaligned_o & mem_we_i;
```

理由：

- 前级已有 exception 或 misaligned 时，不应该向 data subsystem 发起真实访问。
- access fault 需要 data subsystem 根据地址译码得出，所以不能在发请求前就门控。
- data subsystem 对未命中地址不写任何 RAM/MMIO，只返回 access fault。

## 6. 新增 `rtl/soc/rv32i_soc.sv` `已完成`

### 6.1 模块职责

`rv32i_soc` 是当前最小平台顶层，不替代 `core` 的 CPU core 职责。

职责：

- 实例化 `core`。
- 实例化 `simple_rom` 作为 IMEM。
- 实例化 `data_subsystem` 作为 DMEM/MMIO 数据侧。
- 把 `data_subsystem.core_access_fault_o` 接回 `core.lsu_access_fault_i`。
- 导出 commit/trap 观察信号给 testbench。
- 导出 UART/GPIO/data access 观察信号给 testbench。

### 6.2 建议端口

```systemverilog
module rv32i_soc (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic [31:0]               gpio0_in_i,
    output logic [31:0]               gpio0_out_o,
    output logic [31:0]               gpio0_oe_o,

    output logic                      uart0_tx_valid_o,
    output logic [7:0]                uart0_tx_data_o,

    output logic                      data_re_o,
    output logic                      data_we_o,
    output logic [3:0]                data_be_o,
    output logic [core_pkg::XLEN-1:0] data_addr_o,
    output logic [core_pkg::XLEN-1:0] data_wdata_o,
    output logic                      data_access_fault_o,
    output logic                      dmem_access_o,
    output logic                      mmio_access_o,

    output logic                      commit_valid_o,
    output logic [core_pkg::XLEN-1:0] commit_pc_o,
    output logic [core_pkg::ILEN-1:0] commit_instr_o,
    output core_pkg::instr_id_e       commit_instr_id_o,
    output logic                      commit_reg_we_o,
    output logic [4:0]                commit_rd_addr_o,
    output logic [core_pkg::XLEN-1:0] commit_rd_wdata_o,

    output logic                      trap_valid_o,
    output logic [core_pkg::XLEN-1:0] trap_pc_o,
    output core_pkg::trap_cause_e     trap_cause_o,
    output logic [core_pkg::XLEN-1:0] trap_tval_o,
    output logic                      trap_return_o,
    output logic [core_pkg::XLEN-1:0] trap_redirect_pc_o
);
```

说明：

- `data_*` 是 testbench 观察口，来自 core 的 data access request。
- `dmem_access_o/mmio_access_o` 用于区分统计和 debug。
- `gpio0_in_i` 第一版 testbench 可以固定为某个常量，例如 `32'hA5A5_5A5A`。

### 6.3 core 连接

### 6.4 rom 连接

### 6.5 data_subsystem 连接

---

# 以下开始 SoC 仿真平台和定向测试入口

## 7. 新增 SoC-level testbench

### 7.1 保留 core-level regression

`tb/sv/tb_core_pipeline5.sv` 暂时保留为 core-only 回归入口：

```text
tb_core_pipeline5
    |-> core
    |-> simple_rom
    |-> simple_ram
```

原因：

- 它已经能覆盖 RV32I 主路径、CSR/trap、pipeline hazard 和既有 C/ASM 回归。
- core-only 回归可以证明 SoC 集成和外设修改没有破坏 CPU core 本身。
- 旧的 `sim/pipeline5_asm`、`sim/pipeline5_c` 流程可以继续服务 core 回归；如果脚本已经统一包含 `rtl/periph/*.sv`、`rtl/soc/*.sv`，也不影响 core-only top。

### 7.2 新增 `tb/sv/tb_rv32i_soc.sv`

新增 SoC-level testbench：

```text
tb_rv32i_soc
    |
    v
rv32i_soc
    |-> core
    |-> simple_rom
    |-> data_subsystem
            |-> simple_ram
            |-> mmio_uart
            |-> mmio_gpio
```

职责：

- 实例化 `rv32i_soc`。
- 继续使用 `+imem=<path>`、`+dmem=<path>` 加载镜像；ROM/RAM 在 SoC 层级内部，plusarg 机制不需要改变。
- 保留 PASS/FAIL 状态字：`DMEM_BASE + 0x100` 仍是自动结束条件。
- 观察 commit/trap/MRET trace。
- 观察 data access、DMEM/MMIO 命中、access fault。
- 驱动 GPIO 输入，观察 GPIO 输出。
- 收集 UART TX event，并可打印字符或按测试期望比对字符串。

### 7.3 `tb_rv32i_soc` 基本信号

建议新增：

```systemverilog
logic [31:0] gpio0_in;
logic [31:0] gpio0_out;
logic [31:0] gpio0_oe;

logic        uart0_tx_valid;
logic [7:0]  uart0_tx_data;

logic                      data_re;
logic                      data_we;
logic [3:0]                data_be;
logic [core_pkg::XLEN-1:0] data_addr;
logic [core_pkg::XLEN-1:0] data_wdata;
logic [core_pkg::XLEN-1:0] data_rdata;
logic                      data_access_fault;
logic                      dmem_access;
logic                      mmio_access;
```

`gpio0_in` 第一版可以给固定值，也可以在测试中按 cycle 或事件驱动变化：

```systemverilog
assign gpio0_in = 32'hA5A5_5A5A;
```

后续做 GPIO external interrupt 时，`gpio0_in` 不再固定，而由 testbench 在指定时间拉高/拉低或产生边沿。

### 7.4 UART/GPIO 观察

UART TX event 建议单独打印，避免和 commit trace 混在一起：

```systemverilog
always_ff @(posedge clk) begin
    if (rst_n && uart0_tx_valid) begin
        $display("[UART] 0x%02h '%c'", uart0_tx_data, uart0_tx_data);
    end
end
```

如果某个测试需要比对字符串，testbench 可以把 `uart0_tx_data` 收进 byte queue 或定长数组，最后和期望字符串比较。

GPIO 观察至少覆盖：

- `gpio0_out` 是否等于软件写入的 OUT。
- `gpio0_oe` 是否等于软件写入的 OE。
- 软件读 `GPIO_IN` 时，返回值是否来自 testbench 驱动的 `gpio0_in`。

### 7.5 PASS/FAIL 检测

SoC TB 仍用 DMEM 状态字作为统一 PASS/FAIL：

```systemverilog
localparam logic [core_pkg::XLEN-1:0] TEST_STATUS_ADDR = core_pkg::DMEM_BASE + 32'h100;
```

检测口径：

```systemverilog
if (data_we && dmem_access && data_addr == TEST_STATUS_ADDR) begin
    test_passed       <= (data_wdata == TEST_PASS_VALUE);
    test_status_value <= data_wdata;
end
```

说明：

- PASS/FAIL 不急着改到 MMIO，避免把“测试结束机制”和“外设功能验证”绑在一起。
- `dmem_access` 来自 `data_subsystem` 的真实译码结果，比只看地址范围更贴近当前 SoC 行为。

### 7.6 DMEM/stack 统计

SoC TB 的 DMEM 访问统计建议使用：

```systemverilog
wire dmem_access_for_stats = rst_n
                           && dmem_access
                           && (data_re || data_we)
                           && (data_addr != TEST_STATUS_ADDR);
```

`current_sp` 层级路径应从 core-only TB 的：

```systemverilog
u_core.u_regfile.gpr_q[2]
```

改为 SoC TB 中的：

```systemverilog
u_soc.u_core.u_regfile.gpr_q[2]
```

### 7.7 trap/commit trace

`rv32i_soc` 已透传 commit/trap 观察信号，SoC TB 可以复用原有提交打印格式。

建议在 trap 打印中保留：

- `trap_valid`
- `trap_pc`
- `trap_cause`
- `trap_tval`
- `trap_redirect_pc`
- `trap_return`

这样后续 0833 interrupt 测试可以直接观察 `mcause` 高位 interrupt 标志、返回 PC 和 handler 执行过程。

## 8. 新增 SoC 仿真脚本

### 8.1 保留现有 pipeline5 脚本

`sim/pipeline5_asm` 和 `sim/pipeline5_c` 继续作为 core-level 回归入口。

如果这些脚本的 RTL 文件列表已经统一包含：

```bash
rtl/common/*.sv
rtl/core/*.sv
rtl/mem/*.sv
rtl/periph/*.sv
rtl/soc/*.sv
```

可以保留；如果仍只包含 core/mem，也不影响 core-only 回归，但后续 SoC 脚本必须包含 `rtl/periph/*.sv` 和 `rtl/soc/*.sv`。

### 8.2 新增 `sim/soc_asm/run_test.sh`

建议新增 SoC ASM 测试入口：

```text
sim/soc_asm/run_test.sh <test>
```

职责：

- 根据测试名编译 `sw/asm/<test>.S`。
- 生成 IMEM/DMEM mem 文件。
- 编译并运行 `tb/sv/tb_rv32i_soc.sv`。
- RTL 文件列表包含 `rtl/common/*.sv`、`rtl/core/*.sv`、`rtl/mem/*.sv`、`rtl/periph/*.sv`、`rtl/soc/*.sv`。
- top module 使用 `tb_rv32i_soc`。

### 8.3 新增 `sim/soc_c/run_test.sh`

建议新增 SoC C 测试入口：

```text
sim/soc_c/run_test.sh <test>
```

职责：

- 复用当前 C bare-metal 编译、链接、objcopy、mem 生成流程。
- 增加 `-I sw/include`，便于 C 程序包含 `platform.h`。
- 编译并运行 `tb/sv/tb_rv32i_soc.sv`。
- top module 使用 `tb_rv32i_soc`。

### 8.4 `run_all.sh` 暂缓

SoC 测试集会随着 0832/0833/0834 持续扩展，不建议一开始把所有测试混到一个全局 `run_all.sh`。

可以等 SoC smoke、MMIO、access fault、interrupt、wait-state 分组稳定后，再分别做：

```text
sim/soc_asm/run_all.sh
sim/soc_c/run_all.sh
```

或者只维护分组脚本，避免“all”的含义频繁变化。

## 9. SoC directed test 规划

### 9.1 0832 当前测试

当前阶段先覆盖固定响应 MMIO 和 access fault：

| 编号 | 建议文件 | 目标 |
|---:|---|---|
| `0601` | `sw/asm/0601_soc_smoke.S` | 旧主路径程序通过 `rv32i_soc` 跑通，证明 SoC wrapper 不破坏 core |
| `0602` | `sw/asm/0602_uart_tx.S` | 软件开启 UART，写 `TXDATA`，testbench 观察 TX event |
| `0603` | `sw/asm/0603_gpio_rw.S` | 写 `GPIO_OUT/OE`，读 `GPIO_IN`，验证普通 RW/RO MMIO |
| `0604` | `sw/asm/0604_mmio_access_fault.S` | 访问未实现 MMIO/保留区，检查 load/store access fault |
| `0605` | `sw/asm/0605_mmio_misaligned_priority.S` | MMIO 不对齐访问优先报 misaligned，不报 access fault |
| `0606` | `sw/asm/0606_wrong_path_mmio.S` | branch/trap wrong-path store 不应触发 UART/GPIO 副作用 |
| `0651` | `sw/c/0651_soc_mmio_smoke.c` | C 程序通过 `platform.h` 访问 UART/GPIO，做 MMIO 冒烟 |

说明：

- 0832 的测试重点是地址译码、副作用门控、MMIO 观察和 access fault。
- 异常测试可以继续使用 trap handler 写 DMEM PASS/FAIL。
- C 测试不需要覆盖所有异常，重点展示软件驱动风格和 `volatile` MMIO 访问。

### 9.2 0833 interrupt/timer 测试预留

后续 0833 加 machine interrupt 与 timer 后，继续复用 `tb_rv32i_soc`。

建议测试：

| 编号 | 建议文件 | 目标 |
|---:|---|---|
| `0701` | `sw/asm/0701_timer_irq_smoke.S` | 配置 timer compare，打开 `mie.MTIE/mstatus.MIE`，进入 timer interrupt handler |
| `0702` | `sw/asm/0702_gpio_irq_smoke.S` | testbench 驱动 `gpio0_in_i` 产生事件，进入 machine external interrupt handler |
| `0703` | `sw/asm/0703_irq_mask.S` | pending 已有但 enable/global MIE 未开时不进入；打开后进入 |
| `0704` | `sw/asm/0704_irq_mret.S` | interrupt handler 执行 `MRET` 后回到被打断程序继续执行 |
| `0705` | `sw/asm/0705_exception_over_irq.S` | 同边界有同步 exception 和 pending interrupt 时，同步 exception 优先 |
| `0751` | `sw/c/0751_irq_smoke.c` | C handler 处理一次 timer 或 GPIO interrupt 冒烟 |

GPIO external interrupt 的推荐仿真模型：

```text
tb 驱动 gpio0_in_i 边沿或电平
    -> mmio_gpio 置 pending
    -> gpio_irq_o
    -> SoC 汇总为 core interrupt 输入
    -> core 在提交边界接受 machine external interrupt
    -> handler 读 cause / 清 pending / mret
```

interrupt 测试不应要求“事件发生后固定第 N 拍进入 handler”。更稳妥的检查是：在 pending 和 enable 都满足后，有限时间内必须进入 handler，并且 `mepc/mcause/mtval/MRET` 行为正确。

### 9.3 0834 wait-state/backpressure 测试预留

后续 0834 加 ready/valid 或简化 bus response 后，仍以 SoC TB 为入口扩展：

| 建议方向 | 目标 |
|---|---|
| DMEM load 延迟 | load 等待期间流水线 stall，不丢指令 |
| MMIO store 延迟 | 等待期间不能重复触发 UART/GPIO 副作用 |
| MMIO load 延迟 | 返回数据只写回一次，load-use stall/backpressure 行为正确 |
| response error 延迟 | access fault 随 response 返回后进入 trap |
| trap/redirect 与 wait 同时存在 | 优先级稳定，wrong-path 无副作用 |

这一阶段可以开始把 SoC TB 中的观察逻辑沉淀成 monitor/scoreboard。即使后续上 UVM，也可以复用同一套观察点：

- commit monitor
- trap monitor
- data bus/MMIO monitor
- UART monitor
- GPIO monitor

## 10. 软件可见常量

### 10.1 新增 C 侧 platform header

建议新增：

```text
sw/include/platform.h
```

第一版内容包含地址常量和简单 MMIO 访问函数：

```c
#ifndef PLATFORM_H
#define PLATFORM_H

#define IMEM_BASE       0x00000000u
#define DMEM_BASE       0x00040000u
#define MMIO_BASE       0x00080000u

#define GPIO0_BASE      0x00080000u
#define GPIO_OUT        (GPIO0_BASE + 0x00u)
#define GPIO_IN         (GPIO0_BASE + 0x04u)
#define GPIO_OE         (GPIO0_BASE + 0x08u)

#define UART0_BASE      0x00082000u
#define UART_TXDATA     (UART0_BASE + 0x00u)
#define UART_STATUS     (UART0_BASE + 0x04u)
#define UART_CTRL       (UART0_BASE + 0x08u)

static inline void mmio_write32(unsigned int addr, unsigned int value) {
    *(volatile unsigned int *)addr = value;
}

static inline unsigned int mmio_read32(unsigned int addr) {
    return *(volatile unsigned int *)addr;
}

#endif
```

说明：

- C 测试后续包含这个头文件访问 UART/GPIO。
- 当前编译脚本若还没有 include path，需要后续测试阶段补 `-I sw/include`；本阶段可以先把头文件建好，也可以等写 C 测试时一起补脚本。

### 10.2 ASM 侧公共 include 暂缓

手写汇编可以后续新增：

```text
sw/asm/include/platform.inc
```

但本阶段先不强制做，避免影响现有 asm 构建脚本。

后续写 MMIO asm 测试时再决定是每个 `.S` 内写 `.equ`，还是统一 include。

## 11. 文档同步

### 11.1 同步 `sw/linker/readme.md`

需要补充 MMIO window：

| 区域 | 起始地址 | 结束地址 | 大小 | 用途 |
|---|---:|---:|---:|---|
| MMIO | `0x0008_0000` | `0x0008_FFFF` | 64 KiB | UART/GPIO/TIMER/ACCEL MMIO window |

并增加外设寄存器表：

| 外设 | base | 当前状态 |
|---|---:|---|
| GPIO0 | `0x0008_0000` | 已实现 OUT/IN/OE |
| TIMER0 | `0x0008_1000` | 地址预留，访问 fault |
| UART0 | `0x0008_2000` | 已实现 TXDATA/STATUS/CTRL |
| ACCEL0 | `0x0008_8000` | 地址预留，访问 fault |

### 11.2 同步 README 和 simulation flow 文档

需要后续同步：

- `README.md`
  - 保留 core-level 回归入口。
  - 新增 SoC-level 平台测试入口。
  - 支持最小 MMIO 和 access fault。
- `docs/simulation_flow_pipeline_asm.md`
  - 说明该流程仍用于 core-level regression。
- `docs/simulation_flow_pipeline_c.md`
  - 说明该流程仍用于 core-level regression。
- 后续新增的 SoC simulation flow 文档
  - 说明 `tb_rv32i_soc` 内部实例化 SoC wrapper。
  - 说明 UART/GPIO 输出观察口。
  - 说明 C 程序可包含 `sw/include/platform.h` 访问 MMIO。

本章只列同步项；具体文字可以在 RTL 完成后根据真实实现补。

## 12. 文件清单总览

### 12.1 新增文件

本阶段建议新增：

| 文件 | 作用 |
|---|---|
| `rtl/common/soc_pkg.sv` | SoC/MMIO 地址图和外设寄存器 offset |
| `rtl/periph/mmio_uart.sv` | UART0 最小 MMIO 寄存器块，当前只实现 TX |
| `rtl/periph/mmio_gpio.sv` | GPIO0 最小 MMIO 寄存器块 |
| `rtl/soc/data_subsystem.sv` | data address decode、DMEM/MMIO mux、access fault 汇总 |
| `rtl/soc/rv32i_soc.sv` | 最小平台 wrapper |
| `tb/sv/tb_rv32i_soc.sv` | SoC-level directed testbench |
| `sim/soc_asm/run_test.sh` | SoC ASM 定向测试入口 |
| `sim/soc_c/run_test.sh` | SoC C 定向测试入口 |
| `sw/include/platform.h` | C 侧 MMIO 地址常量和访问函数 |

目录若不存在，需要新增：

```text
rtl/periph/
rtl/soc/
sim/soc_asm/
sim/soc_c/
sw/include/
```

### 12.2 修改文件

本阶段预计修改：

| 文件 | 修改内容 |
|---|---|
| `rtl/common/core_pkg.sv` | 移出 MMIO/外设地址常量；保留 IMEM/DMEM/reset/trap 默认入口；新增 access fault trap cause |
| `rtl/core/core.sv` | 由 `core_pipeline5.sv` 改名而来；模块名从 `core_pipeline5` 改为 `core`；数据访问端口从 `dmem_*` 改名为 `lsu_*`；新增 `lsu_access_fault_i` 并连接到 `mem_stage` |
| `rtl/core/mem_stage.sv` | 合并 load/store access fault exception |
| `tb/sv/tb_core_pipeline5.sv` | 只做 core 模块名和 `lsu_*` 端口适配，继续作为 core-only TB |
| `sim/pipeline5_asm/06_run_sim.sh` | 可保留 core-only 流程；若已统一 RTL 文件列表，包含 `rtl/periph/*.sv`、`rtl/soc/*.sv` 也可以 |
| `sim/pipeline5_c/06_run_sim.sh` | 可保留 core-only 流程；若已统一 RTL 文件列表，包含 `rtl/periph/*.sv`、`rtl/soc/*.sv` 也可以 |
| `sw/linker/readme.md` | 补 MMIO window 和外设地址说明 |
| `README.md` | 补当前平台支持 MMIO/access fault |
| `docs/simulation_flow_pipeline_asm.md` | 说明该流程仍是 core-level regression，SoC 测试走 `sim/soc_asm` |
| `docs/simulation_flow_pipeline_c.md` | 说明该流程仍是 core-level regression，SoC 测试走 `sim/soc_c` |

### 12.3 不应修改的核心文件

正常情况下，本阶段不需要修改：

| 文件 | 原因 |
|---|---|
| `rtl/common/pipeline_pkg.sv` | 不新增流水线寄存器字段 |
| `rtl/core/decoder.sv` | MMIO 是 load/store 地址语义，不是新指令 |
| `rtl/core/id_stage.sv` | 不新增译码控制 |
| `rtl/core/ex_stage.sv` | 地址仍由现有 ALU 计算 |
| `rtl/core/trap_ctrl.sv` | access fault 走现有 `mem_exception_*` 输入 |
| `rtl/core/csr_file.sv` | `mcause/mtval` 写入路径已存在 |
| `rtl/core/hazard_unit.sv` | 固定响应，无新 stall |
| `rtl/core/forwarding_unit.sv` | MMIO load 仍走 `WB_MEM`，不新增 forwarding 类型 |

如果实现过程中发现必须修改这些文件，需要先确认是不是把 MMIO 语义放错层级。
