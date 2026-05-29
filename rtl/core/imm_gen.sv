//------------------------------------------------------------------------------
// 文件      : rtl/core/imm_gen.sv
// 用途      : RV32I 立即数生成器。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - imm_sel_i 从 core_pkg::imm_sel_e 中选择一种立即数格式。
//
// 功能：
//   - 从 32 bit 指令中拼接并扩展 I/S/B/U/J 五类立即数。
//   - B 类型和 J 类型输出已经包含最低位补 0，分支/JAL 目标地址逻辑应直接使用
//     pc + imm_o，不要再次左移。
//------------------------------------------------------------------------------

`default_nettype none

module imm_gen (
    input  logic              [core_pkg::ILEN-1:0] instr_i,
    input  core_pkg::imm_sel_e                     imm_sel_i,
    output logic              [core_pkg::XLEN-1:0] imm_o
);
    import core_pkg::*;

    always_comb begin
        unique case (imm_sel_i)
            IMM_I:     imm_o = {{20{instr_i[31]}},instr_i[31:20]};
            IMM_S:     imm_o = {{19{instr_i[31]}},instr_i[31],instr_i[31:25],instr_i[11:7]};
            IMM_B:     imm_o = {{19{instr_i[31]}},instr_i[31],instr_i[7],instr_i[30:25],instr_i[11:8],1'b0};
            IMM_U:     imm_o = {instr_i[31:12],12'b0};
            IMM_J:     imm_o = {{11{instr_i[31]}},instr_i[31],instr_i[19:12],instr_i[20],instr_i[30:21],1'b0};
            IMM_NONE:  imm_o = '0;
            default:   imm_o = '0;
        endcase
    end

endmodule

`default_nettype wire
