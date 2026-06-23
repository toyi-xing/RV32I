//------------------------------------------------------------------------------
// 文件      : rtl/periph/mmio_gpio.sv
// 用途      : GPIO0 最小固定响应 MMIO 寄存器块。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 当前是固定响应 MMIO register block，没有 ready/valid backpressure。
//   - valid_i 表示地址已经命中该外设窗口。
//   - GPIO_WIDTH 表示本 GPIO block 的引脚数，当前限制为 1..XLEN。
//   - access_fault_o 表示地址已命中本外设窗口，但 offset 或访问类型不被接受。真正未映射地址由 data_subsystem 汇总判断。
//
// 功能：
//   - 普通 RW 寄存器按 byte enable 更新。
//   - OUT（offset 0x00）是 RW，保存 GPIO 输出值。
//   - IN（offset 0x04）是 RO，返回两级同步后的 gpio_in_i。
//   - OE（offset 0x08）是 RW，保存 GPIO 输出使能。
//   - IRQ_EN/IRQ_RISE_EN/IRQ_FALL_EN/IRQ_HIGH_EN/IRQ_LOW_EN 是 RW 中断配置寄存器。
//   - IRQ_PENDING 是 R/W1C pending 寄存器，软件写 1 清除对应 bit，硬件触发同拍 set 优先。
//   - IRQ_STATUS 是 RO，返回 IRQ_PENDING & IRQ_EN。
//   - gpio_irq_o 是 level interrupt 输出。
//   - gpio_in_i 先同步到 clk_i 域，再用于 IN 读值和 interrupt 触发检测。
//   - 当前只对未知 offset 输出 access_fault_o；写 RO 寄存器等无害访问先忽略。
//------------------------------------------------------------------------------

`default_nettype none

module mmio_gpio #(
    parameter logic [core_pkg::XLEN-1:0] BASE_ADDR  = soc_pkg::GPIO0_BASE,          // 起始地址分配
    parameter int unsigned               GPIO_WIDTH = 32                            // GPIO 引脚个数，当前应保持 1..XLEN
)(
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  logic                      valid_i,         // 地址已命中 GPIO 窗口。
    input  logic                      we_i,            // 本拍是对 GPIO 的 store。
    input  logic [3:0]                be_i,            // byte enable，bit0 对应 wdata_i[7:0]。
    input  logic [core_pkg::XLEN-1:0] addr_i,          // 完整 byte address，内部用 addr_i - BASE_ADDR 得到 offset。
    input  logic [core_pkg::XLEN-1:0] wdata_i,         // store 写数据。
    output logic [core_pkg::XLEN-1:0] rdata_o,         // 读返回数据。
    output logic                      access_fault_o,  // offset 不存在时拉高。后续也可用于权限/访问类型错误。

    input  logic [GPIO_WIDTH-1:0]     gpio_in_i,       // 来自 SoC/testbench 的 GPIO 输入。
    output logic [GPIO_WIDTH-1:0]     gpio_out_o,      // GPIO OUT 寄存器值。
    output logic [GPIO_WIDTH-1:0]     gpio_oe_o,       // GPIO OE 寄存器值。

    output logic                      gpio_irq_o       // GPIO 产生中断，电平信号
);

    import core_pkg::*;
    import soc_pkg::*;

    // GPIO 输入来自 SoC/testbench 外部，可能跨时钟域；先同步到 clk_i 域。
    reg [GPIO_WIDTH-1:0] gpio_in_meta, gpio_in_sync, gpio_in_sync_q;
    always_ff @(posedge clk_i or negedge rst_n_i) begin : GPIO_SYNC
        if (!rst_n_i) begin
            gpio_in_meta  <= '0;
            gpio_in_sync   <= '0;
            gpio_in_sync_q <= '0;
        end
        else begin
            gpio_in_meta   <= gpio_in_i;
            gpio_in_sync   <= gpio_in_meta;
            gpio_in_sync_q <= gpio_in_sync;
        end
    end

    // 直接设为 12 位宽，方便与 soc 包中的 OFFSET 比较
    // valid_i 保证地址已命中本外设窗口；本模块只检查窗口内 offset 是否为已定义寄存器。
    wire [core_pkg::XLEN-1:0] full_offset = addr_i - BASE_ADDR;
    wire [11:0]               offset      = full_offset[11:0];

    // 内部寄存器声明，保持 XLEN 位宽；RW/RO 按属性分组，便于后续扩展。
    // RW 属性寄存器
    localparam RW_N = 7;
    reg  [core_pkg::XLEN-1:0] gpio_rw[RW_N];
    localparam OUT_IDX          = 0;
    localparam OE_IDX           = 1;
    localparam IRQ_EN_IDX       = 2;
    localparam IRQ_RISE_EN_IDX  = 3;
    localparam IRQ_FALL_EN_IDX  = 4;
    localparam IRQ_HIGH_EN_IDX  = 5;
    localparam IRQ_LOW_EN_IDX   = 6;
    // RO 属性寄存器
    localparam RO_N = 2;
    wire [core_pkg::XLEN-1:0] gpio_ro[RO_N];
    localparam IN_IDX           = 0;
    localparam IRQ_STATUS_IDX   = 1;
    // RW1C 属性寄存器，可读，写 1 清除，写 0 保持
    localparam RW1C_N = 1;
    reg  [core_pkg::XLEN-1:0] gpio_rw1c[RW1C_N];
    localparam IRQ_PENDING_IDX  = 0;

    // 输出端口与状态寄存器的控制关系
    assign gpio_out_o       = gpio_rw[OUT_IDX][GPIO_WIDTH-1:0];
    assign gpio_oe_o        = gpio_rw[OE_IDX ][GPIO_WIDTH-1:0];

    // 目前 access_fault_o 仅检测未知 offset，写只读等情况不触发，后续可以用 | 扩展
    assign access_fault_o = offset_illegal;

    // 读端口与 offset 非法检测
    logic offset_illegal;
    always_comb begin : GPIO_READ
        rdata_o        = '0;
        offset_illegal = 1'b0;
        if (valid_i) begin
            unique case (offset)
                GPIO_OUT_OFFSET         : rdata_o = gpio_rw[OUT_IDX];
                GPIO_IN_OFFSET          : rdata_o = gpio_ro[IN_IDX];
                GPIO_OE_OFFSET          : rdata_o = gpio_rw[OE_IDX];
                GPIO_IRQ_EN_OFFSET      : rdata_o = gpio_rw[IRQ_EN_IDX];
                GPIO_IRQ_RISE_EN_OFFSET : rdata_o = gpio_rw[IRQ_RISE_EN_IDX];
                GPIO_IRQ_FALL_EN_OFFSET : rdata_o = gpio_rw[IRQ_FALL_EN_IDX];
                GPIO_IRQ_HIGH_EN_OFFSET : rdata_o = gpio_rw[IRQ_HIGH_EN_IDX];
                GPIO_IRQ_LOW_EN_OFFSET  : rdata_o = gpio_rw[IRQ_LOW_EN_IDX];
                GPIO_IRQ_PENDING_OFFSET : rdata_o = gpio_rw1c[IRQ_PENDING_IDX];
                GPIO_IRQ_STATUS_OFFSET  : rdata_o = gpio_ro[IRQ_STATUS_IDX];
                default: offset_illegal  = 1'b1;
            endcase
        end
    end

    // RW 寄存器 IDX 译码
    logic rw_hit;
    logic [$clog2(RW_N)-1:0] rw_idx;
    always_comb begin : GPIO_RW_IDX_DECODE
        rw_idx = '0;
        rw_hit = 1'b1;
        unique case (offset)
            GPIO_OUT_OFFSET         : rw_idx = OUT_IDX;
            GPIO_OE_OFFSET          : rw_idx = OE_IDX;
            GPIO_IRQ_EN_OFFSET      : rw_idx = IRQ_EN_IDX;
            GPIO_IRQ_RISE_EN_OFFSET : rw_idx = IRQ_RISE_EN_IDX;
            GPIO_IRQ_FALL_EN_OFFSET : rw_idx = IRQ_FALL_EN_IDX;
            GPIO_IRQ_HIGH_EN_OFFSET : rw_idx = IRQ_HIGH_EN_IDX;
            GPIO_IRQ_LOW_EN_OFFSET  : rw_idx = IRQ_LOW_EN_IDX;
            default: rw_hit = 1'b0;
        endcase
    end
    // RW1C 寄存器 IDX 译码
    logic rw1c_hit;
    logic rw1c_idx;   // 后续多于 2 个寄存器时应使用 [$clog2(RW1C_N)-1:0]
    always_comb begin : GPIO_RW1C_IDX_DECODE
        rw1c_idx = '0;
        rw1c_hit = 1'b1;
        unique case (offset)
            GPIO_IRQ_PENDING_OFFSET : rw1c_idx = IRQ_PENDING_IDX;
            default: rw1c_hit = 1'b0;
        endcase
    end

    // 非可写寄存器硬件自动更新：IN GPIO 同步输入值
    assign gpio_ro[IN_IDX]          = {{(core_pkg::XLEN-GPIO_WIDTH){1'b0}}, gpio_in_sync};
    assign gpio_ro[IRQ_STATUS_IDX]  = gpio_rw[IRQ_EN_IDX] & gpio_rw1c[IRQ_PENDING_IDX];

    // 写端口与 IRQ_PENDING 硬件 set 合并更新。
    always_ff @(posedge clk_i or negedge rst_n_i) begin : GPIO_WRITE
        if (!rst_n_i) begin
            for (int i = 0; i < RW_N; i++) begin
                gpio_rw[i]   <= '0;
            end
            for (int i = 0; i < RW1C_N; i++) begin
                gpio_rw1c[i] <= '0;
            end
        end
        else begin
            if (valid_i && we_i && rw_hit) begin
                if (be_i[0]) begin
                    gpio_rw[rw_idx][7:0]   <= wdata_i[7:0];
                end
                if (be_i[1]) begin
                    gpio_rw[rw_idx][15:8]  <= wdata_i[15:8];
                end
                if (be_i[2]) begin
                    gpio_rw[rw_idx][23:16] <= wdata_i[23:16];
                end
                if (be_i[3]) begin
                    gpio_rw[rw_idx][31:24] <= wdata_i[31:24];
                end
            end
            // 通用 RW1C 写分支当前不用单独启用；IRQ_PENDING 在后面的合并逻辑中统一处理。
            // else if (valid_i && we_i && rw1c_hit) begin
            //     if (be_i[0]) begin
            //         gpio_rw1c[rw1c_idx][7:0]   <= ~wdata_i[7:0] & gpio_rw1c[rw1c_idx][7:0];
            //     end
            //     if (be_i[1]) begin
            //         gpio_rw1c[rw1c_idx][15:8]  <= ~wdata_i[15:8] & gpio_rw1c[rw1c_idx][15:8];
            //     end
            //     if (be_i[2]) begin
            //         gpio_rw1c[rw1c_idx][23:16] <= ~wdata_i[23:16] & gpio_rw1c[rw1c_idx][23:16];
            //     end
            //     if (be_i[3]) begin
            //         gpio_rw1c[rw1c_idx][31:24] <= ~wdata_i[31:24] & gpio_rw1c[rw1c_idx][31:24];
            //     end
            // end
            // else if (valid_i && we_i) begin
            //     // 后续可拓展”写只读“、“写未定义”触发异常，当前不实现
            // end

            //------------------------------------------------------------------
            // 硬件自动更新
            //------------------------------------------------------------------
            // IRQ_PENDING 合并软件 W1C clear 和硬件 set；同拍冲突时 set 优先。
            gpio_rw1c[IRQ_PENDING_IDX] <= (gpio_rw1c[IRQ_PENDING_IDX] & ~clear_pending_mask) | pending_valid;
        end
    end

    // 请求挂起信号处理
    wire [GPIO_WIDTH-1:0] rise_hit      =  gpio_in_sync & ~gpio_in_sync_q;
    wire [GPIO_WIDTH-1:0] fall_hit      = ~gpio_in_sync &  gpio_in_sync_q;
    wire [GPIO_WIDTH-1:0] high_hit      =  gpio_in_sync;
    wire [GPIO_WIDTH-1:0] low_hit       = ~gpio_in_sync;
        // 不考虑中断使能，可能要挂起的位
    wire [GPIO_WIDTH-1:0] pending_hit   = (gpio_rw[IRQ_RISE_EN_IDX][GPIO_WIDTH-1:0] & rise_hit) |
                                          (gpio_rw[IRQ_FALL_EN_IDX][GPIO_WIDTH-1:0] & fall_hit) |
                                          (gpio_rw[IRQ_HIGH_EN_IDX][GPIO_WIDTH-1:0] & high_hit) |
                                          (gpio_rw[IRQ_LOW_EN_IDX][GPIO_WIDTH-1:0]  & low_hit);
        // 将要挂起的位
    wire [core_pkg::XLEN-1:0] pending_valid = {{(core_pkg::XLEN-GPIO_WIDTH){1'b0}}, pending_hit & gpio_rw[IRQ_EN_IDX]};
        // 本拍要被清掉的挂起位
    logic [core_pkg::XLEN-1:0] clear_pending_mask;
    always_comb begin
        clear_pending_mask = '0;
        if(valid_i && we_i && rw1c_hit && rw1c_idx == IRQ_PENDING_IDX) begin
            clear_pending_mask[7:0]   = be_i[0] ? wdata_i[7:0]   : 8'h00;
            clear_pending_mask[15:8]  = be_i[1] ? wdata_i[15:8]  : 8'h00;
            clear_pending_mask[23:16] = be_i[2] ? wdata_i[23:16] : 8'h00;
            clear_pending_mask[31:24] = be_i[3] ? wdata_i[31:24] : 8'h00;
        end
    end

    // 中断输出
    assign gpio_irq_o = |gpio_ro[IRQ_STATUS_IDX];

endmodule

// =============================================================================
// GPIO IO/Pad 模型说明
// =============================================================================
// 本模块将 out/oe/in 分离为独立端口，是规范的 GPIO IP 内部接口。
// 真正 tri-state pad 驱动在芯片顶层处理，不在本模块内实现。
//
//    mmio_gpio (本模块)
//      gpio_out_o ──┐
//      gpio_oe_o  ──┤→ [pad ring: inout tri-state buffer] →─ 引脚
//      gpio_in_i  ←─┘
//
// OUT 寄存器含义：
//   - 软件写入的值。
//   - 当 OE[bit]=1 时，该 bit 会被驱动到引脚（物理意义）。
//   - 当 OE[bit]=0 时，该 bit 只是寄存器中的暂存值，不影响引脚。
//
// OE 寄存器含义：
//   - 控制每个 bit 的方向：1=输出模式，0=输入模式（高阻）。
//
// IN 寄存器含义：
//   - 读回同步后的引脚电平（由 gpio_in_i 两级同步得到）。
//   - 不受 OE 影响：输出模式下仍可读引脚。
//   - 不受 OUT 影响：写 OUT 不会改变 IN 的返回值。
//
// 外部中断检测：
//   - 检测同步后 IN 的变化（引脚电平变化），与 OUT/OE 无关。
//   - 因此本模块的 in_i 始终来自外部输入（TB 驱动或 pad），
//     不与 out_o/oe_o 耦合，简化了中断信号的产生逻辑。
//
// 当前教学平台的简化：
//   - 不实例化实际 tri-state pad，out/o/in 三端口直接暴露给 SoC 顶层。
//   - 不视为一组可变可选的 I/O 口，而视为 一组 32 bit 的 IN 端口，和一组可配置驱动输出的 OUT 端口
//   - gpio0_oe 直接暴露由 TB 观察，供软件验证读写正确性。
// =============================================================================

`default_nettype wire
