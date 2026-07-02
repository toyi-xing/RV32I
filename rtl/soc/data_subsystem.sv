//------------------------------------------------------------------------------
// 文件      : rtl/soc/data_subsystem.sv
// 用途      : core LSU simple data bus 与具体数据设备之间的译码/响应包装层。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - core 侧使用单 outstanding request/response 简化 data bus。
//   - core_req_valid_i/core_req_ready_o 接受一次 load/store request。
//   - core_resp_valid_o/core_resp_error_o 返回该 request 的完成结果。
//   - dmem_access_o/mmio_access_o 是 accepted request 命中观察信号，给 testbench 做统计或波形 debug。
//
// 功能：
//   - 接收 core 的 data request（valid/write/be/addr/wdata）。
//   - 判断地址命中 DMEM、UART0、GPIO0、TIMER0，还是未映射。
//   - 通过外置固定响应 DMEM 端口访问上层连接的 simple_ram/DMEM model。
//   - 实例化 mmio_uart、mmio_gpio、mmio_timer32。
//   - 在 request accepted 当拍访问固定响应 DMEM/MMIO target，并锁存 rdata/error。
//   - 根据 TB 配置的 delay cycles 同拍或延迟返回 response。
//   - 对未映射 load/store，返回 response error，读数据返回 0。
//   - 暴露 GPIO 输出、UART TX/RX 事件接口和 GPIO/UART/TIMER0 中断给 SoC/testbench。
//------------------------------------------------------------------------------

`default_nettype none

module data_subsystem (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

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

    // 供 tb mailbox 配置的 data target 响应延迟，默认 0 时等价于固定响应。
    input  logic [6:0]                dmem_resp_delay_cycles_i,
    input  logic [6:0]                gpio0_resp_delay_cycles_i,
    input  logic [6:0]                uart0_resp_delay_cycles_i,
    input  logic [6:0]                timer0_resp_delay_cycles_i,

    output logic                      dmem_access_o,        // 观察信号：本拍 accepted request 命中 DMEM。
    output logic                      mmio_access_o         // 观察信号：本拍 accepted request 命中 MMIO。
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

    //======================================================================
    // 固定响应 target 的延时响应包装层，用计数器注入非 0 wait-state。
    // 固定响应 DMEM/MMIO 在 accepted request 当拍完成本体访问并锁存返回值，
    // wrapper 根据 TB 配置的 delay cycles 延后向 core 返回 response。
    // 后续真实慢 slave 可以替换该 wrapper，或自行按 simple bus 语义产生 response。
    //======================================================================

    wire [6:0] req_delay_cycles = dmem_hit   ? dmem_resp_delay_cycles_i   :
                                  gpio0_hit  ? gpio0_resp_delay_cycles_i  :
                                  uart0_hit  ? uart0_resp_delay_cycles_i  :
                                  timer0_hit ? timer0_resp_delay_cycles_i : '0;
    wire [core_pkg::XLEN-1:0] resp_rdata = dmem_hit   ? dmem_rdata_i :
                                           gpio0_hit  ? gpio0_rdata  :
                                           uart0_hit  ? uart0_rdata  :
                                           timer0_hit ? timer0_rdata : '0;
    wire resp_error =  gpio0_hit  ? gpio0_access_fault  :
                       uart0_hit  ? uart0_access_fault  :
                       timer0_hit ? timer0_access_fault : 1'b0 ;
    reg       resp_delay_pending_q;     // 信号等价于 resp_pending_q，驱动与语义稍有差别便于理解
    reg [6:0] resp_delay_cnt, req_delay_cycles_q;
    reg                      resp_valid_q;
    reg [core_pkg::XLEN-1:0] resp_rdata_q;
    reg                      resp_error_q;
    always_ff @(posedge clk_i or negedge rst_n_i) begin : RESP_DELAY
        if (!rst_n_i) begin
            resp_delay_pending_q <= 1'b0;
            resp_delay_cnt <= '0;
            resp_valid_q <= 1'b0;
            resp_rdata_q <= '0;
            resp_error_q <= 1'b0;
        end else begin
            resp_valid_q <= 1'b0;
            if (req_accept_fire) begin
                if (req_delay_cycles == 0) begin // 当拍响应
                    // 同拍响应时，组合输出直通，不过包装层，无需 resp_valid_q
                end else begin                   // 需要几拍记数后响应
                    resp_rdata_q <= resp_rdata;             // 锁存 req 脉冲拍 addr 对应的数据
                    resp_error_q <= resp_error;             // 锁存 req 脉冲外设的 error 状态
                    resp_delay_pending_q <= 1'b1;           // 打开计数器
                    resp_delay_cnt <= 1;                    // 计数器 + 1
                    req_delay_cycles_q <= req_delay_cycles; // 锁存 req 脉冲外设的延迟拍数
                    if (req_delay_cycles == 7'd1) begin  // 只延迟一拍时，本拍就应非阻塞赋值
                        resp_valid_q <= 1'b1;
                    end
                end
            end
            if (resp_delay_pending_q) begin     // 多拍响应记数阶段
                resp_delay_cnt <= resp_delay_cnt + 1;
                // req_delay_cycles_q 恒大于 0
                if (resp_delay_cnt == req_delay_cycles_q - 1) begin // 本拍够，上拍就应非阻塞赋值
                    resp_valid_q <= 1'b1;
                end
                // 若本拍已够，下拍不用加了
                if (resp_delay_cnt == req_delay_cycles_q) begin
                    resp_delay_pending_q <= 1'b0;
                    resp_delay_cnt <= '0;
                end
            end
        end
    end

    // 使用包装层接线
    wire resp_zero_fire = req_accept_fire && (req_delay_cycles == 7'd0);    // 同拍响应脉冲

    wire                      resp_dmem_valid   = resp_zero_fire ? req_dmem_valid : (resp_valid_q & (resp_target_q == TARGET_DMEM));
    wire [core_pkg::XLEN-1:0] resp_dmem_rdata   = resp_zero_fire ? dmem_rdata_i : resp_rdata_q;

    wire                      resp_gpio0_valid  = resp_zero_fire ? req_gpio0_valid : (resp_valid_q & (resp_target_q == TARGET_GPIO0));
    wire [core_pkg::XLEN-1:0] resp_gpio0_rdata  = resp_zero_fire ? gpio0_rdata : resp_rdata_q;
    wire                      resp_gpio0_error  = resp_zero_fire ? gpio0_access_fault : resp_error_q;

    wire                      resp_uart0_valid  = resp_zero_fire ? req_uart0_valid : (resp_valid_q & (resp_target_q == TARGET_UART0));
    wire [core_pkg::XLEN-1:0] resp_uart0_rdata  = resp_zero_fire ? uart0_rdata : resp_rdata_q;
    wire                      resp_uart0_error  = resp_zero_fire ? uart0_access_fault : resp_error_q;

    wire                      resp_timer0_valid = resp_zero_fire ? req_timer0_valid : (resp_valid_q & (resp_target_q == TARGET_TIMER0));
    wire [core_pkg::XLEN-1:0] resp_timer0_rdata = resp_zero_fire ? timer0_rdata : resp_rdata_q;
    wire                      resp_timer0_error = resp_zero_fire ? timer0_access_fault : resp_error_q;

    //==============================================================
    // 子模块实例化
    //==============================================================

    // 外置 simple_ram 固定响应端口。未命中 DMEM 时地址指向 DMEM_BASE，避免 RAM model 看到无意义索引。
    assign dmem_we_o    = req_we_accept & req_dmem_valid;
    assign dmem_be_o    = core_req_be_i;
    assign dmem_addr_o  = dmem_hit ? core_req_addr_i : DMEM_BASE;
    assign dmem_wdata_o = core_req_wdata_i;
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
    // undefined
    wire resp_undefined_valid = req_undefined_valid;    // undefined 保持同拍响应

    // core_resp MUX
    soc_pkg::target_e resp_target;
    assign resp_target = resp_pending_q ? resp_target_q : target;    // 0 wait-state 时，使用组合信号当拍响应
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
    assign dmem_access_o = req_dmem_valid;
    assign mmio_access_o = req_gpio0_valid | req_uart0_valid | req_timer0_valid;

endmodule

`default_nettype wire
