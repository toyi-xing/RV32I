`default_nettype none

module uart_rx_phy #(
    parameter int unsigned CLK_FREQ_HZ = 50_000_000,
    parameter int unsigned BAUD        = 115_200
) (
    input  logic       clk_i,
    input  logic       rst_n_i,
    input  logic       rx_i,
    output logic       valid_o,
    output logic [7:0] data_o
);
    localparam int unsigned CLKS_PER_BIT = CLK_FREQ_HZ / BAUD;
    localparam int unsigned HALF_BIT     = CLKS_PER_BIT / 2;
    localparam int unsigned CNT_WIDTH    = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);
    localparam logic [CNT_WIDTH:0] BIT_TICKS  = CLKS_PER_BIT[CNT_WIDTH:0] - 1'b1;
    localparam logic [CNT_WIDTH:0] HALF_TICKS = HALF_BIT[CNT_WIDTH:0];

    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_e;

    rx_state_e          state;
    logic [CNT_WIDTH:0] clk_cnt;
    logic [2:0]         bit_idx;
    logic [7:0]         data_shift;
    logic               rx_meta;
    logic               rx_sync;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= rx_i;
            rx_sync <= rx_meta;
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state      <= RX_IDLE;
            clk_cnt    <= '0;
            bit_idx    <= '0;
            data_shift <= '0;
            data_o     <= '0;
            valid_o    <= 1'b0;
        end
        else begin
            valid_o <= 1'b0;

            unique case (state)
                RX_IDLE: begin
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    if (!rx_sync) begin
                        state <= RX_START;
                    end
                end

                RX_START: begin
                    if (clk_cnt == HALF_TICKS) begin
                        clk_cnt <= '0;
                        state   <= rx_sync ? RX_IDLE : RX_DATA;
                    end
                    else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                RX_DATA: begin
                    if (clk_cnt == BIT_TICKS) begin
                        clk_cnt             <= '0;
                        data_shift[bit_idx] <= rx_sync;
                        bit_idx             <= bit_idx + 1'b1;
                        if (bit_idx == 3'd7) begin
                            state <= RX_STOP;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                RX_STOP: begin
                    if (clk_cnt == BIT_TICKS) begin
                        clk_cnt <= '0;
                        state   <= RX_IDLE;
                        if (rx_sync) begin
                            data_o  <= data_shift;
                            valid_o <= 1'b1;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: begin
                    state <= RX_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
