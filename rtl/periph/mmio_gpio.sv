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
//   - IN（offset 0x04）是 RO，返回 gpio_in_i。
//   - OE（offset 0x08）是 RW，保存 GPIO 输出使能。
//   - 当前只对未知 offset 输出 access_fault_o；写 IN 等无害访问先忽略。
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
    output logic [GPIO_WIDTH-1:0]     gpio_oe_o        // GPIO OE 寄存器值。
);

    import core_pkg::*;
    import soc_pkg::*;

    // 直接设为 12 位宽，方便与 soc 包中的 OFFSET 比较
    // valid_i 保证地址已命中本外设窗口；本模块只检查窗口内 offset 是否为已定义寄存器。
    wire [core_pkg::XLEN-1:0] full_offset = addr_i - BASE_ADDR;
    wire [11:0]               offset      = full_offset[11:0];

    // 内部寄存器声明，保持 XLEN 位宽；RW/RO 按属性分组，便于后续扩展。
    // RW 属性寄存器
    localparam RW_N = 2;
    reg  [core_pkg::XLEN-1:0] gpio_rw[RW_N];
    localparam OUT_IDX = 0;
    localparam OE_IDX  = 1;
    // RO 属性寄存器
    localparam RO_N = 1;
    wire [core_pkg::XLEN-1:0] gpio_ro[RO_N];
    localparam IN_IDX  = 0;

    // 输入输出端口与状态寄存器的控制关系
    assign gpio_out_o       = gpio_rw[OUT_IDX][GPIO_WIDTH-1:0];
    assign gpio_ro[IN_IDX]  = {{(core_pkg::XLEN-GPIO_WIDTH){1'b0}}, gpio_in_i};
    assign gpio_oe_o        = gpio_rw[OE_IDX ][GPIO_WIDTH-1:0];

    // 目前 access_fault_o 仅检测未知 offset ，写只读等情况不触发，后续可以用 | 扩展
    assign access_fault_o = offset_illegal;

    // 读端口与 offset 非法检测
    logic offset_illegal;
    always_comb begin : GPIO_READ
        rdata_o        = '0;
        offset_illegal = 1'b0;
        if (valid_i) begin
            unique case (offset)
                GPIO_OUT_OFFSET: rdata_o = gpio_rw[OUT_IDX];
                GPIO_IN_OFFSET : rdata_o = gpio_ro[IN_IDX];
                GPIO_OE_OFFSET : rdata_o = gpio_rw[OE_IDX];
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
            GPIO_OUT_OFFSET: rw_idx = OUT_IDX;
            GPIO_OE_OFFSET : rw_idx = OE_IDX;
            default: rw_hit = 1'b0;
        endcase
    end
    // 写端口
    always_ff @(posedge clk_i or negedge rst_n_i) begin : GPIO_WRITE
        if (!rst_n_i) begin
            for (int i = 0; i < RW_N; i++) begin
                gpio_rw[i] <= '0;
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
            // else if (valid_i && we_i) begin
            //     // 后续可拓展”写只读“、“写未定义”触发异常，当前不实现
            // end
        end
    end

endmodule

`default_nettype wire
