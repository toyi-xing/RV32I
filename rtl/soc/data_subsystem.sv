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
//   - 判断地址命中 DMEM、UART0、GPIO0，还是未映射。
//   - 实例化 simple_ram、mmio_uart、mmio_gpio。
//   - 对 store，只把写使能送到命中的设备。
//   - 对 load，返回命中设备的 32-bit rdata。
//   - 对未映射 load/store，返回 core_access_fault_o = 1，读数据返回 0。
//   - 暴露 UART/GPIO 观察信号给 SoC/testbench。
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

    input  logic [31:0]               gpio0_in_i,
    output logic [31:0]               gpio0_out_o,
    output logic [31:0]               gpio0_oe_o,

    output logic                      uart0_tx_valid_o,
    output logic [7:0]                uart0_tx_data_o,

    output logic                      dmem_access_o,        // 观察信号：本拍访问命中 DMEM。
    output logic                      mmio_access_o         // 观察信号：本拍访问命中 MMIO。
);

    import core_pkg::*;
    import soc_pkg::*;

    // 本拍是一个真实的访存信号，若访存但未落到任何外设窗口，则 access_fault
    wire access_valid = core_re_i | core_we_i;

    // core_addr 命中分配
    wire dmem_hit, gpio0_hit, uart0_hit;
    wire mapped_hit;    // addr 命中已实现的地址
    assign dmem_hit   = (core_addr_i >= DMEM_BASE)  & (core_addr_i < DMEM_BASE  + DMEM_SIZE_BYTES);
    assign gpio0_hit  = (core_addr_i >= GPIO0_BASE) & (core_addr_i < GPIO0_BASE + GPIO0_SIZE_BYTES);
    assign uart0_hit  = (core_addr_i >= UART0_BASE) & (core_addr_i < UART0_BASE + UART0_SIZE_BYTES);
    assign mapped_hit = dmem_hit | gpio0_hit | uart0_hit;

    // 命中窗口 + cpu 是访存信号则有效
    wire   dmem_valid, gpio0_valid, uart0_valid;
    assign dmem_valid   = dmem_hit  & access_valid;
    assign gpio0_valid  = gpio0_hit & access_valid;
    assign uart0_valid  = uart0_hit & access_valid;

    //==============================================================
    // 子模块实例化
    //==============================================================

    // 只要落入 ram，不存在 access_fault
    wire dmem_we = core_we_i & dmem_valid;
    wire [core_pkg::XLEN-1:0] dmem_addr = dmem_hit ? core_addr_i : DMEM_BASE;     // 无意义索引统一指向 ram[0]
    wire [core_pkg::XLEN-1:0] dmem_rdata;
    simple_ram #(
        .ADDR_WIDTH (core_pkg::DMEM_ADDR_WIDTH)
    ) u_simple_ram (
        .clk_i   (clk_i),
        .we_i    (dmem_we),      // ram 无 valid 输入，读无条件，写需要额外逻辑
        .be_i    (core_be_i),
        .addr_i  (dmem_addr),
        .wdata_i (core_wdata_i),
        .rdata_o (dmem_rdata)
    );

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
        .gpio_oe_o      (gpio0_oe_o)
    );

    wire [core_pkg::XLEN-1:0] uart0_rdata;
    wire uart0_access_fault;
    mmio_uart #(
        .BASE_ADDR (soc_pkg::UART0_BASE)
    ) u_mmio_uart0 (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .valid_i        (uart0_valid),
        .we_i           (core_we_i),
        .be_i           (core_be_i),
        .addr_i         (core_addr_i),
        .wdata_i        (core_wdata_i),
        .rdata_o        (uart0_rdata),
        .access_fault_o (uart0_access_fault),

        .tx_valid_o     (uart0_tx_valid_o),
        .tx_data_o      (uart0_tx_data_o)
    );

    // core_rdata_o MUX
    always_comb begin
        core_rdata_o = '0;
        if (dmem_valid) begin
            core_rdata_o = dmem_rdata;
        end
        else if (gpio0_valid) begin
            core_rdata_o = gpio0_rdata;
        end
        else if (uart0_valid) begin
            core_rdata_o = uart0_rdata;
        end
    end

    // 外设输出的 access_fault 已检测是否为本外设，此处不做重复逻辑
    assign core_access_fault_o = (access_valid & !mapped_hit) |
                                  gpio0_access_fault | uart0_access_fault;

    // 观察信号驱动
    assign dmem_access_o = dmem_valid;
    assign mmio_access_o = gpio0_valid | uart0_valid;

endmodule

`default_nettype wire
