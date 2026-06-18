# v3.0 最小 memory map 与 MMIO 执行计划

当前五级流水线核已经完成 RV32I 主路径、CSR/trap、C runtime trap 入口和 256 KiB IMEM/DMEM 地址图。本计划根据 `docs/08xx/0832 最小memory map与MMIO外设规划.md` 编写，把第二阶段拆成可直接施工的 RTL/工程步骤。

本计划只写实现拆分，暂不写测试程序、回归命令和后续问题记录；这些内容后续需要时再补。

## 0. 实现边界

本阶段目标：

- 保持 `core_pipeline5.sv` 作为 CPU core，不在 core 内部实例化 RAM 或外设。
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
- 后续 0833/0834 增加 timer/interrupt/wait-state 时，优先在这个平台层扩展，不污染 `core_pipeline5` 的 CPU 微架构边界。

目标结构：

```text
tb_core_pipeline5
    |
    v
rv32i_soc
    |-> core_pipeline5
    |-> simple_rom
    |-> data_subsystem
            |-> simple_ram
            |-> mmio_uart
            |-> mmio_gpio
            |-> access fault
```

说明：

- `core_pipeline5` 仍暴露 `imem_*` 和 `dmem_*` 风格接口。
- `dmem_*` 在 core 边界继续沿用现有命名，但语义上变成 data access request，不再等价于“只访问 simple_ram”。
- `data_subsystem` 根据地址决定访问 DMEM、UART、GPIO，或返回 access fault。

## 1. 公共类型和地址常量 `已完成`

### 1.1 修改 `rtl/common/core_pkg.sv`

新增 MMIO 总窗口常量：

```systemverilog
parameter logic [XLEN-1:0] MMIO_BASE       = 32'h0008_0000;
parameter logic [XLEN-1:0] MMIO_SIZE_BYTES = 32'h0001_0000;
```

当前地址图应保持：

| 区域 | 起始地址 | 结束地址 | 大小 |
|---|---:|---:|---:|
| IMEM | `0x0000_0000` | `0x0003_FFFF` | 256 KiB |
| DMEM | `0x0004_0000` | `0x0007_FFFF` | 256 KiB |
| MMIO | `0x0008_0000` | `0x0008_FFFF` | 64 KiB |

新增外设窗口常量：

```systemverilog
parameter logic [XLEN-1:0] GPIO_BASE         = 32'h0008_0000;
parameter logic [XLEN-1:0] GPIO_SIZE_BYTES   = 32'h0000_0400;
parameter logic [XLEN-1:0] GPIO_STRIDE       = 32'h0000_0100;
parameter int unsigned     GPIO_NUM          = 4;

parameter logic [XLEN-1:0] TIMER_BASE        = 32'h0008_1000;
parameter logic [XLEN-1:0] TIMER_SIZE_BYTES  = 32'h0000_0600;
parameter logic [XLEN-1:0] TIMER_STRIDE      = 32'h0000_0100;
parameter int unsigned     TIMER_NUM         = 6;

parameter logic [XLEN-1:0] UART_BASE         = 32'h0008_2000;
parameter logic [XLEN-1:0] UART_SIZE_BYTES   = 32'h0000_0600;
parameter logic [XLEN-1:0] UART_STRIDE       = 32'h0000_0100;
parameter int unsigned     UART_NUM          = 6;

parameter logic [XLEN-1:0] ACCEL_BASE       = 32'h0008_8000;
parameter logic [XLEN-1:0] ACCEL_SIZE_BYTES = 32'h0000_4000;
parameter logic [XLEN-1:0] ACCEL_STRIDE     = 32'h0000_1000;
parameter int unsigned     ACCEL_NUM        = 4;

parameter logic [XLEN-1:0] GPIO0_BASE       = GPIO_BASE;
parameter logic [XLEN-1:0] GPIO0_SIZE_BYTES = GPIO_STRIDE;

parameter logic [XLEN-1:0] TIMER0_BASE       = TIMER_BASE;
parameter logic [XLEN-1:0] TIMER0_SIZE_BYTES = TIMER_STRIDE;

parameter logic [XLEN-1:0] UART0_BASE       = UART_BASE;
parameter logic [XLEN-1:0] UART0_SIZE_BYTES = UART_STRIDE;

parameter logic [XLEN-1:0] ACCEL0_BASE       = ACCEL_BASE;
parameter logic [XLEN-1:0] ACCEL0_SIZE_BYTES = ACCEL_STRIDE;
```

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

新增 UART0 offset 常量：

```systemverilog
parameter logic [11:0] UART_TXDATA_OFFSET = 12'h000;
parameter logic [11:0] UART_STATUS_OFFSET = 12'h004;
parameter logic [11:0] UART_CTRL_OFFSET   = 12'h008;
```

新增 GPIO0 offset 常量：

```systemverilog
parameter logic [11:0] GPIO_OUT_OFFSET = 12'h000;
parameter logic [11:0] GPIO_IN_OFFSET  = 12'h004;
parameter logic [11:0] GPIO_OE_OFFSET  = 12'h008;
```

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
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = core_pkg::UART0_BASE,
    parameter logic [core_pkg::XLEN-1:0] SIZE_BYTES = core_pkg::UART0_SIZE_BYTES
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
- 未知 offset 不更新任何寄存器，`access_fault_o = valid_i`。

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
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = core_pkg::GPIO0_BASE,
    parameter logic [core_pkg::XLEN-1:0] SIZE_BYTES = core_pkg::GPIO0_SIZE_BYTES
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

    input  logic [31:0]               gpio_in_i,
    output logic [31:0]               gpio_out_o,
    output logic [31:0]               gpio_oe_o
);
```

寄存器规划：

| offset | 名称 | 属性 | 行为 |
|---:|---|---|---|
| `0x00` | `OUT` | RW | 保存 GPIO 输出值 |
| `0x04` | `IN` | RO | 返回 `gpio_in_i` |
| `0x08` | `OE` | RW | 保存 GPIO 输出使能 |

写行为：

- 写 `OUT/OE` 时按 `be_i` 更新 byte lane。
- 写 `IN` 忽略，不产生 access fault。
- 未知 offset 不更新任何寄存器，`access_fault_o = valid_i`。

byte lane 更新建议封装成局部函数或局部 `always_comb`，避免重复写四段逻辑也可以；如果直接展开，也要和 `simple_ram` 的 byte lane 风格保持一致。

### 2.3 外设模块注释口径 `已完成`

文件头注释要说明：

- 当前是固定响应 MMIO register block。
- 没有 ready/valid backpressure。
- `valid_i` 表示地址已经命中该外设窗口。
- `access_fault_o` 只表示外设窗口内 offset 不存在，不负责判断整个地址是否命中外设。
- 真正未映射地址由 `data_subsystem` 汇总判断。

## 3. 新增 `rtl/soc/data_subsystem.sv` `执行中`

### 3.1 模块职责

`data_subsystem` 是 core data access 和具体数据设备之间的固定响应译码层。

职责：

- 接收 `core_pipeline5` 的 `dmem_*` request。
- 判断地址命中 DMEM、UART0、GPIO0，还是未映射。
- 实例化 `simple_ram`、`mmio_uart`、`mmio_gpio`。
- 对 store，只把写使能送到命中的设备。
- 对 load，返回命中设备的 32-bit `rdata`。
- 对未映射 load/store，返回 `access_fault_o = 1`，读数据返回 0。
- 暴露 UART/GPIO 观察信号给 SoC/testbench。

### 3.2 建议端口

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

    input  logic [31:0]               gpio_in_i,
    output logic [31:0]               gpio_out_o,
    output logic [31:0]               gpio_oe_o,

    output logic                      uart_tx_valid_o,
    output logic [7:0]                uart_tx_data_o,

    output logic                      dmem_access_o,
    output logic                      mmio_access_o
);
```

说明：

- `core_re_i/core_we_i` 来自 `core_pipeline5.dmem_re_o/dmem_we_o`。
- `core_access_fault_o` 接回 `core_pipeline5.dmem_access_fault_i`。
- `dmem_access_o/mmio_access_o` 只是观察信号，给 testbench 做统计或波形 debug。

### 3.3 地址命中判断

建议写辅助 hit 信号：

```systemverilog
wire access_valid = core_re_i | core_we_i;

wire dmem_hit  = access_valid
               & (core_addr_i >= core_pkg::DMEM_BASE)
               & (core_addr_i <  core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES);

wire uart_hit  = access_valid
               & (core_addr_i >= core_pkg::UART0_BASE)
               & (core_addr_i <  core_pkg::UART0_BASE + core_pkg::UART0_SIZE_BYTES);

wire gpio_hit  = access_valid
               & (core_addr_i >= core_pkg::GPIO0_BASE)
               & (core_addr_i <  core_pkg::GPIO0_BASE + core_pkg::GPIO0_SIZE_BYTES);
```

`GPIO1-31/UART1-15/TIMER0-15/ACCEL0` 本阶段不作为 hit：

- 地址常量可以存在。
- 不实例化对应外设。
- 命中预留窗口仍视为未映射，产生 access fault。

### 3.4 simple_ram 安全地址

`simple_ram` 内部会根据 `addr_i - DMEM_BASE` 计算 word index。为了避免 MMIO/未映射地址让 RAM 内部出现无意义索引，建议给 RAM 一个安全地址：

```systemverilog
wire [core_pkg::XLEN-1:0] ram_addr = dmem_hit ? core_addr_i : core_pkg::DMEM_BASE;
wire                      ram_we   = core_we_i & dmem_hit;
```

实例化：

```systemverilog
simple_ram u_simple_ram (
    .clk_i   (clk_i),
    .we_i    (ram_we),
    .be_i    (core_be_i),
    .addr_i  (ram_addr),
    .wdata_i (core_wdata_i),
    .rdata_o (ram_rdata)
);
```

说明：

- `simple_ram` 仍用 `+dmem=<path>` 初始化。
- RAM read 没有读使能，未命中时给安全地址即可。
- DMEM 访问统计不要依赖 RAM 内部读口，应在 testbench 用 `dmem_access_o` 或地址范围判断。

### 3.5 外设 access fault 合并

UART/GPIO 模块各自输出 offset 是否非法：

```systemverilog
logic uart_access_fault;
logic gpio_access_fault;
```

最终 fault：

```systemverilog
assign core_access_fault_o = access_valid
                           & ( (~dmem_hit & ~uart_hit & ~gpio_hit)
                             | (uart_hit & uart_access_fault)
                             | (gpio_hit & gpio_access_fault) );
```

说明：

- 地址未命中任何已实现设备：fault。
- 命中 UART/GPIO 窗口但 offset 不存在：fault。
- 命中 RO 寄存器并执行 store 是否 fault 由外设模块决定；本计划建议 RO 写忽略，不产生 fault，先保持 MMIO 语义简单。

### 3.6 读数据 mux

```systemverilog
always_comb begin
    core_rdata_o = '0;
    if (dmem_hit) begin
        core_rdata_o = ram_rdata;
    end else if (uart_hit) begin
        core_rdata_o = uart_rdata;
    end else if (gpio_hit) begin
        core_rdata_o = gpio_rdata;
    end
end
```

未映射地址读返回 0，同时 `core_access_fault_o = 1`。最终不会正常写回 GPR，因为 access fault 会在 MEM 边界被 trap 接受，`kill_mem_wb` 会阻止 faulting load 进入普通 WB。

## 4. 扩展 core 数据访问错误通路

### 4.1 修改 `rtl/core/core_pipeline5.sv` 端口

保留现有 `dmem_*` 端口：

```systemverilog
output logic                      dmem_re_o,
output logic                      dmem_we_o,
output logic [3:0]                dmem_be_o,
output logic [core_pkg::XLEN-1:0] dmem_addr_o,
output logic [core_pkg::XLEN-1:0] dmem_wdata_o,
input  logic [core_pkg::XLEN-1:0] dmem_rdata_i,
```

新增 data access fault 输入：

```systemverilog
input logic dmem_access_fault_i,  // 当前 dmem_* 访问命中未映射或非法 data 地址。
```

命名暂时沿用 `dmem_` 前缀，避免大规模重命名。头注释需要说明：

- 这些端口在 core 边界是 data access bus。
- 外部可以把它接到 RAM，也可以接到包含 RAM/MMIO 的 data subsystem。
- `dmem_access_fault_i` 只表示 data load/store 访问错误，不表示指令取指错误。

### 4.2 修改 `rtl/core/mem_stage.sv` 端口

新增输入：

```systemverilog
input logic dmem_access_fault_i, // 当前有效 load/store 地址没有命中已实现 data region。
```

新增观察输出，方便波形和后续 testbench：

```systemverilog
output logic load_access_fault_o,
output logic store_access_fault_o,
```

`core_pipeline5.sv` 里可以先接到内部 wire，暂不导出顶层。

### 4.3 修改 `core_pipeline5.sv` 中 `mem_stage` 实例连接

`u_mem_stage` 新增连接：

```systemverilog
.dmem_access_fault_i (dmem_access_fault_i),
.load_access_fault_o (mem_load_access_fault),
.store_access_fault_o(mem_store_access_fault),
```

`mem_load_access_fault/mem_store_access_fault` 可作为内部 wire，暂时不导出 `core_pipeline5`。

### 4.4 `mem_stage` access fault 判断

新增组合信号：

```systemverilog
wire mem_access_fault = valid_i
                      & (mem_re_i | mem_we_i)
                      & dmem_access_fault_i;

assign load_access_fault_o  = valid_i & mem_re_i & mem_access_fault;
assign store_access_fault_o = valid_i & mem_we_i & mem_access_fault;
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
                         | mem_access_fault;

assign exception_cause_o = exception_valid_i      ? exception_cause_i                  :
                           load_misaligned_o      ? TRAP_CAUSE_LOAD_ADDR_MISALIGNED    :
                           store_misaligned_o     ? TRAP_CAUSE_STORE_ADDR_MISALIGNED   :
                           load_access_fault_o    ? TRAP_CAUSE_LOAD_ACCESS_FAULT       :
                           store_access_fault_o   ? TRAP_CAUSE_STORE_ACCESS_FAULT      :
                                                     TRAP_CAUSE_ILLEGAL_INSTR;

assign exception_tval_o  = exception_valid_i ? exception_tval_i :
                           mem_misaligned_o  ? alu_result_i     :
                           mem_access_fault  ? alu_result_i     : '0;
```

注意：

- `dmem_re_o/dmem_we_o` 不建议反向被 `dmem_access_fault_i` 门控，否则容易形成 `mem_stage -> data_subsystem -> mem_stage` 的组合闭环。
- 未映射 store 的实际副作用由 `data_subsystem` 地址命中信号屏蔽，而不是由 `mem_stage` 关掉 `dmem_we_o`。
- `mem_stage` 只负责把 access fault 变成 precise trap。

### 4.5 `dmem_re_o/dmem_we_o` 保持现有门控

保持当前门控条件：

```systemverilog
assign dmem_re_o = valid_i & ~exception_valid_i & ~mem_misaligned_o & mem_re_i;
assign dmem_we_o = valid_i & ~exception_valid_i & ~mem_misaligned_o & mem_we_i;
```

理由：

- 前级已有 exception 或 misaligned 时，不应该向 data subsystem 发起真实访问。
- access fault 需要 data subsystem 根据地址译码得出，所以不能在发请求前就门控。
- data subsystem 对未命中地址不写任何 RAM/MMIO，只返回 access fault。

## 5. 新增 `rtl/soc/rv32i_soc.sv`

### 5.1 模块职责

`rv32i_soc` 是当前最小平台顶层，不替代 `core_pipeline5` 的 CPU core 职责。

职责：

- 实例化 `core_pipeline5`。
- 实例化 `simple_rom` 作为 IMEM。
- 实例化 `data_subsystem` 作为 DMEM/MMIO 数据侧。
- 把 `data_subsystem.core_access_fault_o` 接回 `core_pipeline5.dmem_access_fault_i`。
- 导出 commit/trap 观察信号给 testbench。
- 导出 UART/GPIO/data access 观察信号给 testbench。

### 5.2 建议端口

```systemverilog
module rv32i_soc (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic [31:0]               gpio_in_i,
    output logic [31:0]               gpio_out_o,
    output logic [31:0]               gpio_oe_o,

    output logic                      uart_tx_valid_o,
    output logic [7:0]                uart_tx_data_o,

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
- `gpio_in_i` 第一版 testbench 可以固定为某个常量，例如 `32'hA5A5_5A5A`。

### 5.3 core 连接

`rv32i_soc` 内部连线：

```systemverilog
logic [core_pkg::ILEN-1:0] core_imem_rdata;
logic [core_pkg::XLEN-1:0] core_imem_addr;

logic                      core_dmem_re;
logic                      core_dmem_we;
logic [3:0]                core_dmem_be;
logic [core_pkg::XLEN-1:0] core_dmem_addr;
logic [core_pkg::XLEN-1:0] core_dmem_wdata;
logic [core_pkg::XLEN-1:0] core_dmem_rdata;
logic                      core_dmem_access_fault;
```

连接 `core_pipeline5`：

```systemverilog
.imem_rdata_i        (core_imem_rdata),
.imem_addr_o         (core_imem_addr),
.dmem_re_o           (core_dmem_re),
.dmem_we_o           (core_dmem_we),
.dmem_be_o           (core_dmem_be),
.dmem_addr_o         (core_dmem_addr),
.dmem_wdata_o        (core_dmem_wdata),
.dmem_rdata_i        (core_dmem_rdata),
.dmem_access_fault_i (core_dmem_access_fault),
```

### 5.4 simple_rom 连接

```systemverilog
simple_rom u_simple_rom (
    .addr_i  (core_imem_addr),
    .rdata_o (core_imem_rdata)
);
```

仍由 `+imem=<path>` 初始化，不需要 SoC 顶层新增文件路径端口。

### 5.5 data_subsystem 连接

```systemverilog
data_subsystem u_data_subsystem (
    .clk_i                 (clk_i),
    .rst_n_i               (rst_n_i),

    .core_re_i             (core_dmem_re),
    .core_we_i             (core_dmem_we),
    .core_be_i             (core_dmem_be),
    .core_addr_i           (core_dmem_addr),
    .core_wdata_i          (core_dmem_wdata),
    .core_rdata_o          (core_dmem_rdata),
    .core_access_fault_o   (core_dmem_access_fault),

    .gpio_in_i             (gpio_in_i),
    .gpio_out_o            (gpio_out_o),
    .gpio_oe_o             (gpio_oe_o),

    .uart_tx_valid_o       (uart_tx_valid_o),
    .uart_tx_data_o        (uart_tx_data_o),

    .dmem_access_o         (dmem_access_o),
    .mmio_access_o         (mmio_access_o)
);
```

### 5.6 观察口赋值

把 core data request 导出：

```systemverilog
assign data_re_o           = core_dmem_re;
assign data_we_o           = core_dmem_we;
assign data_be_o           = core_dmem_be;
assign data_addr_o         = core_dmem_addr;
assign data_wdata_o        = core_dmem_wdata;
assign data_access_fault_o = core_dmem_access_fault;
```

commit/trap 观察信号直接透传 `core_pipeline5` 输出。

## 6. 适配 `tb/sv/tb_core_pipeline5.sv`

### 6.1 实例化对象从 core 改为 SoC

当前 testbench 直接实例化：

```systemverilog
core_pipeline5 u_core (...);
simple_rom u_simple_rom (...);
simple_ram u_simple_ram (...);
```

本阶段改为：

```systemverilog
rv32i_soc u_soc (...);
```

删除 testbench 中直接实例化 `simple_rom/simple_ram` 的代码。

### 6.2 testbench 信号重命名

原有 `dmem_*` 观察信号可以改名为 `data_*`，或者保留局部名但注释改成 data access。

建议改成：

```systemverilog
logic                      data_re;
logic                      data_we;
logic [3:0]                data_be;
logic [core_pkg::XLEN-1:0] data_addr;
logic [core_pkg::XLEN-1:0] data_wdata;
logic                      data_access_fault;
logic                      dmem_access;
logic                      mmio_access;
```

SoC 连接：

```systemverilog
.data_re_o           (data_re),
.data_we_o           (data_we),
.data_be_o           (data_be),
.data_addr_o         (data_addr),
.data_wdata_o        (data_wdata),
.data_access_fault_o (data_access_fault),
.dmem_access_o       (dmem_access),
.mmio_access_o       (mmio_access),
```

### 6.3 GPIO/UART 观察信号

新增：

```systemverilog
logic [31:0] gpio_in;
logic [31:0] gpio_out;
logic [31:0] gpio_oe;
logic        uart_tx_valid;
logic [7:0]  uart_tx_data;
```

第一版可以固定：

```systemverilog
assign gpio_in = 32'hA5A5_5A5A;
```

UART 打印：

```systemverilog
always_ff @(posedge clk) begin
    if (rst_n && uart_tx_valid) begin
        $write("%c", uart_tx_data);
    end
end
```

如果担心 UART 字符和 commit trace 混在一起，可以打印成单独 trace：

```systemverilog
$display("[UART] 0x%02h '%c'", uart_tx_data, uart_tx_data);
```

具体格式后续做测试时再定，先保证能观察。

### 6.4 PASS/FAIL 检测改用 data access

原逻辑：

```systemverilog
else if (dmem_we && dmem_addr == TEST_STATUS_ADDR) begin
```

改为：

```systemverilog
else if (data_we && data_addr == TEST_STATUS_ADDR) begin
```

并使用：

```systemverilog
test_passed       <= (data_wdata == TEST_PASS_VALUE);
test_status_value <= data_wdata;
```

说明：

- PASS/FAIL 地址仍在 DMEM。
- 即使顶层变成 SoC wrapper，自动结束机制不变。

### 6.5 DMEM/stack 统计改用 DMEM 命中

原统计：

```systemverilog
wire dmem_access_for_stats = rst_n && (dmem_re || dmem_we) && (dmem_addr != TEST_STATUS_ADDR);
```

建议改为：

```systemverilog
wire dmem_access_for_stats = rst_n
                           && dmem_access
                           && (data_addr != TEST_STATUS_ADDR);
```

或者不依赖 SoC 输出，直接用地址范围：

```systemverilog
wire data_addr_in_dmem = (data_addr >= core_pkg::DMEM_BASE)
                       && (data_addr <  core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES);

wire dmem_access_for_stats = rst_n
                           && (data_re || data_we)
                           && data_addr_in_dmem
                           && (data_addr != TEST_STATUS_ADDR);
```

推荐使用 `dmem_access`，因为它来自 `data_subsystem` 的真实译码结果。

### 6.6 current_sp 层级路径调整

原路径：

```systemverilog
wire [core_pkg::XLEN-1:0] current_sp = u_core.u_regfile.gpr_q[2];
```

改为：

```systemverilog
wire [core_pkg::XLEN-1:0] current_sp = u_soc.u_core.u_regfile.gpr_q[2];
```

### 6.7 trap/commit trace 保持不变

commit/trap 观察信号由 `rv32i_soc` 透传，因此提交打印逻辑基本不需要改。

可在 `trap_valid` 打印中追加 cause/tval，后续测试阶段再决定是否改格式。本阶段只要求端口连接正确。

## 7. 修改仿真脚本 RTL 文件列表

### 7.1 修改 `sim/pipeline5_asm/06_run_sim.sh`

当前：

```bash
RTL_FILES=(
    rtl/common/*.sv
    rtl/core/*.sv
    rtl/mem/*.sv
)
```

改为：

```bash
RTL_FILES=(
    rtl/common/*.sv
    rtl/core/*.sv
    rtl/mem/*.sv
    rtl/periph/*.sv
    rtl/soc/*.sv
)
```

### 7.2 修改 `sim/pipeline5_c/06_run_sim.sh`

做同样修改：

```bash
RTL_FILES=(
    rtl/common/*.sv
    rtl/core/*.sv
    rtl/mem/*.sv
    rtl/periph/*.sv
    rtl/soc/*.sv
)
```

### 7.3 脚本 top-module 保持不变

`--top-module tb_core_pipeline5` 保持不变。

原因：

- testbench 文件名和模块名暂时不改，减少脚本影响。
- testbench 内部从实例化 `core_pipeline5` 改成实例化 `rv32i_soc`。

## 8. 软件可见常量

### 8.1 新增 C 侧 platform header

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

### 8.2 ASM 侧公共 include 暂缓

手写汇编可以后续新增：

```text
sw/asm/include/platform.inc
```

但本阶段先不强制做，避免影响现有 asm 构建脚本。

后续写 MMIO asm 测试时再决定是每个 `.S` 内写 `.equ`，还是统一 include。

## 9. 文档同步

### 9.1 同步 `sw/linker/readme.md`

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

### 9.2 同步 README 和 simulation flow 文档

需要后续同步：

- `README.md`
  - 当前顶层从 core-level 测试切到 `rv32i_soc` 平台测试。
  - 支持最小 MMIO 和 access fault。
- `docs/simulation_flow_pipeline_asm.md`
  - 说明 testbench 内部实例化 SoC wrapper。
  - 说明 UART/GPIO 输出观察口。
- `docs/simulation_flow_pipeline_c.md`
  - 说明 C 程序可包含 `sw/include/platform.h` 访问 MMIO。

本章只列同步项；具体文字可以在 RTL 完成后根据真实实现补。

## 10. 文件清单总览

### 10.1 新增文件

本阶段建议新增：

| 文件 | 作用 |
|---|---|
| `rtl/periph/mmio_uart.sv` | UART0 最小 MMIO 寄存器块，当前只实现 TX |
| `rtl/periph/mmio_gpio.sv` | GPIO0 最小 MMIO 寄存器块 |
| `rtl/soc/data_subsystem.sv` | data address decode、DMEM/MMIO mux、access fault 汇总 |
| `rtl/soc/rv32i_soc.sv` | 最小平台 wrapper |
| `sw/include/platform.h` | C 侧 MMIO 地址常量和访问函数 |

目录若不存在，需要新增：

```text
rtl/periph/
rtl/soc/
sw/include/
```

### 10.2 修改文件

本阶段预计修改：

| 文件 | 修改内容 |
|---|---|
| `rtl/common/core_pkg.sv` | 新增 MMIO 地址常量、外设 offset、access fault trap cause |
| `rtl/core/core_pipeline5.sv` | 新增 `dmem_access_fault_i` 并连接到 `mem_stage` |
| `rtl/core/mem_stage.sv` | 合并 load/store access fault exception |
| `tb/sv/tb_core_pipeline5.sv` | 从直接实例化 core/memory 改为实例化 `rv32i_soc` |
| `sim/pipeline5_asm/06_run_sim.sh` | RTL 文件列表加入 `rtl/periph/*.sv`、`rtl/soc/*.sv` |
| `sim/pipeline5_c/06_run_sim.sh` | RTL 文件列表加入 `rtl/periph/*.sv`、`rtl/soc/*.sv` |
| `sw/linker/readme.md` | 补 MMIO window 和外设地址说明 |
| `README.md` | 补当前平台支持 MMIO/access fault |
| `docs/simulation_flow_pipeline_asm.md` | 补 SoC wrapper 和 MMIO 观察说明 |
| `docs/simulation_flow_pipeline_c.md` | 补 C platform header 和 MMIO 说明 |

### 10.3 不应修改的核心文件

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
