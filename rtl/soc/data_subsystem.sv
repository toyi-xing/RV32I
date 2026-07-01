//------------------------------------------------------------------------------
// 文件      : rtl/soc/data_subsystem.sv
// 用途      : core LSU 数据访问与具体数据设备之间的固定响应译码层。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 当前是固定响应译码层，没有 ready/valid backpressure。
//   - core_re_i/core_we_i 来自 core.lsu_re_o/lsu_we_o。
//   - core_access_fault_o 接回 core.lsu_access_fault_i。
//   - dmem_access_o/mmio_access_o 只是观察信号，给 testbench 做统计或波形 debug。
//
// 功能：
//   - 接收 core 的 lsu_* request（re/we/be/addr/wdata）。
//   - 判断地址命中 DMEM、UART0、GPIO0、TIMER0，还是未映射。
//   - 通过外置固定响应 DMEM 端口访问上层连接的 simple_ram/DMEM model。
//   - 实例化 mmio_uart、mmio_gpio、mmio_timer32。
//   - 对 store，只把写使能送到命中的设备。
//   - 对 load，返回命中设备的 32-bit rdata。
//   - 对未映射 load/store，返回 core_access_fault_o = 1，读数据返回 0。
//   - 暴露 GPIO 输出、UART TX/RX 事件接口和 GPIO/UART/TIMER0 中断给 SoC/testbench。
//------------------------------------------------------------------------------

`default_nettype none

module data_subsystem (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    // input  logic                      core_re_i,            // cpu 为 load 指令
    // input  logic                      core_we_i,            // cpu 为 store 指令
    // input  logic [3:0]                core_be_i,            // 字节使能
    // input  logic [core_pkg::XLEN-1:0] core_addr_i,
    // input  logic [core_pkg::XLEN-1:0] core_wdata_i,
    // output logic [core_pkg::XLEN-1:0] core_rdata_o,
    // output logic                      core_access_fault_o,  // core 发送的访存指令地址为定义（当前仅上报未映射地址/未知 offset，不实现权限错误）

    output logic                      core_req_ready_o,
    input  logic                      core_req_valid_i,
    input  logic                      core_req_write_i,
    input  logic [3:0]                core_req_be_i,
    input  logic [core_pkg::XLEN-1:0] core_req_addr_i,
    input  logic [core_pkg::XLEN-1:0] core_req_wdata_i,

    output logic                      core_resp_valid_o,
    output logic [core_pkg::XLEN-1:0] core_resp_rdata_o,
    output logic                      core_resp_error_o,

    output logic                      dmem_we_o,
    output logic [3:0]                dmem_be_o,
    output logic [core_pkg::XLEN-1:0] dmem_addr_o,
    output logic [core_pkg::XLEN-1:0] dmem_wdata_o,
    input  logic [core_pkg::XLEN-1:0] dmem_rdata_i,

    input  logic [31:0]               gpio0_in_i,
    output logic [31:0]               gpio0_out_o,
    output logic [31:0]               gpio0_oe_o,

    output logic                      uart0_tx_valid_o,
    output logic [7:0]                uart0_tx_data_o,
    input  logic                      uart0_rx_valid_i,
    input  logic [7:0]                uart0_rx_data_i,

    // 中断输出
    output logic                      gpio0_irq_o,
    output logic                      uart0_irq_o,
    output logic                      timer0_irq_o,

    output logic                      dmem_access_o,        // 观察信号：本拍访问命中 DMEM。
    output logic                      mmio_access_o         // 观察信号：本拍访问命中 MMIO。
);

    import core_pkg::*;
    import soc_pkg::*;

    // 状态信号
    reg resp_pending_q; // 接受了 req 但还没给出 resp
    soc_pkg::target_e target, resp_target_q; // req 请求的目标，resp 响应源
    assign target = dmem_hit   ? TARGET_DMEM   :
                    gpio0_hit  ? TARGET_GPIO0  :
                    uart0_hit  ? TARGET_UART0  :
                    timer0_hit ? TARGET_TIMER0 : TARGET_UNDEFINED;
    always_ff @(posedge clk_i or negedge rst_n_i) begin : STATUS_CTRL
        if (!rst_n_i) begin
            resp_pending_q <= 1'b0;
            resp_target_q  <= TARGET_UNDEFINED;
        end
        else begin
            if (req_accept_fire) begin
                resp_pending_q <= 1'b1;
                resp_target_q  <= target;
            end
            if (core_resp_valid_o) begin    // 0 wait-state 时 resp_pending_q 无需置位
                resp_pending_q <= 1'b0;
            end
        end
    end
    assign core_req_ready_o = !resp_pending_q;

    // 本拍是一个真实被接受的的访存信号（脉冲信号）
    wire req_accept_fire = core_req_valid_i &  core_req_ready_o;
    wire req_re_accept   = req_accept_fire  & !core_req_write_i;
    wire req_we_accept   = req_accept_fire  &  core_req_write_i;

    // core_addr 命中分配
    wire dmem_hit   = (core_req_addr_i >= DMEM_BASE)   & (core_req_addr_i < DMEM_BASE   + DMEM_SIZE_BYTES);
    wire gpio0_hit  = (core_req_addr_i >= GPIO0_BASE)  & (core_req_addr_i < GPIO0_BASE  + GPIO0_SIZE_BYTES);
    wire uart0_hit  = (core_req_addr_i >= UART0_BASE)  & (core_req_addr_i < UART0_BASE  + UART0_SIZE_BYTES);
    wire timer0_hit = (core_req_addr_i >= TIMER0_BASE) & (core_req_addr_i < TIMER0_BASE + TIMER0_SIZE_BYTES);
    wire mapped_hit = dmem_hit | gpio0_hit | uart0_hit | timer0_hit;    // addr 命中已实现的地址

    //accepted request 命中各目标窗口时，产生对应 target 的访问脉冲
    wire req_dmem_valid      = req_accept_fire &  dmem_hit;
    wire req_gpio0_valid     = req_accept_fire &  gpio0_hit;
    wire req_uart0_valid     = req_accept_fire &  uart0_hit;
    wire req_timer0_valid    = req_accept_fire &  timer0_hit;
    wire req_undefined_valid = req_accept_fire & !mapped_hit;

    //==============================================================
    // 子模块实例化
    //==============================================================

    // 外置 simple_ram 固定响应端口。未命中 DMEM 时地址指向 DMEM_BASE，避免 RAM model 看到无意义索引。
    assign dmem_we_o    = req_we_accept & req_dmem_valid;
    assign dmem_be_o    = core_req_be_i;
    assign dmem_addr_o  = dmem_hit ? core_req_addr_i : DMEM_BASE;
    assign dmem_wdata_o = core_req_wdata_i;
    wire                      resp_dmem_valid = req_dmem_valid;    // 暂时同拍响应，未改 dmem 延迟
    wire [core_pkg::XLEN-1:0] resp_dmem_rdata = dmem_rdata_i;

    wire [core_pkg::XLEN-1:0] gpio0_rdata;
    wire gpio0_access_fault;
    mmio_gpio #(
        .BASE_ADDR  (soc_pkg::GPIO0_BASE),
        .GPIO_WIDTH (32)
    ) u_mmio_gpio0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (req_gpio0_valid),
        .we_i           (req_we_accept),
        .be_i           (core_req_be_i),
        .addr_i         (core_req_addr_i),
        .wdata_i        (core_req_wdata_i),
        .rdata_o        (gpio0_rdata),
        .access_fault_o (gpio0_access_fault),

        .gpio_in_i      (gpio0_in_i),
        .gpio_out_o     (gpio0_out_o),
        .gpio_oe_o      (gpio0_oe_o),

        .gpio_irq_o     (gpio0_irq_o)
    );
    wire                      resp_gpio0_valid = req_gpio0_valid;    // 暂时同拍响应，未改外设延迟
    wire [core_pkg::XLEN-1:0] resp_gpio0_rdata = gpio0_rdata;
    wire                      resp_gpio0_error = gpio0_access_fault;


    wire [core_pkg::XLEN-1:0] uart0_rdata;
    wire uart0_access_fault;
    mmio_uart #(
        .BASE_ADDR (soc_pkg::UART0_BASE)
    ) u_mmio_uart0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (req_uart0_valid),
        .re_i           (req_re_accept),
        .we_i           (req_we_accept),
        .be_i           (core_req_be_i),
        .addr_i         (core_req_addr_i),
        .wdata_i        (core_req_wdata_i),
        .rdata_o        (uart0_rdata),
        .access_fault_o (uart0_access_fault),

        .tx_valid_o     (uart0_tx_valid_o),
        .tx_data_o      (uart0_tx_data_o),

        .rx_valid_i     (uart0_rx_valid_i),
        .rx_data_i      (uart0_rx_data_i),

        .uart_irq_o     (uart0_irq_o)
    );
    wire                      resp_uart0_valid = req_uart0_valid;    // 暂时同拍响应，未改外设延迟
    wire [core_pkg::XLEN-1:0] resp_uart0_rdata = uart0_rdata;
    wire                      resp_uart0_error = uart0_access_fault;

    wire [core_pkg::XLEN-1:0] timer0_rdata;
    wire timer0_access_fault;
    mmio_timer32 #(
        .BASE_ADDR (soc_pkg::TIMER0_BASE)
    ) u_mmio_timer32_0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (req_timer0_valid),
        .we_i           (req_we_accept),
        .be_i           (core_req_be_i),
        .addr_i         (core_req_addr_i),
        .wdata_i        (core_req_wdata_i),
        .rdata_o        (timer0_rdata),
        .access_fault_o (timer0_access_fault),

        .timer32_irq_o  (timer0_irq_o)
    );
    wire                      resp_timer0_valid = req_timer0_valid;    // 暂时同拍响应，未改外设延迟
    wire [core_pkg::XLEN-1:0] resp_timer0_rdata = timer0_rdata;
    wire                      resp_timer0_error = timer0_access_fault;

    // undefined
    wire resp_undefined_valid = req_undefined_valid;    // undefined同拍响应

    // core_resp MUX
    soc_pkg::target_e resp_target = resp_pending_q ? resp_target_q : target;    // 0 wait-state 时，使用组合信号当拍响应
    always_comb begin
        core_resp_valid_o = 1'b0;
        core_resp_rdata_o = '0;
        core_resp_error_o = 1'b0;
        unique case (resp_target)
            TARGET_DMEM: begin
                core_resp_valid_o = resp_dmem_valid;
                core_resp_rdata_o = resp_dmem_rdata;
                core_resp_error_o = 1'b0;   // 目前 ram 窗口内不产生 bus error，若上 FPGA 调整 RAM 容量则需调整此处
            end
            TARGET_GPIO0: begin
                core_resp_valid_o = resp_gpio0_valid;
                core_resp_rdata_o = resp_gpio0_rdata;
                core_resp_error_o = resp_gpio0_error;
            end
            TARGET_UART0: begin
                core_resp_valid_o = resp_uart0_valid;
                core_resp_rdata_o = resp_uart0_rdata;
                core_resp_error_o = resp_uart0_error;
            end
            TARGET_TIMER0: begin
                core_resp_valid_o = resp_timer0_valid;
                core_resp_rdata_o = resp_timer0_rdata;
                core_resp_error_o = resp_timer0_error;
            end
            default: begin  // TARGET_UNDEFINED
                core_resp_valid_o = resp_undefined_valid;
                core_resp_rdata_o = '0;
                core_resp_error_o = 1'b1;   // undefined 直接出错
            end
        endcase
    end

    // 观察信号驱动
    assign dmem_access_o = resp_dmem_valid;
    assign mmio_access_o = resp_gpio0_valid | resp_uart0_valid | resp_timer0_valid;

endmodule

`default_nettype wire
