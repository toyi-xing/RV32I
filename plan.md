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

单周期顶层 `core_single_cycle.sv` 不再作为后续维护目标。本阶段允许共享 stage 新增端口后只保证五级流水顶层可用；单周期相关 RTL、testbench、仿真脚本和现行流程文档后续统一清理或改为历史说明。

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

| 字段 | 作用 |
|---|---|
| `core_pkg::instr_id_e instr_id` | ID 译码出的指令类型，用于 debug/trace/后续 assertion，不作为后级重新译码的唯一依据。 |
| `logic exception_valid` | 该指令已经在 ID 或更早规划阶段发现 synchronous exception。 |
| `core_pkg::trap_cause_e exception_cause` | 该 exception 的 cause，后续写入 `mcause`。 |
| `logic [core_pkg::XLEN-1:0] exception_tval` | 该 exception 的附加信息，后续写入 `mtval`。 |
| `logic fence` | 该指令是否为 `FENCE`；本阶段作为 NOP 随流水线传递。 |
| `logic mret` | 该指令是否为 `MRET`；到 MEM/trap 接受点触发返回 redirect。 |
| `logic csr` | 该指令是否为 6 条 Zicsr CSR 指令之一。它是指令属性，不等同于 `csr_file.csr_valid_i`。 |
| `core_pkg::csr_op_e csr_op` | CSR 操作类型：RW/RS/RC/RWI/RSI/RCI。 |
| `logic [11:0] csr_addr` | CSR 地址字段 `instr[31:20]`。 |
| `logic [4:0] csr_uimm` | CSR immediate 形式的 `uimm` 字段 `instr[19:15]`，送到 EX 后零扩展。 |
| `logic csr_uses_rs1` | CSR register 形式是否读取 rs1，用于 hazard/forwarding 判断。 |
| `logic csr_writes_rd` | CSR 旧值是否需要写回 GPR `rd`，即 `rd != x0`。 |
| `logic csr_write_en` | 该 CSR 指令是否尝试写 CSR；由指令形式和 `rs1/uimm` 编号决定。 |

`ex_mem_reg_t` 新增字段：

| 字段 | 作用 |
|---|---|
| `core_pkg::instr_id_e instr_id` | 指令类型继续向 MEM/WB 传递，用于 debug/trace。 |
| `logic exception_valid` | ID/EX 阶段已经确认的 exception 是否有效。 |
| `core_pkg::trap_cause_e exception_cause` | 传到 MEM/trap 接受点的 exception cause。 |
| `logic [core_pkg::XLEN-1:0] exception_tval` | 传到 MEM/trap 接受点的 exception tval。 |
| `logic fence` | `FENCE` 标志继续随指令流动；当前无额外副作用。 |
| `logic mret` | `MRET` 标志传到 MEM/trap 接受点。 |
| `logic csr` | 该 MEM 槽是否为 CSR 指令；到 MEM 阶段还要结合 valid/exception 门控生成 CSR 文件访问 valid。 |
| `core_pkg::csr_op_e csr_op` | CSR 操作类型，送入 `csr_file`。 |
| `logic [11:0] csr_addr` | CSR 地址，送入 `csr_file`。 |
| `logic [core_pkg::XLEN-1:0] csr_operand` | EX 阶段生成的 CSR 操作数；register 形式来自 forwarding 后 rs1，immediate 形式来自零扩展 `csr_uimm`。 |
| `logic csr_writes_rd` | CSR 旧值是否需要在 WB 写回 GPR。 |
| `logic csr_write_en` | 是否尝试写 CSR，送入 `csr_file` 做写使能和非法写判断。 |

`mem_wb_reg_t` 新增字段：

| 字段 | 作用 |
|---|---|
| `core_pkg::instr_id_e instr_id` | 指令类型进入 WB/commit 观察点。 |
| `logic [core_pkg::XLEN-1:0] csr_rdata` | MEM 阶段从 CSR 文件读出的旧 CSR 值，`WB_CSR` 时写回 GPR。 |

说明：

- `instr_id` 从 ID 产生后随指令一直传到 MEM/WB，用于波形观察、commit trace、后续 assertion/统计；功能控制仍然使用已经译码出的专用控制字段。
- `exception_valid/cause/tval` 从 ID 或 EX 产生后随指令向 MEM 传递。
- `csr` 表示“这条指令是 CSR 指令”；`csr_file.csr_valid_i` 表示“MEM 阶段这一拍实际访问 CSR 文件”。二者不是同一个信号。
- `csr_operand` 应在 EX 阶段用 forwarding 后的 rs1 数据或 `csr_uimm` 生成，避免 CSR 指令读取到旧 GPR 值。
- `csr_write_en` 表示这条 CSR 指令是否真的尝试写 CSR。它和 `csr_operand != 0` 不是一回事：`CSRRS/CSRRC` 看 `rs1_addr != x0`，即使 rs1 数据为 0，也仍然是一次 CSR 写尝试。
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

> RTL 之外的配套改动暂不在本步实施：由于 2.2 把 `mtvec` 复位值改为 `MTVEC_RESET`，后续 linker script、启动代码和 trap 测试程序需要约定 `.text.trap`/`__trap_vector`，并在软件启动阶段显式写 `mtvec`。见文末“12. RTL 之外的后续配套改动”。

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

该模块只做控制选择，不保存 CSR 状态。它汇总 MEM 附近的 exception、CSR illegal、`MRET`，输出 PC redirect、kill 和 CSR 写控制。

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
    output logic                      kill_mem_wb_o
);
```

### 3.2 trap 选择逻辑 `已完成`

exception 来源分两类：

- `mem_exception_valid_i`：ID/EX/MEM 已经产生并随流水线带到 MEM 的 exception。
- `mem_csr_illegal_i`：CSR 文件在 MEM 对当前 CSR 指令判断出的非法 CSR 访问。

选择规则：

- `mem_valid_i && mem_exception_valid_i` 时，使用随流水线带来的 cause/tval。
- 否则若 `mem_valid_i && mem_csr_illegal_i`，生成 illegal instruction exception，`tval = mem_instr_i`。
- 否则若 `mem_valid_i && mem_mret_i`，执行 `MRET` redirect。

这里的优先级仍是防御性写法。正常情况下，`mem_csr_valid_i` 应该已经被已有 exception 门控，CSR illegal 不会和随流水线带来的 exception 同时有效；如果后续 RTL 改动导致二者同时为 1，仍要保持“同一条指令先发现的异常先保持”。

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
- `kill_mem_wb_o = 1`，阻止当前 MEM 指令作为普通指令进入 MEM/WB。

`kill_mem_wb_o` 很关键：

- faulting load 不能写 rd。
- faulting JAL/JALR 不能写 link rd。
- faulting CSR 不能写 rd。
- `MRET` 已在 MEM 被接受，不需要作为普通 WB 指令继续提交。

这里的 `kill_mem_wb_o` 不是杀掉已经处在 WB 阶段的 older instruction，而是让 MEM/WB 寄存器在本拍写入 invalid bubble。也就是说，它结束当前 MEM 指令的普通 WB 路径；trap/MRET 本身已经在 MEM 边界由 `trap_ctrl` 接受。

## 4. 扩展译码和 ID 阶段 `已完成`

### 4.0 调整简单指令标志的生成位置 `已完成`

`decoder.sv` 不再为每一类简单指令都增加独立布尔端口。它负责识别 `instr_id_o`、生成通用控制信号、CSR 控制候选和 exception 候选；需要结合流水线 valid 才有意义的简单指令标志统一放在 `id_stage.sv` 生成。

当前已经按这个规则处理：

- `jump_o = if_valid_i && (instr_id_o == INSTR_JAL || instr_id_o == INSTR_JALR)`
- `jalr_o = if_valid_i && (instr_id_o == INSTR_JALR)`

后续新增系统指令时也按同一口径处理：

- `fence_o = if_valid_i && (instr_id_o == INSTR_FENCE)`
- `mret_o = if_valid_i && (instr_id_o == INSTR_MRET)`
- `ECALL/EBREAK` 不需要作为跨模块布尔端口从 decoder 透传；ID 阶段根据 `instr_id_o` 或 decoder 给出的 exception 候选生成 `exception_valid/cause/tval`。

这样做的原因：

- 这些信号本质上是 `instr_id_o` 的简单别名，还必须被 `if_valid_i` 约束。
- 放在 `id_stage.sv` 里生成可以减少 `decoder -> id_stage` 的端口搬运。
- 后续继续增加类似的单指令控制标志时，不需要反复扩展 decoder 端口。

### 4.1 修改 `rtl/core/decoder.sv` `已完成`

新增输出端口：

| 端口 | 作用 |
|---|---|
| `csr_o` | 当前译码结果是否为 6 条 Zicsr CSR 指令之一；只是指令属性，不表示已经访问 CSR 文件。 |
| `core_pkg::csr_op_e csr_op_o` | CSR 操作类型：RW/RS/RC/RWI/RSI/RCI。 |
| `logic [11:0] csr_addr_o` | CSR 地址字段 `instr_i[31:20]`。 |
| `logic [4:0] csr_uimm_o` | CSR immediate 形式的 `uimm` 字段 `instr_i[19:15]`。 |
| `logic csr_uses_rs1_o` | CSR register 形式是否读取 rs1，用于 hazard/forwarding。 |
| `logic csr_writes_rd_o` | CSR 指令是否把旧 CSR 值写回 GPR `rd`，通常为 `rd_addr_o != x0`。 |
| `logic csr_write_en_o` | CSR 指令是否尝试写 CSR，用于 CSR 文件写使能和只读 CSR 非法写判断。 |
| `logic exception_valid_o` | decoder/ID 已能确认的 synchronous exception 是否有效。 |
| `core_pkg::trap_cause_e exception_cause_o` | decoder/ID exception 的 cause。 |
| `logic [core_pkg::XLEN-1:0] exception_tval_o` | decoder/ID exception 的 tval。非法指令通常为原始指令，`ECALL/EBREAK` 为 0。 |

补充 `INSTR_ID_GEN` 译码表。`decoder` 虽然不直接输出 `fence_o/ecall_o/ebreak_o/mret_o` 这类简单布尔信号，但必须把新增指令识别成对应的 `instr_id_o`；所有不满足完整编码约束的情况都保持 `INSTR_INVALID`。

| opcode 分支 | 进一步检查条件 | `instr_id_o` | 说明 |
|---|---|---|---|
| `OPCODE_MISC_MEM` | `funct3_o == 3'b000` | `INSTR_FENCE` | 本阶段 `FENCE` 作为 NOP；`fm/pred/succ/rs1/rd` 暂不影响功能。 |
| `OPCODE_MISC_MEM` | 其他 `funct3_o` | `INSTR_INVALID` | 例如 `FENCE.I` 属于 `Zifencei`，本阶段不支持。 |
| `OPCODE_SYSTEM` | `instr_i == 32'h0000_0073` | `INSTR_ECALL` | 必须精确匹配整条指令。 |
| `OPCODE_SYSTEM` | `instr_i == 32'h0010_0073` | `INSTR_EBREAK` | 必须精确匹配整条指令。 |
| `OPCODE_SYSTEM` | `instr_i == 32'h3020_0073` | `INSTR_MRET` | 特权指令，本阶段只支持 M-mode return。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b001` | `INSTR_CSRRW` | CSR 地址是否合法、只读 CSR 是否被写，交给 `csr_file` 判断。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b010` | `INSTR_CSRRS` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b011` | `INSTR_CSRRC` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b101` | `INSTR_CSRRWI` | immediate 形式使用 `instr_i[19:15]` 作为 `uimm`。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b110` | `INSTR_CSRRSI` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b111` | `INSTR_CSRRCI` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b000` 但不是上述精确编码，或 `funct3_o == 3'b100` | `INSTR_INVALID` | 未支持的 SYSTEM 编码统一作为 illegal instruction。 |

- `csr_addr_o = instr_i[31:20]`。
- `csr_uimm_o = instr_i[19:15]`。
- register 形式 `CSRRW/CSRRS/CSRRC`：`csr_uses_rs1_o = 1`。
- immediate 形式 `CSRRWI/CSRRSI/CSRRCI`：`csr_uses_rs1_o = 0`。
- CSR 指令写 rd 的数据是旧 CSR 值，`csr_writes_rd_o = (rd_addr_o != 5'd0)`。
- CSR 写 CSR 的意图由 `csr_write_en_o` 表示：
  - `CSRRW/CSRRWI`：`csr_write_en_o = 1`。
  - `CSRRS/CSRRC`：`csr_write_en_o = (rs1_addr_o != 5'd0)`。
  - `CSRRSI/CSRRCI`：`csr_write_en_o = (csr_uimm_o != 5'd0)`。

**原有信号译码扩展**

- `uses_rs1_o` 是通用 RAW hazard 语义信号，CSR register 形式也要计入；`csr_uses_rs1_o` 保留为 CSR 专用分类信号。
- `reg_we_o` 是通用 GPR 写回语义信号，CSR 写 rd 时也要计入；`csr_writes_rd_o` 保留为 CSR 专用分类信号。
- `wb_sel_o` 对 CSR 写 rd 的指令应选择 `WB_CSR`，表示 WB 阶段写回旧 CSR 值。

`illegal_instr_o` 的语义要调整：

- 对 CSR 地址是否存在、只读 CSR 是否被写，不在 decoder 做最终判断，交给 `csr_file.sv`。

补充说明：CSR register 形式的 operand 虽然后续才用于 CSR 新值计算，但当前数据通路仍然在 ID 阶段读 GPR，并把 rs1 数据随流水线传递。因此对当前实现来说，CSR register 形式必须进入通用 `uses_rs1_o`，让现有 hazard/forwarding 能看到这条 GPR RAW 依赖。后续若专门把 CSR operand 延迟到更晚阶段获取，可以再做更细的 stall 优化。

### 4.2 修改 `rtl/core/id_stage.sv` `已完成`

新增输出端口。CSR 和 exception 候选从 decoder 透传并在 ID 阶段结合 `if_valid_i` 约束；简单指令标志在 ID 阶段根据 `instr_id_o` 直接生成：

| 端口 | 作用 |
|---|---|
| `fence_o` | 当前有效 ID 指令是否为 `FENCE`；本阶段作为 NOP 控制标志。 |
| `mret_o` | 当前有效 ID 指令是否为 `MRET`；后续传到 MEM/trap 接受点。 |
| `csr_o` | 当前有效 ID 指令是否为 CSR 指令；后续随流水线传递。 |
| `csr_op_o` | CSR 操作类型。 |
| `csr_addr_o` | CSR 地址。 |
| `csr_uimm_o` | CSR immediate 操作数字段，后续 EX 阶段零扩展。 |
| `csr_uses_rs1_o` | CSR register 形式是否读取 rs1。 |
| `csr_writes_rd_o` | CSR 旧值是否写回 GPR rd。 |
| `csr_write_en_o` | CSR 指令是否尝试写 CSR。 |
| `exception_valid_o` | ID 阶段发现的 exception 是否有效。 |
| `exception_cause_o` | ID 阶段 exception cause。 |
| `exception_tval_o` | ID 阶段 exception tval。 |

ID 阶段 exception 初始规则：

- `illegal_instr_o` 可以继续作为调试信号保留。
- `exception_valid_o = if_valid_i & decoder_exception_valid`。
- 对非法普通指令，`exception_cause_o = TRAP_CAUSE_ILLEGAL_INSTR`，`exception_tval_o = if_instr_i`。
- 对 `ECALL/EBREAK`，使用 decoder 给出的 cause/tval。
- `fence_o = if_valid_i & (instr_id_o == INSTR_FENCE)`。
- `mret_o = if_valid_i & (instr_id_o == INSTR_MRET)`。

## 5. 扩展 EX 阶段 `已完成`

### 5.1 修改 `rtl/core/ex_stage.sv` `已完成`

新增输入端口：

| 端口 | 作用 |
|---|---|
| `exception_valid_i` | 前级已发现的 exception 是否有效；有效时 EX 不再产生普通 redirect。 |
| `exception_cause_i` | 前级 exception cause，EX 透传或在更高优先级时替换。 |
| `exception_tval_i` | 前级 exception tval，EX 透传或在更高优先级时替换。 |
| `csr_i` | 当前 EX 指令是否为 CSR 指令。 |
| `csr_op_i` | CSR 操作类型，用于选择 rs1 还是 uimm 作为 CSR 操作数。 |
| `csr_uimm_i` | CSR immediate 字段，EX 阶段零扩展后形成 `csr_operand_o`。 |
| `mret_i` | `MRET` 标志透传到 EX/MEM。 |

新增输出端口：

| 端口 | 作用 |
|---|---|
| `exception_valid_o` | EX 输出的 exception 是否有效，包含前级透传和 target misaligned。 |
| `exception_cause_o` | EX 输出 exception cause。 |
| `exception_tval_o` | EX 输出 exception tval。 |
| `csr_operand_o` | 送入 CSR 文件的操作数；register 形式来自 forwarding 后 rs1，immediate 形式来自零扩展 uimm。 |
| `mret_o` | `MRET` 标志透传输出。 |

### 5.2 检查 instruction address misaligned `已完成`

当前 `ex_stage` 对 branch/JAL/JALR 直接输出 redirect。加入 trap 后要改为：

- 先计算原始跳转目标 `branch_target`。
- JALR 目标继续执行 `target = alu_result & ~32'b1`。
- 当 `valid_i && (branch_taken || jump_i) && target[1:0] != 2'b00` 时，产生 instruction address misaligned exception：
  - `exception_valid_o = 1`
  - `exception_cause_o = TRAP_CAUSE_INST_ADDR_MISALIGNED`
  - `exception_tval_o = target`
  - `redirect_valid_o = 0`
- 当没有 target misaligned 时，原 branch/JAL/JALR redirect 逻辑保持不变。

实现时需要把“指令原始 redirect 请求”和“最终发给 PC 的 redirect”拆开：

- 原始 redirect 请求只看 `valid_i && (branch_taken || jump_i)`，用于判断这条指令是否本来要改变 PC。
- instruction address misaligned 必须基于原始 redirect 请求和目标地址低位判断。
- 最终 `redirect_valid_o` 还要被 `exception_valid_o` 屏蔽，避免已有 exception 或 target misaligned 时继续发普通 branch/JAL/JALR redirect。

这样可以避免 `redirect_valid_o`、`exception_valid_o`、target misaligned 之间形成组合环，也能保证“异常路径”和“普通 redirect 路径”语义分开。

如果输入已经带有 `exception_valid_i`：

- EX 不应再产生普通 redirect。
- exception 继续向 EX/MEM 传递。
- ALU 结果可以照常计算，但后续副作用必须由 trap kill 屏蔽。

### 5.3 生成 CSR 写源数据 `已完成`

在 EX 阶段生成 `csr_operand_o`：

- `CSR_OP_RW/RS/RC` 使用 forwarding 后的 `rs1_data_i`。
- `CSR_OP_RWI/RSI/RCI` 使用 `{27'b0, csr_uimm_i}`。
- 非 CSR 指令输出 0。

这样 CSR 指令和普通 ALU 指令共用现有 GPR forwarding 结果，避免 CSR 源寄存器读到旧值。

## 6. 扩展 MEM 阶段 `已完成`

### 6.1 修改 `rtl/core/mem_stage.sv` `已完成`

保留现有 `mem_misaligned_o`，同时新增更明确的输出：

| 端口 | 作用 |
|---|---|
| `exception_valid_i` | 前级已经发现的 exception 是否有效；有效时 MEM 不再产生访存副作用。 |
| `exception_cause_i` | 前级 exception cause。 |
| `exception_tval_i` | 前级 exception tval。 |
| `load_misaligned_o` | 当前有效 load 访问地址不满足访问宽度对齐要求。 |
| `store_misaligned_o` | 当前有效 store 访问地址不满足访问宽度对齐要求。 |
| `exception_valid_o` | MEM 边界最终 exception 是否有效，包含前级透传和本级 misaligned。 |
| `exception_cause_o` | MEM 边界最终 exception cause。 |
| `exception_tval_o` | MEM 边界最终 exception tval。 |

`mem_stage` 接收 `ex_mem_data_q.exception_*`，并在模块内部合并前级 exception 和本级 load/store misaligned。这样顶层不再需要额外的 `pipe_exception_*` 组合逻辑，MEM 输出的 `exception_*_o` 已经是送给 `trap_ctrl` 的 MEM 边界最终 exception。

合并优先级：

```systemverilog
前级 exception > MEM 本地 load/store misaligned
```

这个优先级体现“同一条指令先发现的异常先保持”。CSR illegal 不在 `mem_stage` 合并，它仍作为 `trap_ctrl` 的第二类输入；CSR file 和 MEM stage 是 MEM 边界的两个并行检出点。

### 6.2 拆分 load/store misaligned `已完成`

当前 `mem_misaligned_o` 已能判断 half/word 对齐错误。需要拆成：

- `load_misaligned_o = valid_i && mem_re_i && addr_misaligned`
- `store_misaligned_o = valid_i && mem_we_i && addr_misaligned`
- `mem_misaligned_o = load_misaligned_o | store_misaligned_o`

exception 输出：

- load 不对齐：cause 4，tval = `alu_result_i`
- store 不对齐：cause 6，tval = `alu_result_i`
- 无不对齐：不产生 MEM exception

### 6.3 保持错误访存副作用屏蔽 `已完成`

访存副作用需要同时被前级 exception 和本级 misaligned 屏蔽：

- `dmem_re_o = valid_i & ~exception_valid_i & ~mem_misaligned_o & mem_re_i`
- `dmem_we_o = valid_i & ~exception_valid_i & ~mem_misaligned_o & mem_we_i`

后续顶层还要配合 `trap_ctrl.kill_mem_wb_o`，保证 faulting load 不进入 WB 写 rd。

## 7. 扩展 WB 和 forwarding/hazard `已完成`

### 7.1 修改 `rtl/core/wb_stage.sv` `已完成`

新增输入：

| 端口 | 作用 |
|---|---|
| `logic [core_pkg::XLEN-1:0] csr_rdata_i` | MEM/WB 携带的 CSR 旧值；当 `wb_sel_i == WB_CSR` 时作为 GPR 写回数据。 |

修改写回 mux：

- `WB_CSR: wb_wdata_o = csr_rdata_i`

`reg_we_o` 仍由 `valid_i & reg_we_i` 控制。faulting instruction 是否进入 WB，由 MEM/WB 寄存器的 `kill_i` 统一屏蔽。

### 7.2 修改 `rtl/core/forwarding_unit.sv` `已完成`

紧邻的 CSR-use 和 load-use 一样不走 forwarding，而应该 stall，因此在 EX/MEM -> EX 前递检测中做防御性屏蔽。

隔一条的 CSR-use 和 load-use 则无需 stall，直接走 MEM/WB -> EX 前递即可。CSR 读结果并入 `mem_wb_wdata_i` 后，MEM/WB -> EX 路径可以自然复用。

这里的 EX/MEM 屏蔽属于防御性写法：正常 back-to-back 场景会被 `hazard_unit` 先插入 bubble，`forwarding_unit` 的 `id_ex_valid_i` 检测也会让错误前递自动失效。但显式屏蔽 load/CSR late result 更直观，也能避免后续改动时误把未就绪数据从 EX/MEM 前递出去。

- 将原 `ex_mem_mem_re_i` 改成 `ex_mem_load_re_i`，语义更明确：EX/MEM 指令是否为 load。
- 新增 `ex_mem_csr_re_i`，语义为 EX/MEM 指令是否为 CSR late result。
- EX/MEM 命中时，只有 `!ex_mem_load_re_i && !ex_mem_csr_re_i` 才允许选择 `FWD_EX_MEM`。

### 7.3 修改 `rtl/core/hazard_unit.sv` `已完成`

新增输入：

| 端口 | 作用 |
|---|---|
| `id_ex_reg_we_i` | ID/EX 指令是否会写 GPR，用于判断 late-result-use hazard。 |
| `id_ex_load_re_i` | ID/EX 指令是否为 load；load 写回数据到 MEM 后才就绪。 |
| `id_ex_csr_re_i` | ID/EX 指令是否为 CSR 写 rd；CSR 旧值到 MEM 后才就绪。 |

扩展 load-use stall 为 late-result-use stall：

```text
late_result = id_ex_load_re_i || id_ex_csr_re_i
```

当前实现选择显式传入 `id_ex_load_re_i/id_ex_csr_re_i`，而不是让 `hazard_unit` 解析 `wb_sel_i`。这样 `hazard_unit` 只关心“这条生产指令的 rd 是否晚就绪”，不用知道完整写回 mux 编码。

stall 条件仍是：

- IF/ID 有效。
- ID/EX 有效。
- ID/EX 会写 rd。
- ID 当前指令使用 rs1 或 rs2。
- ID rs 命中 ID/EX rd。

这样 back-to-back `csrr x1, ...; add x2, x1, x3` 会 stall 一拍，等 CSR 旧值进入 MEM/WB 后再前递。

`hazard_unit` 不接入 trap/MRET redirect。trap/MRET 属于 MEM 边界的精确提交控制，后续由 `trap_ctrl.kill_if_id_o/kill_id_ex_o/kill_ex_mem_o/kill_mem_wb_o` 直接连到流水线寄存器 kill 入口处理。

```text
EX branch/JAL/JALR redirect > late-result-use stall
```

也就是说，`hazard_unit` 继续只产生普通 control hazard 的 flush：EX redirect 时 flush IF/ID 和 ID/EX；trap/MRET 导致的 control hazard 统一使用 kill 口径，不混入 `hazard_unit`。

## 8. 扩展流水线寄存器 kill 能力 `已完成`

### 8.1 修改 `rtl/core/pipe_reg.sv` `已完成`

`pipe_reg_if_id` 和 `pipe_reg_id_ex` 保留普通 redirect 使用的 `flush_i`，同时新增 trap/MRET 使用的 `kill_i`。

`pipe_reg_ex_mem` 和 `pipe_reg_mem_wb` 新增 `kill_i`：

- 优先级：reset > kill > flush/stall/bubble > normal advance。具体到各寄存器，`kill_i` 都高于普通 `flush_i`、`stall_i` 和 `bubble_i`。
- trap/MRET 在 MEM 被接受时，当前 EX 阶段指令是 younger instruction，不能在同一拍进入 EX/MEM。
- trap/MRET 在 MEM 被接受时，当前 MEM 指令已经由 `trap_ctrl` 接受，不能再作为普通指令进入 MEM/WB。

`pipe_reg_mem_wb.kill_i` 的语义是清掉下一拍进入 WB 的槽位，不是取消已经在 WB 的 older instruction。

### 8.2 修改注释 `已完成`

`pipe_reg.sv` 文件头和各寄存器附近需要直接说明 flush/kill 口径，避免只看 RTL 时误把两类控制混在一起：

- branch/JAL/JALR 的 EX redirect 仍只需要 flush IF/ID 和 ID/EX。
- trap/MRET 在 MEM 接受时，需要额外 kill 当前 EX -> EX/MEM 的年轻指令。
- MEM/WB 使用 `kill_i` 写入 invalid bubble，避免 faulting/MRET 指令作为普通指令进入 WB。

## 9. 集成到 `core_pipeline5.sv` `执行中`

本步以当前已经落地的 1～8 步 RTL 接口为准，不再沿用最初“顶层门控 MEM/WB valid”或“单周期最小兼容”的旧方案。

### 9.1 顶层新增 wire 分组 `已完成`

PC redirect 分成两类来源：

| 信号 | 来源 | 去向 | 说明 |
|---|---|---|---|
| `ex_redirect_valid/ex_redirect_pc` | `ex_stage` | `hazard_unit`、最终 PC mux | 普通 branch/JAL/JALR redirect，只负责 flush IF/ID、ID/EX。 |
| `trap_redirect_valid/trap_redirect_pc` | `trap_ctrl.redirect_*` | 最终 PC mux | trap/MRET redirect，优先级高于 EX redirect。 |
| `redirect_valid/redirect_pc` | 顶层 mux | `pc_reg` | 最终 PC 重定向请求。 |

最终 redirect 选择：

```systemverilog
assign redirect_valid = trap_redirect_valid | ex_redirect_valid;
assign redirect_pc    = trap_redirect_valid ? trap_redirect_pc : ex_redirect_pc;
```

trap/MRET kill 信号：

| 信号 | 来源 | 去向 | 说明 |
|---|---|---|---|
| `kill_if_id` | `trap_ctrl.kill_if_id_o` | `pipe_reg_if_id.kill_i` | 清掉 IF/ID younger instruction。 |
| `kill_id_ex` | `trap_ctrl.kill_id_ex_o` | `pipe_reg_id_ex.kill_i` | 清掉 ID/EX younger instruction。 |
| `kill_ex_mem` | `trap_ctrl.kill_ex_mem_o` | `pipe_reg_ex_mem.kill_i` | 阻止当前 EX younger instruction 进入 EX/MEM。 |
| `kill_mem_wb` | `trap_ctrl.kill_mem_wb_o` | `pipe_reg_mem_wb.kill_i` | 阻止当前 MEM 指令进入普通 WB 路径。 |

CSR/trap 数据信号：

| 信号 | 作用 |
|---|---|
| `id_instr_id` | 接 `id_stage.instr_id_o`，随流水线传到 MEM/WB，用于 debug/trace。 |
| `id_fence/id_mret` | ID 阶段简单指令标志。 |
| `id_csr/id_csr_op/id_csr_addr/id_csr_uimm` | CSR 指令属性和字段。 |
| `id_csr_uses_rs1/id_csr_writes_rd/id_csr_write_en` | CSR hazard、WB 和 CSR 写控制。 |
| `id_exception_valid/id_exception_cause/id_exception_tval` | ID 阶段发现的 exception。 |
| `ex_exception_valid/ex_exception_cause/ex_exception_tval` | EX 阶段输出的最终 exception。 |
| `ex_csr_operand` | EX 阶段生成的 CSR 操作数。 |
| `mem_exception_valid/mem_exception_cause/mem_exception_tval` | MEM 边界最终 exception，由 `mem_stage` 内部合并前级 exception 和本级 load/store misaligned 得到。 |
| `mem_csr_valid/mem_csr_rdata/mem_csr_illegal` | MEM 阶段 CSR 文件访问结果。 |
| `csr_mtvec/csr_mepc/csr_mstatus` | CSR 文件输出，其中 `mtvec/mepc` 送 `trap_ctrl`。 |
| `trap_valid/trap_pc/trap_cause/trap_tval` | trap entry 被接受后写 CSR 的信息。 |
| `mret_valid` | MRET 被接受，驱动 CSR 文件恢复 `mstatus`。 |

### 9.2 修改 `id_stage` 实例连接 `已完成`

`id_stage` 新增或原先悬空的端口需要全部接到顶层 wire：

| `id_stage` 端口 | 顶层信号 |
|---|---|
| `.instr_id_o` | `id_instr_id` |
| `.fence_o` | `id_fence` |
| `.mret_o` | `id_mret` |
| `.csr_o` | `id_csr` |
| `.csr_op_o` | `id_csr_op` |
| `.csr_addr_o` | `id_csr_addr` |
| `.csr_uimm_o` | `id_csr_uimm` |
| `.csr_uses_rs1_o` | `id_csr_uses_rs1` |
| `.csr_writes_rd_o` | `id_csr_writes_rd` |
| `.csr_write_en_o` | `id_csr_write_en` |
| `.exception_valid_o` | `id_exception_valid` |
| `.exception_cause_o` | `id_exception_cause` |
| `.exception_tval_o` | `id_exception_tval` |

`id_uses_rs1` 已经包含 CSR register 形式的 rs1 使用信息，后续 hazard 和 forwarding 继续使用 `id_uses_rs1/id_uses_rs2` 即可，不需要单独把 `csr_uses_rs1` 再接到 `hazard_unit`。

### 9.3 修改 hazard/forwarding 连接 `已完成`

`hazard_unit` 继续只处理普通 EX redirect 和 late-result-use stall。新增端口连接：

| `hazard_unit` 端口 | 顶层连接 |
|---|---|
| `.id_ex_reg_we_i` | `id_ex_data_q.reg_we` |
| `.id_ex_load_re_i` | `id_ex_data_q.mem_re` |
| `.id_ex_csr_re_i` | `id_ex_data_q.csr_writes_rd` |
| `.redirect_valid_i` | `ex_redirect_valid` |

`forwarding_unit` 新增 CSR late-result 屏蔽：

| `forwarding_unit` 端口 | 顶层连接 |
|---|---|
| `.ex_mem_load_re_i` | `ex_mem_data_q.mem_re` |
| `.ex_mem_csr_re_i` | `ex_mem_data_q.csr_writes_rd` |
| `.mem_wb_wdata_i` | `wb_rd_wdata` |

注意：trap/MRET redirect 不接入 `hazard_unit`。trap/MRET 由 `trap_ctrl` 通过四路 kill 直接处理，PC redirect 通过顶层最终 redirect mux 进入 `pc_reg`。

### 9.4 修改四个 pipeline register 实例 `已完成`

新增 kill 连接：

| pipeline register | 新增连接 |
|---|---|
| `u_pipe_reg_if_id` | `.kill_i(kill_if_id)` |
| `u_pipe_reg_id_ex` | `.kill_i(kill_id_ex)` |
| `u_pipe_reg_ex_mem` | `.kill_i(kill_ex_mem)` |
| `u_pipe_reg_mem_wb` | `.kill_i(kill_mem_wb)` |

普通 branch/JAL/JALR redirect 仍只使用 `flush_if_id/flush_id_ex`；trap/MRET 统一使用 kill。`pipe_reg_mem_wb.valid_i` 继续接 `mem_valid`，不要在顶层额外写 `mem_valid & ~kill_mem_wb`。

### 9.5 修改 `pc_reg` 连接 `已完成`

`pc_reg` 改接最终 redirect：

| `pc_reg` 端口 | 顶层连接 |
|---|---|
| `.redirect_pc_i` | `redirect_pc` |
| `.redirect_valid_i` | `redirect_valid` |
| `.stall_pc_i` | `stall_if` |

依赖 `pc_reg` 内部 `redirect > stall` 的优先级：即使同拍有 late-result-use stall，只要 trap/MRET redirect 有效，PC 也必须跳到 `mtvec/mepc`。

### 9.6 补齐 ID/EX 组包连接 `已完成`

`id_ex_reg_t` 的字段已在 1.2 定义，本步只在 `core_pipeline5.sv` 中补齐 `id_ex_data_d` 的 assign 连接：

| 字段 | 来源 |
|---|---|
| `instr_id` | `id_instr_id` |
| `exception_valid` | `id_exception_valid` |
| `exception_cause` | `id_exception_cause` |
| `exception_tval` | `id_exception_tval` |
| `fence` | `id_fence` |
| `mret` | `id_mret` |
| `csr` | `id_csr` |
| `csr_op` | `id_csr_op` |
| `csr_addr` | `id_csr_addr` |
| `csr_uimm` | `id_csr_uimm` |
| `csr_uses_rs1` | `id_csr_uses_rs1` |
| `csr_writes_rd` | `id_csr_writes_rd` |
| `csr_write_en` | `id_csr_write_en` |

`id_valid` 为 0 时，字段值不会产生副作用；为了波形整洁，可以仍按 ID 输出组包，也可以在后续统一清零，不影响功能。

### 9.7 修改 `ex_stage` 实例连接 `已完成`

新增输入连接：

| `ex_stage` 端口 | 顶层连接 |
|---|---|
| `.exception_valid_i` | `id_ex_data_q.exception_valid` |
| `.exception_cause_i` | `id_ex_data_q.exception_cause` |
| `.exception_tval_i` | `id_ex_data_q.exception_tval` |
| `.csr_i` | `id_ex_data_q.csr` |
| `.csr_op_i` | `id_ex_data_q.csr_op` |
| `.csr_uimm_i` | `id_ex_data_q.csr_uimm` |
| `.mret_i` | `id_ex_data_q.mret` |

新增输出连接：

| `ex_stage` 端口 | 顶层信号 |
|---|---|
| `.exception_valid_o` | `ex_exception_valid` |
| `.exception_cause_o` | `ex_exception_cause` |
| `.exception_tval_o` | `ex_exception_tval` |
| `.csr_operand_o` | `ex_csr_operand` |
| `.mret_o` | `ex_mret` |

CSR register 形式的 operand 使用 forwarding 后的 `ex_rs1_op_data`，因此不需要给 CSR 再做单独的 forwarding mux。

### 9.8 补齐 EX/MEM 组包连接 `已完成`

`ex_mem_reg_t` 的字段已在 1.2 定义，本步只在 `core_pipeline5.sv` 中补齐 `ex_mem_data_d` 的 assign 连接：

| 字段 | 来源 |
|---|---|
| `instr_id` | `id_ex_data_q.instr_id` |
| `exception_valid` | `ex_exception_valid` |
| `exception_cause` | `ex_exception_cause` |
| `exception_tval` | `ex_exception_tval` |
| `fence` | `id_ex_data_q.fence` |
| `mret` | `ex_mret` |
| `csr` | `id_ex_data_q.csr` |
| `csr_op` | `id_ex_data_q.csr_op` |
| `csr_addr` | `id_ex_data_q.csr_addr` |
| `csr_operand` | `ex_csr_operand` |
| `csr_writes_rd` | `id_ex_data_q.csr_writes_rd` |
| `csr_write_en` | `id_ex_data_q.csr_write_en` |

`ex_mem_reg_t.csr_operand` 是 EX 阶段生成的 CSR 操作数；连接 `csr_file.csr_operand_i` 时使用 `ex_mem_data_q.csr_operand`。

### 9.9 修改 `mem_stage` 实例连接 `已完成`

`mem_stage` 接收 EX/MEM 中保存的前级 exception，并在模块内部合并前级 exception 和 MEM 本地 load/store misaligned。顶层只负责端口连接，不再额外生成 `pipe_exception_*`。

新增输入连接：

| `mem_stage` 端口 | 顶层连接 |
|---|---|
| `.exception_valid_i` | `ex_mem_data_q.exception_valid` |
| `.exception_cause_i` | `ex_mem_data_q.exception_cause` |
| `.exception_tval_i` | `ex_mem_data_q.exception_tval` |

新增输出连接：

| `mem_stage` 端口 | 顶层信号 |
|---|---|
| `.load_misaligned_o` | `mem_load_misaligned` |
| `.store_misaligned_o` | `mem_store_misaligned` |
| `.exception_valid_o` | `mem_exception_valid` |
| `.exception_cause_o` | `mem_exception_cause` |
| `.exception_tval_o` | `mem_exception_tval` |

`mem_exception_*` 已经是 MEM 边界最终 exception，后续直接送 `trap_ctrl`。CSR illegal 不在这里合并，它仍作为 `trap_ctrl` 的第二类输入。

### 9.10 实例化 `csr_file` `已完成`

在 MEM/trap 组合控制附近实例化：

```systemverilog
csr_file u_csr_file (...);
```

CSR 指令访问：

| `csr_file` 端口 | 顶层连接 |
|---|---|
| `.csr_valid_i` | `mem_csr_valid` |
| `.csr_op_i` | `ex_mem_data_q.csr_op` |
| `.csr_addr_i` | `ex_mem_data_q.csr_addr` |
| `.csr_operand_i` | `ex_mem_data_q.csr_operand` |
| `.csr_write_en_i` | `ex_mem_data_q.csr_write_en` |
| `.csr_rdata_o` | `mem_csr_rdata` |
| `.csr_illegal_o` | `mem_csr_illegal` |

`mem_csr_valid` 建议生成：

```systemverilog
assign mem_csr_valid = ex_mem_valid
                     & ex_mem_data_q.csr
                     & ~mem_exception_valid;
```

trap/MRET 硬件写 CSR：

| `csr_file` 端口 | 顶层连接 |
|---|---|
| `.trap_valid_i` | `trap_valid` |
| `.trap_pc_i` | `trap_pc` |
| `.trap_cause_i` | `trap_cause` |
| `.trap_tval_i` | `trap_tval` |
| `.mret_valid_i` | `mret_valid` |
| `.mtvec_o` | `csr_mtvec` |
| `.mepc_o` | `csr_mepc` |
| `.mstatus_o` | `csr_mstatus` |

### 9.11 实例化 `trap_ctrl` `已完成`

在 `mem_stage` 和 `csr_file` 组合输出之后实例化：

```systemverilog
trap_ctrl u_trap_ctrl (...);
```

连接清单：

| `trap_ctrl` 端口 | 顶层连接 |
|---|---|
| `.mem_valid_i` | `ex_mem_valid` |
| `.mem_pc_i` | `ex_mem_data_q.pc` |
| `.mem_instr_i` | `ex_mem_data_q.instr` |
| `.mem_mret_i` | `ex_mem_data_q.mret` |
| `.mem_exception_valid_i` | `mem_exception_valid` |
| `.mem_exception_cause_i` | `mem_exception_cause` |
| `.mem_exception_tval_i` | `mem_exception_tval` |
| `.mem_csr_valid_i` | `mem_csr_valid` |
| `.mem_csr_illegal_i` | `mem_csr_illegal` |
| `.csr_mtvec_i` | `csr_mtvec` |
| `.csr_mepc_i` | `csr_mepc` |
| `.trap_valid_o` | `trap_valid` |
| `.trap_pc_o` | `trap_pc` |
| `.trap_cause_o` | `trap_cause` |
| `.trap_tval_o` | `trap_tval` |
| `.mret_valid_o` | `mret_valid` |
| `.redirect_valid_o` | `trap_redirect_valid` |
| `.redirect_pc_o` | `trap_redirect_pc` |
| `.kill_if_id_o` | `kill_if_id` |
| `.kill_id_ex_o` | `kill_id_ex` |
| `.kill_ex_mem_o` | `kill_ex_mem` |
| `.kill_mem_wb_o` | `kill_mem_wb` |

`csr_file` 和 `trap_ctrl` 之间有组合读取 `csr_illegal/mtvec/mepc`，但 `trap_valid/mret_valid` 只影响 `csr_file` 的同步写状态，不应形成组合环。

### 9.12 补齐 MEM/WB 组包连接和 WB 实例 `已完成`

`mem_wb_reg_t` 的字段已在 1.2 定义，本步只在 `core_pipeline5.sv` 中补齐 `mem_wb_data_d` 的 assign 连接：

| 字段 | 来源 |
|---|---|
| `instr_id` | `ex_mem_data_q.instr_id` |
| `csr_rdata` | `mem_csr_rdata` |

`pipe_reg_mem_wb` 连接：

```systemverilog
.valid_i(mem_valid),
.kill_i (kill_mem_wb)
```

`wb_stage` 新增端口连接：

```systemverilog
.csr_rdata_i(mem_wb_data_q.csr_rdata)
```

faulting/MRET 指令会被 `kill_mem_wb` 清成 invalid bubble，因此 `mem_wb_data_d.reg_we` 可以继续从 `ex_mem_data_q.reg_we` 透传。

### 9.13 调整顶层观察输出 `执行中`

现有 `illegal_instr_o` 和 `mem_misaligned_o` 不应再作为“遇到错误立即停机”的语义：

- `mem_misaligned_o` 可以继续接 `mem_stage.mem_misaligned_o`，作为 MEM 当拍观察信号。
- `illegal_instr_o` 若继续保留，建议改为 `trap_valid && trap_cause == TRAP_CAUSE_ILLEGAL_INSTR`，因为非法指令不会再进入普通 WB。

建议新增或后续在 testbench 层观察这些 trap 信号：

| 信号 | 来源 |
|---|---|
| `trap_valid_o` | `trap_valid` |
| `trap_pc_o` | `trap_pc` |
| `trap_cause_o` | `trap_cause` |
| `trap_tval_o` | `trap_tval` |
| `trap_return_o` | `mret_valid` |
| `trap_return_pc_o` | `csr_mepc` |

这些信号只用于 debug/trace/testbench，不参与 core 内部功能闭环。

## 10. 清理单周期相关文件和流程

单周期顶层不再随共享 stage 继续维护。本步目标不是保持单周期可编译，而是把现行流程切换为五级流水为唯一维护对象，并删除或标注单周期路径。

### 10.1 建议删除的 RTL/TB 文件

| 文件 | 处理 |
|---|---|
| `rtl/core/core_single_cycle.sv` | 删除或移动到历史归档目录；不再接共享 stage 新端口。 |
| `tb/sv/tb_core_single_cycle.sv` | 删除或移动到历史归档目录；后续只维护流水线 testbench。 |

不删除共享模块，例如 `id_stage/ex_stage/mem_stage/wb_stage/regfile/pc_reg`。这些模块继续服务五级流水顶层。

### 10.2 建议删除的单周期仿真脚本

| 文件/目录 | 处理 |
|---|---|
| `sim/single_cycle_asm/05_build_mem.sh` | 删除。 |
| `sim/single_cycle_asm/06_run_sim.sh` | 删除。 |
| `sim/single_cycle_asm/run_test.sh` | 删除。 |
| `sim/single_cycle_asm/run_all.sh` | 删除。 |
| `sim/single_cycle_c/05_build_mem.sh` | 删除。 |
| `sim/single_cycle_c/06_run_sim.sh` | 删除。 |
| `sim/single_cycle_c/run_test.sh` | 删除。 |

`sim/common/resolve_test_name.sh` 仍被流水线脚本使用，应保留。

生成物不需要入库清理，但本地可按需删除：

- `build/single_cycle_asm/`
- `build/single_cycle_c/`
- `obj_dir/Vtb_core_single_cycle`

### 10.3 建议删除或改写的现行流程文档

| 文件 | 处理 |
|---|---|
| `docs/simulation_flow_singlecycle_asm.md` | 删除，或改成历史说明并从 README 中移除现行入口。 |
| `docs/simulation_flow_singlecycle_c.md` | 删除，或改成历史说明并从 README 中移除现行入口。 |
| `docs/simulation_flow_pipeline_asm.md` | 改为自包含文档，不再写“只说明与单周期流程的差异”。 |
| `docs/simulation_flow_pipeline_c.md` | 改为自包含文档，不再引用单周期 C 流程作为通用说明。 |
| `README.md` | 删除“单周期核”现行章节，仓库状态改成以五级流水为唯一维护 core。 |

`docs/08xx/0823 从单周期语义模型到五级流水线.md` 等早期规划文档可以保留为历史背景，但如果其中有“当前仍维护单周期”的说法，需要加注说明它不再代表现行工程状态。

### 10.4 需要同步改掉的单周期措辞

这些文件不一定删除，但有单周期现行口径，需要后续统一改：

| 文件 | 需要改的典型表述 |
|---|---|
| `rtl/common/pipeline_pkg.sv` | “成员顺序对应 core_single_cycle.sv” 等注释改为“五级流水寄存器字段顺序”。 |
| `rtl/core/regfile.sv` | `BYPASS_EN` 注释中“单周期顶层保持默认 0”改成泛化说明。 |
| `rtl/core/id_stage.sv`、`rtl/core/ex_stage.sv`、`rtl/core/pc_reg.sv` | “单周期 demo”措辞改成“非流水/组合路径历史用法”或直接删除。 |
| `sim/pipeline5_asm/run_all.sh` | “单周期指令集全覆盖”改为“基础 RV32I 指令集测试”。 |
| `sw/asm/0001_smoke.S` | 文件头“单周期 core”改为“基础 RV32I smoke”。 |
| `sw/c/0202_dmem_init.c` | 文件头“单周期 RV32I C”改为“RV32I C 裸机”。 |
| `docs/08xx/0827 Testbench、commit trace与测试集组织.md` | 当前命令和 DUT 描述改成流水线为现行路径，单周期作为历史阶段。 |

### 10.5 测试程序和软件目录保留

`sw/asm/`、`sw/c/`、`sw/c_runtime/`、`sw/linker/` 不因删除单周期顶层而删除。基础 ISA 测试仍然用于流水线回归；只是脚本入口从 `sim/single_cycle_*` 迁移为 `sim/pipeline5_*`。

### 10.6 简化 pipeline5 仿真脚本的 RTL 文件列表

当前 `sim/pipeline5_asm/06_run_sim.sh`、`sim/pipeline5_asm/run_all.sh`、`sim/pipeline5_c/06_run_sim.sh` 仍显式列出 Verilator 输入文件。这样虽然啰嗦，但能避免 `rtl/core/core_single_cycle.sv` 被一起编译。

完成 10.1 删除或归档单周期顶层后，可以把 pipeline5 脚本改成按目录收集 RTL 文件，例如：

```bash
rtl/common/*.sv
rtl/core/*.sv
rtl/mem/*.sv
```

或用脚本数组统一维护文件列表。改完后需要确认：

- `rtl/core/` 下不再包含不维护的单周期顶层。
- `tb/sv/` 仍只显式选择 `tb_core_pipeline5.sv`，不要把所有 testbench 一起编译。
- 三个 pipeline5 脚本使用同一套 RTL 文件收集规则，避免 asm/c/run_all 行为不一致。

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
- 产生 kill IF/ID、ID/EX、EX/MEM、MEM/WB 的控制。
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
- 生成 forwarding 后的 `csr_operand`。

### Step 6: 扩展 MEM

修改：

- `rtl/core/mem_stage.sv`

目标：

- 接收并透传前级 exception。
- 拆分 load/store misaligned。
- 在 MEM 内部合并前级 exception 和本级 misaligned，输出 MEM 边界最终 exception cause/tval。
- 保持已有 exception 或 misaligned load/store 不访问 dmem。

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
- hazard 仍只处理普通 EX redirect，优先级为 EX redirect > late-result-use stall；trap/MRET redirect 由 `trap_ctrl` 的 kill 口径处理。

### Step 8: 扩展 pipeline register kill

修改：

- `rtl/core/pipe_reg.sv`

目标：

- `pipe_reg_if_id`、`pipe_reg_id_ex`、`pipe_reg_ex_mem`、`pipe_reg_mem_wb` 增加或使用 `kill_i`。
- trap/MRET 在 MEM 接受时能杀掉当前 EX 年轻指令，并阻止当前 MEM 指令进入普通 WB。
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
- 连接 trap kill 到 IF/ID、ID/EX、EX/MEM、MEM/WB。
- 连接 `WB_CSR` 写回路径。
- 保留并调整 commit/debug 输出。

### Step 10: 清理单周期相关文件和流程

修改：

- `rtl/core/core_single_cycle.sv`
- `tb/sv/tb_core_single_cycle.sv`
- `sim/single_cycle_asm/`
- `sim/single_cycle_c/`
- 单周期现行流程文档和 README 入口

目标：

- 不再维护单周期顶层和单周期 testbench。
- 删除或归档单周期仿真脚本。
- 把现行说明改成五级流水为唯一维护 core。
- 保留基础 ISA 测试程序，但只通过 pipeline5 脚本回归。

完成以上步骤后，再另起验证计划，补测试程序、脚本和文档说明。

## 12. RTL 之外的后续配套改动（暂不实施）

本章记录由 RTL 设计选择带来的软件、linker、仿真流程配套需求。当前先只规划，不修改 `rtl/` 之外的文件；等 RTL 主体完成并确定仿真策略后再统一实施。

### 12.1 由 2.2 `MTVEC_RESET` 引出的 trap handler 布局

> 来源：见 2.2 “CSR 状态寄存器”。该步把 `mtvec` 的复位值从 0 设置为 `core_pkg::MTVEC_RESET`，当前平台约定为 `IMEM_BASE + 32'h80`。因此 RTL 默认 trap 入口、linker 放置的 handler 地址、软件写入 `mtvec` 的地址需要保持一致。

后续需要修改：

- `sw/linker/asm_test.ld`
- `sw/linker/c_baremetal.ld`
- 新增或调整 trap 相关 `.S` 测试程序。
- 视 C trap 测试需求，新增专用 trap runtime 或独立启动文件；不要直接让当前共享 `sw/c_runtime/crt0.S` 无条件执行 CSR 指令，否则会影响现有 pipeline5 C 基础回归。
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
- C 侧若要测试 trap，优先使用独立的 trap-aware runtime，或给 pipeline5 CSR/trap 测试单独 build flow；不要影响现有 pipeline5 C 基础测试。

### 12.2 后续统一扩展 IMEM/DMEM 容量与地址图

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
- `tb/sv/tb_core_pipeline5.sv`：同样更新 DMEM 尾地址和栈顶统计。

软件和仿真流程需要同步修改：

- `sw/linker/asm_test.ld`：更新 `IMEM LENGTH`、`DMEM ORIGIN`、`DMEM LENGTH`。
- `sw/linker/c_baremetal.ld`：更新 `IMEM/DMEM` memory region；`__stack_bottom` 不再按 4 KiB 写死为 `ORIGIN(DMEM) + 0x0e00`，建议改成 `__stack_top - 固定栈大小`。
- `sw/asm/*.S`：若 `DMEM_BASE` 改变，所有手写 `lui ..., 0x10` 的地址常量都要同步更新；更推荐逐步改成 `%hi/%lo(__test_status_addr)` 或其他 linker symbol，减少后续地址图变化带来的重复修改。
- `sw/c_runtime/crt0.S` 当前使用 linker symbol 设置 `sp` 和测试状态地址，原则上随 linker 更新即可，不应硬编码 DMEM 地址。
- `sim/pipeline5_*/05_build_mem.sh` 当前主要依赖 linker script 和 objcopy，通常不需要因容量扩大单独改；若后续加入镜像大小检查，再统一接入共享容量约束。
- 保留的 `docs/simulation_flow_pipeline_*.md`、`README.md` 和 08xx 中涉及 `4 KiB`、`0x00010000`、`lui ..., 0x10` 的说明需要在最后统一同步。

仿真影响：

- 对 Verilator 仿真来说，`ADDR_WIDTH = 16` 只是把 ROM/RAM 数组扩到每个 256 KiB，通常影响很小。
- 仿真速度主要取决于执行了多少 cycle、是否打开波形、是否 dump 大量内部信号；单纯扩大未访问的 memory 容量不是主要瓶颈。
- 综合/FPGA 资源会明显受 memory 容量影响，因此仿真可先放宽，综合目标需要单独评估。
