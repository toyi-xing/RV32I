//------------------------------------------------------------------------------
// 文件      : rtl/bus/axi_lite/axi_lite_router.sv
// 用途      : 将单个 AXI4-Lite master transaction 按地址路由到固定下游 target。
//
// 规范：
//   - 上游和各下游均使用 axi_lite_pkg 聚合的 AW/W/B/AR/R 五通道接口。
//   - router 只支持一个全局 outstanding read 或 write，不实现多 master 仲裁。
//   - write target 由 AWADDR 决定，B response 完成前保持 route 不变。
//   - read target 由 ARADDR 决定，R response 完成前保持 route 不变。
//   - 未选中的下游保持空闲，未映射地址由内部 error slave 返回 DECERR。
//
// 功能：
//   - DMEM 地址路由到外部 AXI-Lite RAM slave。
//   - GPIO0/UART0/TIMER0 地址路由到 AXI-Lite-to-APB4 bridge。
//   - ACCEL0 保留独立下游端口，未启用时与其它未映射地址一样返回 DECERR。
//   - AW/W 允许同拍或分拍握手；W 先有效时等待 AWADDR 确定 target。
//   - 异常同拍出现 read/write request 时固定选择 write，避免同时接受两笔事务。
//------------------------------------------------------------------------------

`default_nettype none

module axi_lite_router #(
    parameter bit ENABLE_ACCEL0 = 1'b0
) (
    input  logic                              clk_i,
    input  logic                              rst_n_i,

    input  axi_lite_pkg::axi_lite_req_t       upstream_req_i,    // 上游 AXI-Lite master request。
    output axi_lite_pkg::axi_lite_resp_t      upstream_resp_o,   // 返回上游的 selected target response。

    output axi_lite_pkg::axi_lite_req_t       dmem_req_o,        // DMEM AXI-Lite slave request。
    input  axi_lite_pkg::axi_lite_resp_t      dmem_resp_i,       // DMEM AXI-Lite slave response。

    output axi_lite_pkg::axi_lite_req_t       apb_req_o,         // AXI-Lite-to-APB4 bridge request。
    input  axi_lite_pkg::axi_lite_resp_t      apb_resp_i,        // AXI-Lite-to-APB4 bridge response。

    output axi_lite_pkg::axi_lite_req_t       accel0_req_o,      // 预留 ACCEL0 AXI-Lite slave request。
    input  axi_lite_pkg::axi_lite_resp_t      accel0_resp_i      // 预留 ACCEL0 AXI-Lite slave response。
);
    import axi_lite_pkg::*;
    import core_pkg::*;
    import soc_pkg::*;

    typedef enum logic [1:0] {
        ROUTER_IDLE,          // 无 outstanding transaction，可以接受一笔 read 或 write request。
        ROUTER_WRITE_REQ,     // target 已确定，等待 AW/W 中尚未完成的 channel。（当前 core 与外设模型不访问此状态）
        ROUTER_WRITE_RESP,    // AW/W 均已完成，等待 selected target 的 B response。
        ROUTER_READ_RESP      // AR 已完成，等待 selected target 的 R response。
    } router_state_e;

    typedef enum logic [1:0] {
        ROUTE_DMEM,           // 外部 AXI-Lite DMEM slave。
        ROUTE_APB,            // AXI-Lite-to-APB4 bridge。
        ROUTE_ACCEL0,         // 可选 ACCEL0 direct AXI-Lite slave。
        ROUTE_ERROR           // 内部 default error slave。
    } router_target_e;

    router_state_e              state_q;          // 当前 router transaction 状态。
    router_target_e             target_q;         // 当前 outstanding transaction 的下游 target。
    reg                         aw_done_q;        // 当前 write 的 AW handshake 已完成。
    reg                         w_done_q;         // 当前 write 的 W handshake 已完成。

    router_target_e             active_target;    // 本拍 request/response 实际使用的 target。
    axi_lite_req_t              routed_req;       // 只发送给 active target 的 channel request。
    axi_lite_req_t              error_req;        // 内部 error slave request。
    axi_lite_resp_t             error_resp;       // 内部 error slave response。
    axi_lite_resp_t             selected_resp;    // active target 返回的 channel response。

    wire idle_write_select;                       // IDLE 同拍 read/write 竞争时固定选择 write。
    wire upstream_aw_accept;                      // 上游 AW 与 selected target 完成 handshake。
    wire upstream_w_accept;                       // 上游 W 与 selected target 完成 handshake。
    wire upstream_b_accept;                       // 上游接受 selected target 的 B response。
    wire upstream_ar_accept;                      // 上游 AR 与 selected target 完成 handshake。
    wire upstream_r_accept;                       // 上游接受 selected target 的 R response。
    wire write_req_complete;                      // AW/W 均已完成，可以等待 B response。

    function automatic router_target_e decode_target(input axi_lite_addr_t addr);
        if ((addr >= DMEM_BASE) && (addr < (DMEM_BASE + DMEM_SIZE_BYTES))) begin
            decode_target = ROUTE_DMEM;
        end
        else if (((addr >= GPIO0_BASE)  && (addr < (GPIO0_BASE  + GPIO0_SIZE_BYTES ))) ||
                 ((addr >= TIMER0_BASE) && (addr < (TIMER0_BASE + TIMER0_SIZE_BYTES))) ||
                 ((addr >= UART0_BASE)  && (addr < (UART0_BASE  + UART0_SIZE_BYTES )))) begin
            decode_target = ROUTE_APB;
        end
        else if (ENABLE_ACCEL0 &&
                 (addr >= ACCEL0_BASE) &&
                 (addr < (ACCEL0_BASE + ACCEL0_SIZE_BYTES))) begin
            decode_target = ROUTE_ACCEL0;
        end
        else begin
            decode_target = ROUTE_ERROR;
        end
    endfunction

    assign idle_write_select  = (state_q == ROUTER_IDLE) && (upstream_req_i.aw_valid || upstream_req_i.w_valid);

    assign upstream_aw_accept = upstream_req_i.aw_valid && upstream_resp_o.aw_ready;
    assign upstream_w_accept  = upstream_req_i.w_valid  && upstream_resp_o.w_ready;
    assign upstream_b_accept  = upstream_resp_o.b_valid && upstream_req_i.b_ready;

    assign upstream_ar_accept = upstream_req_i.ar_valid && upstream_resp_o.ar_ready;
    assign upstream_r_accept  = upstream_resp_o.r_valid && upstream_req_i.r_ready;

    // 包含本拍 handshake，避免 AW/W 同拍完成时额外停留一拍。
    assign write_req_complete = (aw_done_q || upstream_aw_accept) &&
                                (w_done_q  || upstream_w_accept);

    // 内部状态机，IDLE 时直通上游输出，req 提交后进入新状态等待 resp
    // 与 simple_bus_to_axi_lite 状态转移条件相同，两状态机并行运行，状态转移延迟不累加
    always_ff @(posedge clk_i or negedge rst_n_i) begin : ROUTER_STATE
        if (!rst_n_i) begin
            state_q   <= ROUTER_IDLE;
            target_q  <= ROUTE_ERROR;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
        end
        else begin
            case (state_q)
                ROUTER_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                    if (idle_write_select && upstream_req_i.aw_valid) begin
                        if (upstream_aw_accept || upstream_w_accept) begin
                            target_q <= decode_target(upstream_req_i.aw.addr);
                            if (upstream_aw_accept) begin
                                aw_done_q <= 1'b1;
                            end
                            if (upstream_w_accept) begin
                                w_done_q <= 1'b1;
                            end
                            if (write_req_complete) begin
                                state_q <= ROUTER_WRITE_RESP;
                            end
                            // 本项目 SoC 往往 aw、w 同时完成，不会跳到 ROUTER_WRITE_REQ
                            else begin
                                state_q <= ROUTER_WRITE_REQ;
                            end
                        end
                    end
                    else if (upstream_ar_accept) begin
                        state_q  <= ROUTER_READ_RESP;
                        target_q <= decode_target(upstream_req_i.ar.addr);
                    end
                end

                ROUTER_WRITE_REQ: begin
                    if (upstream_aw_accept) begin
                        aw_done_q <= 1'b1;
                    end
                    if (upstream_w_accept) begin
                        w_done_q <= 1'b1;
                    end
                    if (write_req_complete) begin
                        state_q <= ROUTER_WRITE_RESP;
                    end
                end

                ROUTER_WRITE_RESP: begin
                    if (upstream_b_accept) begin
                        state_q   <= ROUTER_IDLE;
                        target_q  <= ROUTE_ERROR;
                        aw_done_q <= 1'b0;
                        w_done_q  <= 1'b0;
                    end
                end

                ROUTER_READ_RESP: begin
                    if (upstream_r_accept) begin
                        state_q  <= ROUTER_IDLE;
                        target_q <= ROUTE_ERROR;
                    end
                end

                default: begin
                    state_q   <= ROUTER_IDLE;
                    target_q  <= ROUTE_ERROR;
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                end
            endcase
        end
    end

    // IDLE 时使用当前 AW/AR address 组合选择 target；请求被接受后只使用锁存 route。
    always_comb begin : ACTIVE_TARGET_SELECT
        active_target = target_q;
        if (state_q == ROUTER_IDLE) begin
            if (idle_write_select && upstream_req_i.aw_valid) begin
                active_target = decode_target(upstream_req_i.aw.addr);
            end
            else if (!idle_write_select && upstream_req_i.ar_valid) begin
                active_target = decode_target(upstream_req_i.ar.addr);
            end
            else begin
                active_target = ROUTE_ERROR;
            end
        end
    end

    // router 不增加 request register slice，只按当前状态转发允许握手的 channel。
    // 路由给 target -----------------------------------------------------------------------------
    always_comb begin : ROUTED_REQUEST_BUILD
        routed_req = AXI_LITE_REQ_IDLE;
        if (rst_n_i) begin
            case (state_q)
                ROUTER_IDLE: begin
                    if (idle_write_select && upstream_req_i.aw_valid) begin
                        routed_req.aw_valid = upstream_req_i.aw_valid;
                        routed_req.aw       = upstream_req_i.aw;
                        routed_req.w_valid  = upstream_req_i.w_valid;
                        routed_req.w        = upstream_req_i.w;
                    end
                    else if (!idle_write_select && upstream_req_i.ar_valid) begin
                        routed_req.ar_valid = upstream_req_i.ar_valid;
                        routed_req.ar       = upstream_req_i.ar;
                    end
                end

                ROUTER_WRITE_REQ: begin
                    routed_req.aw_valid = upstream_req_i.aw_valid && !aw_done_q;
                    routed_req.aw       = upstream_req_i.aw;
                    routed_req.w_valid  = upstream_req_i.w_valid && !w_done_q;
                    routed_req.w        = upstream_req_i.w;
                end

                ROUTER_WRITE_RESP: begin
                    routed_req.b_ready = upstream_req_i.b_ready;
                end

                ROUTER_READ_RESP: begin
                    routed_req.r_ready = upstream_req_i.r_ready;
                end

                default: begin
                    routed_req = AXI_LITE_REQ_IDLE;
                end
            endcase
        end
    end

    // 只有 active target 能观察到有效 channel，其它下游保持完全空闲。
    assign dmem_req_o   = (active_target == ROUTE_DMEM)   ? routed_req : AXI_LITE_REQ_IDLE;
    assign apb_req_o    = (active_target == ROUTE_APB)    ? routed_req : AXI_LITE_REQ_IDLE;
    assign accel0_req_o = (active_target == ROUTE_ACCEL0) ? routed_req : AXI_LITE_REQ_IDLE;
    assign error_req    = (active_target == ROUTE_ERROR)  ? routed_req : AXI_LITE_REQ_IDLE;

    // router 内部实例化 axi_lite_error_slave 负责未定义 target 的内部兜底机制。
    axi_lite_error_slave u_axi_lite_error_slave (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .axi_req_i  (error_req),
        .axi_resp_o (error_resp)
    );

    always_comb begin : SELECTED_RESPONSE_MUX
        case (active_target)
            ROUTE_DMEM:   selected_resp = dmem_resp_i;
            ROUTE_APB:    selected_resp = apb_resp_i;
            ROUTE_ACCEL0: selected_resp = accel0_resp_i;
            default:      selected_resp = error_resp;
        endcase
    end

    // 只把当前状态允许的 READY/response 返回上游，避免接受第二笔 transaction。
    // 汇总响应并返回 resp -----------------------------------------------------------------------------
    always_comb begin : UPSTREAM_RESPONSE_BUILD
        upstream_resp_o = AXI_LITE_RESP_IDLE;
        if (rst_n_i) begin
            case (state_q)
                ROUTER_IDLE: begin
                    if (idle_write_select && upstream_req_i.aw_valid) begin
                        upstream_resp_o.aw_ready = selected_resp.aw_ready;
                        upstream_resp_o.w_ready  = selected_resp.w_ready;
                    end
                    else if (!idle_write_select && upstream_req_i.ar_valid) begin
                        upstream_resp_o.ar_ready = selected_resp.ar_ready;
                    end
                end

                ROUTER_WRITE_REQ: begin
                    upstream_resp_o.aw_ready = !aw_done_q && selected_resp.aw_ready;
                    upstream_resp_o.w_ready  = !w_done_q  && selected_resp.w_ready;
                end

                ROUTER_WRITE_RESP: begin
                    upstream_resp_o.b_valid = selected_resp.b_valid;
                    upstream_resp_o.b       = selected_resp.b;
                end

                ROUTER_READ_RESP: begin
                    upstream_resp_o.r_valid = selected_resp.r_valid;
                    upstream_resp_o.r       = selected_resp.r;
                end

                default: begin
                    upstream_resp_o = AXI_LITE_RESP_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
