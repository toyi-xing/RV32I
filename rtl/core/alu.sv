//------------------------------------------------------------------------------
// 文件      : rtl/core/alu.sv
// 用途      : RV32I 整数 ALU。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - 运算类型由 core_pkg::alu_op_e 选择。
//
// 功能：
//   - 实现 RV32I 整数算术、逻辑、移位、比较、访存读写地址计算所需的 ALU 运算。
//   - 分支是否跳转、访存读写字节使能和数据对齐不放在本模块中处理。
//------------------------------------------------------------------------------

`default_nettype none

module alu (
    input  core_pkg::alu_op_e                 alu_op_i,
    input  logic              [core_pkg::XLEN-1:0] op_a_i,
    input  logic              [core_pkg::XLEN-1:0] op_b_i,
    output logic              [core_pkg::XLEN-1:0] result_o
);
    import core_pkg::*;

    logic [4:0] shamt;

    assign shamt = op_b_i[4:0];

    always_comb begin
        unique case (alu_op_i)
            ALU_NONE:            result_o = '0;
            ALU_ADD:             result_o = op_a_i + op_b_i;
            ALU_SUB:             result_o = op_a_i - op_b_i;
            ALU_XOR:             result_o = op_a_i ^ op_b_i;
            ALU_OR:              result_o = op_a_i | op_b_i;
            ALU_AND:             result_o = op_a_i & op_b_i;
            ALU_SLL:             result_o = op_a_i << shamt;
            ALU_SRL:             result_o = op_a_i >> shamt;
            ALU_SRA:             result_o = $signed(op_a_i) >>> shamt;
            ALU_SLT:             result_o = ($signed(op_a_i) < $signed(op_b_i)) ? {{(XLEN-1){1'b0}}, 1'b1} : '0;
            ALU_SLTU:            result_o = (op_a_i < op_b_i) ? {{(XLEN-1){1'b0}}, 1'b1} : '0;
            default:             result_o = '0;
        endcase
    end

endmodule

`default_nettype wire
