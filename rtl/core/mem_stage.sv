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
//   - 对 load 生成 dmem 读使能。
//   - 对 store 生成 dmem 写使能、byte enable 和按 byte lane 对齐后的写数据。
//   - 对 load 从 dmem_rdata_i 中选出 byte/halfword/word，并按 mem_unsigned_i 做符号或零扩展。
//   - load/store 地址来自 EX 阶段 ALU 结果，本模块不重新计算地址。
//   - 检出 load/store address misaligned，不对齐时屏蔽 dmem 访问。
//   - store 的 byte lane 移位逻辑在某种非对齐场景下仍能产生正确结果，
//     但会被 dmem_we_o 门控屏蔽掉，不对齐的 store 不会实际写入。
//
// CSR、trap 相关功能：
//   - MEM 阶段负责识别的异常：load address misaligned、store address misaligned
//   - 检出不对齐时产生对应 exception cause（load=4, store=6）和 tval（faulting address）
//   - 不接收前级 exception，前级、本级以及与本级同拍的 CSR 异常信息统一由 trap_ctrl 选择最终 exception
//------------------------------------------------------------------------------

`default_nettype none

module mem_stage (
    input  logic                          valid_i,         // 当前 MEM 槽是否有效；用于门控访存副作用和错误上报。
    input  logic [core_pkg::XLEN-1:0]     alu_result_i,    // EX 阶段 ALU 结果，load/store 时作为 dmem 地址。
    input  logic [core_pkg::XLEN-1:0]     store_data_i,    // store 指令要写入 dmem 的原始 rs2 数据。
    input  logic                          mem_re_i,        // 当前指令是否执行 load。
    input  logic                          mem_we_i,        // 当前指令是否执行 store。
    input  core_pkg::mem_size_e           mem_size_i,      // 访存宽度：byte、halfword 或 word。
    input  logic                          mem_unsigned_i,  // load 是否零扩展；为 0 时表示符号扩展。
    input  logic [core_pkg::XLEN-1:0]     dmem_rdata_i,    // dmem 返回的 32 bit 读数据。

    output logic                          valid_o,         // 送入 MEM/WB 的 valid；第一版 MEM 不主动丢弃指令，直接透传 valid_i。
    output logic                          dmem_re_o,       // 输出到 dmem 的 load 读使能；地址不对齐时不发起读访问。
                                                           // 实际上 RAM 无需读使能，但此处可以作为 wb 阶段写回确定
    output logic                          dmem_we_o,       // 输出到 dmem 的 store 写使能。
    output logic [3:0]                    dmem_be_o,       // 输出到 dmem 的 store byte enable，如：SH x1, 0(x2) → 写 2 个字节 → be = 0011 / 1100
    output logic [core_pkg::XLEN-1:0]     dmem_addr_o,     // 输出到 dmem 的 load/store 地址。
    output logic [core_pkg::XLEN-1:0]     dmem_wdata_o,    // 输出到 dmem 的按 byte lane 对齐后的 store 数据。
    output logic [core_pkg::XLEN-1:0]     load_data_o,     // 送往 WB 的 32 bit load 扩展结果。

    //  trap 相关
    output logic                          mem_misaligned_o, // 为 1 时表示当前 load/store 地址不满足访问宽度对齐要求
    output logic                          load_misaligned_o,    // 当前有效 load 访问地址不满足访问宽度对齐要求。
    output logic                          store_misaligned_o,   // 当前有效 store 访问地址不满足访问宽度对齐要求。
    output logic                          exception_valid_o,    // MEM 阶段产生的 load/store address misaligned exception 是否有效。
    output core_pkg::trap_cause_e         exception_cause_o,    // MEM 阶段 exception cause，load 不对齐为 4，store 不对齐为 6。
    output logic [core_pkg::XLEN-1:0]     exception_tval_o      // MEM 阶段 exception tval，填 faulting memory address。
);
    import core_pkg::*;

    assign valid_o = valid_i;

    assign dmem_re_o = valid_i & ~mem_misaligned_o & mem_re_i;
    assign dmem_we_o = valid_i & ~mem_misaligned_o & mem_we_i;

    assign dmem_be_o = ~dmem_we_o ? 4'b0000 : ( (mem_size_i == MEM_WORD ? 4'b1111 : 4'b0000) |
                                                (mem_size_i == MEM_HALF ? 4'b0011 << alu_result_i[1:0] : 4'b0000) |
                                                (mem_size_i == MEM_BYTE ? 4'b0001 << alu_result_i[1:0] : 4'b0000) );

    assign dmem_addr_o  = alu_result_i;

    assign dmem_wdata_o = dmem_we_o ? store_data_i << {alu_result_i[1:0], 3'b000} : '0;

    // 按地址偏移右移并低位对齐后取出的原始 load 数据，尚未做符号/零扩展。
    wire [XLEN-1:0] load_raw = (dmem_rdata_i >> {alu_result_i[1:0], 3'b000}) &
                               (mem_size_i == MEM_WORD ? 32'hffffffff :
                               (mem_size_i == MEM_HALF ? 32'h0000ffff : 32'h000000ff));
    assign load_data_o       = mem_size_i == MEM_WORD ? load_raw :
                              (mem_size_i == MEM_HALF ? {{16{~mem_unsigned_i & load_raw[15]}}, load_raw[15:0]} :
                              (mem_size_i == MEM_BYTE ? {{24{~mem_unsigned_i & load_raw[ 7]}}, load_raw[ 7:0]} : '0));

    wire misa_lw            = valid_i && (mem_re_i || mem_we_i) && (mem_size_i == MEM_WORD) && (|alu_result_i[1:0]);
    wire misa_lh            = valid_i && (mem_re_i || mem_we_i) && (mem_size_i == MEM_HALF) && (alu_result_i[0]);
    assign mem_misaligned_o = valid_i && misa_lw || misa_lh;

    assign load_misaligned_o    = valid_i & mem_misaligned_o & mem_re_i;
    assign store_misaligned_o   = valid_i & mem_misaligned_o & mem_we_i;

    assign exception_valid_o    = mem_misaligned_o;
    assign exception_cause_o    = load_misaligned_o  ? TRAP_CAUSE_LOAD_ADDR_MISALIGNED  :
                                  store_misaligned_o ? TRAP_CAUSE_STORE_ADDR_MISALIGNED : TRAP_CAUSE_ILLEGAL_INSTR; // 默认值设为非法指令，此处无实意
    assign exception_tval_o     = mem_misaligned_o ? alu_result_i : '0;

endmodule

`default_nettype wire
