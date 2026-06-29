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
//   - 当前是教学用简化 UART 模型，TX/RX 都按单拍事件处理，不做真实串口采样。
//   - 真正 TX event：CTRL.tx_enable=1 时，对 TXDATA 发起有效 store，且 be_i[0]=1。
//   - TX event 在时钟沿后表现为 tx_valid_o 拉高一拍，tx_data_o 为 TXDATA[7:0]。
//   - RX event：rx_valid_i 拉高一拍时锁存 rx_data_i，置 rx_valid 和 rx_irq_pending。
//   - rx_valid_i/rx_data_i 约定已经在 clk_i 域，不在本模块内做跨时钟同步。
//   - STATUS（offset 0x04）提供 tx_ready/rx_valid/irq_pending 只读视图。
//   - CTRL（offset 0x08）是 RW 寄存器，bit0 为 tx_enable，bit1 为 rx_irq_enable。
//   - RXDATA（offset 0x0C）读出最近 RX byte；读 RXDATA 会清 rx_valid 和 rx_irq_pending。
//   - IRQ_PENDING（offset 0x10）是 R/W1C 寄存器；读本寄存器只观察 pending，写 1 清 pending。
//   - uart_irq_o = CTRL.rx_irq_enable && IRQ_PENDING[0]，是 level 信号。
//   - 当前只对未知 offset 输出 access_fault_o；读 TXDATA 返回 0，不触发异常。
//------------------------------------------------------------------------------

`default_nettype none

module mmio_uart #(
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = soc_pkg::UART0_BASE
)(
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      valid_i,         // 地址已命中 UART 窗口。
    input  logic                      re_i,            // 本拍确实是一个 load 指令。实际上 valid_i 已经确保是仿存指令，此处为通用加双重保险。
    input  logic                      we_i,            // 本拍是对 UART 的 store。
    input  logic [3:0]                be_i,            // byte enable，bit0 对应 wdata_i[7:0]。
    input  logic [core_pkg::XLEN-1:0] addr_i,          // 完整 byte address，内部用 addr_i - BASE_ADDR 得到 offset。
    input  logic [core_pkg::XLEN-1:0] wdata_i,         // store 写数据。
    output logic [core_pkg::XLEN-1:0] rdata_o,         // 读返回数据。
    output logic                      access_fault_o,  // 当前未知 offset 时拉高；后续也可用于权限/访问类型错误。

    // TX
    output logic                      tx_valid_o,      // 写 TXDATA 时输出一拍有效。
    output logic [7:0]                tx_data_o,       // TXDATA 低 8 bit 字符，tx_valid_o == 0 时无实意。
    // RX，当前简化模型为同步信号
    input  logic                      rx_valid_i,
    input  logic [7:0]                rx_data_i,

    output logic                      uart_irq_o       // RX 到 1 byte 数据，产生中断
);

    import core_pkg::*;
    import soc_pkg::*;

    // 直接设为 12 位宽，方便与 soc 包中的 OFFSET 比较
    // valid_i 保证地址已命中本外设窗口；本模块只检查窗口内 offset 是否为已定义寄存器。
    wire [core_pkg::XLEN-1:0] full_offset = addr_i - BASE_ADDR;
    wire [11:0]               offset      = full_offset[11:0];

    // 内部寄存器声明，保持 XLEN 位宽；RW/RO/WO 按属性分组，便于后续扩展。
    // RW 属性寄存器
    localparam RW_N = 1;
    reg  [core_pkg::XLEN-1:0] uart_rw[RW_N];
    localparam CTRL_IDX = 0;
    // RO 属性寄存器
    localparam RO_N = 2;
    wire [core_pkg::XLEN-1:0] uart_ro[RO_N];
    localparam STATUS_IDX  = 0;
    localparam RXDATA_IDX  = 1;
    // WO 属性寄存器
    localparam WO_N = 1;
    reg  [core_pkg::XLEN-1:0] uart_wo[WO_N];
    localparam TXDATA_IDX  = 0;
    // RW1C 属性寄存器，可读，写 1 清除，写 0 保持
    localparam RW1C_N = 1;
    reg  [core_pkg::XLEN-1:0] uart_rw1c[RW1C_N];
    localparam IRQ_PENDING_IDX  = 0;        // ***读 RXDATA 会将该寄存器 bit 0 清 0***

    // 输出端口与状态寄存器的控制关系
    // TX event 条件：tx_enable=1，写 TXDATA，且 byte0 真正被写入。
    always_ff @(posedge clk_i or negedge rst_n_i) begin : UART_TX_EVENT
        if (!rst_n_i) begin
            tx_valid_o <= 1'b0;
        end
        else begin
            tx_valid_o <= uart_rw[CTRL_IDX][UART_CTRL_TX_EN_BIT] & valid_i & we_i & wo_hit & wo_idx == TXDATA_IDX & be_i[0];
        end
    end
    assign tx_data_o = uart_wo[TXDATA_IDX][7:0];


    // 目前 access_fault_o 仅检测未知 offset，写只读等情况不触发，后续可以用 | 扩展
    assign access_fault_o = offset_illegal;

    // 读端口与 offset 非法检测
    logic offset_illegal;
    always_comb begin : UART_READ
        rdata_o        = '0;
        offset_illegal = 1'b0;
        if (valid_i) begin
            unique case (offset)
                UART_TXDATA_OFFSET: ;
                UART_STATUS_OFFSET      : rdata_o = uart_ro[STATUS_IDX];
                UART_CTRL_OFFSET        : rdata_o = uart_rw[CTRL_IDX];
                UART_RXDATA_OFFSET      : rdata_o = uart_ro[RXDATA_IDX];
                UART_IRQ_PENDING_OFFSET : rdata_o = uart_rw1c[IRQ_PENDING_IDX];
                default: offset_illegal = 1'b1;
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
    // RW1C 寄存器 IDX 译码
    logic rw1c_hit;
    logic rw1c_idx;     // 后续多于 2 个寄存器时应使用 [$clog2(RW1C_N)-1:0]
    always_comb begin : UART_RW1C_IDX_DECODE
        rw1c_idx = '0;
        rw1c_hit = 1'b1;
        unique case (offset)
            UART_IRQ_PENDING_OFFSET : rw1c_idx = IRQ_PENDING_IDX;
            default: rw1c_hit = 1'b0;
        endcase
    end

    // 非可写寄存器硬件自动更新：STATUS 当前保持 ready，并反映 RX 保存状态。
    reg rx_data_valid;  // RXDATA 中有尚未被读走的 byte；读 RXDATA 时清零。
    assign uart_ro[STATUS_IDX] = ({31'b0, 1'b1}                                             << UART_STATUS_TX_READY_BIT) |
                                 ({31'b0, rx_data_valid}                                    << UART_STATUS_RX_VALID_BIT) |
                                 ({31'b0, uart_rw1c[IRQ_PENDING_IDX][UART_IRQ_PENDING_BIT]} << UART_STATUS_IRQ_PENDING_BIT);
    reg [7:0] rx_data;  // RXDATA 保存最近一次收到的 byte；新 RX event 会覆盖旧值。
    assign uart_ro[RXDATA_IDX] = {{(core_pkg::XLEN-8){1'b0}},rx_data};        // 使用软件可见 wire + 内部 reg 实现只读 reg

    // 写端口 与 可写寄存器硬件、写合并更新。
    always_ff @(posedge clk_i or negedge rst_n_i) begin : UART_WRITE
        if (!rst_n_i) begin
            for (int i = 0; i < RW_N; i++) begin
                uart_rw[i] <= '0;
            end
            for (int i = 0; i < WO_N; i++) begin
                uart_wo[i] <= '0;
            end
            for (int i = 0; i < RW1C_N; i++) begin
                uart_rw1c[i] <= '0;
            end
            uart_rw[CTRL_IDX][UART_CTRL_TX_EN_BIT] <= 1'b0;   // tx_enable 复位为 0，若使用 TX 需要软件提前开启。
            rx_data_valid <= 1'b0;
            rx_data <= '0;
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
            else if (valid_i && we_i && rw1c_hit) begin
                if (be_i[0]) begin
                    uart_rw1c[rw1c_idx][7:0]   <= ~wdata_i[7:0] & uart_rw1c[rw1c_idx][7:0];
                end
                if (be_i[1]) begin
                    uart_rw1c[rw1c_idx][15:8]  <= ~wdata_i[15:8] & uart_rw1c[rw1c_idx][15:8];
                end
                if (be_i[2]) begin
                    uart_rw1c[rw1c_idx][23:16] <= ~wdata_i[23:16] & uart_rw1c[rw1c_idx][23:16];
                end
                if (be_i[3]) begin
                    uart_rw1c[rw1c_idx][31:24] <= ~wdata_i[31:24] & uart_rw1c[rw1c_idx][31:24];
                end
            end
            // else if (alid_i && we_i) begin
            //     // 后续可拓展”写只读“、“写未定义”触发异常，当前不实现
            // end

            //------------------------------------------------------------------
            // 硬件自动更新
            //------------------------------------------------------------------
            // 读 RXDATA 清 rx_data_valid 和 irq_pending；若同拍有 RX event，下面的 set 优先。
            if (valid_i && re_i && offset == UART_RXDATA_OFFSET) begin
                rx_data_valid <= 1'b0;
                uart_rw1c[IRQ_PENDING_IDX][UART_IRQ_PENDING_BIT] <= 1'b0;
            end
            // RX event 保存数据并置 pending；旧 RXDATA 未读时允许被覆盖。
            if (rx_valid_i) begin
                rx_data_valid <= 1'b1;
                rx_data <= rx_data_i;   // 旧值未读将被覆盖
                uart_rw1c[IRQ_PENDING_IDX][UART_IRQ_PENDING_BIT] <= 1'b1;
            end

        end
    end

    // 中断输出
    assign uart_irq_o = uart_rw[CTRL_IDX][UART_CTRL_RX_IRQ_EN_BIT] & uart_ro[STATUS_IDX][UART_STATUS_IRQ_PENDING_BIT];


endmodule

`default_nettype wire
