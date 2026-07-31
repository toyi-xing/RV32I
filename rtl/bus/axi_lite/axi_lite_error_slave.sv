//------------------------------------------------------------------------------
// 文件      : rtl/bus/axi_lite/axi_lite_error_slave.sv
// 用途      : 为未映射或尚未实现的 AXI4-Lite target 返回标准 DECERR response。
//
// 规范：
//   - 上游使用 axi_lite_pkg 聚合的 AW/W/B/AR/R 五通道接口。
//   - write address 与 write data 独立握手，二者均完成后才能产生 B response。
//   - read address 完成握手后产生 R response，read data 固定返回 0。
//   - B/R response 在上游接受前保持有效且 payload 稳定。
//   - 全局只保存一笔 read 或 write，符合本项目 single-outstanding 边界。
//
// 功能：
//   - 终止 router 未命中地址和尚未实现的预留 target 访问，避免 transaction hang。
//   - read/write 均返回 DECERR，不执行 memory、MMIO 或其它软件可见副作用。
//   - 异常同拍出现 read/write request 时固定选择 write，正常 CPU adapter 不会产生该场景。
//------------------------------------------------------------------------------

`default_nettype none

module axi_lite_error_slave (
    input  logic                              clk_i,
    input  logic                              rst_n_i,

    input  axi_lite_pkg::axi_lite_req_t       axi_req_i,   // 上游 AXI-Lite master request。
    output axi_lite_pkg::axi_lite_resp_t      axi_resp_o   // 本模块返回的 DECERR response。
);
    import axi_lite_pkg::*;

    typedef enum logic [1:0] {
        ERROR_IDLE,          // 无 outstanding transaction，可以接受一笔 read 或 write request。
        ERROR_WRITE_REQ,     // 等待 AW/W 中尚未完成的 request channel。
        ERROR_WRITE_RESP,    // AW/W 均已完成，保持 BVALID 等待 B handshake。
        ERROR_READ_RESP      // AR 已完成，保持 RVALID 等待 R handshake。
    } error_state_e;

    error_state_e state_q;       // 当前 error slave transaction 状态。
    reg           aw_done_q;     // 当前 write 的 AW handshake 已完成。
    reg           w_done_q;      // 当前 write 的 W handshake 已完成。

    wire idle_write_select;      // IDLE 同拍 read/write 竞争时固定选择 write。
    wire axi_aw_accept;          // AWVALID && AWREADY。
    wire axi_w_accept;           // WVALID && WREADY。
    wire axi_b_accept;           // BVALID && BREADY。
    wire axi_ar_accept;          // ARVALID && ARREADY。
    wire axi_r_accept;           // RVALID && RREADY。
    wire write_req_complete;     // AW/W 均已完成，可以生成 B response。

    assign idle_write_select = (state_q == ERROR_IDLE) && (axi_req_i.aw_valid || axi_req_i.w_valid);

    assign axi_aw_accept = axi_req_i.aw_valid && axi_resp_o.aw_ready;
    assign axi_w_accept  = axi_req_i.w_valid  && axi_resp_o.w_ready;
    assign axi_b_accept  = axi_resp_o.b_valid && axi_req_i.b_ready;

    assign axi_ar_accept = axi_req_i.ar_valid && axi_resp_o.ar_ready;
    assign axi_r_accept  = axi_resp_o.r_valid && axi_req_i.r_ready;

    // 包含本拍 handshake，避免 AW/W 同拍完成时额外停留一拍。
    assign write_req_complete = (aw_done_q || axi_aw_accept) &&
                                (w_done_q  || axi_w_accept);

    always_ff @(posedge clk_i or negedge rst_n_i) begin : ERROR_STATE
        if (!rst_n_i) begin
            state_q   <= ERROR_IDLE;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
        end
        else begin
            case (state_q)
                ERROR_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                    if (idle_write_select) begin
                        if (axi_aw_accept) begin
                            aw_done_q <= 1'b1;
                        end
                        if (axi_w_accept) begin
                            w_done_q <= 1'b1;
                        end
                        if (write_req_complete) begin
                            state_q <= ERROR_WRITE_RESP;
                        end
                        else begin
                            state_q <= ERROR_WRITE_REQ;
                        end
                    end
                    else if (axi_ar_accept) begin
                        state_q <= ERROR_READ_RESP;
                    end
                end

                ERROR_WRITE_REQ: begin
                    if (axi_aw_accept) begin
                        aw_done_q <= 1'b1;
                    end
                    if (axi_w_accept) begin
                        w_done_q <= 1'b1;
                    end
                    if (write_req_complete) begin
                        state_q <= ERROR_WRITE_RESP;
                    end
                end

                ERROR_WRITE_RESP: begin
                    if (axi_b_accept) begin
                        state_q   <= ERROR_IDLE;
                        aw_done_q <= 1'b0;
                        w_done_q  <= 1'b0;
                    end
                end

                ERROR_READ_RESP: begin
                    if (axi_r_accept) begin
                        state_q <= ERROR_IDLE;
                    end
                end

                default: begin
                    state_q   <= ERROR_IDLE;
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                end
            endcase
        end
    end

    // IDLE 时 write 优先；进入 WRITE_REQ 后只接受尚未完成的 channel。
    assign axi_resp_o.aw_ready = rst_n_i &&
                                 (idle_write_select || ((state_q == ERROR_WRITE_REQ) && !aw_done_q));
    assign axi_resp_o.w_ready  = rst_n_i &&
                                 (idle_write_select || ((state_q == ERROR_WRITE_REQ) && !w_done_q));

    assign axi_resp_o.b_valid  = (state_q == ERROR_WRITE_RESP);
    assign axi_resp_o.b.resp   = AXI_RESP_DECERR;

    assign axi_resp_o.ar_ready = rst_n_i &&
                                 (state_q == ERROR_IDLE) && !idle_write_select;

    assign axi_resp_o.r_valid  = (state_q == ERROR_READ_RESP);
    assign axi_resp_o.r.data   = '0;
    assign axi_resp_o.r.resp   = AXI_RESP_DECERR;

endmodule

`default_nettype wire
