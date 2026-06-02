//------------------------------------------------------------------------------
// 文件      : rtl/mem/simple_rom.sv
// 用途      : 教学用固定响应指令 ROM。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是仿真/教学 memory model，第一版固定响应，无 valid/ready 握手。
//   - 内部 memory 为 32 bit word array，适配每行一个 32 bit word 的 $readmemh 文件。
//   - CPU 使用 byte address，ROM 内部使用 word index，因此默认用 addr_i[ADDR_WIDTH+1:2] 取 word。
//
// 功能：
//   - 根据 addr_i 组合读出对应 32 bit instruction。
//   - 仿真开始时如果 plusarg 提供 +imem=<path>，则使用 $readmemh 加载 ROM 内容。
//   - 若没有提供 +imem，则 ROM 保持初始 0，便于尽早暴露测试环境未加载程序的问题。
//------------------------------------------------------------------------------

`default_nettype none

module simple_rom #(
    parameter int unsigned ADDR_WIDTH = 10
) (
    input  logic [core_pkg::XLEN-1:0]     addr_i,     // CPU 发出的 byte address 取指地址。
    output logic [core_pkg::ILEN-1:0]     rdata_o     // 返回给 CPU 的 32 bit instruction。
);
    import core_pkg::*;

    localparam int unsigned DEPTH = 1 << ADDR_WIDTH;

    logic [ILEN-1:0] mem [DEPTH];
    logic [ADDR_WIDTH-1:0] word_addr;

    assign word_addr = ADDR_WIDTH'((addr_i - IMEM_BASE) >> 2);
    assign rdata_o   = mem[word_addr];

    initial begin
        string imem_file;

        for (int unsigned i = 0; i < DEPTH; i++) begin
            mem[i] = '0;
        end

        if ($value$plusargs("imem=%s", imem_file)) begin
            $readmemh(imem_file, mem);
        end
    end

endmodule

`default_nettype wire
