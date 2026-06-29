`default_nettype none

module uart_tx_phy #(
    parameter int unsigned CLK_FREQ_HZ = 50_000_000,
    parameter int unsigned BAUD        = 115_200
) (
    input  logic       clk_i,
    input  logic       rst_n_i,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    output logic       ready_o,
    output logic       tx_o
);
    localparam int unsigned CLKS_PER_BIT = CLK_FREQ_HZ / BAUD;
    localparam int unsigned CNT_WIDTH    = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);
    localparam logic [CNT_WIDTH-1:0] BIT_TICKS = CLKS_PER_BIT[CNT_WIDTH-1:0] - 1'b1;

    logic [CNT_WIDTH-1:0] baud_cnt;
    logic [3:0]           bit_idx;
    logic [9:0]           shifter;
    logic                 busy;

    assign ready_o = !busy;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            baud_cnt <= '0;
            bit_idx  <= '0;
            shifter  <= 10'h3ff;
            busy     <= 1'b0;
            tx_o     <= 1'b1;
        end
        else begin
            if (!busy) begin
                tx_o <= 1'b1;
                if (valid_i) begin
                    shifter  <= {1'b1, data_i, 1'b0};
                    bit_idx  <= 4'd0;
                    baud_cnt <= '0;
                    busy     <= 1'b1;
                    tx_o     <= 1'b0;
                end
            end
            else if (baud_cnt == BIT_TICKS) begin
                baud_cnt <= '0;
                if (bit_idx == 4'd9) begin
                    busy <= 1'b0;
                    tx_o <= 1'b1;
                end
                else begin
                    shifter <= {1'b1, shifter[9:1]};
                    bit_idx <= bit_idx + 1'b1;
                    tx_o    <= shifter[1];
                end
            end
            else begin
                baud_cnt <= baud_cnt + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
