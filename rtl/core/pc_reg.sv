//------------------------------------------------------------------------------
// 文件      : rtl/core/pc_reg.sv
// 用途      : RV32I 取指 PC 寄存器。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是时序逻辑，负责保存 PC 状态，因此包含 clk_i 和 rst_n_i。
//   - 组合取指数据通路放在 if_stage.sv，本模块不读取 imem，也不处理 instruction。
//   - PC 更新优先级建议为 reset > redirect > stall > PC+4。
//
// 功能：
//   - 复位后把 PC 设置为 core_pkg::RESET_PC。
//   - 正常情况下把 PC 更新为 pc_plus4_i。
//   - stall_pc_i 有效时保持当前 PC 不变。
//   - redirect_valid_i 有效时把 PC 更新为 redirect_pc_i。
//   - 输出当前 PC 和当前 PC 是否有效。
//   - 本文件只定义端口和说明，内部逻辑留作练习实现。
//------------------------------------------------------------------------------

`default_nettype none

module pc_reg (
    input  logic [core_pkg::XLEN-1:0]     pc_plus4_i,         // 默认顺序下一 PC，通常来自 if_stage 的 PC+4。
    input  logic [core_pkg::XLEN-1:0]     redirect_pc_i,      // branch/JAL/JALR 产生的重定向目标 PC。
    input  logic                          clk_i,
    input  logic                          rst_n_i,
    input  logic                          stall_pc_i,         // 为 1 时保持 PC 不变。
    input  logic                          redirect_valid_i,   // 为 1 时下一拍 PC 跳转到 redirect_pc_i。

    output logic [core_pkg::XLEN-1:0]     pc_o,               // 当前取指 PC。
    output logic                          pc_valid_o          // 当前 PC 是否有效；复位后通常为 0，进入运行后为 1。
);
    import core_pkg::*;

endmodule

`default_nettype wire
