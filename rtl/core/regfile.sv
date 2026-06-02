//------------------------------------------------------------------------------
// 文件      : rtl/core/regfile.sv
// 用途      : RV32I 的 32 项通用寄存器堆。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 写端口在时钟上升沿同步写入。
//   - 两个读端口是组合读。
//   - rst_n_i 是低有效复位。
//
// 功能：
//   - 为整数数据通路提供两个读端口和一个写端口。
//   - x0 硬连为 0：对 x0 的写入会被丢弃，读取 x0 永远返回 0。
//   - 读端口直接返回当前寄存器数组中的值，不在 regfile 内部做同拍写读旁路。
//------------------------------------------------------------------------------

`default_nettype none

module regfile (
    input  logic                         clk_i,
    input  logic                         rst_n_i,

    input  logic [4:0]                   rs1_addr_i,
    output logic [core_pkg::XLEN-1:0]    rs1_rdata_o,

    input  logic [4:0]                   rs2_addr_i,
    output logic [core_pkg::XLEN-1:0]    rs2_rdata_o,

    input  logic                         we_i,
    input  logic [4:0]                   rd_addr_i,
    input  logic [core_pkg::XLEN-1:0]    rd_wdata_i
);
    import core_pkg::*;

    logic [XLEN-1:0] gpr_q [32];

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (int i = 0; i < 32; i++) begin
                gpr_q[i] <= '0;
            end
        end else begin
            if (we_i && (rd_addr_i != 5'd0)) begin
                gpr_q[rd_addr_i] <= rd_wdata_i;
            end

            gpr_q[0] <= '0;
        end
    end

    always_comb begin
        if (rs1_addr_i == 5'd0) begin
            rs1_rdata_o = '0;
        end else begin
            rs1_rdata_o = gpr_q[rs1_addr_i];
        end
    end

    always_comb begin
        if (rs2_addr_i == 5'd0) begin
            rs2_rdata_o = '0;
        end else begin
            rs2_rdata_o = gpr_q[rs2_addr_i];
        end
    end

endmodule

`default_nettype wire
