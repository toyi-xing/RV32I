//------------------------------------------------------------------------------
// 文件      : rtl/core/ex_stage.sv
// 用途      : RV32I 执行阶段。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - ALU 操作、操作数选择、分支比较类型统一使用 core_pkg.sv 中的枚举。
//   - 第一版先接收已经完成 forwarding 选择后的 rs1/rs2 数据。
//
// 功能：
//   - 根据 op_a_sel_i/op_b_sel_i 选择 ALU 输入操作数。
//   - 使用 alu_op_i 计算 ALU 结果；ALU 结果可表示普通运算结果、访存地址或跳转目标。
//   - 使用 branch_op_i 判断条件分支是否 taken。
//   - 对 taken branch、JAL、JALR 产生 redirect_valid_o 和 redirect_pc_o。
//   - 传出 store_data_o，供 MEM 阶段执行 store。
//------------------------------------------------------------------------------

`default_nettype none

module ex_stage (
    input  logic [core_pkg::XLEN-1:0]     pc_i,              // 当前 EX 阶段指令的 PC。
    input  logic [core_pkg::XLEN-1:0]     rs1_data_i,        // forwarding 后的 rs1 数据。
    input  logic [core_pkg::XLEN-1:0]     rs2_data_i,        // forwarding 后的 rs2 数据，branch 比较和 store data 都会使用。
    input  logic [core_pkg::XLEN-1:0]     imm_i,             // ID 阶段生成并传入的 32 bit 立即数。
    input  logic                          valid_i,           // 当前 EX 槽是否有效。各阶段有各自的 valid 门控其副作用：
                                                             //   EX→redirect，MEM→dmem 写，WB→regfile 写。
    input  core_pkg::alu_op_e             alu_op_i,          // ALU 运算类型。
    input  core_pkg::op_a_sel_e           op_a_sel_i,        // ALU 第一个操作数选择。
    input  core_pkg::op_b_sel_e           op_b_sel_i,        // ALU 第二个操作数选择。
    input  core_pkg::branch_op_e          branch_op_i,       // 条件分支比较类型；BR_NONE 表示非条件分支。
    input  logic                          jump_i,            // 当前指令是否为 JAL/JALR。
    input  logic                          jalr_i,            // 当前指令是否为 JALR；JALR 目标地址需要清 bit0。

    output logic [core_pkg::XLEN-1:0]     alu_result_o,      // ALU 计算结果，向 EX/MEM 传递。
    output logic [core_pkg::XLEN-1:0]     store_data_o,      // 传给 MEM 阶段的 store 写数据。
    output logic                          branch_taken_o,    // 条件分支是否满足跳转条件。
    output logic                          redirect_valid_o,  // 当前 EX 指令是否要求重定向 PC。
    output logic [core_pkg::XLEN-1:0]     redirect_pc_o      // branch/JAL/JALR 的目标 PC。
);
    import core_pkg::*;

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

    branch_unit u_branch_unit (
        .branch_op_i    (branch_op_i),
        .rs1_data_i     (rs1_data_i),
        .rs2_data_i     (rs2_data_i),
        .branch_taken_o (branch_taken_o)
    );

    assign redirect_valid_o = valid_i & (branch_taken_o | jump_i);

    assign redirect_pc_o = jalr_i ? (alu_result_o & ~32'b1) : alu_result_o;

endmodule

`default_nettype wire
