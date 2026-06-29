`default_nettype none

module fpga_imem #(
    parameter int unsigned ADDR_WIDTH = core_pkg::IMEM_ADDR_WIDTH
) (
    input  logic                          clk_i,
    input  logic [core_pkg::XLEN-1:0]     addr_i,
    output logic [core_pkg::ILEN-1:0]     rdata_o
);
    import core_pkg::*;

    localparam int unsigned DEPTH = 1 << ADDR_WIDTH;

    (* ramstyle = "M9K" *) logic [ILEN-1:0] mem [0:DEPTH-1];

    always_ff @(negedge clk_i) begin
        rdata_o   <= mem[ADDR_WIDTH'((addr_i - IMEM_BASE) >> 2)];
    end

    initial begin
        for (int unsigned i = 0; i < DEPTH; i++) begin
            mem[i] = '0;
        end

        $readmemh("../mem/current_imem.mem", mem);
    end

endmodule

`default_nettype wire
