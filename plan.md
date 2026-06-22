# v4.1 machine interrupt 与 timer 执行计划

当前工程已经完成：

- RV32I 五级流水线主路径。
- 最小 M-mode CSR/trap。
- `ECALL/EBREAK/MRET` 和 Zicsr。
- 256 KiB IMEM/DMEM 地址图。
- 最小 SoC wrapper、data subsystem、GPIO0、UART0 TX、data access fault。

本计划根据 `docs/08xx/0833 machine interrupt与timer规划.md` 编写，目标是在当前 SoC 上加入 machine interrupt 与 32-bit TIMER0，并让 GPIO/UART 作为 machine external interrupt 的来源。

## 0. 实现边界

本阶段实现：

- `mie/mip` CSR 的 machine timer/external interrupt 位。
- `mcause[31]` interrupt bit。
- `MTIP`：由 32-bit TIMER0 的 `MTIME >= MTIMECMP` 产生。
- `MEIP`：由 `gpio_irq_o | uart_irq_o` 汇总产生。
- GPIO0 按 bit 配置中断使能和触发类型，pending 使用 `R/W1C`。
- UART0 增加仿真 RX，RX event 置 pending 并产生 UART interrupt。
- core 在 MEM/commit 边界接受 interrupt。
- interrupt entry 写 `mepc/mcause/mtval/mstatus`，redirect 到 `mtvec`。
- `MRET` 继续使用现有返回路径。
- interrupt 返回 PC 使用“当前提交指令的实际下一条 PC”，不能简单固定为 `mem_pc + 4`。

本阶段不实现：

- `MSIP` software interrupt。`mip.MSIP` 读 0，`mie.MSIE` 写入按 WARL 忽略。
- PLIC/CLINT 完整模型。
- vectored `mtvec`。
- nested interrupt 完整策略。
- `WFI`。
- ready/valid、wait-state、MEM stall。
- 标准总线。

中断优先级：

```text
同步 exception > MRET > MEIP > MTIP > 普通指令提交
```

`MEIP > MTIP` 是本阶段固定选择；后续若加入 PLIC 或更完整平台，可以再调整。

## 1. 公共常量和类型 `已完成`

### 1.1 修改 `rtl/common/core_pkg.sv` `已完成`

新增 CSR 地址：

```systemverilog
CSR_ADDR_MIE = 12'h304;     // RW
CSR_ADDR_MIP = 12'h344;     // RO，硬件自动更新
```

新增 interrupt bit 位置：

```systemverilog
// MIP_MSIP_BIT = 3;   // 本阶段不实现
MIP_MTIP_BIT = 7;
MIP_MEIP_BIT = 11;

// MIE_MSIE_BIT = 3;   // 本阶段不实现
MIE_MTIE_BIT = 7;
MIE_MEIE_BIT = 11;
```

新增 `mcause` interrupt bit：

```systemverilog
MCAUSE_INTERRUPT_BIT = XLEN - 1;
```

当前 `excp_cause_e` 是 5-bit exception code。本阶段不要把 interrupt bit 塞进这个 enum；新增 `irq_cause_e` 表示 interrupt code，后续再由单独 trap kind 信号区分 exception/interrupt。

```systemverilog
typedef enum logic [4:0] {
    // IRQ_CAUSE_M_SOFTWARE = 5'd3,  // 本阶段不实现 MSIP
    IRQ_CAUSE_M_TIMER    = 5'd7,
    IRQ_CAUSE_M_EXTERNAL = 5'd11
} irq_cause_e;
```

### 1.2 修改 `rtl/common/soc_pkg.sv` `已完成`

补 TIMER0 offset：

```systemverilog
TIMER0_MTIME_OFFSET    = 12'h000;
TIMER0_MTIMECMP_OFFSET = 12'h004;
TIMER0_CTRL_OFFSET     = 12'h008;
TIMER0_STATUS_OFFSET   = 12'h00c;
```

补 TIMER bit：

```systemverilog
TIMER0_CTRL_EN_BIT     = 0;
TIMER0_STATUS_MTIP_BIT = 0;
```

补 GPIO interrupt offset：

```systemverilog
GPIO_IRQ_EN_OFFSET      = 12'h00c;
GPIO_IRQ_RISE_EN_OFFSET = 12'h010;
GPIO_IRQ_FALL_EN_OFFSET = 12'h014;
GPIO_IRQ_HIGH_EN_OFFSET = 12'h018;
GPIO_IRQ_LOW_EN_OFFSET  = 12'h01c;
GPIO_IRQ_PENDING_OFFSET = 12'h020;
GPIO_IRQ_STATUS_OFFSET  = 12'h024;
```

补 UART RX/interrupt offset。当前已有：

```systemverilog
UART_TXDATA_OFFSET = 12'h000;
UART_STATUS_OFFSET = 12'h004;
UART_CTRL_OFFSET   = 12'h008;
```

本阶段扩展：

```systemverilog
UART_RXDATA_OFFSET     = 12'h00c;
UART_IRQ_PENDING_OFFSET = 12'h010;
```

UART bit 规划：

```text
STATUS[0] = tx_ready
STATUS[1] = rx_valid
STATUS[2] = irq_pending，即 IRQ_PENDING[0] 的只读镜像

CTRL[0] = enable
CTRL[1] = rx_irq_enable

IRQ_PENDING[0] = rx_irq_pending，R/W1C
```

本阶段保留独立 `IRQ_PENDING`，便于软件 W1C；`STATUS[2]` 只作为轮询视图，不参与清除语义。

## 2. 流水线 next PC 信息 `已完成`

### 2.1 修改 `rtl/common/pipeline_pkg.sv` `已完成`

interrupt 需要返回到第一条未提交指令，因此 MEM 边界必须知道当前提交指令的实际下一条 PC。

当前实现不在 `id_ex_reg_t` 新增 `next_pc`，因为 ID/EX 已经有 `pc_plus4`，顺序下一条 PC 可以直接复用。只在 `ex_mem_reg_t` 中新增：

```systemverilog
logic [core_pkg::XLEN-1:0] next_pc;
```

`mem_wb_reg_t` 也不需要新增该字段，因为 interrupt 在 MEM/commit 边界接受，不等到 WB。

### 2.2 修改 `rtl/core/ex_stage.sv` `已完成`

新增输入：

```systemverilog
input logic [core_pkg::XLEN-1:0] pc_plus4_i
```

新增输出：

```systemverilog
output logic [core_pkg::XLEN-1:0] next_pc_o
```

生成规则：

```text
普通非控制指令      -> pc_i + 4
not-taken branch    -> pc_i + 4
taken branch        -> branch target
JAL                 -> jump target
JALR                -> jalr target
```

注意：

- 当前实现用已有 `pc_plus4_i` 表示 `pc_i + 4`，避免在 EX 里重复加法。
- `next_pc_o` 是“当前指令提交后，下一条架构 PC”。
- 它不替代现有 `redirect_pc_o`。
- `redirect_pc_o` 仍用于 EX 阶段控制流重定向。
- `next_pc_o` 只给后续 interrupt 写 `mepc` 使用。

### 2.3 修改 `rtl/core/core.sv` 的流水线组包 `已完成`

`ex_stage` 实例新增连接：

```systemverilog
.pc_plus4_i (id_ex_data_q.pc_plus4),
.next_pc_o  (ex_next_pc)
```

EX/MEM 组包：

```systemverilog
ex_mem_data_d.next_pc = ex_next_pc;
```

其中 `ex_next_pc` 来自 `ex_stage.next_pc_o`。ID/EX 不新增 `next_pc` 字段。

## 3. CSR 文件扩展 `已完成`

### 3.1 修改 `rtl/core/csr_file.sv` 端口 `已完成`

新增 raw pending 输入：

```systemverilog
input logic mtip_i;
input logic meip_i;
```

`MSIP` 本阶段不做，不加 `msip_i`。后续需要时再补。

新增 trap kind 输入：

```systemverilog
input logic trap_is_interrupt_i;
input logic [4:0] trap_cause_code_i;
```

现有：

```systemverilog
input core_pkg::excp_cause_e trap_cause_i
```

需要调整为低 5 bit code 形式。可选方案：

- 方案 A：保留 `trap_cause_i` 给 exception，另加 `trap_irq_cause_i`。
- 方案 B：统一改为 `logic [4:0] trap_cause_code_i`，再用 `trap_is_interrupt_i` 区分。

本阶段选择方案 B，`csr_file` 写 `mcause` 时更直接。

新增输出给 `trap_ctrl`：

```systemverilog
output logic [core_pkg::XLEN-1:0] mie_o;
output logic [core_pkg::XLEN-1:0] mip_o;
```

本阶段输出 CSR 原值，让 `trap_ctrl` 统一做优先级选择。

当前 core 顶层先做最小适配：`mtip_i/meip_i` 暂接 0，`mie_o/mip_o` 暂未接入 `trap_ctrl`，后续第 4/5 步统一连线。

### 3.2 新增 CSR storage `已完成`

新增：

```systemverilog
reg [core_pkg::XLEN-1:0] mie;
```

`mip` 可以不作为纯 storage 保存全部 bit，因为 `MTIP/MEIP` 来自硬件 raw pending。

当前做法：

```systemverilog
logic [XLEN-1:0] mip;
```

其中：

```systemverilog
always_comb begin
    mip               = '0;
    mip[MIP_MTIP_BIT] = mtip_i;
    mip[MIP_MEIP_BIT] = meip_i;
end
```

### 3.3 CSR read decode 与 CSR 输出 `已完成`

`CSR_READ` 增加：

```systemverilog
CSR_ADDR_MIE: csr_rdata_o = mie;
CSR_ADDR_MIP: csr_rdata_o = mip;
```

并驱动新增输出：

```systemverilog
assign mie_o = mie;
assign mip_o = mip;
```

### 3.4 CSR write illegal 检测 `已完成`

`CSR_ILLEGAL_W` 中：

- `mstatus/mtvec/mscratch/mepc/mcause/mtval/mie` 可写。
- `mip` 本阶段不建议软件直接写，写 `mip` 作为非法 CSR 写，或按 WARL 忽略。

推荐第一版：

```text
写 mie 合法
写 mip 非法
读 mip 合法
```

这样更清楚地区分 enable CSR 和 hardware pending CSR。

### 3.5 CSR WARL 处理 `已完成`

`CSR_WARL_CAL` 中增加 `CSR_ADDR_MIE`：

```text
mie[MTIE] 可写
mie[MEIE] 可写
mie[MSIE] 本阶段写忽略，读 0
其它 bit 写忽略，读 0
```

写法上可以先令 `csr_warl = '0`，只拷贝 `MTIE/MEIE`。

`mstatus` WARL 保持当前 `MIE/MPIE/MPP` 逻辑。

普通 CSR 写端口需要同步增加 `mie` 写回：

```systemverilog
CSR_ADDR_MIE: mie <= csr_warl;
```

### 3.6 CSR reset  `已完成`

复位值：

```text
mie = 0
mip = raw pending 组合值，不需要复位 storage
```

`mstatus.MIE = 0`，因此即使 timer/GPIO/UART 复位后 pending 意外为 1，也不会在软件开启前进入 interrupt。

### 3.7 trap entry 写 CSR `已完成`

trap entry 时：

```systemverilog
mepc   <= trap_pc_i;
mcause <= {trap_is_interrupt_i, (XLEN-1)'(trap_cause_code_i)};
mtval  <= trap_is_interrupt_i ? '0 : trap_tval_i;
MPIE   <= MIE;
MIE    <= 1'b0;
MPP    <= M;
```

注意：

- exception 的 `trap_pc_i` 是 faulting PC。
- interrupt 的 `trap_pc_i` 是 interrupt return PC。
- 因此 `csr_file` 注释里不要再把 `trap_pc_i` 固定描述为 fault 指令 PC。
- `mcause` 低 `XLEN-1` 位保存 cause code。当前 `trap_cause_code_i` 只有 5 bit，写入时零扩展；后续如果 cause code 宽度扩展，这里的拼接结构不用变。

## 4. trap_ctrl 扩展 `执行中`

### 4.1 修改 `rtl/core/trap_ctrl.sv` 端口

新增输入：

```systemverilog
input logic [core_pkg::XLEN-1:0] mem_interrupt_return_pc_i;
input logic [core_pkg::XLEN-1:0] csr_mstatus_i;
input logic [core_pkg::XLEN-1:0] csr_mie_i;
input logic [core_pkg::XLEN-1:0] csr_mip_i;
```

新增输出：

```systemverilog
output logic                      trap_is_interrupt_o;
output logic [4:0]                trap_cause_code_o;
output logic                      kill_mem_wb_o;
```

现有 `trap_cause_o` 若仍是 `excp_cause_e`，需要改为低 5 bit code 或配合 `trap_is_interrupt_o` 重命名。

建议输出语义：

```systemverilog
trap_valid_o          // exception 或 interrupt 被接受
trap_is_interrupt_o   // 1 表示 interrupt，0 表示 exception
trap_pc_o             // 写 mepc 的值：exception=fault PC，interrupt=return PC
trap_cause_code_o     // mcause 低 5 bit
trap_tval_o           // interrupt 时为 0
```

### 4.2 生成 interrupt pending

组合逻辑：

```text
global_en = csr_mstatus_i[MSTATUS_MIE_BIT]
mtip_en   = csr_mie_i[MIE_MTIE_BIT]
meip_en   = csr_mie_i[MIE_MEIE_BIT]
mtip_pend = csr_mip_i[MIP_MTIP_BIT]
meip_pend = csr_mip_i[MIP_MEIP_BIT]
```

有效 interrupt：

```text
meip_take = global_en & meip_en & meip_pend
mtip_take = global_en & mtip_en & mtip_pend
```

优先级：

```text
MEIP > MTIP
```

### 4.3 trap entry 优先级

最终优先级：

```text
pipeline_exception
csr_illegal_exception
MRET
MEIP
MTIP
none
```

解释：

- `pipeline_exception` 与 `csr_illegal_exception` 都是同步 exception。
- `MRET` 优先于 interrupt，避免 `MRET` 同拍恢复 `MIE` 后立即被同一边界 interrupt 抢走。
- interrupt 只在 `mem_valid_i=1` 的提交边界接受。

### 4.4 exception 和 interrupt 输出差异

同步 exception：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 0
trap_pc_o           = mem_pc_i
trap_cause_code_o   = exception cause code
trap_tval_o         = exception tval
redirect_pc_o       = csr_mtvec_i
kill IF/ID, ID/EX, EX/MEM
kill MEM/WB 输入
```

CSR illegal exception：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 0
trap_pc_o           = mem_pc_i
trap_cause_code_o   = ILLEGAL_INSTR
trap_tval_o         = mem_instr_i
redirect_pc_o       = csr_mtvec_i
kill IF/ID, ID/EX, EX/MEM
kill MEM/WB 输入
```

interrupt：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 1
trap_pc_o           = mem_interrupt_return_pc_i
trap_cause_code_o   = IRQ_CAUSE_M_EXTERNAL 或 IRQ_CAUSE_M_TIMER
trap_tval_o         = 0
redirect_pc_o       = csr_mtvec_i
kill IF/ID, ID/EX, EX/MEM
不 kill MEM/WB 输入
```

MRET：

```text
mret_valid_o        = 1
redirect_pc_o       = csr_mepc_i
kill IF/ID, ID/EX, EX/MEM
kill MEM/WB 输入
```

MRET 是否 kill MEM/WB 输入沿用当前实现即可。MRET 本身没有普通 WB 行为，让它不进入 WB 更符合当前 trap_ctrl 语义。

### 4.5 `kill_mem_wb_o` 语义修正

当前 `kill_mem_wb_o = redirect_valid_o`。

本阶段需要改为：

```text
kill_mem_wb_o = exception_trap_valid | mret_valid
```

不能包含 interrupt trap。

原因：

- exception：当前 MEM 指令是 faulting instruction，不能作为普通指令提交。
- MRET：当前 MEM 指令是控制流返回指令，没有普通 WB 生命周期。
- interrupt：当前 MEM 指令是旧指令，应允许正常完成；interrupt 在它之后被接受。

## 5. core 顶层接线

### 5.1 修改 `rtl/core/core.sv` 端口

新增输入：

```systemverilog
input logic mtip_i;
input logic meip_i;
```

不加 `msip_i`。

新增观察输出：

```systemverilog
output logic                      trap_is_interrupt_o;
output logic [4:0]                trap_cause_code_o;
```

现有 `trap_cause_o` 若继续保留 `excp_cause_e` 类型，会不适合表示 interrupt。建议改成：

```systemverilog
output logic [4:0] trap_cause_code_o
```

或者保留旧名但改类型。为了减少歧义，推荐使用新名。

### 5.2 core 内部 CSR/trap 信号

新增 wire：

```systemverilog
wire [core_pkg::XLEN-1:0] csr_mie;
wire [core_pkg::XLEN-1:0] csr_mip;
wire                      trap_is_interrupt;
wire [4:0]                trap_cause_code;
wire [core_pkg::XLEN-1:0] mem_interrupt_return_pc;
wire [core_pkg::XLEN-1:0] ex_next_pc;
```

### 5.3 ex_stage 实例连接

连接新增端口：

```systemverilog
.next_pc_o (ex_next_pc)
```

EX/MEM 组包：

```systemverilog
assign ex_mem_data_d.next_pc = ex_next_pc;
```

### 5.4 csr_file 实例连接

新增连接：

```systemverilog
.mtip_i              (mtip_i),
.meip_i              (meip_i),
.trap_is_interrupt_i (trap_is_interrupt),
.trap_cause_code_i   (trap_cause_code),
.mie_o               (csr_mie),
.mip_o               (csr_mip)
```

如果 `csr_file` 端口从 `trap_cause_i` 改为 `trap_cause_code_i`，同步替换原连接。

### 5.5 trap_ctrl 实例连接

新增连接：

```systemverilog
.mem_interrupt_return_pc_i (ex_mem_data_q.next_pc),
.csr_mstatus_i             (csr_mstatus),
.csr_mie_i                 (csr_mie),
.csr_mip_i                 (csr_mip),
.trap_is_interrupt_o       (trap_is_interrupt),
.trap_cause_code_o         (trap_cause_code)
```

原 `trap_cause_o` 连接同步改名或改类型。

### 5.6 commit/trap 观察输出

导出：

```systemverilog
assign trap_is_interrupt_o = trap_is_interrupt;
assign trap_cause_code_o   = trap_cause_code;
```

`trap_pc_o` 注释改成：

```text
写入 mepc 的 PC；exception 时为 fault PC，interrupt 时为 return PC。
```

## 6. TIMER0 外设

### 6.1 新建 `rtl/periph/mmio_timer.sv`

端口建议：

```systemverilog
module mmio_timer #(
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR = soc_pkg::TIMER0_BASE
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

    output logic                      mtip_o
);
```

### 6.2 TIMER0 寄存器

寄存器：

| offset | 名称 | 属性 | 作用 |
|---:|---|---|---|
| `0x00` | `MTIME` | RW | 当前 32-bit 计数值 |
| `0x04` | `MTIMECMP` | RW | 32-bit 比较值 |
| `0x08` | `CTRL` | RW | bit0 enable |
| `0x0C` | `STATUS` | RO | bit0 raw `MTIP` |

### 6.3 TIMER0 行为

复位：

```text
MTIME = 0
MTIMECMP = 0
CTRL.enable = 0
```

计数：

```text
if CTRL.enable:
    MTIME <= MTIME + 1
```

比较：

```text
mtip_o = CTRL.enable && (MTIME >= MTIMECMP)
STATUS[0] = mtip_o
```

写 `MTIME/MTIMECMP/CTRL` 按 byte enable 更新。

写 `STATUS` 忽略。

未知 offset 输出 `access_fault_o`。

### 6.4 timer 与软件 pending

`MTIP` 是 level pending。handler 必须：

- 写 `MTIMECMP` 到未来；或
- 关闭 `CTRL.enable`。

否则 `MRET` 后会立刻再次进入 timer interrupt。

## 7. GPIO0 中断扩展

### 7.1 修改 `rtl/periph/mmio_gpio.sv` 端口

新增输出：

```systemverilog
output logic gpio_irq_o
```

### 7.2 扩展 GPIO 寄存器

在现有 `OUT/IN/OE` 后新增：

| offset | 名称 | 属性 | 行为 |
|---:|---|---|---|
| `0x0C` | `IRQ_EN` | RW | 每 bit 中断总使能 |
| `0x10` | `IRQ_RISE_EN` | RW | 每 bit 上升沿触发使能 |
| `0x14` | `IRQ_FALL_EN` | RW | 每 bit 下降沿触发使能 |
| `0x18` | `IRQ_HIGH_EN` | RW | 每 bit 高电平触发使能 |
| `0x1C` | `IRQ_LOW_EN` | RW | 每 bit 低电平触发使能 |
| `0x20` | `IRQ_PENDING` | R/W1C | 读 pending；写 1 清对应 bit；写 0 保持 |
| `0x24` | `IRQ_STATUS` | RO | `IRQ_PENDING & IRQ_EN` |

### 7.3 GPIO 输入采样

新增寄存器：

```systemverilog
reg [GPIO_WIDTH-1:0] gpio_in_q;
```

每拍采样：

```systemverilog
gpio_in_q <= gpio_in_i;
```

触发检测：

```text
rise_hit =  gpio_in_i & ~gpio_in_q
fall_hit = ~gpio_in_i &  gpio_in_q
high_hit =  gpio_in_i
low_hit  = ~gpio_in_i
```

### 7.4 pending 更新

组合：

```text
trigger_hit =
    (IRQ_RISE_EN & rise_hit) |
    (IRQ_FALL_EN & fall_hit) |
    (IRQ_HIGH_EN & high_hit) |
    (IRQ_LOW_EN  & low_hit)
```

时序：

```text
clear_mask = 写 IRQ_PENDING 时 wdata 中为 1 的 bit
set_mask   = IRQ_EN & trigger_hit

IRQ_PENDING <= (IRQ_PENDING & ~clear_mask) | set_mask
```

`set` 与 `clear` 同拍冲突时建议 `set` 优先。原因是如果外部 level 仍保持触发状态，软件清 pending 后应继续看到 pending。

### 7.5 GPIO irq 输出

```text
IRQ_STATUS = IRQ_PENDING & IRQ_EN
gpio_irq_o = |IRQ_STATUS
```

`gpio_irq_o` 是 level 信号，不是 pulse。

## 8. UART0 RX 与中断扩展

### 8.1 修改 `rtl/periph/mmio_uart.sv` 端口

新增输入：

```systemverilog
input logic       rx_valid_i;
input logic [7:0] rx_data_i;
```

新增输出：

```systemverilog
output logic uart_irq_o
```

`rx_valid_i` 来自 SoC/testbench，用于模拟外部收到一个字节，不是真实串口采样。

### 8.2 扩展 UART 寄存器

现有：

| offset | 名称 | 属性 |
|---:|---|---|
| `0x00` | `TXDATA` | WO |
| `0x04` | `STATUS` | RO |
| `0x08` | `CTRL` | RW |

扩展：

| offset | 名称 | 属性 | 行为 |
|---:|---|---|---|
| `0x0C` | `RXDATA` | RO | 返回最近收到的 RX byte；读取可清 `rx_valid/rx_irq_pending` |
| `0x10` | `IRQ_PENDING` | R/W1C | bit0 为 RX pending，写 1 清 |

`STATUS` bit：

```text
STATUS[0] = tx_ready，固定 1
STATUS[1] = rx_valid
STATUS[2] = irq_pending
```

`CTRL` bit：

```text
CTRL[0] = enable
CTRL[1] = rx_irq_enable
```

### 8.3 UART RX event

当：

```text
rx_valid_i && CTRL.enable
```

发生时：

```text
RXDATA <= rx_data_i
rx_valid <= 1
rx_irq_pending <= 1
```

如果旧 RXDATA 尚未被读走，又来新的 `rx_valid_i`：

- 第一版可以覆盖旧值。
- 可在注释里说明当前无 FIFO，软件应及时读取。

### 8.4 UART pending 清除

清除方式：

- 读 `RXDATA` 清 `rx_valid` 和 `rx_irq_pending`；或
- 写 `IRQ_PENDING[0]=1` 清 `rx_irq_pending`，是否清 `rx_valid` 由实现统一决定。

推荐第一版：

```text
读 RXDATA：清 rx_valid 和 rx_irq_pending
写 IRQ_PENDING[0]=1：只清 rx_irq_pending，不清 RXDATA/rx_valid
```

这样软件可以先关中断或清 pending，再决定是否读取数据。

### 8.5 UART irq 输出

```text
uart_irq_o = CTRL.enable && CTRL.rx_irq_enable && rx_irq_pending
```

`uart_irq_o` 是 level 信号，不是 pulse。

## 9. data_subsystem 集成

### 9.1 修改 `rtl/soc/data_subsystem.sv` 端口

新增 UART RX 输入：

```systemverilog
input logic       uart0_rx_valid_i;
input logic [7:0] uart0_rx_data_i;
```

新增 interrupt 输出：

```systemverilog
output logic timer0_mtip_o;
output logic gpio0_irq_o;
output logic uart0_irq_o;
```

### 9.2 地址命中

新增：

```systemverilog
wire timer0_hit;
wire timer0_valid;
```

命中范围：

```text
TIMER0_BASE <= core_addr_i < TIMER0_BASE + TIMER0_SIZE_BYTES
```

`mapped_hit` 增加 `timer0_hit`。

`mmio_access_o` 增加 `timer0_valid`。

### 9.3 实例化 `mmio_timer`

在 `simple_ram/mmio_gpio/mmio_uart` 同级实例化：

```systemverilog
mmio_timer #(
    .BASE_ADDR (soc_pkg::TIMER0_BASE)
) u_mmio_timer0 (...);
```

连接：

```text
valid_i        = timer0_valid
we_i           = core_we_i
be_i           = core_be_i
addr_i         = core_addr_i
wdata_i        = core_wdata_i
rdata_o        = timer0_rdata
access_fault_o = timer0_access_fault
mtip_o         = timer0_mtip_o
```

### 9.4 更新 read mux 和 access fault

`core_rdata_o` mux 增加：

```text
else if (timer0_valid) core_rdata_o = timer0_rdata;
```

`core_access_fault_o` 增加：

```text
| timer0_access_fault
```

### 9.5 GPIO/UART irq 连接

`u_mmio_gpio0` 连接：

```text
.gpio_irq_o (gpio0_irq_o)
```

`u_mmio_uart0` 连接：

```text
.rx_valid_i (uart0_rx_valid_i)
.rx_data_i  (uart0_rx_data_i)
.uart_irq_o (uart0_irq_o)
```

## 10. SoC 顶层集成

### 10.1 修改 `rtl/soc/rv32i_soc.sv` 端口

新增 UART RX 输入：

```systemverilog
input logic       uart0_rx_valid_i;
input logic [7:0] uart0_rx_data_i;
```

新增 interrupt 观察输出：

```systemverilog
output logic timer0_mtip_o;
output logic gpio0_irq_o;
output logic uart0_irq_o;
output logic meip_o;
```

新增 trap 观察输出：

```systemverilog
output logic       trap_is_interrupt_o;
output logic [4:0] trap_cause_code_o;
```

### 10.2 汇总 MEIP

内部：

```systemverilog
wire meip = gpio0_irq_o | uart0_irq_o;
assign meip_o = meip;
```

`core` 连接：

```systemverilog
.mtip_i (timer0_mtip_o)
.meip_i (meip)
```

### 10.3 data_subsystem 连接

`u_data_subsystem` 连接新增端口：

```systemverilog
.uart0_rx_valid_i (uart0_rx_valid_i)
.uart0_rx_data_i  (uart0_rx_data_i)
.timer0_mtip_o    (timer0_mtip_o)
.gpio0_irq_o      (gpio0_irq_o)
.uart0_irq_o      (uart0_irq_o)
```

### 10.4 观察口注释

更新文件头注释：

- SoC 现在包含 TIMER0。
- UART0 支持 TX event 和仿真 RX event。
- GPIO0/UART0 interrupt 汇总为 `MEIP`。
- TIMER0 interrupt 作为 `MTIP` 输入 core。

## 11. core-only testbench 最小适配

### 11.1 修改 `tb/sv/tb_core_pipeline5.sv`

core 增加 interrupt 输入后，core-only tb 需要固定拉低：

```systemverilog
mtip_i = 1'b0
meip_i = 1'b0
```

若 core trap 观察口改名或新增：

```systemverilog
trap_is_interrupt_o
trap_cause_code_o
```

tb 要同步连线，并在 trace 中使用新 `trap_cause_code`。

core-only 旧测试不主动触发 interrupt，预期仍全部通过。

## 12. SoC testbench 验证准备

本章只写验证必备支持，不写完整测试方案。

### 12.1 修改 `tb/sv/tb_rv32i_soc.sv`

新增驱动信号：

```systemverilog
logic       uart0_rx_valid;
logic [7:0] uart0_rx_data;
```

连接到 `rv32i_soc`。

新增观察信号：

```systemverilog
timer0_mtip
gpio0_irq
uart0_irq
meip
trap_is_interrupt
trap_cause_code
```

### 12.2 UART RX 注入任务

增加 task：

```systemverilog
task automatic inject_uart0_rx(input [7:0] data);
```

行为：

- 某个时钟边界拉高 `uart0_rx_valid` 一拍。
- 同拍提供 `uart0_rx_data`。
- 下一拍拉低 `uart0_rx_valid`。

### 12.3 GPIO 输入驱动

保留并扩展现有 `gpio0_in` 驱动能力：

- 能在指定时刻改变某个 bit。
- 能测试上升沿、下降沿、高电平、低电平 pending。

不需要在本阶段写完整用例，但 tb 必须具备驱动这些输入的能力。

### 12.4 trap trace

trap 打印区分：

```text
trap_is_interrupt = 0 -> exception
trap_is_interrupt = 1 -> interrupt
```

`mcause` 显示时应能组合为：

```text
{trap_is_interrupt, trap_cause_code}
```

或直接打印：

```text
interrupt code = 7/11
exception code = ...
```

### 12.5 平台头文件准备

新增或更新：

```text
sw/include/platform.h
```

内容至少包含：

- `GPIO0_BASE`
- `UART0_BASE`
- `TIMER0_BASE`
- TIMER0 offset 和 bit mask
- GPIO IRQ offset 和 bit mask
- UART RX/IRQ offset 和 bit mask
- `MSTATUS_MIE`
- `MIE_MTIE`
- `MIE_MEIE`
- `MIP_MTIP`
- `MIP_MEIP`
- `MCAUSE_INTERRUPT_BIT`
- `MCAUSE_CODE_MASK`

`MIE_MSIE/MIP_MSIP` 可以作为注释保留，不作为本阶段测试依赖。

### 12.6 脚本准备

后续 directed test 需要 SoC 平台脚本支持：

- 继续使用 SoC 仿真入口。
- 增加 interrupt 测试编号分组。
- timeout 可能需要比普通 MMIO smoke 更长。

具体测试程序和 run_all 策略等 RTL 稳定后再写。

## 13. 文档和注释同步

RTL 完成后同步检查：

- `docs/08xx/0833 machine interrupt与timer规划.md` 是否与最终实现一致。
- `rtl/core/csr_file.sv` 头注释是否写明 `mie/mip/mcause[31]`。
- `rtl/core/trap_ctrl.sv` 头注释是否区分 exception、interrupt、MRET。
- `rtl/periph/mmio_gpio.sv` 头注释是否写明 `R/W1C IRQ_PENDING`。
- `rtl/periph/mmio_uart.sv` 头注释是否写明仿真 RX 和 UART interrupt。
- `rtl/periph/mmio_timer.sv` 头注释是否写明 32-bit 教学 timer。
- SoC/testbench 注释是否说明 `MEIP = GPIO irq | UART irq`、`MTIP = TIMER0`。
