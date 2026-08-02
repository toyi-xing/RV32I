//------------------------------------------------------------------------------
// 文件      : rtl/bus/apb/apb_mux.sv
// 用途      : 将单个 APB4 master transaction 按地址分发到 GPIO0、UART0 或 TIMER0。
//
// 规范：
//   - 上游和各下游均使用 apb_pkg 聚合的 APB4 request/response。
//   - mux 为纯组合路径，内部完成地址译码、request 分发和 response 选择，不保存 transaction 状态。
//   - APB master 在 SETUP/ACCESS 期间保持地址稳定，因此同一笔访问的 target 不会改变。
//   - 只有被选中的外设观察到 PSEL，其余下游保持 APB_REQ_IDLE。
//
// 功能：
//   - GPIO0、UART0、TIMER0 地址分别路由到对应 APB peripheral port。
//   - 被选中外设的 PREADY/PRDATA/PSLVERR 返回上游。
//   - 未映射地址在首个 ACCESS phase 返回 PSLVERR，避免 transaction 永久等待。
//------------------------------------------------------------------------------

`default_nettype none

module apb_mux (
    input  apb_pkg::apb_req_t        upstream_req_i,    // 上游 APB4 master request。
    output apb_pkg::apb_resp_t       upstream_resp_o,   // selected target 返回的 APB4 response。

    output apb_pkg::apb_req_t        gpio0_req_o,       // GPIO0 APB request。
    input  apb_pkg::apb_resp_t       gpio0_resp_i,      // GPIO0 APB response。

    output apb_pkg::apb_req_t        uart0_req_o,       // UART0 APB request。
    input  apb_pkg::apb_resp_t       uart0_resp_i,      // UART0 APB response。

    output apb_pkg::apb_req_t        timer0_req_o,      // TIMER0 APB request。
    input  apb_pkg::apb_resp_t       timer0_resp_i      // TIMER0 APB response。
);
    import apb_pkg::*;
    import soc_pkg::*;

    typedef enum logic [1:0] {
        APB_TARGET_GPIO0,      // GPIO0 register window。
        APB_TARGET_UART0,      // UART0 register window。
        APB_TARGET_TIMER0,     // TIMER0 register window。
        APB_TARGET_ERROR       // 未映射 APB address。
    } apb_target_e;

    apb_target_e active_target;   // 当前 PADDR 组合译码得到的 target。

    function automatic apb_target_e decode_target(input apb_addr_t addr);
        if ((addr >= GPIO0_BASE) && (addr < (GPIO0_BASE + GPIO0_SIZE_BYTES))) begin
            decode_target = APB_TARGET_GPIO0;
        end
        else if ((addr >= UART0_BASE) && (addr < (UART0_BASE + UART0_SIZE_BYTES))) begin
            decode_target = APB_TARGET_UART0;
        end
        else if ((addr >= TIMER0_BASE) && (addr < (TIMER0_BASE + TIMER0_SIZE_BYTES))) begin
            decode_target = APB_TARGET_TIMER0;
        end
        else begin
            decode_target = APB_TARGET_ERROR;
        end
    endfunction

    assign active_target = decode_target(upstream_req_i.paddr);

    // 只有 active target 保留 PSEL，其余 APB peripheral 始终处于未选中状态。
    assign gpio0_req_o  = (upstream_req_i.psel && (active_target == APB_TARGET_GPIO0))
                        ? upstream_req_i : APB_REQ_IDLE;
    assign uart0_req_o  = (upstream_req_i.psel && (active_target == APB_TARGET_UART0))
                        ? upstream_req_i : APB_REQ_IDLE;
    assign timer0_req_o = (upstream_req_i.psel && (active_target == APB_TARGET_TIMER0))
                        ? upstream_req_i : APB_REQ_IDLE;

    // APB response 组合返回；default target 在首个 ACCESS phase 以 PSLVERR 正常结束。
    always_comb begin : APB_RESPONSE_MUX
        upstream_resp_o = APB_RESP_IDLE;
        if (upstream_req_i.psel) begin
            case (active_target)
                APB_TARGET_GPIO0: begin
                    upstream_resp_o = gpio0_resp_i;
                end

                APB_TARGET_UART0: begin
                    upstream_resp_o = uart0_resp_i;
                end

                APB_TARGET_TIMER0: begin
                    upstream_resp_o = timer0_resp_i;
                end

                default: begin
                    upstream_resp_o.pready  = 1'b1;
                    upstream_resp_o.prdata  = '0;
                    upstream_resp_o.pslverr = upstream_req_i.penable;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
