//------------------------------------------------------------------------------
// 文件      : rtl/bus/bridge/axi_lite_to_apb.sv
// 用途      : 将单笔 AXI4-Lite transaction 转换为一笔 APB4 peripheral transaction。
//
// 规范：
//   - 面向上游作为 AXI4-Lite slave，面向下游作为 APB4 master。
//   - write address 与 write data 独立握手，二者均完成后才能启动 APB write。
//   - 每笔 APB transaction 严格经过 SETUP 和 ACCESS，PREADY 为 0 时保持 request 稳定。
//   - APB completion 最多产生一次 AXI B/R response，response 在上游接受前保持稳定。
//   - 全局只保存一笔 read 或 write，异常同拍出现两类请求时固定选择 write。
//
// 功能：
//   - AXI AW/W payload 映射为 APB PADDR/PWDATA/PSTRB/PPROT/PWRITE。
//   - AXI AR payload 映射为 APB PADDR/PPROT，并发起 APB read。
//   - APB PRDATA 返回 AXI RDATA，PSLVERR 映射为 AXI SLVERR。
//   - 支持 AXI 五通道和 APB PREADY 的独立 backpressure。
//------------------------------------------------------------------------------

`default_nettype none

module axi_lite_to_apb (
    input  logic                              clk_i,
    input  logic                              rst_n_i,

    input  axi_lite_pkg::axi_lite_req_t       axi_req_i,    // 上游 AXI-Lite master request。
    output axi_lite_pkg::axi_lite_resp_t      axi_resp_o,   // bridge 返回的 AXI-Lite response。

    output apb_pkg::apb_req_t                 apb_req_o,    // 下游 APB4 peripheral request。
    input  apb_pkg::apb_resp_t                apb_resp_i    // 下游 APB4 peripheral response。
);
    import axi_lite_pkg::*;
    import apb_pkg::*;

    typedef enum logic [2:0] {
        BRIDGE_IDLE,          // 无 outstanding transaction，可以接受一笔 AXI read 或 write request。
        BRIDGE_WRITE_REQ,     // 等待 AW/W 中尚未完成的 AXI request channel。
        BRIDGE_APB_SETUP,     // APB SETUP phase，PSEL=1、PENABLE=0。
        BRIDGE_APB_ACCESS,    // APB ACCESS phase，等待 PREADY completion。
        BRIDGE_WRITE_RESP,    // APB write 已完成，保持 BVALID 等待 B handshake。
        BRIDGE_READ_RESP      // APB read 已完成，保持 RVALID 等待 R handshake。
    } bridge_state_e;

    bridge_state_e                  state_q;         // 当前 bridge transaction 状态。
    reg                             aw_done_q;       // 当前 write 的 AW handshake 已完成。
    reg                             w_done_q;        // 当前 write 的 W handshake 已完成。

    reg [APB_ADDR_WIDTH-1:0]        apb_addr_q;      // APB transaction byte address。
    reg [APB_DATA_WIDTH-1:0]        apb_wdata_q;     // APB write data。
    reg [APB_STRB_WIDTH-1:0]        apb_strb_q;      // APB write byte strobe。
    reg [APB_PROT_WIDTH-1:0]        apb_prot_q;      // APB protection attribute。
    reg                             apb_write_q;     // 当前 APB transaction 方向。

    reg [AXI_LITE_DATA_WIDTH-1:0]   r_data_q;        // 注册式 AXI read response data。
    axi_lite_resp_e                 b_resp_q;        // 注册式 AXI write response 状态。
    axi_lite_resp_e                 r_resp_q;        // 注册式 AXI read response 状态。

    wire idle_write_select;                          // IDLE 同拍 read/write 竞争时固定选择 write。
    wire axi_aw_accept;                              // AWVALID && AWREADY。
    wire axi_w_accept;                               // WVALID && WREADY。
    wire axi_b_accept;                               // BVALID && BREADY。
    wire axi_ar_accept;                              // ARVALID && ARREADY。
    wire axi_r_accept;                               // RVALID && RREADY。
    wire write_req_complete;                         // AW/W 均已完成，可以启动 APB write。
    wire apb_access_complete;                        // PSEL && PENABLE && PREADY。

    assign idle_write_select = (state_q == BRIDGE_IDLE) &&
                               (axi_req_i.aw_valid || axi_req_i.w_valid);

    assign axi_aw_accept = axi_req_i.aw_valid && axi_resp_o.aw_ready;
    assign axi_w_accept  = axi_req_i.w_valid  && axi_resp_o.w_ready;
    assign axi_b_accept  = axi_resp_o.b_valid && axi_req_i.b_ready;

    assign axi_ar_accept = axi_req_i.ar_valid && axi_resp_o.ar_ready;
    assign axi_r_accept  = axi_resp_o.r_valid && axi_req_i.r_ready;

    // 包含本拍 handshake，AW/W 同拍或分拍到达时都能及时进入 APB SETUP。
    assign write_req_complete = (aw_done_q || axi_aw_accept) && (w_done_q  || axi_w_accept);
    assign apb_access_complete = apb_req_o.psel &&
                                 apb_req_o.penable &&
                                 apb_resp_i.pready;

    always_ff @(posedge clk_i or negedge rst_n_i) begin : BRIDGE_TRANSACTION
        if (!rst_n_i) begin
            state_q      <= BRIDGE_IDLE;
            aw_done_q    <= 1'b0;
            w_done_q     <= 1'b0;
            apb_addr_q   <= '0;
            apb_wdata_q  <= '0;
            apb_strb_q   <= '0;
            apb_prot_q   <= '0;
            apb_write_q  <= 1'b0;
            r_data_q     <= '0;
            b_resp_q     <= AXI_RESP_OKAY;
            r_resp_q     <= AXI_RESP_OKAY;
        end
        else begin
            case (state_q)
                BRIDGE_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                    if (idle_write_select) begin
                        apb_write_q <= 1'b1;
                        if (axi_aw_accept) begin
                            apb_addr_q <= axi_req_i.aw.addr;
                            apb_prot_q <= axi_req_i.aw.prot;
                            aw_done_q  <= 1'b1;
                        end
                        if (axi_w_accept) begin
                            apb_wdata_q <= axi_req_i.w.data;
                            apb_strb_q  <= axi_req_i.w.strb;
                            w_done_q    <= 1'b1;
                        end
                        if (write_req_complete) begin
                            state_q <= BRIDGE_APB_SETUP;
                        end
                        else begin
                            state_q <= BRIDGE_WRITE_REQ;
                        end
                    end
                    else if (axi_ar_accept) begin
                        apb_addr_q  <= axi_req_i.ar.addr;
                        apb_wdata_q <= '0;
                        apb_strb_q  <= '0;
                        apb_prot_q  <= axi_req_i.ar.prot;
                        apb_write_q <= 1'b0;
                        state_q     <= BRIDGE_APB_SETUP;
                    end
                end

                BRIDGE_WRITE_REQ: begin
                    if (axi_aw_accept) begin
                        apb_addr_q <= axi_req_i.aw.addr;
                        apb_prot_q <= axi_req_i.aw.prot;
                        aw_done_q  <= 1'b1;
                    end
                    if (axi_w_accept) begin
                        apb_wdata_q <= axi_req_i.w.data;
                        apb_strb_q  <= axi_req_i.w.strb;
                        w_done_q    <= 1'b1;
                    end
                    if (write_req_complete) begin
                        state_q <= BRIDGE_APB_SETUP;
                    end
                end

                // SETUP 拉高 PSEL，slave 可完成地址译码并准备访问；本阶段不能结束 transaction。
                BRIDGE_APB_SETUP: begin
                    state_q <= BRIDGE_APB_ACCESS;
                end

                // ACCESS 由 PREADY 表示 completion；read 数据和 PSLVERR 也在 completion 当拍采样。
                BRIDGE_APB_ACCESS: begin
                    if (apb_access_complete) begin
                        if (apb_write_q) begin
                            b_resp_q <= apb_resp_i.pslverr ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
                            state_q  <= BRIDGE_WRITE_RESP;
                        end
                        else begin
                            r_data_q <= apb_resp_i.prdata;
                            r_resp_q <= apb_resp_i.pslverr ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
                            state_q  <= BRIDGE_READ_RESP;
                        end
                    end
                end

                BRIDGE_WRITE_RESP: begin
                    if (axi_b_accept) begin
                        state_q   <= BRIDGE_IDLE;
                        aw_done_q <= 1'b0;
                        w_done_q  <= 1'b0;
                    end
                end

                BRIDGE_READ_RESP: begin
                    if (axi_r_accept) begin
                        state_q <= BRIDGE_IDLE;
                    end
                end

                default: begin
                    state_q   <= BRIDGE_IDLE;
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                end
            endcase
        end
    end

    // AXI-Lite slave 汇总响应。未完成 response 前不再接受下一笔 transaction。
    assign axi_resp_o.aw_ready = rst_n_i &&
                                 (idle_write_select || ((state_q == BRIDGE_WRITE_REQ) && !aw_done_q));
    assign axi_resp_o.w_ready  = rst_n_i &&
                                 (idle_write_select || ((state_q == BRIDGE_WRITE_REQ) && !w_done_q));

    assign axi_resp_o.b_valid  = (state_q == BRIDGE_WRITE_RESP);
    assign axi_resp_o.b.resp   = b_resp_q;

    assign axi_resp_o.ar_ready = rst_n_i &&
                                 (state_q == BRIDGE_IDLE) && !idle_write_select;

    assign axi_resp_o.r_valid  = (state_q == BRIDGE_READ_RESP);
    assign axi_resp_o.r.data   = r_data_q;
    assign axi_resp_o.r.resp   = r_resp_q;

    // APB request payload 在 SETUP/ACCESS 期间来自同一组寄存器，wait-state 中保持稳定。
    assign apb_req_o.psel    = rst_n_i &&
                               ((state_q == BRIDGE_APB_SETUP) || (state_q == BRIDGE_APB_ACCESS));
    assign apb_req_o.penable = rst_n_i && (state_q == BRIDGE_APB_ACCESS);
    assign apb_req_o.pwrite  = apb_write_q;
    assign apb_req_o.paddr   = apb_addr_q;
    assign apb_req_o.pwdata  = apb_wdata_q;
    assign apb_req_o.pstrb   = apb_strb_q;
    assign apb_req_o.pprot   = apb_prot_q;

endmodule

`default_nettype wire
