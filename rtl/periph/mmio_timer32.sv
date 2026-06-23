//------------------------------------------------------------------------------
// 文件      : rtl/periph/mmio_timer32.sv
// 用途      : 32-bit TIMER0 最小固定响应 MMIO 寄存器块。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 当前是固定响应 MMIO register block，没有 ready/valid backpressure。
//   - valid_i 表示地址已经命中该外设窗口。
//   - access_fault_o 表示地址已命中本外设窗口，但 offset 或访问类型不被接受。
//
// 功能：
//   - MTIME（offset 0x00）是 32-bit RW 计数器，使能时每个 clk 递增。
//   - MTIMECMP（offset 0x04）是 32-bit RW 比较值。
//   - CTRL（offset 0x08）是 RW 控制寄存器，CTRL[0]=enable。
//   - STATUS（offset 0x0C）是 RO 状态寄存器，STATUS[0]=timer32_irq_o。
//   - timer32_irq_o = CTRL.enable && (MTIME >= MTIMECMP)。
//   - 写 STATUS 忽略；未知 offset 输出 access_fault_o。
//   - 写 MTIME 时本拍不自增；写 MTIMECMP/CTRL 时，若旧 CTRL.enable=1，MTIME 仍会自增。
//------------------------------------------------------------------------------

`default_nettype none

module mmio_timer32 #(
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR = soc_pkg::TIMER0_BASE           // 起始地址分配
)(
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      valid_i,         // 地址已命中 TIMER0 窗口。
    input  logic                      we_i,            // 本拍是对 TIMER0 的 store。
    input  logic [3:0]                be_i,            // byte enable，bit0 对应 wdata_i[7:0]。
    input  logic [core_pkg::XLEN-1:0] addr_i,          // 完整 byte address，内部用 addr_i - BASE_ADDR 得到 offset。
    input  logic [core_pkg::XLEN-1:0] wdata_i,         // store 写数据。
    output logic [core_pkg::XLEN-1:0] rdata_o,         // 读返回数据。
    output logic                      access_fault_o,  // offset 不存在时拉高。

    output logic                      timer32_irq_o    // timer interrupt pending（level）。
);

    import core_pkg::*;
    import soc_pkg::*;

    // 直接设为 12 位宽，方便与 soc 包中的 OFFSET 比较
    // valid_i 保证地址已命中本外设窗口；本模块只检查窗口内 offset 是否为已定义寄存器。
    wire [core_pkg::XLEN-1:0] full_offset = addr_i - BASE_ADDR;
    wire [11:0]               offset      = full_offset[11:0];

    // 内部寄存器声明，保持 XLEN 位宽；RW/RO 按属性分组。
    // RW 属性寄存器
    localparam RW_N = 3;
    reg  [core_pkg::XLEN-1:0] timer32_rw[RW_N];
    localparam MTIME_IDX    = 0;
    localparam MTIMECMP_IDX = 1;
    localparam CTRL_IDX     = 2;
    // RO 属性寄存器
    localparam RO_N = 1;
    wire [core_pkg::XLEN-1:0] timer32_ro[RO_N];
    localparam STATUS_IDX = 0;

    // 定时器无其他输出

    // 目前 access_fault_o 仅检测未知 offset，写只读等情况不触发，后续可以用 | 扩展
    assign access_fault_o = offset_illegal;

    // 读端口与 offset 非法检测
    logic offset_illegal;
    always_comb begin : TIMER32_READ
        rdata_o        = '0;
        offset_illegal = 1'b0;
        if (valid_i) begin
            unique case (offset)
                TIMER32_MTIME_OFFSET:    rdata_o = timer32_rw[MTIME_IDX];
                TIMER32_MTIMECMP_OFFSET: rdata_o = timer32_rw[MTIMECMP_IDX];
                TIMER32_CTRL_OFFSET:     rdata_o = timer32_rw[CTRL_IDX];
                TIMER32_STATUS_OFFSET:   rdata_o = timer32_ro[STATUS_IDX];
                default: offset_illegal          = 1'b1;
            endcase
        end
    end

    // RW 寄存器 IDX 译码
    logic rw_hit;
    logic [$clog2(RW_N)-1:0] rw_idx;
    always_comb begin : TIMER32_RW_IDX_DECODE
        rw_idx = '0;
        rw_hit = 1'b1;
        unique case (offset)
            TIMER32_MTIME_OFFSET:    rw_idx = MTIME_IDX;
            TIMER32_MTIMECMP_OFFSET: rw_idx = MTIMECMP_IDX;
            TIMER32_CTRL_OFFSET:     rw_idx = CTRL_IDX;
            default: rw_hit = 1'b0;
        endcase
    end

    // 非可写寄存器硬件自动更新：STATUS 中断状态
    assign timer32_ro[STATUS_IDX] = {{(core_pkg::XLEN-1){1'b0}}, 
                                     timer32_rw[CTRL_IDX][TIMER32_CTRL_EN_BIT] && (timer32_rw[MTIME_IDX] >= timer32_rw[MTIMECMP_IDX])};

    // 写端口 与 可写寄存器硬件自动更新
    always_ff @(posedge clk_i or negedge rst_n_i) begin : TIMER32_WRITE
        if (!rst_n_i) begin
            for (int i = 0; i < RW_N; i++) begin
                timer32_rw[i] <= '0;
            end
        end
        else begin
            if (valid_i && we_i && rw_hit) begin
                if (be_i[0]) begin
                    timer32_rw[rw_idx][7:0]   <= wdata_i[7:0];
                end
                if (be_i[1]) begin
                    timer32_rw[rw_idx][15:8]  <= wdata_i[15:8];
                end
                if (be_i[2]) begin
                    timer32_rw[rw_idx][23:16] <= wdata_i[23:16];
                end
                if (be_i[3]) begin
                    timer32_rw[rw_idx][31:24] <= wdata_i[31:24];
                end
            end
            // else if (valid_i && we_i) begin
            //     // 后续可拓展”写只读“、“写未定义”触发异常，当前不实现
            // end

            //------------------------------------------------------------------
            // 硬件自动更新
            //------------------------------------------------------------------
            if (valid_i && we_i && rw_hit && rw_idx == MTIME_IDX) begin
                // 写 MTIME 时保留写
            end
            else if (timer32_rw[CTRL_IDX][TIMER32_CTRL_EN_BIT]) begin
                // 非写 MTIME 时自增
                timer32_rw[MTIME_IDX] <= timer32_rw[MTIME_IDX] + 1;
            end
        end
    end

    // 中断输出
    assign timer32_irq_o = timer32_ro[STATUS_IDX][TIMER32_STATUS_MTIP_BIT];

endmodule

`default_nettype wire
