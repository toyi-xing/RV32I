//------------------------------------------------------------------------------
// 文件      : rtl/mem/axi_lite_ram.sv
// 用途      : 为 RV32I 教学 SoC 提供可综合的 32-bit AXI4-Lite 数据 RAM slave。
//
// 规范：
//   - 上游使用 axi_lite_pkg 聚合的 AW/W/B/AR/R 五通道接口。
//   - write address 与 write data 独立握手，二者均完成后只提交一次写操作。
//   - 内部 memory 为 32-bit word array，BASE_ADDR 映射到 mem[0]。
//   - AXI byte address 低两位不参与 word 选择，实际写入 byte lane 由 WSTRB 决定。
//   - B/R response 使用注册输出，并在上游接受前保持 valid 和 payload 稳定。
//
// 功能：
//   - 合法 read 返回地址对应的完整 32-bit word，合法 write 按 WSTRB 更新 byte lane。
//   - 地址超出 RAM window 时返回 SLVERR，不访问非法数组索引。
//   - 全局只保存一笔 read 或 write，符合本项目 single-outstanding 边界。
//   - memory 初始化由 testbench 或 FPGA wrapper 负责，本模块不包含 plusarg、随机延迟或 mailbox。
//------------------------------------------------------------------------------

`default_nettype none

module axi_lite_ram #(
    parameter int unsigned                                     ADDR_WIDTH = core_pkg::DMEM_ADDR_WIDTH,
    parameter logic [axi_lite_pkg::AXI_LITE_ADDR_WIDTH-1:0]    BASE_ADDR  = core_pkg::DMEM_BASE
) (
    input  logic                              clk_i,
    input  logic                              rst_n_i,

    input  axi_lite_pkg::axi_lite_req_t       axi_req_i,   // 上游 AXI-Lite master request。
    output axi_lite_pkg::axi_lite_resp_t      axi_resp_o   // RAM 返回的 AXI-Lite response。
);
    import axi_lite_pkg::*;

    localparam int unsigned DEPTH = 1 << ADDR_WIDTH;
    localparam logic [AXI_LITE_ADDR_WIDTH-1:0] RAM_SIZE_BYTES = DEPTH * AXI_LITE_STRB_WIDTH;

    typedef enum logic [1:0] {
        RAM_IDLE,          // 无 outstanding transaction，可以接受一笔 read 或 write request。
        RAM_WRITE_REQ,     // 等待 AW/W 中尚未完成的 request channel。
        RAM_WRITE_RESP,    // 写操作已提交，保持 BVALID 等待 B handshake。
        RAM_READ_RESP      // 读数据已保存，保持 RVALID 等待 R handshake。
    } ram_state_e;

    ram_state_e                    state_q;          // 当前 RAM transaction 状态。
    reg [AXI_LITE_DATA_WIDTH-1:0]  mem [0:DEPTH-1]; // 32-bit word 存储数组，允许 testbench 层级加载。

    reg [AXI_LITE_ADDR_WIDTH-1:0]  aw_addr_q;        // 已独立接受的 AWADDR。
    reg [AXI_LITE_DATA_WIDTH-1:0]  w_data_q;         // 已独立接受的 WDATA。
    reg [AXI_LITE_STRB_WIDTH-1:0]  w_strb_q;         // 已独立接受的 WSTRB。
    reg                            aw_done_q;        // 当前 write 的 AW handshake 已完成。
    reg                            w_done_q;         // 当前 write 的 W handshake 已完成。

    reg [AXI_LITE_DATA_WIDTH-1:0]  r_data_q;         // 注册式 read response data。
    axi_lite_resp_e                b_resp_q;         // 注册式 write response 状态。
    axi_lite_resp_e                r_resp_q;         // 注册式 read response 状态。

    wire idle_write_select;                           // IDLE 同拍 read/write 竞争时固定选择 write。
    wire axi_aw_accept;                               // AWVALID && AWREADY。
    wire axi_w_accept;                                // WVALID && WREADY。
    wire axi_b_accept;                                // BVALID && BREADY。
    wire axi_ar_accept;                               // ARVALID && ARREADY。
    wire axi_r_accept;                                // RVALID && RREADY。
    wire write_req_complete;                          // AW/W 均已完成，可以提交一次写操作。

    wire [AXI_LITE_ADDR_WIDTH-1:0] write_addr;        // 当前完整 write transaction 的有效地址。
    wire [AXI_LITE_DATA_WIDTH-1:0] write_data;        // 当前完整 write transaction 的有效数据。
    wire [AXI_LITE_STRB_WIDTH-1:0] write_strb;        // 当前完整 write transaction 的有效 byte strobe。
    wire [ADDR_WIDTH-1:0]          write_word_addr;   // write byte address 对应的内部 word index。
    wire [ADDR_WIDTH-1:0]          read_word_addr;    // ARADDR 对应的内部 word index。
    wire                           write_addr_valid;  // write address 位于本 RAM window。
    wire                           read_addr_valid;   // read address 位于本 RAM window。

    assign idle_write_select = (state_q == RAM_IDLE) && (axi_req_i.aw_valid || axi_req_i.w_valid);

    assign axi_aw_accept = axi_req_i.aw_valid && axi_resp_o.aw_ready;
    assign axi_w_accept  = axi_req_i.w_valid  && axi_resp_o.w_ready;
    assign axi_b_accept  = axi_resp_o.b_valid && axi_req_i.b_ready;

    assign axi_ar_accept = axi_req_i.ar_valid && axi_resp_o.ar_ready;
    assign axi_r_accept  = axi_resp_o.r_valid && axi_req_i.r_ready;

    // 包含本拍 handshake，AW/W 同拍或分拍到达时均只提交一次 write。
    assign write_req_complete = (aw_done_q || axi_aw_accept) &&
                                (w_done_q  || axi_w_accept);

    // 优先使用此前已经锁存的 channel payload，否则使用本拍完成 handshake 的输入。
    assign write_addr = aw_done_q ? aw_addr_q : axi_req_i.aw.addr;
    assign write_data = w_done_q  ? w_data_q  : axi_req_i.w.data;
    assign write_strb = w_done_q  ? w_strb_q  : axi_req_i.w.strb;

    assign write_addr_valid = (write_addr >= BASE_ADDR) &&
                              (write_addr < (BASE_ADDR + RAM_SIZE_BYTES));
    assign read_addr_valid  = (axi_req_i.ar.addr >= BASE_ADDR) &&
                              (axi_req_i.ar.addr < (BASE_ADDR + RAM_SIZE_BYTES));

    assign write_word_addr = ADDR_WIDTH'((write_addr - BASE_ADDR) >> 2);
    assign read_word_addr  = ADDR_WIDTH'((axi_req_i.ar.addr - BASE_ADDR) >> 2);

    // mem 允许由 testbench 层级加载，因此使用时序 always，避免 always_ff 单写者约束冲突。
    always @(posedge clk_i or negedge rst_n_i) begin : RAM_TRANSACTION
        if (!rst_n_i) begin
            state_q   <= RAM_IDLE;
            aw_addr_q <= '0;
            w_data_q  <= '0;
            w_strb_q  <= '0;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            r_data_q  <= '0;
            b_resp_q  <= AXI_RESP_OKAY;
            r_resp_q  <= AXI_RESP_OKAY;
        end
        else begin
            case (state_q)
                RAM_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                    if (idle_write_select) begin
                        if (axi_aw_accept) begin
                            aw_addr_q <= axi_req_i.aw.addr;
                            aw_done_q <= 1'b1;
                        end
                        if (axi_w_accept) begin
                            w_data_q  <= axi_req_i.w.data;
                            w_strb_q  <= axi_req_i.w.strb;
                            w_done_q  <= 1'b1;
                        end
                        if (write_req_complete) begin
                            if (write_addr_valid) begin
                                if (write_strb[0]) begin
                                    mem[write_word_addr][7:0] <= write_data[7:0];
                                end
                                if (write_strb[1]) begin
                                    mem[write_word_addr][15:8] <= write_data[15:8];
                                end
                                if (write_strb[2]) begin
                                    mem[write_word_addr][23:16] <= write_data[23:16];
                                end
                                if (write_strb[3]) begin
                                    mem[write_word_addr][31:24] <= write_data[31:24];
                                end
                                b_resp_q <= AXI_RESP_OKAY;
                            end
                            else begin
                                b_resp_q <= AXI_RESP_SLVERR;    // 选中 ram，但 ram 无法完成访问。
                            end
                            state_q <= RAM_WRITE_RESP;
                        end
                        else begin
                            state_q <= RAM_WRITE_REQ;
                        end
                    end
                    else if (axi_ar_accept) begin
                        if (read_addr_valid) begin
                            r_data_q <= mem[read_word_addr];
                            r_resp_q <= AXI_RESP_OKAY;
                        end
                        else begin
                            r_data_q <= '0;
                            r_resp_q <= AXI_RESP_SLVERR;
                        end
                        state_q <= RAM_READ_RESP;
                    end
                end

                // aw、w 未同时接收， idle 未写 ram，需要在本状态写
                RAM_WRITE_REQ: begin
                    if (axi_aw_accept) begin
                        aw_addr_q <= axi_req_i.aw.addr;
                        aw_done_q <= 1'b1;
                    end
                    if (axi_w_accept) begin
                        w_data_q <= axi_req_i.w.data;
                        w_strb_q <= axi_req_i.w.strb;
                        w_done_q <= 1'b1;
                    end
                    if (write_req_complete) begin
                        if (write_addr_valid) begin
                            if (write_strb[0]) begin
                                mem[write_word_addr][7:0] <= write_data[7:0];
                            end
                            if (write_strb[1]) begin
                                mem[write_word_addr][15:8] <= write_data[15:8];
                            end
                            if (write_strb[2]) begin
                                mem[write_word_addr][23:16] <= write_data[23:16];
                            end
                            if (write_strb[3]) begin
                                mem[write_word_addr][31:24] <= write_data[31:24];
                            end
                            b_resp_q <= AXI_RESP_OKAY;
                        end
                        else begin
                            b_resp_q <= AXI_RESP_SLVERR;
                        end
                        state_q <= RAM_WRITE_RESP;
                    end
                end

                RAM_WRITE_RESP: begin
                    if (axi_b_accept) begin
                        state_q   <= RAM_IDLE;
                        aw_done_q <= 1'b0;
                        w_done_q  <= 1'b0;
                    end
                end

                RAM_READ_RESP: begin
                    if (axi_r_accept) begin
                        state_q <= RAM_IDLE;
                    end
                end

                default: begin
                    state_q   <= RAM_IDLE;
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;
                end
            endcase
        end
    end

    // AXI-Lite slave 汇总响应。B/R payload 均来自寄存器，在 stalled response 期间保持稳定。
    assign axi_resp_o.aw_ready = rst_n_i &&
                                 (idle_write_select || ((state_q == RAM_WRITE_REQ) && !aw_done_q));
    assign axi_resp_o.w_ready  = rst_n_i &&
                                 (idle_write_select || ((state_q == RAM_WRITE_REQ) && !w_done_q));

    assign axi_resp_o.b_valid  = (state_q == RAM_WRITE_RESP);
    assign axi_resp_o.b.resp   = b_resp_q;

    assign axi_resp_o.ar_ready = rst_n_i &&
                                 (state_q == RAM_IDLE) && !idle_write_select;

    assign axi_resp_o.r_valid  = (state_q == RAM_READ_RESP);
    assign axi_resp_o.r.data   = r_data_q;
    assign axi_resp_o.r.resp   = r_resp_q;

endmodule

`default_nettype wire
