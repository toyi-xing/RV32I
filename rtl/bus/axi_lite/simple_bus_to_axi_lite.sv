//------------------------------------------------------------------------------
// 文件      : rtl/bus/axi_lite/simple_bus_to_axi_lite.sv
// 用途      : 将 CPU data-side simple request/response 转换为 AXI4-Lite master transaction。
//
// 规范：
//   - 上游保持 data_bus_pkg 定义的 single-outstanding request/response 语义。
//   - 下游使用 axi_lite_pkg 聚合的 AW/W/B/AR/R 五通道接口。
//   - 接受 simple request 后锁存完整 payload，不再依赖上游继续保持输入。
//   - AXI channel valid 在握手前保持，AW 与 W 分别记录握手完成状态。
//
// 功能：
//   - read transaction 依次完成 AR handshake 和 R response。
//   - write transaction 独立完成 AW/W handshake，再等待 B response。
//   - AXI OKAY 映射为 simple response success，其他 response 映射为 error。
//   - 每笔 AXI completion 只产生一次 simple response，完成后才接受下一笔请求。
//------------------------------------------------------------------------------

`default_nettype none

module simple_bus_to_axi_lite (
    input  logic                              clk_i,
    input  logic                              rst_n_i,

    output logic                              simple_req_ready_o, // adapter 可以接受一笔新的 simple request。
    input  data_bus_pkg::data_req_t           simple_req_i,       // CPU data-side load/store request。
    output data_bus_pkg::data_resp_t          simple_resp_o,      // 当前 outstanding request 的完成结果。

    output axi_lite_pkg::axi_lite_req_t       axi_req_o,          // AXI-Lite master 发往下游 slave 的五通道信号。
    input  axi_lite_pkg::axi_lite_resp_t      axi_resp_i          // 下游 AXI-Lite slave 返回的握手与响应信号。
);
    import axi_lite_pkg::*;

    typedef enum logic [2:0] {
        ADAPTER_IDLE,          // 无 outstanding transaction，可以接受 simple request。
        ADAPTER_READ_ADDR,     // 保持 ARVALID，等待 AR handshake。
        ADAPTER_READ_RESP,     // AR 已被接受，等待 R response。
        ADAPTER_WRITE_REQ,     // 分别保持 AWVALID/WVALID，等待两个 request channel 完成。
        ADAPTER_WRITE_RESP     // AW/W 均已被接受，等待 B response。
    } adapter_state_e;

    // transaction 状态与 simple request payload 寄存器。
    adapter_state_e                  state_q;       // 当前 adapter transaction 状态。
    reg [AXI_LITE_ADDR_WIDTH-1:0]    req_addr_q;    // simple request 的 byte address 锁存值。
    reg [AXI_LITE_DATA_WIDTH-1:0]    req_wdata_q;   // simple request 的 write data 锁存值。
    reg [AXI_LITE_STRB_WIDTH-1:0]    req_strb_q;    // simple request 的 byte enable 锁存值。
    reg                              aw_done_q;     // 当前 write 的 AW handshake 已完成。
    reg                              w_done_q;      // 当前 write 的 W handshake 已完成。

    // 各层真实 handshake 事件。
    wire simple_req_accept;                      // 接受一笔新的 simple request。
    wire axi_aw_accept;                          // AWVALID && AWREADY。
    wire axi_w_accept;                           // WVALID && WREADY。
    wire axi_b_accept;                           // BVALID && BREADY。
    wire axi_ar_accept;                          // ARVALID && ARREADY。
    wire axi_r_accept;                           // RVALID && RREADY。
    wire write_req_complete;                     // AW/W 均已完成，下一状态可以等待 B response。

    assign simple_req_accept  = simple_req_i.valid && simple_req_ready_o;

    assign axi_aw_accept = axi_req_o.aw_valid && axi_resp_i.aw_ready;
    assign axi_w_accept  = axi_req_o.w_valid  && axi_resp_i.w_ready;
    assign axi_b_accept  = axi_resp_i.b_valid && axi_req_o.b_ready;

    assign axi_ar_accept = axi_req_o.ar_valid && axi_resp_i.ar_ready;
    assign axi_r_accept  = axi_resp_i.r_valid && axi_req_o.r_ready;

    // 包含本拍 handshake，避免 AW/W 同拍完成时额外停留一拍。
    assign write_req_complete = (aw_done_q || axi_aw_accept) && (w_done_q  || axi_w_accept);

    always_ff @(posedge clk_i or negedge rst_n_i) begin : ADAPTER_STATE
        if (!rst_n_i) begin
            state_q     <= ADAPTER_IDLE;
            req_addr_q  <= '0;
            req_wdata_q <= '0;
            req_strb_q  <= '0;
            aw_done_q   <= 1'b0;
            w_done_q    <= 1'b0;
        end
        else begin
            case (state_q)
                ADAPTER_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                    if (simple_req_accept) begin
                        req_addr_q  <= simple_req_i.addr;
                        req_wdata_q <= simple_req_i.wdata;
                        req_strb_q  <= simple_req_i.be;
                        if (simple_req_i.write) begin
                            state_q <= ADAPTER_WRITE_REQ;
                        end
                        else begin
                            state_q <= ADAPTER_READ_ADDR;
                        end
                    end
                end

                ADAPTER_READ_ADDR: begin
                    if (axi_ar_accept) begin
                        state_q <= ADAPTER_READ_RESP;
                    end
                end

                ADAPTER_READ_RESP: begin
                    if (axi_r_accept) begin
                        state_q <= ADAPTER_IDLE;
                    end
                end

                ADAPTER_WRITE_REQ: begin
                    if (axi_aw_accept) begin
                        aw_done_q <= 1'b1;
                    end
                    if (axi_w_accept) begin
                        w_done_q <= 1'b1;
                    end
                    if (write_req_complete) begin
                        state_q <= ADAPTER_WRITE_RESP;
                    end
                end

                ADAPTER_WRITE_RESP: begin
                    if (axi_b_accept) begin
                        state_q   <= ADAPTER_IDLE;
                        aw_done_q <= 1'b0;
                        w_done_q  <= 1'b0;
                    end
                end

                default: begin
                    state_q   <= ADAPTER_IDLE;
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                end
            endcase
        end
    end

    // AXI-Lite master channel 输出。地址和 payload 在整笔 transaction 完成前保持锁存值。
    assign axi_req_o.aw_valid = (state_q == ADAPTER_WRITE_REQ) && !aw_done_q;    // 状态机 + 独立完成状态，一个状态控制 aw 和 w
    assign axi_req_o.aw.addr  = req_addr_q;
    assign axi_req_o.aw.prot  = AXI_PROT_PRIVILEGED_DATA;   // 安全、特权的数据访问。

    assign axi_req_o.w_valid  = (state_q == ADAPTER_WRITE_REQ) && !w_done_q;
    assign axi_req_o.w.data   = req_wdata_q;
    assign axi_req_o.w.strb   = req_strb_q;

    assign axi_req_o.b_ready  = (state_q == ADAPTER_WRITE_RESP);

    assign axi_req_o.ar_valid = (state_q == ADAPTER_READ_ADDR);
    assign axi_req_o.ar.addr  = req_addr_q;
    assign axi_req_o.ar.prot  = AXI_PROT_PRIVILEGED_DATA;   // 安全、特权的数据访问。

    assign axi_req_o.r_ready  = (state_q == ADAPTER_READ_RESP);

    assign simple_req_ready_o = rst_n_i && (state_q == ADAPTER_IDLE);   // rst 时固定输出 0,异步重置

    // AXI response handshake 直接形成一次 simple response completion。
    assign simple_resp_o.valid = axi_b_accept || axi_r_accept;
    assign simple_resp_o.rdata = axi_r_accept ? axi_resp_i.r.data : '0;
    assign simple_resp_o.error = axi_b_accept ? (axi_resp_i.b.resp != AXI_RESP_OKAY) :
                                 axi_r_accept ? (axi_resp_i.r.resp != AXI_RESP_OKAY) :
                                                1'b0;

endmodule

`default_nettype wire
