//------------------------------------------------------------------------------
// 文件      : rtl/mem/simple_ram.sv
// 用途      : 教学用固定响应数据 RAM。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是仿真/教学 memory model，第一版固定响应，无 valid/ready 握手。
//   - 内部 memory 为 32 bit word array，CPU 使用 byte address。
//   - CPU 地址 core_pkg::DMEM_BASE 映射到内部 mem[0]。
//   - 写端口在时钟上升沿按 byte enable 更新对应 byte lane。
//
// 功能：
//   - load 读路径为组合读，返回 addr_i 对应 word 的 32 bit 数据。
//   - store 写路径为同步写，we_i 有效时按 be_i 写入 wdata_i 的对应 byte lane。
//   - 仿真开始时如果 plusarg 提供 +dmem=<path>，则使用 $readmemh 初始化 RAM 内容。
//   - testbench 可通过层级路径观察 mem 数组内容，例如 u_simple_ram.mem[0]。
//------------------------------------------------------------------------------

`default_nettype none

module simple_ram #(
    parameter int unsigned ADDR_WIDTH = core_pkg::DMEM_ADDR_WIDTH
) (
    input  logic                          clk_i,
    input  logic                          we_i,       // store 写使能。
    input  logic [3:0]                    be_i,       // byte enable，bit0 对应 wdata_i[7:0]。
    input  logic [core_pkg::XLEN-1:0]     addr_i,     // CPU 发出的 byte address 访存地址。
    input  logic [core_pkg::XLEN-1:0]     wdata_i,    // 已按 byte lane 对齐的 store 写数据。
    output logic [core_pkg::XLEN-1:0]     rdata_o     // 返回给 CPU 的 32 bit load 原始 word 数据。
);
    import core_pkg::*;

    localparam int unsigned DEPTH = 1 << ADDR_WIDTH;

    logic [XLEN-1:0] mem [DEPTH];
    logic [ADDR_WIDTH-1:0] word_addr;

    assign word_addr = ADDR_WIDTH'((addr_i - DMEM_BASE) >> 2);
    assign rdata_o   = mem[word_addr];

    always_ff @(posedge clk_i) begin
        if (we_i) begin
            if (be_i[0]) begin
                mem[word_addr][7:0] <= wdata_i[7:0];
            end
            if (be_i[1]) begin
                mem[word_addr][15:8] <= wdata_i[15:8];
            end
            if (be_i[2]) begin
                mem[word_addr][23:16] <= wdata_i[23:16];
            end
            if (be_i[3]) begin
                mem[word_addr][31:24] <= wdata_i[31:24];
            end
        end
    end

    initial begin
        string dmem_file;

        for (int unsigned i = 0; i < DEPTH; i++) begin
            mem[i] = '0;
        end

        if ($value$plusargs("dmem=%s", dmem_file)) begin
            $readmemh(dmem_file, mem);
        end
    end

endmodule

`default_nettype wire
