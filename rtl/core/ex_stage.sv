//------------------------------------------------------------------------------
// 文件      : rtl/core/ex_stage.sv
// 用途      : RV32I 执行阶段。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - ALU 操作、操作数选择、分支比较类型统一使用 core_pkg.sv 中的枚举。
//   - 本模块只接收 EX 实际使用的 rs1/rs2 数据：
//     单周期 demo 中通常直接来自 ID/regfile；五级流水中可来自 forwarding mux。
//
// 功能：
//   - 根据 op_a_sel_i/op_b_sel_i 选择 ALU 输入操作数。
//   - 使用 alu_op_i 计算 ALU 结果；ALU 结果可表示普通运算结果、访存地址或跳转目标。
//   - 使用 branch_op_i 判断条件分支是否 taken。
//   - 对 taken branch、JAL、JALR 产生 redirect_valid_o 和 redirect_pc_o。
//   - 传出 store_data_o，供 MEM 阶段执行 store。
//
// CSR、trap 相关功能：
//   - EX 阶段负责识别的异常：instruction address misaligned（pc 重定向目标未 4 字节对齐）
//   - 使用 forwarding 后的 rs1 或零扩展 uimm 生成 CSR 操作数 csr_operand_o。
//   - 前级已带 exception 的指令，抑制 redirect 并透传 exception 信息（同一条指令先发现的异常先保持）。
//   - MRET 标志透传到 EX/MEM。
//------------------------------------------------------------------------------

`default_nettype none

module ex_stage (
    input  logic                          valid_i,           // 当前 EX 槽是否有效。各阶段有各自的 valid 门控其副作用：
                                                             // EX→redirect，MEM→dmem 写，WB→regfile 写。
    input  logic [core_pkg::XLEN-1:0]     pc_i,              // 当前 EX 阶段指令的 PC。
    input  logic [core_pkg::XLEN-1:0]     rs1_data_i,        // EX 实际使用的 rs1 数据；单周期 demo 直接来自 regfile，流水线中可来自 forwarding mux。
    input  logic [core_pkg::XLEN-1:0]     rs2_data_i,        // EX 实际使用的 rs2 数据；branch 比较和 store data 都会使用。
    input  logic [core_pkg::XLEN-1:0]     imm_i,             // ID 阶段生成并传入的 32 bit 立即数。
    input  core_pkg::alu_op_e             alu_op_i,          // ALU 运算类型。
    input  core_pkg::op_a_sel_e           op_a_sel_i,        // ALU 第一个操作数选择。
    input  core_pkg::op_b_sel_e           op_b_sel_i,        // ALU 第二个操作数选择。
    input  core_pkg::branch_op_e          branch_op_i,       // 条件分支比较类型；BR_NONE 表示非条件分支。
    input  logic                          jump_i,            // 当前指令是否为 JAL/JALR。
    input  logic                          jalr_i,            // 当前指令是否为 JALR；JALR 目标地址需要清 bit0。

    // CSR、trap 相关
    input  logic                          exception_valid_i, // 前级已发现的 exception 是否有效；有效时 EX 不再产生普通 redirect。
    input  core_pkg::trap_cause_e         exception_cause_i, // 前级 exception cause，EX 透传或在更高优先级时替换。
    input  logic [core_pkg::XLEN-1:0]     exception_tval_i,  // 前级 exception tval，EX 透传或在更高优先级时替换。
    input  logic                          csr_i,             // 当前 EX 指令是否为 CSR 指令。
    input  core_pkg::csr_op_e             csr_op_i,          // CSR 操作类型，用于选择 rs1 还是 uimm 作为 CSR 操作数。
    input  logic [4:0]                    csr_uimm_i,        // CSR immediate 字段，EX 阶段零扩展后形成 csr_operand_o。
    input  logic                          mret_i,            // MRET 标志透传到 EX/MEM。

    output logic                          valid_o,           // 送入 EX/MEM 的 valid；第一版 EX 不主动丢弃指令，直接透传 valid_i。
    output logic [core_pkg::XLEN-1:0]     alu_result_o,      // ALU 计算结果，向 EX/MEM 传递。
    output logic [core_pkg::XLEN-1:0]     store_data_o,      // 传给 MEM 阶段的 store 写数据。
    output logic                          redirect_valid_o,  // 当前 EX 指令是否要求重定向 PC。
    output logic [core_pkg::XLEN-1:0]     redirect_pc_o,     // branch/JAL/JALR 的目标 PC。

    // CSR、trap 相关
    output logic                          exception_valid_o, // EX 输出的 exception 是否有效，包含前级透传和 target misaligned。
    output core_pkg::trap_cause_e         exception_cause_o, // EX 输出 exception cause。
    output logic [core_pkg::XLEN-1:0]     exception_tval_o,  // EX 输出 exception tval。
    output logic [core_pkg::XLEN-1:0]     csr_operand_o,     // 送入 CSR 文件的操作数；register 形式来自 forwarding 后 rs1，immediate 形式来自零扩展 uimm。
    output logic                          mret_o             // MRET 标志透传输出。
);
    import core_pkg::*;
    
    assign valid_o = valid_i;

    wire [core_pkg::XLEN-1:0] op_a = (op_a_sel_i == OP_A_RS1) ? rs1_data_i :
                                     (op_a_sel_i == OP_A_PC)  ? pc_i : '0;
    wire [core_pkg::XLEN-1:0] op_b = (op_b_sel_i == OP_B_RS2) ? rs2_data_i : imm_i;
    alu u_alu (
        .alu_op_i   (alu_op_i),
        .op_a_i     (op_a),
        .op_b_i     (op_b),
        .result_o   (alu_result_o)
    );

    assign store_data_o = rs2_data_i;

    wire branch_taken;

    branch_unit u_branch_unit (
        .branch_op_i    (branch_op_i),
        .rs1_data_i     (rs1_data_i),
        .rs2_data_i     (rs2_data_i),
        .branch_taken_o (branch_taken)
    );

    wire   instr_redirect   =  valid_i & (branch_taken | jump_i);   // 指令是否请求 redirect
    assign redirect_valid_o = instr_redirect & !exception_valid_o;  // 无 exception 时发出最终 redirect

    assign redirect_pc_o    = jalr_i ? (alu_result_o & ~32'b1) : alu_result_o;

    // csr、trap 相关---------------------------------------------------------------------
    wire ex_exception_valid;
    assign ex_exception_valid   = valid_i & instr_redirect & (redirect_pc_o[1:0] != 2'b0);    // 指令请求 redirect 但地址非法，则异常
    assign exception_valid_o    = exception_valid_i ? exception_valid_i : ex_exception_valid;
    assign exception_cause_o    = exception_valid_i ? exception_cause_i : TRAP_CAUSE_INST_ADDR_MISALIGNED;
    assign exception_tval_o     = exception_valid_i ? exception_tval_i : redirect_pc_o;

    wire csr_op_reg             = (csr_op_i == CSR_OP_RW)  || (csr_op_i == CSR_OP_RS)  || (csr_op_i == CSR_OP_RC);
    wire csr_op_uimm            = (csr_op_i == CSR_OP_RWI) || (csr_op_i == CSR_OP_RSI) || (csr_op_i == CSR_OP_RCI);
    assign csr_operand_o        = !csr_i? '0 : csr_op_reg ? rs1_data_i : csr_op_uimm ? {{(core_pkg::XLEN-5){1'b0}},csr_uimm_i} : '0;

    assign mret_o = mret_i;

endmodule

`default_nettype wire
