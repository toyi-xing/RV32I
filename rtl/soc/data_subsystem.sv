//------------------------------------------------------------------------------
// 文件      : rtl/soc/data_subsystem.sv
// 用途      : 集成 CPU simple data bus、AXI4-Lite fabric、APB4 外设总线和现有 MMIO 寄存器块。
//
// 规范：
//   - core 侧保持 data_bus_pkg 定义的 single-outstanding request/response 语义。
//   - DMEM 通过独立 AXI4-Lite master port 连接外部 RAM 或其它 memory slave。
//   - GPIO0、UART0、TIMER0 共用 AXI-Lite-to-APB4 bridge，并由 APB mux 选择目标外设。
//   - ACCEL0 未实现，预留窗口和其它未映射地址均由 router 返回 AXI DECERR。
//   - 本模块只负责协议模块和外设集成，不包含 response-delay wrapper 或验证专用配置。
//
// 功能：
//   - 将 core load/store request 转换并路由到外部 DMEM 或内部 APB peripheral path。
//   - 把 AXI OKAY/SLVERR/DECERR 统一转换为 simple response success/error。
//   - 保留 GPIO/UART sideband 和 GPIO/UART/TIMER interrupt，不让其进入 transaction channel。
//   - 输出 accepted request 的 DMEM、已实现 MMIO 和 undefined target 观察脉冲。
//------------------------------------------------------------------------------

`default_nettype none

module data_subsystem (
    input  logic                              clk_i,
    input  logic                              rst_n_i,

    output logic                              core_req_ready_o,
    input  data_bus_pkg::data_req_t           core_req_i,
    output data_bus_pkg::data_resp_t          core_resp_o,

    output axi_lite_pkg::axi_lite_req_t       dmem_axi_req_o,       // 发往外部 DMEM AXI-Lite slave 的 request。
    input  axi_lite_pkg::axi_lite_resp_t      dmem_axi_resp_i,      // 外部 DMEM AXI-Lite slave 的 response。

    input  logic [31:0]                       gpio0_in_i,
    output logic [31:0]                       gpio0_out_o,
    output logic [31:0]                       gpio0_oe_o,

    output logic                              uart0_tx_valid_o,
    output logic [7:0]                        uart0_tx_data_o,
    input  logic                              uart0_rx_valid_i,
    input  logic [7:0]                        uart0_rx_data_i,

    output logic                              gpio0_irq_o,
    output logic                              uart0_irq_o,
    output logic                              timer0_irq_o,

    output logic                              dmem_access_o,        // 本拍 accepted request 命中 DMEM。
    output logic                              mmio_access_o,        // 本拍 accepted request 命中已实现 MMIO。
    output logic                              undefined_access_o    // 本拍 accepted request 命中 undefined target。
);
    import core_pkg::*;
    import soc_pkg::*;
    import axi_lite_pkg::*;
    import apb_pkg::*;

    // simple-bus adapter 与 AXI-Lite router 之间的 upstream channel。
    axi_lite_req_t             adapter_axi_req;
    axi_lite_resp_t            adapter_axi_resp;

    // AXI-Lite router 与 APB bridge 之间的 MMIO channel。
    axi_lite_req_t             apb_axi_req;
    axi_lite_resp_t            apb_axi_resp;

    // APB bridge 与 APB mux 之间的 master channel。
    apb_req_t                  apb_master_req;
    apb_resp_t                 apb_master_resp;

    // APB mux 分发到三个寄存器外设的独立 channel。
    apb_req_t                  gpio0_apb_req;
    apb_resp_t                 gpio0_apb_resp;
    apb_req_t                  uart0_apb_req;
    apb_resp_t                 uart0_apb_resp;
    apb_req_t                  timer0_apb_req;
    apb_resp_t                 timer0_apb_resp;

    // GPIO0 APB-to-register adapter 信号。
    wire                       gpio0_reg_valid;
    wire                       gpio0_reg_we;
    wire [APB_STRB_WIDTH-1:0]  gpio0_reg_be;
    wire [APB_ADDR_WIDTH-1:0]  gpio0_reg_addr;
    wire [APB_DATA_WIDTH-1:0]  gpio0_reg_wdata;
    wire [APB_DATA_WIDTH-1:0]  gpio0_reg_rdata;
    wire                       gpio0_reg_access_fault;

    // UART0 APB-to-register adapter 信号，read enable 用于 RXDATA 读副作用。
    wire                       uart0_reg_valid;
    wire                       uart0_reg_re;
    wire                       uart0_reg_we;
    wire [APB_STRB_WIDTH-1:0]  uart0_reg_be;
    wire [APB_ADDR_WIDTH-1:0]  uart0_reg_addr;
    wire [APB_DATA_WIDTH-1:0]  uart0_reg_wdata;
    wire [APB_DATA_WIDTH-1:0]  uart0_reg_rdata;
    wire                       uart0_reg_access_fault;

    // TIMER0 APB-to-register adapter 信号。
    wire                       timer0_reg_valid;
    wire                       timer0_reg_we;
    wire [APB_STRB_WIDTH-1:0]  timer0_reg_be;
    wire [APB_ADDR_WIDTH-1:0]  timer0_reg_addr;
    wire [APB_DATA_WIDTH-1:0]  timer0_reg_wdata;
    wire [APB_DATA_WIDTH-1:0]  timer0_reg_rdata;
    wire                       timer0_reg_access_fault;

    // accepted request 的地址分类只用于观察，不参与正式 response 路由。
    wire                       core_req_accept;
    wire                       dmem_hit;
    wire                       gpio0_hit;
    wire                       uart0_hit;
    wire                       timer0_hit;
    wire                       implemented_mmio_hit;

    simple_bus_to_axi_lite u_simple_bus_to_axi_lite (
        .clk_i              (clk_i),
        .rst_n_i            (rst_n_i),

        .simple_req_ready_o (core_req_ready_o),
        .simple_req_i       (core_req_i),
        .simple_resp_o      (core_resp_o),

        .axi_req_o          (adapter_axi_req),
        .axi_resp_i         (adapter_axi_resp)
    );

    // router 组合选择 DMEM、APB 或内部 error slave，不额外插入 register slice。
    axi_lite_router #(
        .ENABLE_ACCEL0 (1'b0)
    ) u_axi_lite_router (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .upstream_req_i (adapter_axi_req),
        .upstream_resp_o(adapter_axi_resp),

        .dmem_req_o     (dmem_axi_req_o),
        .dmem_resp_i    (dmem_axi_resp_i),

        .apb_req_o      (apb_axi_req),
        .apb_resp_i     (apb_axi_resp),

        .accel0_req_o   (),
        .accel0_resp_i  (AXI_LITE_RESP_IDLE)
    );

    axi_lite_to_apb u_axi_lite_to_apb (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .axi_req_i  (apb_axi_req),
        .axi_resp_o (apb_axi_resp),

        .apb_req_o  (apb_master_req),
        .apb_resp_i (apb_master_resp)
    );

    // APB mux 同时完成 PADDR 译码、request 分发和 selected response 汇流。
    apb_mux u_apb_mux (
        .upstream_req_i  (apb_master_req),
        .upstream_resp_o (apb_master_resp),

        .gpio0_req_o     (gpio0_apb_req),
        .gpio0_resp_i    (gpio0_apb_resp),

        .uart0_req_o     (uart0_apb_req),
        .uart0_resp_i    (uart0_apb_resp),

        .timer0_req_o    (timer0_apb_req),
        .timer0_resp_i   (timer0_apb_resp)
    );

    apb_to_reg_adapter u_gpio0_apb_to_reg (
        .apb_req_i          (gpio0_apb_req),
        .apb_resp_o         (gpio0_apb_resp),

        .reg_valid_o        (gpio0_reg_valid),
        .reg_re_o           (),
        .reg_we_o           (gpio0_reg_we),
        .reg_be_o           (gpio0_reg_be),
        .reg_addr_o         (gpio0_reg_addr),
        .reg_wdata_o        (gpio0_reg_wdata),
        .reg_rdata_i        (gpio0_reg_rdata),
        .reg_access_fault_i (gpio0_reg_access_fault)
    );

    mmio_gpio #(
        .BASE_ADDR  (GPIO0_BASE),
        .GPIO_WIDTH (32)
    ) u_mmio_gpio0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (gpio0_reg_valid),
        .we_i           (gpio0_reg_we),
        .be_i           (gpio0_reg_be),
        .addr_i         (gpio0_reg_addr),
        .wdata_i        (gpio0_reg_wdata),
        .rdata_o        (gpio0_reg_rdata),
        .access_fault_o (gpio0_reg_access_fault),

        .gpio_in_i      (gpio0_in_i),
        .gpio_out_o     (gpio0_out_o),
        .gpio_oe_o      (gpio0_oe_o),

        .gpio_irq_o     (gpio0_irq_o)
    );

    apb_to_reg_adapter u_uart0_apb_to_reg (
        .apb_req_i          (uart0_apb_req),
        .apb_resp_o         (uart0_apb_resp),

        .reg_valid_o        (uart0_reg_valid),
        .reg_re_o           (uart0_reg_re),
        .reg_we_o           (uart0_reg_we),
        .reg_be_o           (uart0_reg_be),
        .reg_addr_o         (uart0_reg_addr),
        .reg_wdata_o        (uart0_reg_wdata),
        .reg_rdata_i        (uart0_reg_rdata),
        .reg_access_fault_i (uart0_reg_access_fault)
    );

    mmio_uart #(
        .BASE_ADDR (UART0_BASE)
    ) u_mmio_uart0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (uart0_reg_valid),
        .re_i           (uart0_reg_re),
        .we_i           (uart0_reg_we),
        .be_i           (uart0_reg_be),
        .addr_i         (uart0_reg_addr),
        .wdata_i        (uart0_reg_wdata),
        .rdata_o        (uart0_reg_rdata),
        .access_fault_o (uart0_reg_access_fault),

        .tx_valid_o     (uart0_tx_valid_o),
        .tx_data_o      (uart0_tx_data_o),
        .rx_valid_i     (uart0_rx_valid_i),
        .rx_data_i      (uart0_rx_data_i),

        .uart_irq_o     (uart0_irq_o)
    );

    apb_to_reg_adapter u_timer0_apb_to_reg (
        .apb_req_i          (timer0_apb_req),
        .apb_resp_o         (timer0_apb_resp),

        .reg_valid_o        (timer0_reg_valid),
        .reg_re_o           (),
        .reg_we_o           (timer0_reg_we),
        .reg_be_o           (timer0_reg_be),
        .reg_addr_o         (timer0_reg_addr),
        .reg_wdata_o        (timer0_reg_wdata),
        .reg_rdata_i        (timer0_reg_rdata),
        .reg_access_fault_i (timer0_reg_access_fault)
    );

    mmio_timer32 #(
        .BASE_ADDR (TIMER0_BASE)
    ) u_mmio_timer32_0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (timer0_reg_valid),
        .we_i           (timer0_reg_we),
        .be_i           (timer0_reg_be),
        .addr_i         (timer0_reg_addr),
        .wdata_i        (timer0_reg_wdata),
        .rdata_o        (timer0_reg_rdata),
        .access_fault_o (timer0_reg_access_fault),

        .timer32_irq_o  (timer0_irq_o)
    );

    // 汇总 accepted-request 观察信号；正式响应路径完全由 AXI-Lite/APB transaction 决定。
    assign core_req_accept      = core_req_i.valid && core_req_ready_o;
    assign dmem_hit             = (core_req_i.addr >= DMEM_BASE) &&
                                  (core_req_i.addr < (DMEM_BASE + DMEM_SIZE_BYTES));
    assign gpio0_hit            = (core_req_i.addr >= GPIO0_BASE) &&
                                  (core_req_i.addr < (GPIO0_BASE + GPIO0_SIZE_BYTES));
    assign uart0_hit            = (core_req_i.addr >= UART0_BASE) &&
                                  (core_req_i.addr < (UART0_BASE + UART0_SIZE_BYTES));
    assign timer0_hit           = (core_req_i.addr >= TIMER0_BASE) &&
                                  (core_req_i.addr < (TIMER0_BASE + TIMER0_SIZE_BYTES));
    assign implemented_mmio_hit = gpio0_hit || uart0_hit || timer0_hit;

    assign dmem_access_o        = core_req_accept && dmem_hit;
    assign mmio_access_o        = core_req_accept && implemented_mmio_hit;
    assign undefined_access_o   = core_req_accept && !dmem_hit && !implemented_mmio_hit;

endmodule

`default_nettype wire
