# v2.1 最小 M-mode CSR 与 trap 执行计划

当前五级流水线 v2.0 已完成 37 条 RV32I 主路径、forwarding、load-use stall 和 branch/JAL/JALR control hazard。本计划根据 `docs/08xx/0831 最小M-mode CSR与trap规划.md` 编写，把下一阶段拆成可直接施工的 RTL 步骤。

本计划只写实现拆分，暂不写验证、测试程序和回归命令。

## 0. 实现边界

本阶段目标：

- 五级流水 `core_pipeline5` 支持最小 M-mode CSR/trap。
- 支持 `FENCE` 作为 NOP。
- 支持 `ECALL`、`EBREAK`、`MRET`。
- 支持 6 条 Zicsr 指令：`CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI`。
- 支持最小 CSR：`mstatus/mtvec/mscratch/mepc/mcause/mtval`。
- 建议同时支持只读 CSR：`mvendorid/marchid/mimpid/mhartid/misa`。
- 支持 synchronous exception：instruction address misaligned、illegal instruction、breakpoint、load address misaligned、store address misaligned、environment call from M-mode。
- trap 接受点放在 MEM/commit 附近，保证 older instruction 正常提交，faulting instruction 不产生错误副作用，younger instruction 被 kill。

本阶段不做：

- interrupt。
- MMIO timer。
- S-mode/U-mode。
- delegation。
- PMP/MMU。
- nested trap 完整策略。
- vectored `mtvec`。第一版只支持 direct mode，`mtvec[1:0]` 写入后按 WARL 归零。
- `mcycle/minstret` 可先不做，后续单独补。

单周期顶层 `core_single_cycle.sv` 不是本阶段功能目标。但 `id_stage/ex_stage/mem_stage/wb_stage` 是共享模块，新增端口后需要给单周期顶层做最小兼容连接，保证原有单周期合法 RV32I 程序仍可编译。

## 1. 先补公共类型和常量 `已完成`

### 1.1 修改 `rtl/common/core_pkg.sv` `已完成`

新增或恢复 opcode：

- 恢复 `OPCODE_MISC_MEM = 7'b0001111`，用于 `FENCE`。
- 恢复 `OPCODE_SYSTEM = 7'b1110011`，用于 `ECALL/EBREAK/MRET/CSR*`。

扩展 `instr_id_e`：

- 新增 `INSTR_FENCE`。
- 新增 `INSTR_ECALL`。
- 新增 `INSTR_EBREAK`。
- 新增 `INSTR_MRET`。
- 新增 `INSTR_CSRRW`。
- 新增 `INSTR_CSRRS`。
- 新增 `INSTR_CSRRC`。
- 新增 `INSTR_CSRRWI`。
- 新增 `INSTR_CSRRSI`。
- 新增 `INSTR_CSRRCI`。

扩展写回来源：

- 将 `wb_sel_e` 从 2 bit 扩成 3 bit。
- 新增 `WB_CSR`，表示写回 CSR 修改前的旧值。

新增 CSR 操作枚举：

```systemverilog
typedef enum logic [2:0] {
    CSR_OP_NONE,
    CSR_OP_RW,
    CSR_OP_RS,
    CSR_OP_RC,
    CSR_OP_RWI,
    CSR_OP_RSI,
    CSR_OP_RCI
} csr_op_e;
```

新增 trap cause 枚举或常量：

```systemverilog
typedef enum logic [4:0] {
    TRAP_CAUSE_INST_ADDR_MISALIGNED  = 5'd0,
    TRAP_CAUSE_ILLEGAL_INSTR         = 5'd2,
    TRAP_CAUSE_BREAKPOINT            = 5'd3,
    TRAP_CAUSE_LOAD_ADDR_MISALIGNED  = 5'd4,
    TRAP_CAUSE_STORE_ADDR_MISALIGNED = 5'd6,
    TRAP_CAUSE_ECALL_M               = 5'd11
} trap_cause_e;
```

新增 CSR 地址常量：

- `CSR_ADDR_MSTATUS = 12'h300`
- `CSR_ADDR_MISA = 12'h301`
- `CSR_ADDR_MTVEC = 12'h305`
- `CSR_ADDR_MSCRATCH = 12'h340`
- `CSR_ADDR_MEPC = 12'h341`
- `CSR_ADDR_MCAUSE = 12'h342`
- `CSR_ADDR_MTVAL = 12'h343`
- `CSR_ADDR_MVENDORID = 12'hF11`
- `CSR_ADDR_MARCHID = 12'hF12`
- `CSR_ADDR_MIMPID = 12'hF13`
- `CSR_ADDR_MHARTID = 12'hF14`

新增 `mstatus` bit 常量：

- `MSTATUS_MIE_BIT = 3`
- `MSTATUS_MPIE_BIT = 7`
- `MSTATUS_MPP_LSB = 11`
- `MSTATUS_MPP_MSB = 12`
- `MSTATUS_MPP_M = 2'b11`

### 1.2 修改 `rtl/common/pipeline_pkg.sv` `已完成`

在流水线寄存器 struct 中加入 exception、CSR、`MRET` 相关字段。

同时把现有 `id_stage.instr_id_o` 送入流水线寄存器。`instr_id` 只作为 debug、trace、后续断言和 commit 观察用，不替代 `mret/fence/CSR/exception` 等专用控制信号，避免后级重新按 `instr_id` 分散译码。

`id_ex_reg_t` 新增字段建议放在 `illegal_instr` 附近：

- `core_pkg::instr_id_e instr_id;`
- `logic exception_valid;`
- `core_pkg::trap_cause_e exception_cause;`
- `logic [core_pkg::XLEN-1:0] exception_tval;`
- `logic fence;`
- `logic mret;`
- `logic csr_en;`
- `core_pkg::csr_op_e csr_op;`
- `logic [11:0] csr_addr;`
- `logic [4:0] csr_uimm;`
- `logic csr_uses_rs1;`
- `logic csr_writes_rd;`
- `logic csr_write_en;`

`ex_mem_reg_t` 新增字段：

- `core_pkg::instr_id_e instr_id;`
- `logic exception_valid;`
- `core_pkg::trap_cause_e exception_cause;`
- `logic [core_pkg::XLEN-1:0] exception_tval;`
- `logic fence;`
- `logic mret;`
- `logic csr_en;`
- `core_pkg::csr_op_e csr_op;`
- `logic [11:0] csr_addr;`
- `logic [core_pkg::XLEN-1:0] csr_wdata;`
- `logic csr_writes_rd;`
- `logic csr_write_en;`

`mem_wb_reg_t` 新增字段：

- `core_pkg::instr_id_e instr_id;`
- `logic [core_pkg::XLEN-1:0] csr_rdata;`

说明：

- `instr_id` 从 ID 产生后随指令一直传到 MEM/WB，用于波形观察、commit trace、后续 assertion/统计；功能控制仍然使用已经译码出的专用控制字段。
- `exception_valid/cause/tval` 从 ID 或 EX 产生后随指令向 MEM 传递。
- `csr_wdata` 应在 EX 阶段用 forwarding 后的 rs1 数据或 `csr_uimm` 生成，避免 CSR 指令读取到旧 GPR 值。
- `csr_write_en` 表示这条 CSR 指令是否真的尝试写 CSR。它和 `csr_wdata != 0` 不是一回事：`CSRRS/CSRRC` 看 `rs1_addr != x0`，即使 rs1 数据为 0，也仍然是一次 CSR 写尝试。
- `csr_rdata` 是 CSR 指令在 MEM 阶段读出的旧 CSR 值，进入 WB 后通过 `WB_CSR` 写回 GPR。

## 2. 新增 CSR 文件 `已完成`

### 2.1 新建 `rtl/core/csr_file.sv` `已完成`

该模块保存 M-mode CSR 状态，并集中处理三类写 CSR 的来源：

1. 普通 CSR 指令提交。
2. trap entry。
3. `MRET` 返回时恢复 `mstatus`。

建议端口：

```systemverilog
module csr_file (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      csr_valid_i,
    input  core_pkg::csr_op_e         csr_op_i,
    input  logic [11:0]               csr_addr_i,
    input  logic [core_pkg::XLEN-1:0] csr_operand_i,
    input  logic                      csr_write_en_i,

    output logic [core_pkg::XLEN-1:0] csr_rdata_o,
    output logic                      csr_illegal_o,

    input  logic                      trap_valid_i,
    input  logic [core_pkg::XLEN-1:0] trap_pc_i,
    input  core_pkg::trap_cause_e     trap_cause_i,
    input  logic [core_pkg::XLEN-1:0] trap_tval_i,

    input  logic                      mret_valid_i,

    output logic [core_pkg::XLEN-1:0] mtvec_o,
    output logic [core_pkg::XLEN-1:0] mepc_o,
    output logic [core_pkg::XLEN-1:0] mstatus_o
);
```

说明：

- `csr_operand_i` 是 CSR 写操作数，来自 EX 阶段 forwarding 后的 `rs1` 数据或零扩展 `uimm`。
- `csr_file` 不接收 `csr_writes_rd_i`。CSR 旧值是否写回 GPR 属于 WB 阶段行为，应由流水线寄存器继续传递 `csr_writes_rd`。

### 2.2 CSR 状态寄存器 `已完成`

内部寄存器：

- `mstatus`
- `mtvec`
- `mscratch`
- `mepc`
- `mcause`
- `mtval`

当前实现直接使用 CSR 名作为寄存器名，不强制使用 `_q` 后缀；这些寄存器仍然是同步写状态。

复位值：

- `mstatus` 复位后 `MIE=0`，`MPIE=0`，`MPP=M-mode`。
- `mtvec` 复位为 `core_pkg::MTVEC_RESET`，当前为 `IMEM_BASE + 32'h80`，作为平台默认 direct-mode trap 入口。
- `mscratch/mepc/mcause/mtval` 复位为 0。
- RTL 中先将 `mstatus` 整体清 0，再将 `mstatus[12:11]` 写为 `MSTATUS_MPP_M`；这是为了明确保留 M-only 核的 MPP 合法值。

> RTL 之外的配套改动暂不在本步实施：由于 2.2 把 `mtvec` 复位值改为 `MTVEC_RESET`，后续 linker script、启动代码和 trap 测试程序需要约定 `.text.trap`/`__trap_vector`，并在软件启动阶段显式写 `mtvec`。见文末“11. RTL 之外的后续配套改动”。

只读 CSR 可以不建寄存器，直接在读 mux 中返回常量：

- `mvendorid = 0`
- `marchid = 0`
- `mimpid = 0`
- `mhartid = 0`
- `misa = 32'h4000_0100`，表示 RV32 + I

### 2.3 CSR 读、写和非法访问判断 `已完成`

组合读：

- 根据 `csr_addr_i` 返回对应 CSR 当前值。
- 不存在的 CSR 返回 0，同时 `csr_illegal_o = csr_valid_i`。
- 只读 CSR 被写时，`csr_illegal_o = 1`。

CSR 写使能：

- `CSRRW/CSRRWI` 总是写 CSR。
- `CSRRS/CSRRC` 在 `rs1_addr != x0` 时写 CSR，即使 rs1 数据值为 0 也算写尝试。
- `CSRRSI/CSRRCI` 在 `uimm != 0` 时写 CSR。
- `csr_valid_i == 0` 或当前 CSR 访问非法时不更新 CSR 状态。
- 建议由 decoder 直接生成 `csr_write_en_i`，CSR 文件使用 `csr_valid_i && csr_write_en_i` 判断当前是否有 CSR 写请求，并组合判断只读 CSR 写入或未支持 CSR 地址。
- 非法 CSR 写在 CSR 写端口的 `default` 分支中不更新任何状态，非法信息由组合 `csr_illegal_o` 输出。

CSR 新值计算：

- `CSR_OP_RW/RWI`: `csr_new = csr_operand_i`
- `CSR_OP_RS/RSI`: `csr_new = csr_old | csr_operand_i`
- `CSR_OP_RC/RCI`: `csr_new = csr_old & ~csr_operand_i`

WARL 处理：

- 写 `mtvec` 时低 2 bit 清零，只支持 direct mode。
- 写 `mepc` 时低 2 bit 清零，当前不支持 C 扩展，返回地址按 4 字节对齐。
- 写 `mstatus` 时只保留 `MIE/MPIE/MPP` 相关位，`MPP` 保持 M-mode 合法值。

### 2.4 trap entry 和 MRET 写 CSR 及优先级处理 `已完成`

同一拍若多个来源同时有效，优先级：

```text
trap_valid_i > mret_valid_i > normal csr write
```

trap entry 行为：

- `mepc <= trap_pc_i`
- `mcause <= trap_cause_i`
- `mtval <= trap_tval_i`
- `mstatus.MPIE <= mstatus.MIE`
- `mstatus.MIE <= 0`
- `mstatus.MPP <= M-mode`

`MRET` 行为：

- `mstatus.MIE <= mstatus.MPIE`
- `mstatus.MPIE <= 1`
- `mstatus.MPP <= M-mode`

## 3. 新增 trap 控制模块 `已完成`

### 3.1 新建 `rtl/core/trap_ctrl.sv` `已完成`

该模块只做控制选择，不保存 CSR 状态。它汇总 MEM 附近的 exception、CSR illegal、`MRET`，输出 PC redirect、flush/kill 和 CSR 写控制。

建议端口：

```systemverilog
module trap_ctrl (
    input  logic                      mem_valid_i,
    input  logic [core_pkg::XLEN-1:0] mem_pc_i,
    input  logic [core_pkg::ILEN-1:0] mem_instr_i,
    input  logic                      mem_mret_i,

    input  logic                      mem_exception_valid_i,
    input  core_pkg::trap_cause_e     mem_exception_cause_i,
    input  logic [core_pkg::XLEN-1:0] mem_exception_tval_i,

    input  logic                      mem_csr_valid_i,
    input  logic                      mem_csr_illegal_i,

    input  logic [core_pkg::XLEN-1:0] csr_mtvec_i,
    input  logic [core_pkg::XLEN-1:0] csr_mepc_i,

    output logic                      trap_valid_o,
    output logic [core_pkg::XLEN-1:0] trap_pc_o,
    output core_pkg::trap_cause_e     trap_cause_o,
    output logic [core_pkg::XLEN-1:0] trap_tval_o,

    output logic                      mret_valid_o,

    output logic                      redirect_valid_o,
    output logic [core_pkg::XLEN-1:0] redirect_pc_o,

    output logic                      kill_if_id_o,
    output logic                      kill_id_ex_o,
    output logic                      kill_ex_mem_o,
    output logic                      kill_mem_wb_input_o
);
```

### 3.2 trap 选择逻辑 `已完成`

exception 来源分两类：

- `mem_exception_valid_i`：ID/EX/MEM 已经产生并随流水线带到 MEM 的 exception。
- `mem_csr_illegal_i`：CSR 文件在 MEM 对当前 CSR 指令判断出的非法 CSR 访问。

选择规则：

- `mem_valid_i && mem_csr_illegal_i` 时生成 illegal instruction exception，`tval = mem_instr_i`。
- 否则若 `mem_valid_i && mem_exception_valid_i`，使用随流水线带来的 cause/tval。
- 否则若 `mem_valid_i && mem_mret_i`，执行 `MRET` redirect。

redirect 优先级：

```text
trap entry / MRET > EX branch/JAL/JALR redirect > load-use stall
```

trap entry redirect：

- `redirect_valid_o = 1`
- `redirect_pc_o = csr_mtvec_i`
- `trap_valid_o = 1`
- `trap_pc_o = mem_pc_i`

MRET redirect：

- `redirect_valid_o = 1`
- `redirect_pc_o = csr_mepc_i`
- `mret_valid_o = 1`

### 3.3 kill 输出语义 `已完成`

当 trap entry 或 `MRET` 被接受时：

- `kill_if_id_o = 1`，杀掉 IF/ID 年轻指令。
- `kill_id_ex_o = 1`，杀掉 ID/EX 年轻指令。
- `kill_ex_mem_o = 1`，阻止当前 EX 阶段年轻指令进入 EX/MEM。
- `kill_mem_wb_input_o = 1`，阻止当前 MEM 指令作为普通指令进入 MEM/WB。

`kill_mem_wb_input_o` 很关键：

- faulting load 不能写 rd。
- faulting JAL/JALR 不能写 link rd。
- faulting CSR 不能写 rd。
- `MRET` 已在 MEM 被接受，不需要作为普通 WB 指令继续提交。

## 4. 扩展译码和 ID 阶段 `执行中`

### 4.1 修改 `rtl/core/decoder.sv`

新增输出端口：

- `fence_o`
- `ecall_o`
- `ebreak_o`
- `mret_o`
- `csr_en_o`
- `core_pkg::csr_op_e csr_op_o`
- `logic [11:0] csr_addr_o`
- `logic [4:0] csr_uimm_o`
- `logic csr_uses_rs1_o`
- `logic csr_writes_rd_o`
- `logic csr_write_en_o`
- `logic exception_valid_o`
- `core_pkg::trap_cause_e exception_cause_o`
- `logic [core_pkg::XLEN-1:0] exception_tval_o`

`OPCODE_MISC_MEM` 译码：

- `funct3 == 3'b000` 识别为 `INSTR_FENCE`。
- `FENCE` 不写 GPR，不访存，不跳转，ALU 可保持 `ALU_NONE`。
- 其他 `MISC_MEM` 编码先作为 illegal instruction。

`OPCODE_SYSTEM` 且 `funct3 == 3'b000`：

- `instr == 32'h0000_0073` 识别为 `ECALL`，产生 exception cause 11，`tval = 0`。
- `instr == 32'h0010_0073` 识别为 `EBREAK`，产生 exception cause 3，`tval = 0`。
- `instr == 32'h3020_0073` 识别为 `MRET`，不产生 exception，输出 `mret_o = 1`。
- 其他编码作为 illegal instruction，产生 exception cause 2，`tval = instr_i`。

`OPCODE_SYSTEM` 且 `funct3 != 3'b000`：

- 根据 `funct3` 识别 6 条 CSR 指令。
- `csr_addr_o = instr_i[31:20]`。
- `csr_uimm_o = instr_i[19:15]`。
- register 形式 `CSRRW/CSRRS/CSRRC`：`csr_uses_rs1_o = 1`。
- immediate 形式 `CSRRWI/CSRRSI/CSRRCI`：`csr_uses_rs1_o = 0`。
- CSR 指令写 rd 的数据是旧 CSR 值，`csr_writes_rd_o = (rd_addr_o != 5'd0)`。
- CSR 写 CSR 的意图由 `csr_write_en_o` 表示：
  - `CSRRW/CSRRWI`：`csr_write_en_o = 1`。
  - `CSRRS/CSRRC`：`csr_write_en_o = (rs1_addr_o != 5'd0)`。
  - `CSRRSI/CSRRCI`：`csr_write_en_o = (csr_uimm_o != 5'd0)`。
- `reg_we_o` 对 CSR 指令应等于 `csr_writes_rd_o`。
- `wb_sel_o = WB_CSR`。

`illegal_instr_o` 的语义要调整：

- 对无法识别的普通 opcode/funct，仍输出 illegal。
- 对 `ECALL/EBREAK`，不要输出 `illegal_instr_o`，而是输出 `exception_valid_o`。
- 对 CSR 地址是否存在、只读 CSR 是否被写，不在 decoder 做最终判断，交给 `csr_file.sv`。

`uses_rs1_o/uses_rs2_o` 要补 CSR 规则：

- CSR register 形式使用 rs1。
- CSR immediate 形式不使用 rs1。
- CSR 指令不使用 rs2。
- `ECALL/EBREAK/MRET/FENCE` 不使用 GPR 源寄存器。

### 4.2 修改 `rtl/core/id_stage.sv`

新增输出端口并从 decoder 透传：

- `instr_id_o`
- `fence_o`
- `mret_o`
- `csr_en_o`
- `csr_op_o`
- `csr_addr_o`
- `csr_uimm_o`
- `csr_uses_rs1_o`
- `csr_writes_rd_o`
- `csr_write_en_o`
- `exception_valid_o`
- `exception_cause_o`
- `exception_tval_o`

ID 阶段 exception 初始规则：

- `illegal_instr_o` 可以继续作为调试信号保留。
- `exception_valid_o = if_valid_i & decoder_exception_valid`。
- 对非法普通指令，`exception_cause_o = TRAP_CAUSE_ILLEGAL_INSTR`，`exception_tval_o = if_instr_i`。
- 对 `ECALL/EBREAK`，使用 decoder 给出的 cause/tval。

## 5. 扩展 EX 阶段

### 5.1 修改 `rtl/core/ex_stage.sv`

新增输入端口：

- `exception_valid_i`
- `exception_cause_i`
- `exception_tval_i`
- `csr_en_i`
- `csr_op_i`
- `csr_uimm_i`
- `mret_i`

新增输出端口：

- `exception_valid_o`
- `exception_cause_o`
- `exception_tval_o`
- `csr_wdata_o`
- `mret_o`

### 5.2 检查 instruction address misaligned

当前 `ex_stage` 对 branch/JAL/JALR 直接输出 redirect。加入 trap 后要改为：

- 先计算原始跳转目标 `branch_target`。
- JALR 目标继续执行 `target = alu_result & ~32'b1`。
- 当 `valid_i && (branch_taken || jump_i) && target[1:0] != 2'b00` 时，产生 instruction address misaligned exception：
  - `exception_valid_o = 1`
  - `exception_cause_o = TRAP_CAUSE_INST_ADDR_MISALIGNED`
  - `exception_tval_o = target`
  - `redirect_valid_o = 0`
- 当没有 target misaligned 时，原 branch/JAL/JALR redirect 逻辑保持不变。

如果输入已经带有 `exception_valid_i`：

- EX 不应再产生普通 redirect。
- exception 继续向 EX/MEM 传递。
- ALU 结果可以照常计算，但后续副作用必须由 trap kill 屏蔽。

### 5.3 生成 CSR 写源数据

在 EX 阶段生成 `csr_wdata_o`：

- `CSR_OP_RW/RS/RC` 使用 forwarding 后的 `rs1_data_i`。
- `CSR_OP_RWI/RSI/RCI` 使用 `{27'b0, csr_uimm_i}`。
- 非 CSR 指令输出 0。

这样 CSR 指令和普通 ALU 指令共用现有 GPR forwarding 结果，避免 CSR 源寄存器读到旧值。

## 6. 扩展 MEM 阶段

### 6.1 修改 `rtl/core/mem_stage.sv`

保留现有 `mem_misaligned_o`，同时新增更明确的输出：

- `load_misaligned_o`
- `store_misaligned_o`
- `exception_valid_o`
- `exception_cause_o`
- `exception_tval_o`

### 6.2 拆分 load/store misaligned

当前 `mem_misaligned_o` 已能判断 half/word 对齐错误。需要拆成：

- `load_misaligned_o = valid_i && mem_re_i && addr_misaligned`
- `store_misaligned_o = valid_i && mem_we_i && addr_misaligned`
- `mem_misaligned_o = load_misaligned_o | store_misaligned_o`

exception 输出：

- load 不对齐：cause 4，tval = `alu_result_i`
- store 不对齐：cause 6，tval = `alu_result_i`
- 无不对齐：不产生 MEM exception

### 6.3 保持错误访存副作用屏蔽

现有逻辑已经有：

- `dmem_re_o = valid_i & ~mem_misaligned_o & mem_re_i`
- `dmem_we_o = valid_i & ~mem_misaligned_o & mem_we_i`

这一点保留。后续顶层还要配合 `trap_ctrl.kill_mem_wb_input_o`，保证 faulting load 不进入 WB 写 rd。

## 7. 扩展 WB 和 forwarding/hazard

### 7.1 修改 `rtl/core/wb_stage.sv`

新增输入：

- `logic [core_pkg::XLEN-1:0] csr_rdata_i`

修改写回 mux：

- `WB_CSR: wb_wdata_o = csr_rdata_i`

`reg_we_o` 仍由 `valid_i & reg_we_i` 控制。faulting instruction 是否进入 WB，由顶层通过 `mem_wb_valid_i` 统一屏蔽。

### 7.2 修改 `rtl/core/forwarding_unit.sv`

已有 `MEM/WB -> EX` 使用 `mem_wb_wdata_i`，只要 `wb_stage` 支持 `WB_CSR`，这里自然支持 CSR 写 rd 后的前递。

需要额外修改 EX/MEM 前递 mux：

- `WB_CSR` 不从 EX/MEM 前递。
- CSR 旧值在 EX/MEM/MEM 阶段才读出，和 load 一样不能作为普通 EX/MEM ALU 结果前递。
- EX/MEM 命中且 `wb_sel == WB_CSR` 时保持 `FWD_GPR`，由 hazard_unit 插入一拍 stall 后走 MEM/WB 前递。

### 7.3 修改 `rtl/core/hazard_unit.sv`

新增输入：

- `id_ex_reg_we_i`
- `id_ex_wb_sel_i`
- 或者更直接新增 `id_ex_result_late_i`

扩展 load-use stall 为 late-result-use stall：

```text
late_result = id_ex_mem_re_i || (id_ex_reg_we_i && id_ex_wb_sel_i == WB_CSR)
```

stall 条件仍是：

- IF/ID 有效。
- ID/EX 有效。
- ID/EX 会写 rd。
- ID 当前指令使用 rs1 或 rs2。
- ID rs 命中 ID/EX rd。

这样 back-to-back `csrr x1, ...; add x2, x1, x3` 会 stall 一拍，等 CSR 旧值进入 MEM/WB 后再前递。

同时增加 trap redirect 输入：

- `trap_redirect_valid_i`

优先级改为：

```text
trap_redirect_valid_i > ex_redirect_valid_i > late-result-use stall
```

输出策略：

- trap redirect 时至少 flush IF/ID 和 ID/EX。
- EX/MEM 的 younger kill 由 `trap_ctrl.kill_ex_mem_o` 直接连到 EX/MEM 寄存器，不建议混在 hazard_unit 里。

## 8. 扩展流水线寄存器 kill 能力

### 8.1 修改 `rtl/core/pipe_reg.sv`

`pipe_reg_if_id` 和 `pipe_reg_id_ex` 已有 flush，可继续使用。

`pipe_reg_ex_mem` 需要新增 `flush_i` 或 `kill_i`：

- 优先级：reset > flush/kill > stall > normal advance。
- trap/MRET 在 MEM 被接受时，当前 EX 阶段指令是 younger instruction，不能在同一拍进入 EX/MEM。

`pipe_reg_mem_wb` 可以不新增 flush 端口，顶层用 `valid_i = mem_valid & ~kill_mem_wb_input` 即可。

### 8.2 修改注释

当前 `pipe_reg.sv` 注释写着 EX/MEM 和 MEM/WB 不需要 flush。加入 trap 后这句话过时，需要改成：

- branch/JAL/JALR 的 EX redirect 仍只需要 flush IF/ID 和 ID/EX。
- trap/MRET 在 MEM 接受时，需要额外 kill 当前 EX -> EX/MEM 的年轻指令。
- MEM/WB 输入由 `kill_mem_wb_input` 屏蔽，避免 faulting instruction 作为普通指令写回。

## 9. 集成到 `core_pipeline5.sv`

### 9.1 新增顶层信号

PC redirect 信号拆分：

- `ex_redirect_valid/ex_redirect_pc`
- `trap_redirect_valid/trap_redirect_pc`
- `redirect_valid/redirect_pc`

最终 PC redirect 选择：

```systemverilog
assign redirect_valid = trap_redirect_valid | ex_redirect_valid;
assign redirect_pc    = trap_redirect_valid ? trap_redirect_pc : ex_redirect_pc;
```

注意：`hazard_unit` 也要看到 trap redirect 优先级，不能让 load-use stall 卡住 trap/MRET redirect。

新增 trap/CSR 信号：

- `mem_csr_rdata`
- `mem_csr_illegal`
- `trap_valid`
- `trap_pc`
- `trap_cause`
- `trap_tval`
- `mret_valid`
- `kill_ex_mem`
- `kill_mem_wb_input`

### 9.2 实例化 `csr_file`

在 `core_pipeline5.sv` 中实例化：

```systemverilog
csr_file u_csr_file (...);
```

普通 CSR 指令输入来自 MEM 阶段所在的 `ex_mem_data_q`：

- `csr_valid_i = ex_mem_valid & ex_mem_data_q.csr_en & ~ex_mem_data_q.exception_valid`
- `csr_op_i = ex_mem_data_q.csr_op`
- `csr_addr_i = ex_mem_data_q.csr_addr`
- `csr_operand_i = ex_mem_data_q.csr_wdata`
- `csr_write_en_i = ex_mem_data_q.csr_write_en`

trap entry 输入来自 `trap_ctrl`：

- `trap_valid_i = trap_valid`
- `trap_pc_i = trap_pc`
- `trap_cause_i = trap_cause`
- `trap_tval_i = trap_tval`

MRET 输入：

- `mret_valid_i = mret_valid`

输出：

- `csr_rdata_o` 接到 `mem_wb_data_d.csr_rdata`。
- `csr_illegal_o` 接到 `trap_ctrl`。
- `mtvec_o/mepc_o` 接到 `trap_ctrl`。

### 9.3 实例化 `trap_ctrl`

在 MEM 阶段组合结果之后实例化：

```systemverilog
trap_ctrl u_trap_ctrl (...);
```

输入来源：

- `mem_valid_i = ex_mem_valid`
- `mem_pc_i = ex_mem_data_q.pc`
- `mem_instr_i = ex_mem_data_q.instr`
- `mem_exception_valid_i = ex_mem_data_q.exception_valid | mem_exception_valid`
- `mem_exception_cause_i` 需要在 ID/EX/EX exception 和 MEM misaligned exception 间选择。
- `mem_exception_tval_i` 同上。
- `mem_csr_valid_i = ex_mem_data_q.csr_en`
- `mem_csr_illegal_i = mem_csr_illegal`
- `mem_mret_i = ex_mem_data_q.mret`
- `csr_mtvec_i = csr_mtvec`
- `csr_mepc_i = csr_mepc`

MEM exception 选择优先级：

```text
MEM load/store misaligned > EX/ID 已携带 exception
```

正常情况下，带 exception 的指令不应该再发起 dmem 访问；但这个优先级能防止后续改动时出现不明确行为。

### 9.4 修改 PC 和 hazard 连接

`pc_reg` 改为接最终 redirect：

- `.redirect_pc_i(redirect_pc)`
- `.redirect_valid_i(redirect_valid)`

`hazard_unit` 增加：

- `.trap_redirect_valid_i(trap_redirect_valid)`
- `.redirect_valid_i(ex_redirect_valid)`

`stall_if` 不能在 trap redirect 时冻结 PC。trap redirect 的优先级必须高于 stall。

### 9.5 修改 IF/ID、ID/EX 组包

ID/EX 组包新增：

- `instr_id = id_instr_id`
- `exception_valid`
- `exception_cause`
- `exception_tval`
- `fence`
- `mret`
- `csr_en`
- `csr_op`
- `csr_addr`
- `csr_uimm`
- `csr_uses_rs1`
- `csr_writes_rd`
- `csr_write_en`

若当前 ID 指令 invalid，所有新增控制字段应为 0 或 `*_NONE`。

### 9.6 修改 EX/MEM 组包

EX/MEM 组包新增：

- `instr_id = id_ex_data_q.instr_id`
- `exception_valid = ex_exception_valid`
- `exception_cause = ex_exception_cause`
- `exception_tval = ex_exception_tval`
- `fence = id_ex_data_q.fence`
- `mret = id_ex_data_q.mret`
- `csr_en = id_ex_data_q.csr_en`
- `csr_op = id_ex_data_q.csr_op`
- `csr_addr = id_ex_data_q.csr_addr`
- `csr_wdata = ex_csr_wdata`
- `csr_writes_rd = id_ex_data_q.csr_writes_rd`
- `csr_write_en = id_ex_data_q.csr_write_en`

`pipe_reg_ex_mem` 新增：

- `.flush_i(kill_ex_mem)`

### 9.7 修改 MEM/WB 组包

MEM/WB valid 输入：

```systemverilog
wire mem_wb_valid_i = mem_valid & ~kill_mem_wb_input;
```

`pipe_reg_mem_wb.valid_i` 改接 `mem_wb_valid_i`。

MEM/WB 组包新增：

- `instr_id = ex_mem_data_q.instr_id`
- `csr_rdata = mem_csr_rdata`

普通字段需要做副作用屏蔽：

- faulting instruction 不进入 MEM/WB，所以 `reg_we` 可以继续从 `ex_mem_data_q.reg_we` 透传。
- 如果后续选择让 trap 指令进入 MEM/WB 做 trace，也必须强制 `reg_we = 0`，当前计划不采用这个做法。

### 9.8 修改 WB 实例

`wb_stage` 新增端口连接：

- `.csr_rdata_i(mem_wb_data_q.csr_rdata)`

`wb_stage` 内部支持 `WB_CSR` 后，commit 写回信号保持原有路径。

### 9.9 修改顶层调试输出

现有端口：

- `illegal_instr_o`
- `mem_misaligned_o`

保留，但语义调整为观察信号，不再代表 testbench 必须停机。

建议新增顶层输出：

- `trap_valid_o`
- `trap_pc_o`
- `trap_cause_o`
- `trap_tval_o`
- `trap_return_o`
- `trap_return_pc_o`

连接方式：

- `trap_valid_o = trap_valid`
- `trap_pc_o = trap_pc`
- `trap_cause_o = trap_cause`
- `trap_tval_o = trap_tval`
- `trap_return_o = mret_valid`
- `trap_return_pc_o = csr_mepc`

这些信号只用于观察和后续 testbench trace，不参与功能闭环。

`instr_id` 已随流水线进入 MEM/WB，可用于后续 commit trace 打印当前提交指令类型，或在 testbench/assertion 中统计 trap/CSR/branch 等指令提交情况。当前功能逻辑仍不依赖 `instr_id` 反推控制信号。

## 10. 单周期顶层的最小兼容改动

修改 `rtl/core/core_single_cycle.sv`，只处理共享 stage 新增端口导致的编译影响。

### 10.1 `id_stage` 新端口

新增 wire 接住或悬空：

- CSR 控制输出可声明本地 wire。
- exception 输出可接本地 wire。
- 单周期当前不实例化 `csr_file/trap_ctrl`，这些 wire 暂不参与 PC redirect。

### 10.2 `ex_stage` 新端口

输入：

- ID exception wire 接入。
- CSR 控制 wire 接入。
- `mret` wire 接入。

输出：

- EX exception wire 接住。
- CSR 写源 wire 接住。
- `mret_o` wire 接住。

### 10.3 `mem_stage` 新端口

新增 load/store misaligned 和 exception 输出 wire。

保持原有：

- `mem_misaligned_o` 继续接顶层输出。
- dmem 读写门控仍由 `mem_stage` 内部完成。

### 10.4 `wb_stage` 新端口

`csr_rdata_i` 先接 `'0`。

说明：

- 单周期顶层本阶段不支持 CSR/trap 程序。
- 这个兼容改动只保证原有 37 条合法 RV32I 单周期测试不因共享模块端口变化而破坏。

## 11. 推荐施工顺序

### Step 1: 公共类型先落地

修改：

- `rtl/common/core_pkg.sv`
- `rtl/common/pipeline_pkg.sv`

目标：

- 所有后续模块需要的 enum、CSR 地址、trap cause 和 struct 字段先定义好。
- 在 pipeline struct 中加入 `instr_id`，让 `id_stage.instr_id_o` 能随指令一路传到 MEM/WB。
- 先不连功能，只让后续代码有统一类型可用。

### Step 2: 写 `csr_file.sv`

新建：

- `rtl/core/csr_file.sv`

目标：

- 完成 CSR 状态寄存器。
- 完成 CSR read mux。
- 完成 CSR illegal 判断。
- 完成 CSR 指令读改写。
- 完成 trap entry 写 CSR。
- 完成 `MRET` 恢复 `mstatus`。

### Step 3: 写 `trap_ctrl.sv`

新建：

- `rtl/core/trap_ctrl.sv`

目标：

- 汇总 MEM 阶段 exception、CSR illegal 和 `MRET`。
- 产生 trap/MRET redirect。
- 产生 kill IF/ID、ID/EX、EX/MEM、MEM/WB input 的控制。
- 明确 trap/MRET 优先于普通 EX redirect。

### Step 4: 扩展 decoder 和 ID

修改：

- `rtl/core/decoder.sv`
- `rtl/core/id_stage.sv`

目标：

- 译码 `FENCE/ECALL/EBREAK/MRET/CSR*`。
- 产生 CSR 控制字段。
- 产生初始 exception 字段。
- 调整 `uses_rs1/uses_rs2/reg_we/wb_sel`。

### Step 5: 扩展 EX

修改：

- `rtl/core/ex_stage.sv`

目标：

- 传递已有 exception。
- 检测 branch/JAL/JALR target misaligned。
- exception 存在时禁止普通 redirect。
- 生成 forwarding 后的 `csr_wdata`。

### Step 6: 扩展 MEM

修改：

- `rtl/core/mem_stage.sv`

目标：

- 拆分 load/store misaligned。
- 生成 MEM exception cause/tval。
- 保持 misaligned load/store 不访问 dmem。

### Step 7: 扩展 WB、forwarding 和 hazard

修改：

- `rtl/core/wb_stage.sv`
- `rtl/core/forwarding_unit.sv`
- `rtl/core/hazard_unit.sv`

目标：

- WB 支持 `WB_CSR`。
- MEM/WB -> EX forwarding 自然支持 CSR 写 rd。
- EX/MEM 不前递 CSR 旧值。
- hazard 增加 CSR-use stall。
- hazard 优先级改成 trap redirect > EX redirect > late-result-use stall。

### Step 8: 扩展 pipeline register kill

修改：

- `rtl/core/pipe_reg.sv`

目标：

- `pipe_reg_ex_mem` 增加 `flush_i/kill_i`。
- trap/MRET 在 MEM 接受时能杀掉当前 EX 年轻指令。
- 更新过时注释。

### Step 9: 集成 `core_pipeline5.sv`

修改：

- `rtl/core/core_pipeline5.sv`

目标：

- 实例化 `csr_file`。
- 实例化 `trap_ctrl`。
- 把 `instr_id` 从 ID/EX、EX/MEM 一路送到 MEM/WB，用于后续 commit/debug 观察。
- 连接 CSR 指令从 ID 到 MEM 再到 WB 的数据路径。
- 连接 trap/MRET redirect 到 `pc_reg`。
- 连接 trap kill 到 IF/ID、ID/EX、EX/MEM、MEM/WB input。
- 连接 `WB_CSR` 写回路径。
- 保留并调整 commit/debug 输出。

### Step 10: 做单周期最小兼容

修改：

- `rtl/core/core_single_cycle.sv`

目标：

- 接上共享 stage 新增端口。
- 不在单周期里实现完整 CSR/trap。
- 保持原有合法 RV32I 单周期路径不受影响。

完成以上步骤后，再另起验证计划，补测试程序、脚本和文档说明。

## 11. RTL 之外的后续配套改动（暂不实施）

本章记录由 RTL 设计选择带来的软件、linker、仿真流程配套需求。当前先只规划，不修改 `rtl/` 之外的文件；等 RTL 主体完成并确定仿真策略后再统一实施。

### 11.1 由 2.2 `MTVEC_RESET` 引出的 trap handler 布局

> 来源：见 2.2 “CSR 状态寄存器”。该步把 `mtvec` 的复位值从 0 设置为 `core_pkg::MTVEC_RESET`，当前平台约定为 `IMEM_BASE + 32'h80`。因此 RTL 默认 trap 入口、linker 放置的 handler 地址、软件写入 `mtvec` 的地址需要保持一致。

后续需要修改：

- `sw/linker/asm_test.ld`
- `sw/linker/c_baremetal.ld`
- 新增或调整 trap 相关 `.S` 测试程序。
- 视 C trap 测试需求，新增专用 trap runtime 或独立启动文件；不要直接让当前共享 `sw/c_runtime/crt0.S` 无条件执行 CSR 指令，否则会破坏仍不支持 CSR/trap 的单周期 C 仿真流程。
- 仿真脚本按最终测试分组决定是否新增 CSR/trap 专用入口，暂不在本步改。

建议 linker 约定：

- 保持 `_start` / `.text.init` 从 `RESET_PC = IMEM_BASE` 开始执行。
- 在 `IMEM_BASE + 0x80` 放置 `.text.trap`，并导出 `__trap_vector`。
- `.text.trap` 使用 `KEEP(*(.text.trap))`，避免后续启用 section GC 或链接顺序变化时 handler 被丢弃。
- 普通 `.text` 放在 `.text.trap` 之后，防止 `*(.text.*)` 提前吞掉 `.text.trap`。

建议软件约定：

- trap 测试程序在 `.text.trap` 中定义 `trap_handler`。
- 启动阶段显式执行 `csrw mtvec, __trap_vector`，不要长期依赖 CSR reset 默认值。
- 对于只验证“复位后默认 `mtvec` 可用”的专项测试，可以故意不写 `mtvec`，但这类测试应单独命名和说明。
- C 侧若要测试 trap，优先使用独立的 trap-aware runtime，或给 pipeline5 CSR/trap 测试单独 build flow；不要影响现有 single-cycle C 测试。

### 11.2 后续统一扩展 IMEM/DMEM 容量与地址图

> 来源：后续若把 `rtl/mem/simple_rom.sv` 和 `rtl/mem/simple_ram.sv` 的 `ADDR_WIDTH` 从当前 10 扩大，需要同步更新软件可见地址图、linker script、testbench 统计和手写汇编常量。该事项暂不在 CSR/trap RTL 主线中实施，后续统一改。

注意：当前 `ADDR_WIDTH` 表示 32-bit word index 宽度，不是 byte 地址宽度。

- `ADDR_WIDTH = 10` 表示 1024 words，即 4 KiB。
- `ADDR_WIDTH = 14` 表示 16384 words，即 64 KiB。
- `ADDR_WIDTH = 16` 表示 65536 words，即 256 KiB。

后续建议：

- 在 `rtl/common/core_pkg.sv` 中集中定义 IMEM/DMEM 的地址宽度、byte size 和 base address，避免 `rtl/mem/`、testbench、linker 文档各自硬编码。
- `simple_rom.sv` 和 `simple_ram.sv` 的 `ADDR_WIDTH` 默认值改为引用 `core_pkg` 中的常量。
- 保持软件可见地址图不重叠。若 IMEM 从 `0x0000_0000` 开始且 `ADDR_WIDTH = 16`，IMEM byte 范围是 `0x0000_0000` 到 `0x0003_FFFF`，则 `DMEM_BASE` 至少应放到 `0x0004_0000`。
- 如果只想扩到 64 KiB，可以用 `ADDR_WIDTH = 14`；此时当前 `DMEM_BASE = 0x0001_0000` 正好接在 IMEM 之后，地址图变化最小。

RTL/testbench 需要同步修改：

- `rtl/common/core_pkg.sv`：新增或调整 `IMEM_ADDR_WIDTH/DMEM_ADDR_WIDTH`、`IMEM_SIZE_BYTES/DMEM_SIZE_BYTES`、`DMEM_BASE` 等常量。
- `rtl/mem/simple_rom.sv`：改用共享 IMEM 地址宽度常量。
- `rtl/mem/simple_ram.sv`：改用共享 DMEM 地址宽度常量。
- `tb/sv/tb_core_single_cycle.sv`：`DMEM_END_ADDR/STACK_TOP_ADDR` 不再写死 `DMEM_BASE + 0x1000`，改为 `DMEM_BASE + DMEM_SIZE_BYTES`。
- `tb/sv/tb_core_pipeline5.sv`：同样更新 DMEM 尾地址和栈顶统计。

软件和仿真流程需要同步修改：

- `sw/linker/asm_test.ld`：更新 `IMEM LENGTH`、`DMEM ORIGIN`、`DMEM LENGTH`。
- `sw/linker/c_baremetal.ld`：更新 `IMEM/DMEM` memory region；`__stack_bottom` 不再按 4 KiB 写死为 `ORIGIN(DMEM) + 0x0e00`，建议改成 `__stack_top - 固定栈大小`。
- `sw/asm/*.S`：若 `DMEM_BASE` 改变，所有手写 `lui ..., 0x10` 的地址常量都要同步更新；更推荐逐步改成 `%hi/%lo(__test_status_addr)` 或其他 linker symbol，减少后续地址图变化带来的重复修改。
- `sw/c_runtime/crt0.S` 当前使用 linker symbol 设置 `sp` 和测试状态地址，原则上随 linker 更新即可，不应硬编码 DMEM 地址。
- `sim/*/05_build_mem.sh` 当前主要依赖 linker script 和 objcopy，通常不需要因容量扩大单独改；若后续加入镜像大小检查，再统一接入共享容量约束。
- `docs/simulation_flow_*.md`、`README.md` 和 08xx 中涉及 `4 KiB`、`0x00010000`、`lui ..., 0x10` 的说明需要在最后统一同步。

仿真影响：

- 对 Verilator 仿真来说，`ADDR_WIDTH = 16` 只是把 ROM/RAM 数组扩到每个 256 KiB，通常影响很小。
- 仿真速度主要取决于执行了多少 cycle、是否打开波形、是否 dump 大量内部信号；单纯扩大未访问的 memory 容量不是主要瓶颈。
- 综合/FPGA 资源会明显受 memory 容量影响，因此仿真可先放宽，综合目标需要单独评估。
