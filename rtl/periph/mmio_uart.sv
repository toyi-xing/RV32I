//------------------------------------------------------------------------------
// 文件      : rtl/periph/mmio_uart.sv
// 用途      : UART0 最小固定响应 MMIO 寄存器块。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 当前是固定响应 MMIO register block，没有 ready/valid backpressure。
//   - valid_i 表示地址已经命中该外设窗口。
//   - access_fault_o 只表示外设窗口内 offset 不存在，不负责判断整个地址是否命中外设。真正未映射地址由 data_subsystem 汇总判断。
//
// 功能：
//   - 当前只实现发送方向，后续可在同一模块内扩展 RX 与中断相关寄存器。
//   - 真正 TX event：CTRL.enable=1 时，对 TXDATA 发起有效 store，且 be_i[0]=1。
//   - TX event 在时钟沿后表现为 tx_valid_o 拉高一拍，tx_data_o 为 TXDATA[7:0]。
//   - STATUS（offset 0x04）的 tx_ready 固定为 1。
//   - CTRL（offset 0x08）是 RW 寄存器，bit0 enable，复位后为 0，若使用需要软件提前开启。
//   - 当前只对未知 offset 输出 access_fault_o；读 TXDATA 返回 0，不触发异常。
//------------------------------------------------------------------------------

`default_nettype none

module mmio_uart #(
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = core_pkg::UART0_BASE
)(
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      valid_i,         // 地址已命中 UART 窗口。
    input  logic                      we_i,            // 本拍是对 UART 的 store。
    input  logic [3:0]                be_i,            // byte enable，bit0 对应 wdata_i[7:0]。
    input  logic [core_pkg::XLEN-1:0] addr_i,          // 完整 byte address，内部用 addr_i - BASE_ADDR 得到 offset。
    input  logic [core_pkg::XLEN-1:0] wdata_i,         // store 写数据。
    output logic [core_pkg::XLEN-1:0] rdata_o,         // 读返回数据。
    output logic                      access_fault_o,  // 当前未知 offset 时拉高；后续也可用于权限/访问类型错误。

    output logic                      tx_valid_o,      // 写 TXDATA 时输出一拍有效。
    output logic [7:0]                tx_data_o        // TXDATA 低 8 bit 字符，tx_valid_o == 0 时无实意。
);

    import core_pkg::*;

    wire [core_pkg::XLEN-1:0] offset = addr_i - BASE_ADDR;

    // 内部寄存器声明，保持 XLEN 位宽；RW/RO/WO 按属性分组，便于后续扩展。
    // RW 属性寄存器
    localparam RW_N = 1;
    reg  [core_pkg::XLEN-1:0] uart_rw[RW_N];
    localparam CTRL_IDX = 0;
    // RO 属性寄存器
    localparam RO_N = 1;
    wire [core_pkg::XLEN-1:0] uart_ro[RO_N];
    localparam STATUS_IDX  = 0;
    // WO 属性寄存器
    localparam WO_N = 1;
    reg  [core_pkg::XLEN-1:0] uart_wo[WO_N];
    localparam TXDATA_IDX  = 0;

    assign uart_ro[STATUS_IDX] = 32'h1;       // 当前 bit0 固定为 1，表示 ready

    // 输入输出端口与状态寄存器的控制关系
    // TX event 条件：enable=1，写 TXDATA，且 byte0 真正被写入。
    always_ff @(posedge clk_i or negedge rst_n_i) begin : UART_TX_EVENT
        if (!rst_n_i) begin
            tx_valid_o <= 1'b0;
        end
        else begin
            tx_valid_o <= uart_rw[CTRL_IDX][0] & valid_i & we_i & be_i[0] & (offset == UART_TXDATA_OFFSET);
        end
    end
    assign tx_data_o = uart_wo[TXDATA_IDX][7:0];


    // 目前 access_fault_o 仅检测未知 offset ，写只读等情况不触发，后续可以用 | 扩展
    assign access_fault_o = offset_illegal;

    // 读端口与 offset 非法检测
    logic offset_illegal;
    always_comb begin : UART_READ
        rdata_o        = '0;
        offset_illegal = 1'b0;
        if (valid_i) begin
            unique case (offset)
                UART_TXDATA_OFFSET: ;
                UART_STATUS_OFFSET: rdata_o = uart_ro[STATUS_IDX];
                UART_CTRL_OFFSET  : rdata_o = uart_rw[CTRL_IDX];
                default: offset_illegal  = 1'b1;
            endcase
        end
    end

    // 写寄存器译码
    // RW 寄存器 IDX 译码
    logic rw_hit;
    logic rw_idx;        // 后续多于 2 个寄存器时应使用 [$clog2(RW_N)-1:0]
    always_comb begin : UART_RW_IDX_DECODE
        rw_idx = '0;
        rw_hit = 1'b1;
        unique case (offset)
            UART_CTRL_OFFSET: rw_idx = CTRL_IDX;
            default: rw_hit = 1'b0;
        endcase
    end
    // WO 寄存器 IDX 译码
    logic wo_hit;
    logic wo_idx;        // 后续多于 2 个寄存器时应使用 [$clog2(WO_N)-1:0]
    always_comb begin : UART_WO_IDX_DECODE
        wo_idx = '0;
        wo_hit = 1'b1;
        unique case (offset)
            UART_TXDATA_OFFSET: wo_idx = TXDATA_IDX;
            default: wo_hit = 1'b0;
        endcase
    end
    // 写端口
    always_ff @(posedge clk_i or negedge rst_n_i) begin : UART_WRITE
        if (!rst_n_i) begin
            for (int i = 0; i < RW_N; i++) begin
                uart_rw[i] <= '0;
            end
            for (int i = 0; i < WO_N; i++) begin
                uart_wo[i] <= '0;
            end
            uart_rw[CTRL_IDX][0] <= 1'b0;   // uart_enable，复位为 0，若使用需要软件提前开启
        end
        else begin
            if (valid_i && we_i && rw_hit) begin
                if (be_i[0]) begin
                    uart_rw[rw_idx][7:0]   <= wdata_i[7:0];
                end
                if (be_i[1]) begin
                    uart_rw[rw_idx][15:8]  <= wdata_i[15:8];
                end
                if (be_i[2]) begin
                    uart_rw[rw_idx][23:16] <= wdata_i[23:16];
                end
                if (be_i[3]) begin
                    uart_rw[rw_idx][31:24] <= wdata_i[31:24];
                end
            end
            else if (valid_i && we_i && wo_hit) begin
                if (be_i[0]) begin
                    uart_wo[wo_idx][7:0]   <= wdata_i[7:0];
                end
                if (be_i[1]) begin
                    uart_wo[wo_idx][15:8]  <= wdata_i[15:8];
                end
                if (be_i[2]) begin
                    uart_wo[wo_idx][23:16] <= wdata_i[23:16];
                end
                if (be_i[3]) begin
                    uart_wo[wo_idx][31:24] <= wdata_i[31:24];
                end
            end
            // else if (alid_i && we_i) begin
            //     // 后续可拓展”写只读“、“写未定义”触发异常，当前不实现
            // end
        end
    end


endmodule

`default_nettype wire
