`default_nettype none

module e10_rv32i_top #(
    parameter bit LED_ACTIVE_LOW = 1'b0
) (
    input  logic       sys_clk,
    input  logic       sys_rst_n,
    input  logic [1:0] key,
    output logic [1:0] led,
    input  logic       uart_rxd,
    output logic       uart_txd
);
    logic rst_n_sync_0;
    logic rst_n_sync;

    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rst_n_sync_0 <= 1'b0;
            rst_n_sync   <= 1'b0;
        end
        else begin
            rst_n_sync_0 <= 1'b1;
            rst_n_sync   <= rst_n_sync_0;
        end
    end

    logic [core_pkg::XLEN-1:0] imem_addr;
    logic [core_pkg::ILEN-1:0] imem_rdata;
    logic                      dmem_we;
    logic [3:0]                dmem_be;
    logic [core_pkg::XLEN-1:0] dmem_addr;
    logic [core_pkg::XLEN-1:0] dmem_wdata;
    logic [core_pkg::XLEN-1:0] dmem_rdata;

    logic [31:0] gpio0_in;
    logic [31:0] gpio0_out;
    logic [31:0] gpio0_oe;

    logic       uart0_tx_valid;
    logic [7:0] uart0_tx_data;
    logic       uart0_tx_ready;
    logic       uart0_rx_valid;
    logic [7:0] uart0_rx_data;

    assign gpio0_in = {30'b0, key};
    wire [1:0] led_drive = gpio0_out[1:0] & gpio0_oe[1:0];
    assign led = LED_ACTIVE_LOW ? ~led_drive : led_drive;

    rv32i_soc u_soc (
        .clk_i                 (sys_clk),
        .rst_n_i               (rst_n_sync),

        .imem_addr_o           (imem_addr),
        .imem_rdata_i          (imem_rdata),

        .dmem_we_o             (dmem_we),
        .dmem_be_o             (dmem_be),
        .dmem_addr_o           (dmem_addr),
        .dmem_wdata_o          (dmem_wdata),
        .dmem_rdata_i          (dmem_rdata),

        .gpio0_in_i            (gpio0_in),
        .gpio0_out_o           (gpio0_out),
        .gpio0_oe_o            (gpio0_oe),

        .uart0_tx_valid_o      (uart0_tx_valid),
        .uart0_tx_data_o       (uart0_tx_data),
        .uart0_tx_ready_i      (uart0_tx_ready),
        .uart0_rx_valid_i      (uart0_rx_valid),
        .uart0_rx_data_i       (uart0_rx_data),

        .data_re_o             (),
        .data_we_o             (),
        .data_be_o             (),
        .data_addr_o           (),
        .data_wdata_o          (),
        .data_rdata_o          (),
        .data_access_fault_o   (),
        .dmem_access_o         (),
        .mmio_access_o         (),

        .commit_valid_o        (),
        .commit_pc_o           (),
        .commit_instr_o        (),
        .commit_instr_id_o     (),
        .commit_reg_we_o       (),
        .commit_rd_addr_o      (),
        .commit_rd_wdata_o     (),

        .trap_valid_o          (),
        .trap_pc_o             (),
        .trap_is_interrupt_o   (),
        .trap_cause_code_o     (),
        .trap_tval_o           (),
        .trap_return_o         (),
        .trap_redirect_pc_o    (),

        .gpio0_irq_o           (),
        .uart0_irq_o           (),
        .timer0_irq_o          (),
        .meip_o                (),
        .mtip_o                ()
    );

    fpga_imem #(
        .ADDR_WIDTH (core_pkg::IMEM_ADDR_WIDTH)
    ) u_imem (
        .clk_i   (sys_clk),
        .addr_i  (imem_addr),
        .rdata_o (imem_rdata)
    );

    fpga_dmem #(
        .ADDR_WIDTH (core_pkg::DMEM_ADDR_WIDTH)
    ) u_dmem (
        .clk_i   (sys_clk),
        .we_i    (dmem_we),
        .be_i    (dmem_be),
        .addr_i  (dmem_addr),
        .wdata_i (dmem_wdata),
        .rdata_o (dmem_rdata)
    );

    uart_tx_phy #(
        .CLK_FREQ_HZ (50_000_000),
        .BAUD        (115_200)
    ) u_uart_tx (
        .clk_i   (sys_clk),
        .rst_n_i (rst_n_sync),
        .valid_i (uart0_tx_valid),
        .data_i  (uart0_tx_data),
        .ready_o (uart0_tx_ready),
        .tx_o    (uart_txd)
    );

    uart_rx_phy #(
        .CLK_FREQ_HZ (50_000_000),
        .BAUD        (115_200)
    ) u_uart_rx (
        .clk_i   (sys_clk),
        .rst_n_i (rst_n_sync),
        .rx_i    (uart_rxd),
        .valid_o (uart0_rx_valid),
        .data_o  (uart0_rx_data)
    );

endmodule

`default_nettype wire
