//------------------------------------------------------------------------------
// 文件      : rtl/core/branch_unit.sv
// 用途      : RV32I 条件分支判断单元。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - 分支类型统一使用 core_pkg::branch_op_e。
//
// 功能：
//   - 根据 branch_op_i 对 rs1_data_i 和 rs2_data_i 做条件比较。
//   - 对 BEQ/BNE/BLT/BGE/BLTU/BGEU 产生 branch_taken_o。
//   - 只判断条件是否成立，不计算 branch target，不修改 PC。
//------------------------------------------------------------------------------

`default_nettype none

module branch_unit (
    input  core_pkg::branch_op_e          branch_op_i,
    input  logic [core_pkg::XLEN-1:0]     rs1_data_i,
    input  logic [core_pkg::XLEN-1:0]     rs2_data_i,

    output logic                          branch_taken_o
);
    import core_pkg::*;

    always_comb begin
        unique case (branch_op_i)
            BR_EQ:   branch_taken_o = (rs1_data_i == rs2_data_i);
            BR_NE:   branch_taken_o = (rs1_data_i != rs2_data_i);
            BR_LT:   branch_taken_o = ($signed(rs1_data_i) < $signed(rs2_data_i));
            BR_GE:   branch_taken_o = ($signed(rs1_data_i) >= $signed(rs2_data_i));
            BR_LTU:  branch_taken_o = (rs1_data_i < rs2_data_i);
            BR_GEU:  branch_taken_o = (rs1_data_i >= rs2_data_i);
            default: branch_taken_o = 1'b0;
        endcase
    end

endmodule

`default_nettype wire
