//------------------------------------------------------------------------------
// 文件      : rtl/core/wb_stage.sv
// 用途      : RV32I 写回阶段。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - 写回来源选择统一使用 core_pkg::wb_sel_e。
//   - reg_we_o 表示当前提交槽存在 GPR 写回动作；rd=x0 的状态写入由 regfile 屏蔽。
//
// 功能：
//   - 根据 wb_sel_i 在 ALU 结果、load 数据、PC+4、立即数和 CSR 旧值之间选择写回数据。
//   - rd=x0 时输出写回数据归零，避免 trace/forwarding 观察到不会真正保存的临时结果。
//   - 输出给 regfile 的写端口使用。
//   - MEM/WB 到 EX 的 forwarding 后续也可以复用本模块输出的最终写回数据。
//------------------------------------------------------------------------------

`default_nettype none

module wb_stage (
    input  logic                           valid_i,
    input  logic                           reg_we_i,
    input  logic [4:0]                     rd_addr_i,
    input  core_pkg::wb_sel_e              wb_sel_i,
    input  logic [core_pkg::XLEN-1:0]      alu_result_i,
    input  logic [core_pkg::XLEN-1:0]      load_data_i,
    input  logic [core_pkg::XLEN-1:0]      pc_plus4_i,
    input  logic [core_pkg::XLEN-1:0]      imm_i,
    input  logic [core_pkg::XLEN-1:0]      csr_rdata_i,

    output logic                           valid_o,
    output logic                           reg_we_o,
    output logic [core_pkg::XLEN-1:0]      wb_wdata_o
);
    import core_pkg::*;

    assign valid_o  = valid_i;
    
    assign reg_we_o = valid_i & reg_we_i;

    always_comb begin
        // 写 x0 是合法的写回动作，但 architectural state 不变。
        // 这里把数据归零，让 commit trace 和 MEM/WB forwarding 看到的值与 x0 语义一致。
        if (rd_addr_i == '0) begin
            wb_wdata_o = '0;
        end
        else begin
            unique case (wb_sel_i)
                WB_ALU: wb_wdata_o = alu_result_i;
                WB_MEM: wb_wdata_o = load_data_i;
                WB_PC4: wb_wdata_o = pc_plus4_i;
                WB_IMM: wb_wdata_o = imm_i; 
                WB_CSR: wb_wdata_o = csr_rdata_i;
                default: wb_wdata_o = '0;
            endcase
        end
    end


endmodule

`default_nettype wire
