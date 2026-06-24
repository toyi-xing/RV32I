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

中断与 trap/MRET 优先级：

```text
同步 exception > MRET+interrupt > CSR写+interrupt > MRET > interrupt > 普通指令提交
```

`MRET+interrupt` 表示当前 MEM 指令为 MRET，且同一提交边界已经满足 interrupt 接受条件。此时先按 MRET 的目标地址作为 interrupt return PC，再直接进入 interrupt handler。

`CSR写+interrupt` 表示当前 MEM 指令为合法 CSR 写，且该 CSR 写提交后的状态满足 interrupt 接受条件。此时语义等价于“先提交 CSR 写，再接受 interrupt”，不能吞掉 CSR 写。

`MEIP > MTIP` 是本阶段固定 interrupt cause 选择；后续若加入 PLIC 或更完整平台，可以再调整。它只决定同拍多个 interrupt pending 时写入 `mcause` 的 interrupt code，不改变 redirect/kill 行为。

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

补 TIMER32 公用 offset；TIMER0 本阶段使用一个 32-bit timer 实例：

```systemverilog
TIMER32_MTIME_OFFSET    = 12'h000;
TIMER32_MTIMECMP_OFFSET = 12'h004;
TIMER32_CTRL_OFFSET     = 12'h008;
TIMER32_STATUS_OFFSET   = 12'h00c;
```

补 TIMER bit：

```systemverilog
TIMER32_CTRL_EN_BIT     = 0;
TIMER32_STATUS_MTIP_BIT = 0;
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

CTRL[0] = tx_enable
CTRL[1] = rx_irq_enable

IRQ_PENDING[0] = rx_irq_pending，R/W1C
```

本阶段保留独立 `IRQ_PENDING`，便于软件 W1C；`STATUS[2]` 只作为轮询视图，不参与清除语义。读 `IRQ_PENDING` 本身只观察 pending，不清除；读 `RXDATA` 会作为 RXDATA 的读副作用清 `rx_irq_pending`。

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

新增输出给 `trap_ctrl` 和顶层连线：

```systemverilog
output logic [core_pkg::XLEN-1:0] mstatus_o;
output logic [core_pkg::XLEN-1:0] mstatus_commit_o;
output logic [core_pkg::XLEN-1:0] mie_o;
output logic [core_pkg::XLEN-1:0] mie_commit_o;
output logic [core_pkg::XLEN-1:0] mtvec_o;
output logic [core_pkg::XLEN-1:0] mtvec_commit_o;
output logic [core_pkg::XLEN-1:0] mepc_o;
output logic [core_pkg::XLEN-1:0] mip_o;
```

当前实现同时输出 CSR 当前值和普通 CSR 写后的 commit view：

- `mie_o/mtvec_o` 是当前寄存器值，普通 interrupt、MRET+interrupt 和 exception redirect 使用它们，语义直观。
- `mie_commit_o/mtvec_commit_o` 是普通 CSR 写提交后的值，专门用于 `CSR写+interrupt` 这种同拍复合提交。
- 在没有合法普通 CSR 写时，commit view 仍等于当前 CSR 值，但计划中不强制所有路径都复用 commit view。

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

并驱动对外 CSR 视图：

```systemverilog
mstatus_o = mstatus;
mie_o     = mie;
mtvec_o   = mtvec;
mepc_o    = mepc;
mip_o     = mip;
```

`mie_commit_o/mtvec_commit_o` 在后续 `CSR_STATUS_OUT` 中生成，用来描述普通 CSR 写提交后的视图。

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

### 3.7 普通 trap entry 写 CSR `已完成`

仅 exception 或仅 interrupt 的 trap entry 时：

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

### 3.8 复合提交时的 CSR 写语义 `已完成`

第 4 章会允许 MRET 或普通 CSR 写与 interrupt 在同一提交边界同时成立。此时 `csr_file` 不能继续只按：

```text
trap entry > mret > normal csr write
```

这种互斥事件口径写，因为：

- `trap_valid_i` 和 `mret_valid_i` 会在 `MRET+interrupt` 时合法地同时为 1。
- `trap_valid_i` 和普通 CSR 写请求会在 `CSR写+interrupt` 时合法地同时为 1。

当前 `CSR_WRITE` 分支按实际实现拆成：

```text
exception trap > MRET+interrupt > CSR写+interrupt > interrupt trap > MRET > normal CSR write
```

其中：

```text
exception trap    = trap_valid_i && !trap_is_interrupt_i
MRET+interrupt    = trap_valid_i &&  trap_is_interrupt_i && mret_valid_i
CSR写+interrupt   = trap_valid_i &&  trap_is_interrupt_i && !mret_valid_i && csr_valid_i && csr_write_en_i
interrupt trap    = trap_valid_i &&  trap_is_interrupt_i && !mret_valid_i && !csr_write_en_i
MRET              = !trap_valid_i && mret_valid_i
normal CSR write  = csr_valid_i && csr_write_en_i
```

具体改动：

- 修改 `rtl/core/csr_file.sv` 中 `CSR_WRITE` 的注释，说明这里是 CSR 状态更新分支，不是 trap 源仲裁。
- 将当前 `if (trap_valid_i) ... else if (mret_valid_i) ...` 拆成上面的硬件写分支。
- `exception trap` 和 `interrupt trap` 都写：

```systemverilog
mepc   <= trap_pc_i;
mcause <= {trap_is_interrupt_i, (XLEN-1)'(trap_cause_code_i)};
mtval  <= trap_is_interrupt_i ? '0 : trap_tval_i;
```

- `exception trap` 和 `interrupt trap` 的 `mstatus` 按普通 trap entry：

```text
MIE  <= 0
MPIE <= old MIE
MPP  <= M
```

- `MRET+interrupt` 的 `mcause/mtval/mstatus` 按 interrupt trap entry 语义处理。`mepc` 保持当前值，因为当前 `mepc` 本来就是 MRET 要返回的位置，也就是这次 interrupt 结束后应该回去的位置。

`mstatus` 最终效果等价于“先 MRET 再 interrupt entry”：

```text
MIE  <= 0
MPIE <= old MPIE
MPP  <= M
```

也就是 `MPIE` 保持原值，不使用 `old MIE`。

- `CSR写+interrupt` 的语义是“普通 CSR 写先提交，然后 interrupt trap entry 再提交”。当前实现先按 `csr_addr_i` 对合法普通 CSR 写做一次状态更新，再用同一 `always_ff` 后续赋值覆盖 interrupt entry 必须接管的字段。当前最小 CSR 集下合并规则为：

```text
mepc/mcause/mtval  : 最终由 interrupt trap entry 写入；若普通 CSR 写目标也是这些 CSR，则普通写被后续 trap entry 覆盖。
mstatus            : trap entry 最终 MIE=0、MPP=M，MPIE 使用 CSR 写提交后的 MIE。
mie/mtvec/mscratch : 若普通 CSR 写目标是这些 CSR，写入值需要保留。
只读 CSR / 非法 CSR  : 不会进入本分支，已经由 exception trap 处理。
```

因此如果当前 CSR 指令写 `mstatus` 清掉 `MIE`，同拍就不应接受 interrupt；如果写 `mstatus` 打开 `MIE` 且 pending/enable 已满足，可以同拍接受 interrupt。这个判断由第 3.9 的“CSR 提交视图”提供给 `trap_ctrl`。

- `MRET` 单独成立时保持原有语义：

```text
MIE  <= old MPIE
MPIE <= 1
MPP  <= M
```

### 3.9 CSR 提交视图输出 `已完成`

为了让 `trap_ctrl` 支持 `CSR 写+interrupt`，它不能只看当前 CSR 寄存器旧值，而要看“当前合法 CSR 写提交后”的 CSR 视图。

`csr_file` 新增组合输出：

```systemverilog
output logic [core_pkg::XLEN-1:0] mstatus_commit_o;
output logic [core_pkg::XLEN-1:0] mie_commit_o;
output logic [core_pkg::XLEN-1:0] mtvec_commit_o;
```

含义：

```text
mstatus_commit_o = 当前 mstatus 在普通合法 CSR 写提交后的值；若本拍没有合法 mstatus 写，则等于 mstatus。
mie_commit_o     = 当前 mie     在普通合法 CSR 写提交后的值；若本拍没有合法 mie 写，则等于 mie。
mtvec_commit_o   = 当前 mtvec   在普通合法 CSR 写提交后的值；若本拍没有合法 mtvec 写，则等于 mtvec。
```

这些输出只反映普通 CSR 指令写的提交效果，不包含 trap entry 或 MRET 的硬件写效果，避免与 `trap_ctrl -> csr_file` 的 `trap_valid_i/mret_valid_i` 形成组合环。

当前实现：

- 在 `CSR_WARL_CAL` 后增加组合块 `CSR_STATUS_OUT`。
- 默认：

```systemverilog
mstatus_commit_o = mstatus;
mie_commit_o     = mie;
mtvec_commit_o   = mtvec;
```

- 同时输出当前 `mstatus_o/mie_o/mtvec_o/mepc_o/mip_o`。
- 当 `csr_valid_i && csr_write_en_i && !csr_illegal_o` 且地址命中 `mstatus/mie/mtvec` 时，用 `csr_warl` 覆盖对应提交视图。
- commit view 不包含 MRET 后的硬件写效果。`MRET+interrupt` 是否可接受由 `trap_ctrl` 看旧 `mstatus_o[MSTATUS_MPIE_BIT]` 判断；如果把 MRET 后的结果也放入 commit view，反而容易和 `trap_ctrl -> csr_file` 的硬件写控制形成组合环。
- `trap_ctrl` 用当前 CSR 值处理普通 interrupt、MRET+interrupt 和 exception redirect；用 commit view 处理 `CSR写+interrupt` 的中断使能判断和 redirect。

一条 MEM 指令要么是普通 Zicsr 指令，要么是 MRET，不存在“CSR写 + MRET+interrupt”这种同一条指令同时成立的情况。

纯 CSR 读指令不修改 CSR 状态，可以按普通指令处理；如果同拍接受 interrupt，仍然不 kill MEM/WB 输入，保证 CSR 读出的 rd 写回可以正常完成。

## 4. trap_ctrl 扩展 `已完成`

### 4.1 修改 `rtl/core/trap_ctrl.sv` 端口 `已完成`

新增/调整输入：

```systemverilog
input logic [core_pkg::XLEN-1:0] mem_interrupt_return_pc_i;
input logic [core_pkg::XLEN-1:0] csr_mstatus_i;
input logic [core_pkg::XLEN-1:0] csr_mie_i;
input logic [core_pkg::XLEN-1:0] csr_mtvec_i;
input logic [core_pkg::XLEN-1:0] csr_mip_i;
input logic                      mem_csr_write_en_i;
```

`csr_mepc_i` 继续保留，用于普通 MRET redirect 和 MRET+interrupt 的 interrupt return PC。

新增 CSR 提交视图输入，用来支持 `CSR写+interrupt`：

```systemverilog
input logic [core_pkg::XLEN-1:0] csr_mstatus_commit_i;
input logic [core_pkg::XLEN-1:0] csr_mie_commit_i;
input logic [core_pkg::XLEN-1:0] csr_mtvec_commit_i;
```

`trap_ctrl` 同时接当前值和 commit view：

- 当前 `csr_mie_i/csr_mtvec_i` 用于普通 interrupt、MRET+interrupt 和 exception trap entry。
- `csr_mie_commit_i/csr_mtvec_commit_i` 只用于 `CSR写+interrupt`，保证同拍写 `mie/mtvec` 后按新值判断和跳转。
- 普通 MRET redirect 仍使用 `csr_mepc_i`。

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

### 4.2 生成 interrupt request/accept `已完成`

组合逻辑：

```text
global_en = csr_mstatus_i[MSTATUS_MIE_BIT]
mtip_en   = csr_mie_i[MIE_MTIE_BIT]
meip_en   = csr_mie_i[MIE_MEIE_BIT]
mtip_pend = csr_mip_i[MIP_MTIP_BIT]
meip_pend = csr_mip_i[MIP_MEIP_BIT]
```

普通指令提交后的 interrupt request：

```text
irq_only_meip_request = global_en & meip_en & meip_pend
irq_only_mtip_request = global_en & mtip_en & mtip_pend
```

CSR 写同拍 interrupt 单独使用 commit view：

```text
csr_global_en     = csr_mstatus_commit_i[MSTATUS_MIE_BIT]
csr_mtip_en       = csr_mie_commit_i[MIE_MTIE_BIT]
csr_meip_en       = csr_mie_commit_i[MIE_MEIE_BIT]
csr_meip_request = csr_global_en & csr_meip_en & meip_pend
csr_mtip_request = csr_global_en & csr_mtip_en & mtip_pend
```

MRET 同拍 interrupt 需要单独判断，因为 MRET 后的 `MIE` 来自旧 `MPIE`，不是旧 `MIE`：

```text
mret_global_en = csr_mstatus_i[MSTATUS_MPIE_BIT]
mret_meip_request = mret_global_en & meip_en & meip_pend
mret_mtip_request = mret_global_en & mtip_en & mtip_pend
```

这里的 `meip_en/mtip_en` 来自当前 `csr_mie_i`。MRET 指令不是 CSR 写，因此无需看 `mie_commit_i`。

优先级：

```text
MEIP > MTIP
```

当前实现口径：

- `request` 表示 interrupt pending/enable 条件满足。
- `accept` 表示在有效 MEM/commit 边界、且没有同步 exception 时真正接受 interrupt。
- `MRET+interrupt` 和 `CSR写+interrupt` 的 request 先用对应提交类型限定，避免没有 MRET/CSR 写时误判该路径成立。

```systemverilog
wire exception_trap = mem_valid_i &  exception_valid;
wire mret_accept    = mem_valid_i & !exception_valid &  mem_mret_i;
wire csr_we_accept  = mem_valid_i & !exception_valid &  mem_csr_valid_i &  mem_csr_write_en_i;

wire irq_only_meip_request = !mret_accept & !csr_we_accept & irq_global_en & irq_meip_en & irq_meip_pending;
wire irq_only_mtip_request = !mret_accept & !csr_we_accept & irq_global_en & irq_mtip_en & irq_mtip_pending;
wire irq_only_request      = irq_only_meip_request | irq_only_mtip_request;

wire csr_irq_global_en    = csr_mstatus_commit_i[MSTATUS_MIE_BIT];
wire csr_irq_meip_en      = csr_mie_commit_i[MIE_MEIE_BIT];
wire csr_irq_mtip_en      = csr_mie_commit_i[MIE_MTIE_BIT];
wire csr_irq_meip_request = csr_we_accept & csr_irq_global_en & csr_irq_meip_en & irq_meip_pending;
wire csr_irq_mtip_request = csr_we_accept & csr_irq_global_en & csr_irq_mtip_en & irq_mtip_pending;
wire csr_irq_request      = csr_irq_meip_request | csr_irq_mtip_request;

wire mret_irq_global_en   = csr_mstatus_i[MSTATUS_MPIE_BIT];
wire mret_irq_meip_request = mret_accept & mret_irq_global_en & irq_meip_en & irq_meip_pending;
wire mret_irq_mtip_request = mret_accept & mret_irq_global_en & irq_mtip_en & irq_mtip_pending;
wire mret_irq_request      = mret_irq_meip_request | mret_irq_mtip_request;

wire irq_request = irq_only_request | csr_irq_request | mret_irq_request;
wire irq_accept  = mem_valid_i & !exception_valid & irq_request;
```

- cause 最终只需要一套 `irq_cause`，因为同一拍最终只会接受一类 interrupt。
- 生成 `irq_cause` 时使用汇总后的 `irq_meip_request/irq_mtip_request`，保持 `MEIP > MTIP`。

```systemverilog
wire irq_meip_request = mret_irq_meip_request | csr_irq_meip_request | irq_only_meip_request;
wire irq_mtip_request = mret_irq_mtip_request | csr_irq_mtip_request | irq_only_mtip_request;

irq_cause = IRQ_CAUSE_M_TIMER;
if (irq_meip_request) begin
    irq_cause = IRQ_CAUSE_M_EXTERNAL;
end
else if (irq_mtip_request) begin
    irq_cause = IRQ_CAUSE_M_TIMER;
end
```

### 4.3 trap entry 优先级 `已完成`

控制分支优先级：

```text
pipeline_exception
csr_illegal_exception
MRET + interrupt
CSR write + interrupt
MRET
interrupt
none
```

解释：

- `pipeline_exception` 与 `csr_illegal_exception` 都是同步 exception。
- 同步 exception 优先于 MRET 和 interrupt；如果 MRET 指令本身异常，不能先完成 MRET。
- 当前 MEM 指令是 MRET 且同拍满足任一 interrupt 接受条件时，直接支持 `MRET+interrupt` 复合语义：
  - `mret_valid_o = 1`，表示 CSR 文件需要执行 MRET 相关的 `mstatus` 语义。
  - `trap_valid_o = 1` 且 `trap_is_interrupt_o = 1`，表示同一拍接受 interrupt。
  - interrupt 写入 `mepc` 的返回 PC 不是 `mem_interrupt_return_pc_i`，而是 `csr_mepc_i`，也就是 MRET 本来要跳回的位置。
  - 最终 redirect 目标是当前 `csr_mtvec_i`，因为本拍最终进入 interrupt handler，而不是跳回 `mepc` 后继续执行。MRET 本身不会写 `mtvec`。
- 当前 MEM 指令是合法 CSR 写且该 CSR 写提交后的状态满足任一 interrupt 接受条件时，直接支持 `CSR写+interrupt` 复合语义：
  - 普通 CSR 写不能被吞掉，`csr_file` 需要同时完成普通 CSR 写和 interrupt trap entry 的合并更新。
  - interrupt enable 判断使用 `csr_mstatus_commit_i/csr_mie_commit_i`，而不是旧 CSR 值。
  - redirect 目标使用 `csr_mtvec_commit_i`，使同拍写 `mtvec` 后发生 interrupt 时跳到新入口。
- 当前 MEM 指令是 MRET 但没有有效 interrupt 时，执行普通 MRET，redirect 到 `csr_mepc_i`。
- interrupt 只在 `mem_valid_i=1` 的提交边界接受。
- `MEIP > MTIP` 只体现在 `irq_cause` 选择上。二者同拍 pending 时，本次 trap 的 `mcause` 写 external interrupt；进入 handler、kill younger 指令、是否保留 MEM/WB 等控制动作不区分 MEIP/MTIP。

当前实现：

- 保留已有：

```systemverilog
wire pipeline_exception    = mem_valid_i & mem_exception_valid_i;
wire csr_illegal_exception = mem_valid_i & mem_csr_valid_i & mem_csr_illegal_i;
```

- 新增：

```systemverilog
wire exception_trap = mem_valid_i &  exception_valid;
wire mret_accept    = mem_valid_i & !exception_valid &  mem_mret_i;
wire csr_we_accept  = mem_valid_i & !exception_valid &  mem_csr_valid_i &  mem_csr_write_en_i;
wire irq_accept     = mem_valid_i & !exception_valid & irq_request;
```

说明：

- `mret_accept/csr_we_accept/irq_accept` 都被同步 exception 屏蔽。
- `mret_accept` 与 `csr_we_accept` 用名字表示“当前 MEM 指令自身在本边界提交”，不是 interrupt trap entry。
- `irq_request` 表示中断条件请求，`irq_accept` 才表示本拍真正接受 interrupt。
- `MRET+interrupt` 使用 old `MPIE` 判断 MRET 后是否允许 interrupt；普通 interrupt 使用当前 `MIE`；`CSR写+interrupt` 使用 commit view 中的 `MIE`。
- `mret_accept` 优先于 `csr_we_accept`；正常译码下一条指令不会同时是 MRET 和 CSR 写，这里也形成防御性优先级。

### 4.4 exception 和 interrupt 输出差异 `已完成`

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

CSR 写同拍 interrupt：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 1
trap_pc_o           = mem_interrupt_return_pc_i
trap_cause_code_o   = IRQ_CAUSE_M_EXTERNAL 或 IRQ_CAUSE_M_TIMER
trap_tval_o         = 0
mret_valid_o        = 0
redirect_valid_o    = 1
redirect_pc_o       = csr_mtvec_commit_i
kill IF/ID, ID/EX, EX/MEM
不 kill MEM/WB 输入
```

这条路径要求 `csr_file` 同拍完成普通 CSR 写和 interrupt trap entry 的合并更新。

MRET 同拍 interrupt：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 1
trap_pc_o           = csr_mepc_i
trap_cause_code_o   = IRQ_CAUSE_M_EXTERNAL 或 IRQ_CAUSE_M_TIMER
trap_tval_o         = 0
mret_valid_o        = 1
redirect_pc_o       = csr_mtvec_i
kill IF/ID, ID/EX, EX/MEM
kill MEM/WB 输入
```

这条路径的含义是“当前 MRET 指令完成返回语义，但同一提交边界立刻接受 interrupt”。CSR 文件中需要专门处理 `trap_valid_i && trap_is_interrupt_i && mret_valid_i`，使最终 `mstatus` 等价于先 MRET 再 interrupt entry：

```text
MIE  <= 0
MPIE <= old MPIE
MPP  <= M
```

MRET：

```text
mret_valid_o        = 1
redirect_pc_o       = csr_mepc_i
kill IF/ID, ID/EX, EX/MEM
kill MEM/WB 输入
```

MRET 是否 kill MEM/WB 输入沿用当前实现即可。MRET 本身没有普通 WB 行为，让它不进入 WB 更符合当前 trap_ctrl 语义。

### 4.5 `TRAP_CTRL` 组合块改造 `已完成`

原 `TRAP_ENTRY` 组合块只处理 exception，且后面的 `assign` 仍按 `trap_valid_o | mret_valid_o` 简单生成 redirect/kill。当前已改为一个统一的 `TRAP_CTRL` 组合块生成 trap/MRET/interrupt 输出，kill 输出则单独用组合 assign 表达。

当前实现：

- 删除原只计算 exception 的 `always_comb begin : TRAP_ENTRY`。
- 删除原先这些简单 assign：

```systemverilog
assign mret_valid_o     = mem_valid_i & mem_mret_i & ~trap_valid_o;
assign redirect_valid_o = trap_valid_o | mret_valid_o;
assign redirect_pc_o    = trap_valid_o ? csr_mtvec_i : mret_valid_o ? csr_mepc_i : '0;
assign kill_if_id_o     = redirect_valid_o;
assign kill_id_ex_o     = redirect_valid_o;
assign kill_ex_mem_o    = redirect_valid_o;
assign kill_mem_wb_o    = redirect_valid_o;
```

- 在新的组合块里集中生成输出。当前实现先给出无副作用默认值，并让 trap 相关只在 `trap_valid_o=1` 时有意义：

```systemverilog
trap_valid_o        = exception_trap | irq_accept;
trap_pc_o           = exception_trap ? mem_pc_i : mem_interrupt_return_pc_i;
trap_is_interrupt_o = exception_trap ? 1'b0 : 1'b1;
trap_cause_code_o   = exception_trap ? 5'(exception_cause) : 5'(irq_cause);
trap_tval_o         = '0;
mret_valid_o        = 1'b0;
redirect_valid_o    = 1'b0;
redirect_pc_o       = csr_mtvec_i;
```

- 然后按 4.3 控制分支优先级写 `if/else if`：

```text
exception_trap
MRET + interrupt
CSR写 + interrupt
MRET
interrupt
none
```

- exception 分支中仍保留 `pipeline_exception > csr_illegal_exception` 的防御性选择：

```text
pipeline_exception    -> cause/tval 使用流水线携带的 exception 信息
csr_illegal_exception -> cause=ILLEGAL_INSTR, tval=mem_instr_i
```

- MRET+interrupt 分支中：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 1
trap_pc_o           = csr_mepc_i
trap_cause_code_o   = irq_cause
trap_tval_o         = 0
mret_valid_o        = 1
redirect_valid_o    = 1
redirect_pc_o       = csr_mtvec_i
kill IF/ID, ID/EX, EX/MEM, MEM/WB
```

- CSR写+interrupt 分支中：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 1
trap_pc_o           = mem_interrupt_return_pc_i
trap_cause_code_o   = irq_cause
trap_tval_o         = 0
mret_valid_o        = 0
redirect_valid_o    = 1
redirect_pc_o       = csr_mtvec_commit_i
kill IF/ID, ID/EX, EX/MEM
不 kill MEM/WB
```

- MRET 分支中：

```text
trap_valid_o     = 0
mret_valid_o     = 1
redirect_valid_o = 1
redirect_pc_o    = csr_mepc_i
kill IF/ID, ID/EX, EX/MEM, MEM/WB
```

- 普通 interrupt 分支中：

```text
trap_valid_o        = 1
trap_is_interrupt_o = 1
trap_pc_o           = mem_interrupt_return_pc_i
trap_cause_code_o   = irq_cause
trap_tval_o         = 0
mret_valid_o        = 0
redirect_valid_o    = 1
redirect_pc_o       = csr_mtvec_i
kill IF/ID, ID/EX, EX/MEM
不 kill MEM/WB
```

### 4.6 `kill_mem_wb_o` 语义修正 `已完成`

当前实现：

```text
kill_if_id_o   = exception_trap | irq_accept | mret_accept
kill_id_ex_o   = exception_trap | irq_accept | mret_accept
kill_ex_mem_o  = exception_trap | irq_accept | mret_accept
kill_mem_wb_o  = exception_trap | mret_accept
```

`kill_mem_wb_o` 不包含普通 interrupt trap。

原因：

- exception：当前 MEM 指令是 faulting instruction，不能作为普通指令提交。
- MRET：当前 MEM 指令是控制流返回指令，没有普通 WB 生命周期。
- interrupt：当前 MEM 指令是旧指令，应允许正常完成；interrupt 在它之后被接受。
- CSR写+interrupt：当前 MEM 指令是正常提交的 CSR 指令，不应 kill MEM/WB 输入，否则会吞掉 rd 写回；CSR 状态合并写由 `csr_file` 内部处理。

注意：`MRET+interrupt` 同拍时 `mret_accept=1`，因此仍然 kill MEM/WB 输入。这里 kill 的是 MRET 指令本身，不是被 interrupt 打断的普通旧指令。

## 5. core 顶层接线 `已完成`

### 5.1 修改 `rtl/core/core.sv` 端口 `已完成`

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

### 5.2 core 内部 CSR/trap 信号 `已完成`

新增 wire：

```systemverilog
wire [core_pkg::XLEN-1:0] csr_mip;
wire [core_pkg::XLEN-1:0] csr_mstatus;
wire [core_pkg::XLEN-1:0] csr_mie;
wire [core_pkg::XLEN-1:0] csr_mtvec;
wire [core_pkg::XLEN-1:0] csr_mstatus_commit;
wire [core_pkg::XLEN-1:0] csr_mie_commit;
wire [core_pkg::XLEN-1:0] csr_mtvec_commit;
wire [core_pkg::XLEN-1:0] csr_mepc;
wire                      trap_is_interrupt;
wire [4:0]                trap_cause_code;
wire [core_pkg::XLEN-1:0] ex_next_pc;
```

`csr_mie/csr_mtvec` 是当前 CSR 值，`csr_mie_commit/csr_mtvec_commit` 是普通 CSR 写提交后的视图。两类信号都保留，便于 `trap_ctrl` 按不同路径选择。

### 5.3 ex_stage 实例连接 `已完成`

连接新增端口：

```systemverilog
.next_pc_o (ex_next_pc)
```

EX/MEM 组包：

```systemverilog
assign ex_mem_data_d.next_pc = ex_next_pc;
```

### 5.4 csr_file 实例连接 `已完成`

新增连接：

```systemverilog
.mtip_i              (mtip_i),
.meip_i              (meip_i),
.trap_is_interrupt_i (trap_is_interrupt),
.trap_cause_code_i   (trap_cause_code),
.mstatus_o           (csr_mstatus),
.mie_o               (csr_mie),
.mtvec_o             (csr_mtvec),
.mstatus_commit_o    (csr_mstatus_commit),
.mie_commit_o        (csr_mie_commit),
.mtvec_commit_o      (csr_mtvec_commit),
.mepc_o              (csr_mepc),
.mip_o               (csr_mip)
```

如果 `csr_file` 端口从 `trap_cause_i` 改为 `trap_cause_code_i`，同步替换原连接。`trap_cause_code_i` 的输入类型是低 5 bit code，不能继续直接接 `excp_cause_e` 类型的旧 `trap_cause` 信号。

### 5.5 trap_ctrl 实例连接 `已完成`

新增连接：

```systemverilog
.mem_interrupt_return_pc_i (ex_mem_data_q.next_pc),
.mem_csr_write_en_i        (ex_mem_data_q.csr_write_en),
.csr_mstatus_i             (csr_mstatus),
.csr_mie_i                 (csr_mie),
.csr_mtvec_i               (csr_mtvec),
.csr_mip_i                 (csr_mip),
.csr_mstatus_commit_i      (csr_mstatus_commit),
.csr_mie_commit_i          (csr_mie_commit),
.csr_mtvec_commit_i        (csr_mtvec_commit),
.trap_is_interrupt_o       (trap_is_interrupt),
.trap_cause_code_o         (trap_cause_code)
```

原 `trap_cause_o` 连接同步改名或改类型。

### 5.6 commit/trap 观察输出 `已完成`

导出：

```systemverilog
assign trap_is_interrupt_o = trap_is_interrupt;
assign trap_cause_code_o   = trap_cause_code;
```

`trap_pc_o` 注释改成：

```text
写入 mepc 的 PC；exception 时为 fault PC，interrupt 时为 return PC。
```

## 6. TIMER0 外设 `已完成`

### 6.1 新建 `rtl/periph/mmio_timer32.sv`

端口建议：

```systemverilog
module mmio_timer32 #(
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

    output logic                      timer32_irq_o
);
```

### 6.2 TIMER32 寄存器 `已完成`

寄存器：

| offset | 名称 | 属性 | 作用 |
|---:|---|---|---|
| `0x00` | `MTIME` | RW | 当前 32-bit 计数值 |
| `0x04` | `MTIMECMP` | RW | 32-bit 比较值 |
| `0x08` | `CTRL` | RW | bit0 enable |
| `0x0C` | `STATUS` | RO | bit0 raw `MTIP` |

### 6.3 TIMER32 行为 `已完成`

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
timer32_irq_o = CTRL.enable && (MTIME >= MTIMECMP)
STATUS[0] = timer32_irq_o
```

写 `MTIME/MTIMECMP/CTRL` 按 byte enable 更新。当前实现中，写 `MTIME` 时本拍不执行 `MTIME` 自增；写 `MTIMECMP/CTRL` 不阻止计数器自增，是否自增取决于时钟沿前的 `CTRL.enable`。

写 `STATUS` 忽略。

未知 offset 输出 `access_fault_o`。

### 6.4 timer 与软件 pending `无需操作`

`MTIP` 是 level pending。handler 必须：

- 写 `MTIMECMP` 到未来；或
- 关闭 `CTRL.enable`。

否则 `MRET` 后会立刻再次进入 timer interrupt。

## 7. GPIO0 中断扩展 `已完成`

### 7.1 修改 `rtl/periph/mmio_gpio.sv` 端口 `已完成`

新增输出：

```systemverilog
output logic gpio_irq_o
```

### 7.2 扩展 GPIO 寄存器 `已完成`

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

当前实现按寄存器属性分组：

```text
RW   : OUT/OE/IRQ_EN/IRQ_RISE_EN/IRQ_FALL_EN/IRQ_HIGH_EN/IRQ_LOW_EN
RO   : IN/IRQ_STATUS
RW1C : IRQ_PENDING
```

读 mux 需要覆盖全部已定义 offset：

```text
OUT/OE/IRQ_*_EN      -> 对应 RW 寄存器
IN                   -> 同步后的 gpio_in_sync
IRQ_PENDING          -> RW1C pending 寄存器
IRQ_STATUS           -> IRQ_PENDING & IRQ_EN
未知 offset           -> access_fault_o
```

写语义：

```text
RW 写     : 按 byte enable 更新被写 byte，未选 byte 保持。
RW1C 写   : clear_mask 由 byte enable 展开后的 wdata 产生；写 1 清对应 pending bit，写 0 保持。
reset     : RW 和 RW1C 寄存器都清 0。
```

`IRQ_PENDING` 的硬件 set 与软件 W1C clear 合并在 7.4 处理；最终语义仍以 7.4 的 `(pending & ~clear_mask) | set_mask` 为准。

### 7.3 GPIO 输入同步与采样 `已完成`

新增寄存器：

```systemverilog
reg [GPIO_WIDTH-1:0] gpio_in_meta;
reg [GPIO_WIDTH-1:0] gpio_in_sync;
reg [GPIO_WIDTH-1:0] gpio_in_sync_q;
```

`gpio_in_i` 可能来自 core 时钟域外部，本阶段在 GPIO 内部做两级同步。每拍更新：

```systemverilog
gpio_in_meta   <= gpio_in_i;
gpio_in_sync   <= gpio_in_meta;
gpio_in_sync_q <= gpio_in_sync;
```

`GPIO_IN` 读值返回 `gpio_in_sync`。触发检测同样使用同步后的输入：

```text
rise_hit =  gpio_in_sync & ~gpio_in_sync_q
fall_hit = ~gpio_in_sync &  gpio_in_sync_q
high_hit =  gpio_in_sync
low_hit  = ~gpio_in_sync
```

### 7.4 pending 更新 `已完成`

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

### 7.5 GPIO irq 输出 `已完成`

```text
IRQ_STATUS = IRQ_PENDING & IRQ_EN
gpio_irq_o = |IRQ_STATUS
```

`gpio_irq_o` 是 level 信号，不是 pulse。

## 8. UART0 RX 与中断扩展 `已完成`

### 8.1 修改 `rtl/periph/mmio_uart.sv` 端口 `已完成`

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

本阶段约定 `rx_valid_i/rx_data_i` 已经在 `clk_i` 域：

- `rx_valid_i` 是 `clk_i` 域内的单拍 event pulse。
- `rx_data_i` 在 `rx_valid_i=1` 的该拍保持稳定。
- `mmio_uart` 不在内部对 `rx_data_i` 做逐 bit 两级同步；多 bit 数据若来自异步域，必须由外层 UART RX 前端、握手同步或异步 FIFO 先转换到 `clk_i` 域。

原因是 `rx_valid_i/rx_data_i` 是一组事件接口，不是 GPIO 那种独立引脚电平。直接对 data bus 各 bit 分别同步可能得到不一致的数据字节。

### 8.2 扩展 UART 寄存器 `已完成`

现有：

| offset | 名称 | 属性 |
|---:|---|---|
| `0x00` | `TXDATA` | WO |
| `0x04` | `STATUS` | RO |
| `0x08` | `CTRL` | RW |

扩展：

| offset | 名称 | 属性 | 行为 |
|---:|---|---|---|
| `0x0C` | `RXDATA` | RO | 返回最近收到的 RX byte；读取清 `rx_valid/rx_irq_pending` |
| `0x10` | `IRQ_PENDING` | R/W1C | bit0 为 RX pending；读本寄存器只观察；写 1 清 pending |

`STATUS` bit：

```text
STATUS[0] = tx_ready，固定 1
STATUS[1] = rx_valid
STATUS[2] = irq_pending
```

`CTRL` bit：

```text
CTRL[0] = tx_enable
CTRL[1] = rx_irq_enable
```

### 8.3 UART RX event `已完成`

当：

```text
rx_valid_i
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

### 8.4 UART pending 清除 `已完成`

本阶段确定采用第一版清除语义：

- 读 `RXDATA`：清 `rx_valid` 和 `rx_irq_pending`，并返回最近收到的 byte。
- 读 `IRQ_PENDING`：只观察 `rx_irq_pending`，不清除。
- 写 `IRQ_PENDING[0]=1`：只清 `rx_irq_pending`，不清 `RXDATA/rx_valid`。

这样软件可以先关中断或清 pending，再决定是否读取数据。

### 8.5 UART irq 输出 `已完成`

```text
uart_irq_o = CTRL.rx_irq_enable && rx_irq_pending
```

`uart_irq_o` 是 level 信号，不是 pulse。

## 9. data_subsystem 集成 `已完成`

### 9.1 修改 `rtl/soc/data_subsystem.sv` 端口 `已完成`

新增 UART RX 输入：

```systemverilog
input logic       uart0_rx_valid_i;
input logic [7:0] uart0_rx_data_i;
```

新增 interrupt 输出：

```systemverilog
output logic timer0_irq_o;
output logic gpio0_irq_o;
output logic uart0_irq_o;
```

### 9.2 地址命中 `已完成`

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

### 9.3 实例化 `mmio_timer32` `已完成`

在 `simple_ram/mmio_gpio/mmio_uart` 同级实例化：

```systemverilog
mmio_timer32 #(
    .BASE_ADDR (soc_pkg::TIMER0_BASE)
) u_mmio_timer32_0 (...);
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
timer32_irq_o  = timer0_irq_o
```

### 9.4 更新 read mux 和 access fault `已完成`

`core_rdata_o` mux 增加：

```text
else if (timer0_valid) core_rdata_o = timer0_rdata;
```

`core_access_fault_o` 增加：

```text
| timer0_access_fault
```

### 9.5 GPIO/UART irq 连接 `已完成`

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

## 10. SoC 顶层集成 `已完成`

### 10.1 修改 `rtl/soc/rv32i_soc.sv` 端口 `已完成`

新增 UART RX 输入：

```systemverilog
input logic       uart0_rx_valid_i;
input logic [7:0] uart0_rx_data_i;
```

新增 interrupt 观察输出：

```systemverilog
output logic timer0_irq_o;
output logic gpio0_irq_o;
output logic uart0_irq_o;
output logic meip_o;
output logic mtip_o;
```

新增 trap 观察输出：

```systemverilog
output logic       trap_is_interrupt_o;
output logic [4:0] trap_cause_code_o;
```

### 10.2 汇总 MEIP `已完成`

内部：

```systemverilog
wire meip = gpio0_irq_o | uart0_irq_o;
wire mtip = timer0_irq_o;
assign meip_o = meip;
assign mtip_o = mtip;
```

`core` 连接：

```systemverilog
.mtip_i (timer0_irq_o)
.meip_i (meip)
```

### 10.3 data_subsystem 连接 `已完成`

`u_data_subsystem` 连接新增端口：

```systemverilog
.uart0_rx_valid_i (uart0_rx_valid_i)
.uart0_rx_data_i  (uart0_rx_data_i)
.timer0_irq_o     (timer0_irq_o)
.gpio0_irq_o      (gpio0_irq_o)
.uart0_irq_o      (uart0_irq_o)
```

### 10.4 观察口注释 `已完成`

更新文件头注释：

- SoC 现在包含 TIMER0。
- UART0 支持 TX event 和仿真 RX event。
- GPIO0/UART0 interrupt 汇总为 `MEIP`。
- TIMER0 interrupt 作为 `MTIP` 输入 core。
- `trap_cause_code_o` 需要配合 `trap_is_interrupt_o` 解读。

## 11. core-only testbench 最小适配 `不再执行`

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

计划调整：当前项目已经以 SoC 平台作为主要仿真入口，后续准备删除 `tb/sv/tb_core_pipeline5.sv` 及 core-only 仿真脚本，因此不再继续维护 core-only tb 的最小适配。删除动作和相关文件调整纳入 12.0。

## 12. SoC testbench 验证准备 `已完成`

本章只写验证必备支持，不写完整测试方案。

### 12.0 删除 core-only 仿真平台准备 `已完成`

目标：删除 `tb/sv/tb_core_pipeline5.sv`，后续统一使用 SoC testbench 运行已有 ISA、流水线、trap、MMIO 和 interrupt 测试。

需要同步调整：

- 已删除 `tb/sv/tb_core_pipeline5.sv`。
- 已删除 `sim/pipeline5_asm/`、`sim/pipeline5_c/` 下依赖 `tb_core_pipeline5` 的脚本入口。
- 已将 README 中 core-only 仿真命令改为 SoC 仿真命令，避免继续推荐 `sim/pipeline5_*`。
- 已将 `docs/simulation_flow_asm.md`、`docs/simulation_flow_c.md` 中的当前流程改成 SoC-only 口径。
- 已更新 `sw/asm/readme.md`、`sw/c/readme.md` 中的运行平台说明，删除“MMIO 不可在 core-only 运行”的当前流程依赖。
- 已将 `sw/linker/readme.md` 中 `tb_core_pipeline5.sv` 的 PASS/FAIL 地址、DMEM/stack 统计说明迁移到 `tb_rv32i_soc.sv`。
- 历史 `docs/08xx` 规划文档中仍可能出现旧入口作为阶段历史说明，不作为当前执行入口。

### 12.1 修改 `tb/sv/tb_rv32i_soc.sv` `已完成`

新增驱动信号：

```systemverilog
logic       uart0_rx_valid;
logic [7:0] uart0_rx_data;
```

连接到 `rv32i_soc`。

新增观察信号：

```systemverilog
timer0_irq
gpio0_irq
uart0_irq
meip
trap_is_interrupt
trap_cause_code
```

### 12.2 TB command mailbox 规划 `已完成`

本阶段 directed test 仍坚持“程序自检”口径：测试程序自己配置外设、打开 CSR interrupt enable、请求外部激励、在 handler 中检查并清 pending，最后通过 PASS/FAIL 约定结束仿真。

为了让测试程序能按自己的进度请求 GPIO/UART 外部输入，`tb_rv32i_soc.sv` 增加一组只属于该 testbench 的 TB command mailbox。该 mailbox 不是 SoC 硬件 MMIO，也不是外设 ABI；它只是 testbench 监听特定 DMEM store 后产生外部激励的仿真协议。

第一版 mailbox 使用 C linker 已保留的 DMEM 低地址空洞：

```text
TB_CMD_BASE              = DMEM_BASE + 0x180
TB_GPIO0_SET_MASK_ADDR   = TB_CMD_BASE + 0x00
TB_GPIO0_CLR_MASK_ADDR   = TB_CMD_BASE + 0x04
TB_GPIO0_PULSE_CMD_ADDR  = TB_CMD_BASE + 0x08
TB_UART0_RX_ADDR         = TB_CMD_BASE + 0x0c
```

testbench 监听：

```text
rst_n && data_we && dmem_access && data_addr == TB_*_ADDR
```

命中后由 TB task 驱动 SoC 外部输入。第一版实现不做命令队列；GPIO pulse 和 UART RX task 执行期间会占用 mailbox 处理流程，因此软件 directed test 不连续写入 mailbox 命令，命令之间应留出足够间隔。

GPIO 命令语义：

```text
写 TB_GPIO0_SET_MASK_ADDR   : gpio0_in[29:0] <= gpio0_in[29:0] |  wdata[29:0]
写 TB_GPIO0_CLR_MASK_ADDR   : gpio0_in[29:0] <= gpio0_in[29:0] & ~wdata[29:0]
写 TB_GPIO0_PULSE_CMD_ADDR  : 按 wdata packed command 在指定 GPIO0 bit 上产生 pulse
```

`SET/CLR` 的 `wdata` 使用 32-bit mask，但当前 TB 只接受 bit[29:0]；bit[31:30] 是固定周期输入，由 TB 自己驱动，软件 helper 会自动清掉这两位，避免和周期源冲突。

`PULSE_CMD` 的 `wdata` 不解释为 mask，而是 32-bit packed command：

```text
 31   24 23               16  15     9        8       7        5 4              0
+-------+-------------------+----------+-------------+-----------+---------------+
|       | pulse_cycles[7:0] |          | pulse_level |           | gpio_idx[4:0] |
+-------+-------------------+----------+-------------+-----------+---------------+
```

- `gpio_idx[4:0]`：选择要驱动 pulse 的 GPIO0 输入 bit，范围 0~31。
- `pulse_cycles[7:0]`：pulse 持续的 `clk` cycle 数。软件应写非 0 值；第一版 directed test 不依赖 0 的行为。
- `pulse_level`：pulse 期间强制驱动的电平，`1` 表示高脉冲，`0` 表示低脉冲。

实际 TB pulse task 会先把目标 bit 驱动到 `!pulse_level` 一个时钟边界，再驱动到 `pulse_level` 持续 `pulse_cycles` 个时钟边界，再回到 `!pulse_level` 一个时钟边界，最后恢复发起 pulse 前的原始电平。软件侧约束不对 bit[31:30] 发起 pulse。第一版 `PULSE_CMD` 只要求支持单个 GPIO bit 的一个未排队 pulse，不要求支持多个 pulse 并发或排队；directed test 若需要连续 pulse，应在软件中留出足够间隔。

UART 命令语义：

```text
写 TB_UART0_RX_ADDR : wdata[7:0] 作为 RX byte，TB 产生 uart0_rx_valid 一拍
```

第一版不实现 UART RX 队列。测试程序若连续注入多个 byte，应等待前一个 byte 被 handler 消费后再写下一次命令。

该 mailbox 的软件声明放在：

```text
sw/include/tb_rv32i_soc_test.h
```

文件定位：

- 只适用于 `tb/sv/tb_rv32i_soc.sv`。
- 不属于 `rtl/periph/readme.md` 的通用外设寄存器 ABI。
- 换成其他 testbench 或后续 UVM 平台时，可以替换成另一套 testbench 协议头文件。
- C 测试可以使用其中的 `static inline` helper；汇编测试至少可以复用其中的地址和 bit/mask 常量。

### 12.3 GPIO 输入驱动 `已完成`

`tb_rv32i_soc.sv` 中 `gpio0_in` 由 TB 直接驱动：

- `gpio0_in[29:0]`：由 TB command mailbox 的 SET/CLR/PULSE_CMD 命令控制。
- `gpio0_in[30]`：固定周期输入，供 directed test 测试持续外部变化。
- `gpio0_in[31]`：固定周期输入，供 directed test 测试更慢的持续外部变化。

周期性输入第一版约定：

```text
gpio0_in[30] = fast periodic input，每 200 cycle 翻转一次
gpio0_in[31] = slow periodic input，每 2000 cycle 翻转一次
```

`200/2000` 表示翻转间隔，不是完整方波周期。软件 directed test 不通过 SET/CLR/PULSE_CMD 控制 bit 30/31，避免与周期源冲突。

GPIO directed test 可以通过 mailbox 请求：

- 指定 bit 置 1，用于高电平或上升沿触发。
- 指定 bit 清 0，用于低电平或下降沿触发。
- 指定 GPIO bit、pulse 宽度和 pulse 电平，用于短事件触发。

GPIO 输入进入 `mmio_gpio` 后仍按外设实现经过两级同步。测试程序不应依赖 GPIO pending 精确到命令 store 后第几拍出现，只检查最终 pending/handler 行为。

### 12.4 trap trace `已完成`

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

### 12.5 平台头文件准备 `已完成`

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

当前 `platform.h` 已调整为 C/ASM 共享头文件：

- 公共地址、offset、bit mask 使用 `#define`，保持 C 和 `.S` 汇编预处理都可用。
- `#include <stdint.h>`、`static inline` 函数等 C-only 内容使用 `#ifndef __ASSEMBLER__` 保护。
- C 测试继续通过 `platform.h` 使用常量和 helper。
- 汇编测试通过 `#include "platform.h"` 复用常量，不再在每个 `.S` 文件重复 `.equ` 公共地址图、外设 offset、CSR bit mask、PASS/FAIL 地址等常量。
- 各汇编测试仍可保留测试私有常量；公共平台常量应统一来自 `platform.h`。

### 12.6 `tb_rv32i_soc_test.h` 规划 `已完成`

新增：

```text
sw/include/tb_rv32i_soc_test.h
```

该文件专门描述 `tb/sv/tb_rv32i_soc.sv` 的仿真 mailbox 约定，让 C/ASM directed test 能通过普通 DMEM store 请求 TB 产生外部激励。

已实现内容：

```c
#define TB_CMD_BASE               (DMEM_BASE + RV32I_U32_C(0x00000180))
#define TB_GPIO0_SET_MASK_ADDR    (TB_CMD_BASE + RV32I_U32_C(0x00))
#define TB_GPIO0_CLR_MASK_ADDR    (TB_CMD_BASE + RV32I_U32_C(0x04))
#define TB_GPIO0_PULSE_CMD_ADDR   (TB_CMD_BASE + RV32I_U32_C(0x08))
#define TB_UART0_RX_ADDR          (TB_CMD_BASE + RV32I_U32_C(0x0c))

#define TB_GPIO0_FAST_PERIODIC_BIT    RV32I_U32_C(30)
#define TB_GPIO0_SLOW_PERIODIC_BIT    RV32I_U32_C(31)
#define TB_GPIO0_FAST_PERIODIC_MASK   (RV32I_U32_C(1) << TB_GPIO0_FAST_PERIODIC_BIT)
#define TB_GPIO0_SLOW_PERIODIC_MASK   (RV32I_U32_C(1) << TB_GPIO0_SLOW_PERIODIC_BIT)
#define TB_GPIO0_FAST_TOGGLE_CYCLES   RV32I_U32_C(200)
#define TB_GPIO0_SLOW_TOGGLE_CYCLES   RV32I_U32_C(2000)
```

头文件应 `#include "platform.h"`，复用 `DMEM_BASE` 和 C 侧 `mmio_write32` helper。

C-only helper 使用 `#ifndef __ASSEMBLER__` 保护：

```c
static inline void tb_gpio0_set_mask(uint32_t mask);
static inline void tb_gpio0_clear_mask(uint32_t mask);
static inline void tb_gpio0_pulse(uint32_t gpio_idx, uint8_t pulse_cycles, bool pulse_level);
static inline void tb_uart0_rx(uint8_t data);
```

汇编测试只依赖 `#define` 常量，不强制提供汇编宏。若后续多个汇编 interrupt 测试重复出现同类 store 序列，再补预处理宏；第一版保持简单。

### 12.7 汇编公共 include 与测试改造 `已完成`

修改 `sim/soc_asm/05_build_mem.sh`：

```text
-I "${REPO_ROOT}/sw/include"
```

使 `.S` 测试可以直接：

```asm
#include "platform.h"
#include "tb_rv32i_soc_test.h"   // 仅使用 tb_rv32i_soc.sv mailbox 的测试需要
```

本步完成后，改造当前已有所有使用 `.equ` 定义公共常量的汇编程序：

- SoC/DMEM/TEST_STATUS 地址常量改用 `platform.h`。
- GPIO/UART/TIMER32 base/offset/bit mask 改用 `platform.h`。
- 需要 TB 激励的汇编测试使用 `tb_rv32i_soc_test.h` 的 mailbox 地址。
- 不把 `tb_rv32i_soc_test.h` 引入普通硬件无关汇编测试，避免测试和 TB 协议无关时产生不必要依赖。

汇编侧是否提供“函数式 helper”不强制。对于 mailbox 请求，汇编测试可以直接构造 `rs2` 后 `sw` 到对应地址；若后续重复较多，再在 `tb_rv32i_soc_test.h` 中增加预处理宏。

### 12.8 `sw/include` 文档 `已完成`

新增：

```text
sw/include/readme.md
```

说明本目录头文件的分层和适用范围：

- `platform.h`：当前 SoC 平台的软件可见地址图、外设 offset/bit mask、CSR bit mask，以及 C 侧基础 helper；C/ASM 共享常量。
- `tb_rv32i_soc_test.h`：`tb_rv32i_soc.sv` 专用仿真 mailbox 协议；只给 directed test 使用，不属于真实 SoC 或通用外设 ABI。
- `rtl/periph/readme.md` 仍是外设 module 的通用寄存器 ABI 手册；拿到具体 SoC 地址图后，软件维护 `platform.h` 时应以该手册解释各实例寄存器语义。

## 13. interrupt directed test 程序规划 `已完成`

本组测试继续使用程序自检口径：测试程序负责配置外设和 CSR，必要时通过 `tb_rv32i_soc_test.h` 请求 TB 产生 GPIO/UART 外部激励；handler 检查 `mcause/mepc/mip`、外设 pending/status 和恢复路径，最后由 `main()` 返回值通过 `crt0.S` 写 PASS/FAIL。

### 13.0 `0751_timer_smoke` `已完成`

无需 tb 驱动信号，只需 SoC 内部 timer 产生 MTIP 即可，兼容为修改的 SoC 测试平台 tb 也能产生中断。

### 13.1 `0752_gpio_irq_basic.c` `已完成`

覆盖 GPIO0 外部中断基础行为：

- `IRQ_EN` 与 `IRQ_STATUS = IRQ_PENDING & IRQ_EN`。
- 上升沿、下降沿、高电平、低电平四类触发条件。
- `IRQ_PENDING` R/W1C 清除行为。
- GPIO 输入两级同步后的最终 pending/handler 行为。
- GPIO interrupt 进入 core 后表现为 machine external interrupt（`mcause` interrupt bit = 1，cause code = 11）。

### 13.2 `0753_uart_rx_irq.c` `已完成`

覆盖 UART0 RX 与 UART external interrupt：

- TB 注入 `uart0_rx_valid/rx_data` 后，`RXDATA` 保存 byte。
- `STATUS.rx_valid`、`STATUS.irq_pending`、`IRQ_PENDING[0]` 置位。
- `CTRL.rx_irq_enable=0` 时 pending 可以置位，但不应推动 `uart0_irq_o/MEIP`。
- `CTRL.rx_irq_enable=1` 后 pending 推动 machine external interrupt。
- 读 `RXDATA` 清 `rx_valid` 和 `IRQ_PENDING[0]`。
- 写 `IRQ_PENDING[0]=1` 只清 pending，不消费 `RXDATA`。

### 13.3 `0754_external_timer_priority.c` `已完成`

覆盖 MEIP/MTIP 汇总和中断优先级：

- 同时制造 external pending（GPIO 或 UART）和 timer pending。
- 同时打开 `MIE_MEIE | MIE_MTIE` 与 `mstatus.MIE`。
- 验证 first trap 选择 machine external interrupt。
- handler 清 external pending 后，仍存在的 timer pending 应触发 machine timer interrupt。
- 验证 `mip.MEIP/MIP.MTIP` 与外设 pending 状态一致。

### 13.4 `0705_interrupt_commit_precise.S` `已完成`

覆盖 CSR 写同拍 interrupt 的精确提交语义，建议汇编实现：

- pending 已经存在时，通过 CSR 指令打开 `mie.MEIE` 或 `mstatus.MIE`。
- 当前 CSR 指令必须先完成提交，再接受 interrupt。
- interrupt 的 `mepc` 应指向 CSR 指令之后的返回 PC。
- 若 CSR 写更新 `mtvec` 后同拍接受 interrupt，redirect 应使用新 `mtvec`。
- interrupt 不应错误 kill 已提交的 older 指令写回。

### 13.5 `0706_mret_interrupt_reentry.S` `已完成`

覆盖 MRET 同拍 interrupt 语义，建议汇编实现：

- handler 第一次进入时保留 external pending，不清中断源。
- 执行 `mret` 时若 `MPIE` 允许中断，应在 MRET 返回边界立即再次接受 interrupt。
- 第二次 handler 清 pending 后再 `mret`，应正常回到主流程。
- 验证 MRET+interrupt 时 `mepc/mcause/mstatus.MIE/MPIE` 符合“先 MRET，再 interrupt entry”的语义。

### 13.6 `0757_gpio_periodic_irq.c` `已完成`

覆盖 TB 固定周期 GPIO 输入：

- 使用 `gpio0_in[30]` fast periodic input 验证周期边沿可被 GPIO 捕获。
- 使用 `gpio0_in[31]` slow periodic input 验证较慢外部变化不会影响 mailbox 控制位。
- 软件不通过 SET/CLR/PULSE_CMD 控制 bit[31:30]。
- 只检查最终事件计数和 pending/handler 行为，不依赖精确到某一条指令的触发拍。

## 14. 文档和注释同步 `已完成`
