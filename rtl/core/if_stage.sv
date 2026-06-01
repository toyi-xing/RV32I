//------------------------------------------------------------------------------
// 文件      : rtl/core/if_stage.sv
// 用途      : RV32I 取指阶段组合数据通路。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块保持纯组合逻辑，不包含时钟或复位。
//   - PC 时序状态由 pc_reg.sv 单独保存。
//   - 第一版假设 imem 固定响应，没有 valid/ready 握手。
//
// 功能：
//   - 接收 pc_reg 输出的当前取指 PC。
//   - 向 imem 输出取指地址。
//   - 计算当前 PC 对应的 PC+4。
//   - 透传 imem 返回的 instruction 和来自前端控制的 valid。
//   - 本文件只定义端口和说明，内部逻辑留作练习实现。
//------------------------------------------------------------------------------

`default_nettype none

module if_stage (
    input  logic [core_pkg::XLEN-1:0]     pc_i,              // pc_reg 输出的当前取指 PC。
    input  logic [core_pkg::XLEN-1:0]     imem_rdata_i,      // imem 返回的 32 bit 指令。
    input  logic                          pc_valid_i,        // 当前 PC 是否有效；复位后可由 pc_reg 或前端控制拉起。

    output logic [core_pkg::XLEN-1:0]     imem_addr_o,       // 输出给 imem 的取指地址。
    output logic [core_pkg::XLEN-1:0]     if_pc_o,           // 当前 IF 阶段指令的 PC。
    output logic [core_pkg::XLEN-1:0]     if_pc_plus4_o,     // 当前 IF 阶段指令的 PC + 4。
    output logic [core_pkg::ILEN-1:0]     if_instr_o,        // 当前 IF 阶段取回的指令。
    output logic                          if_valid_o         // 当前 IF 输出是否有效。
);
    import core_pkg::*;

endmodule

`default_nettype wire
