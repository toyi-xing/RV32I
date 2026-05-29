//------------------------------------------------------------------------------
// 文件      : rtl/core/mem_stage.sv
// 用途      : RV32I 访存阶段。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - 访存宽度统一使用 core_pkg::mem_size_e。
//   - 第一版假设 dmem 固定响应，没有 valid/ready 握手。
//
// 功能：
//   - 对 store 生成 dmem 写使能、byte enable 和按 byte lane 对齐后的写数据。
//   - 对 load 从 dmem_rdata_i 中选出 byte/halfword/word，并按 mem_unsigned_i 做符号或零扩展。
//   - load/store 地址来自 EX 阶段 ALU 结果，本模块不重新计算地址。
//   - 第一版暂不处理访存不对齐异常，测试程序应只使用合法对齐地址。
//------------------------------------------------------------------------------

`default_nettype none

module mem_stage (
    input  logic [core_pkg::XLEN-1:0]     alu_result_i,    // EX 阶段 ALU 结果，load/store 时作为 dmem 地址。
    input  logic [core_pkg::XLEN-1:0]     store_data_i,    // store 指令要写入 dmem 的原始 rs2 数据。
    input  logic                          mem_re_i,        // 当前指令是否执行 load。
    input  logic                          mem_we_i,        // 当前指令是否执行 store。
    input  core_pkg::mem_size_e           mem_size_i,      // 访存宽度：byte、halfword 或 word。
    input  logic                          mem_unsigned_i,  // load 是否零扩展；为 0 时表示符号扩展。
    input  logic [core_pkg::XLEN-1:0]     dmem_rdata_i,    // dmem 返回的 32 bit 读数据。

    output logic                          dmem_we_o,       // 输出到 dmem 的 store 写使能。
    output logic [3:0]                    dmem_be_o,       // 输出到 dmem 的 byte enable。
    output logic [core_pkg::XLEN-1:0]     dmem_addr_o,     // 输出到 dmem 的 load/store 地址。
    output logic [core_pkg::XLEN-1:0]     dmem_wdata_o,    // 输出到 dmem 的按 byte lane 对齐后的 store 数据。
    output logic [core_pkg::XLEN-1:0]     load_data_o      // 送往 WB 的 32 bit load 扩展结果。
);
    import core_pkg::*;

endmodule

`default_nettype wire
