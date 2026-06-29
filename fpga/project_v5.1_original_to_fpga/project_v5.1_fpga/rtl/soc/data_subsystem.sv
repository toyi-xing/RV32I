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

    input  logic                      core_re_i,            // cpu 为 load 指令
    input  logic                      core_we_i,            // cpu 为 store 指令
    input  logic [3:0]                core_be_i,            // 字节使能
    input  logic [core_pkg::XLEN-1:0] core_addr_i,
    input  logic [core_pkg::XLEN-1:0] core_wdata_i,
    output logic [core_pkg::XLEN-1:0] core_rdata_o,
    output logic                      core_access_fault_o,

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
    input  logic                      uart0_tx_ready_i,
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

    // 本拍是一个真实的访存信号，若访存但未落到任何外设窗口，则 access_fault
    wire access_valid = core_re_i | core_we_i;

    // core_addr 命中分配
    wire dmem_hit   = (core_addr_i >= DMEM_BASE)   & (core_addr_i < DMEM_BASE   + DMEM_SIZE_BYTES);
    wire gpio0_hit  = (core_addr_i >= GPIO0_BASE)  & (core_addr_i < GPIO0_BASE  + GPIO0_SIZE_BYTES);
    wire uart0_hit  = (core_addr_i >= UART0_BASE)  & (core_addr_i < UART0_BASE  + UART0_SIZE_BYTES);
    wire timer0_hit = (core_addr_i >= TIMER0_BASE) & (core_addr_i < TIMER0_BASE + TIMER0_SIZE_BYTES);
    wire mapped_hit = dmem_hit | gpio0_hit | uart0_hit | timer0_hit;    // addr 命中已实现的地址

    // 命中窗口 + cpu 是访存信号则有效
    wire dmem_valid   = dmem_hit   & access_valid;
    wire gpio0_valid  = gpio0_hit  & access_valid;
    wire uart0_valid  = uart0_hit  & access_valid;
    wire timer0_valid = timer0_hit & access_valid;

    //==============================================================
    // 子模块实例化
    //==============================================================

    // 外置 simple_ram 固定响应端口。未命中 DMEM 时地址指向 DMEM_BASE，避免 RAM model 看到无意义索引。
    assign dmem_we_o    = core_we_i & dmem_valid;
    assign dmem_be_o    = core_be_i;
    assign dmem_addr_o  = dmem_hit ? core_addr_i : DMEM_BASE;
    assign dmem_wdata_o = core_wdata_i;

    wire [core_pkg::XLEN-1:0] gpio0_rdata;
    wire gpio0_access_fault;
    mmio_gpio #(
        .BASE_ADDR  (soc_pkg::GPIO0_BASE),
        .GPIO_WIDTH (32)
    ) u_mmio_gpio0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (gpio0_valid),
        .we_i           (core_we_i),
        .be_i           (core_be_i),
        .addr_i         (core_addr_i),
        .wdata_i        (core_wdata_i),
        .rdata_o        (gpio0_rdata),
        .access_fault_o (gpio0_access_fault),

        .gpio_in_i      (gpio0_in_i),
        .gpio_out_o     (gpio0_out_o),
        .gpio_oe_o      (gpio0_oe_o),

        .gpio_irq_o     (gpio0_irq_o)
    );

    wire [core_pkg::XLEN-1:0] uart0_rdata;
    wire uart0_access_fault;
    mmio_uart #(
        .BASE_ADDR (soc_pkg::UART0_BASE)
    ) u_mmio_uart0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (uart0_valid),
        .re_i           (core_re_i),
        .we_i           (core_we_i),
        .be_i           (core_be_i),
        .addr_i         (core_addr_i),
        .wdata_i        (core_wdata_i),
        .rdata_o        (uart0_rdata),
        .access_fault_o (uart0_access_fault),

        .tx_ready_i     (uart0_tx_ready_i),
        .tx_valid_o     (uart0_tx_valid_o),
        .tx_data_o      (uart0_tx_data_o),

        .rx_valid_i     (uart0_rx_valid_i),
        .rx_data_i      (uart0_rx_data_i),

        .uart_irq_o     (uart0_irq_o)
    );

    wire [core_pkg::XLEN-1:0] timer0_rdata;
    wire timer0_access_fault;
    mmio_timer32 #(
        .BASE_ADDR (soc_pkg::TIMER0_BASE)
    ) u_mmio_timer32_0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (timer0_valid),
        .we_i           (core_we_i),
        .be_i           (core_be_i),
        .addr_i         (core_addr_i),
        .wdata_i        (core_wdata_i),
        .rdata_o        (timer0_rdata),
        .access_fault_o (timer0_access_fault),

        .timer32_irq_o  (timer0_irq_o)
    );

    // core_rdata_o MUX
    always_comb begin
        core_rdata_o = '0;
        if (dmem_valid) begin
            core_rdata_o = dmem_rdata_i;
        end
        else if (gpio0_valid) begin
            core_rdata_o = gpio0_rdata;
        end
        else if (uart0_valid) begin
            core_rdata_o = uart0_rdata;
        end
        else if (timer0_valid) begin
            core_rdata_o = timer0_rdata;
        end
    end

    // 外设输出的 access_fault 已检测是否为本外设，此处不做重复逻辑
    assign core_access_fault_o = (access_valid & !mapped_hit) |
                                  gpio0_access_fault | uart0_access_fault | timer0_access_fault;

    // 观察信号驱动
    assign dmem_access_o = dmem_valid;
    assign mmio_access_o = gpio0_valid | uart0_valid | timer0_valid;

endmodule

`default_nettype wire
