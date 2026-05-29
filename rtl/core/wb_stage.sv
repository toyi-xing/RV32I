//------------------------------------------------------------------------------
// 文件      : rtl/core/wb_stage.sv
// 用途      : RV32I 写回阶段。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - 写回来源选择统一使用 core_pkg::wb_sel_e。
//   - 第一版只负责选择写回数据，不在这里处理 rd == x0 的屏蔽。
//
// 功能：
//   - 根据 wb_sel_i 在 ALU 结果、load 数据、PC+4 和立即数之间选择写回数据。
//   - 输出给 regfile 的写端口使用。
//   - MEM/WB 到 EX 的 forwarding 后续也可以复用本模块输出的最终写回数据。
//------------------------------------------------------------------------------

`default_nettype none

module wb_stage (
    input  core_pkg::wb_sel_e              wb_sel_i,
    input  logic [core_pkg::XLEN-1:0]      alu_result_i,
    input  logic [core_pkg::XLEN-1:0]      load_data_i,
    input  logic [core_pkg::XLEN-1:0]      pc_plus4_i,
    input  logic [core_pkg::XLEN-1:0]      imm_i,

    output logic [core_pkg::XLEN-1:0]      wb_wdata_o
);
    import core_pkg::*;

    always_comb begin
        unique case (wb_sel_i)
            WB_ALU: wb_wdata_o = alu_result_i;
            WB_MEM: wb_wdata_o = load_data_i;
            WB_PC4: wb_wdata_o = pc_plus4_i;
            WB_IMM: wb_wdata_o = imm_i; 
            default: wb_wdata_o = '0;
        endcase
    end


endmodule

`default_nettype wire
