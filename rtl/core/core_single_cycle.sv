//------------------------------------------------------------------------------
// 文件      : rtl/core/core_single_cycle.sv
// 用途      : RV32I 单周期教学 demo 顶层。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块用于先跑通“一拍完成一条指令”的指令语义，不是最终五级流水线顶层。
//   - 第一版外接 imem/dmem，不在 core 内部实例化具体 memory。
//   - 第一版假设 imem/dmem 固定响应，没有 valid/ready 握手。
//
// 功能：
//   - 连接 pc_reg、if_stage、id_stage、ex_stage、mem_stage、wb_stage 和 regfile。
//   - 在单周期路径中完成取指、译码、读寄存器、执行、访存、写回和 PC 更新。
//   - 输出 imem/dmem 接口信号，供 testbench 连接 simple_rom/simple_ram。
//   - 输出 commit/debug 信号，便于 testbench 观察每拍提交的指令。
//   - 本文件只定义端口和说明，内部逻辑留作练习实现。
//------------------------------------------------------------------------------

`default_nettype none

module core_single_cycle (
    input  logic                          clk_i,
    input  logic                          rst_n_i,

    output logic [core_pkg::XLEN-1:0]     imem_addr_o,          // 输出给 imem 的取指地址。
    input  logic [core_pkg::ILEN-1:0]     imem_rdata_i,         // imem 返回的 32 bit instruction。

    output logic                          dmem_re_o,            // 输出给 dmem 的 load 读使能。
    output logic                          dmem_we_o,            // 输出给 dmem 的 store 写使能。
    output logic [3:0]                    dmem_be_o,            // 输出给 dmem 的 store byte enable。
    output logic [core_pkg::XLEN-1:0]     dmem_addr_o,          // 输出给 dmem 的 load/store 地址。
    output logic [core_pkg::XLEN-1:0]     dmem_wdata_o,         // 输出给 dmem 的已按 byte lane 对齐的 store 数据。
    input  logic [core_pkg::XLEN-1:0]     dmem_rdata_i,         // dmem 返回的 32 bit load 原始 word 数据。

    output logic                          commit_valid_o,       // 当前拍是否有有效指令提交。
    output logic [core_pkg::XLEN-1:0]     commit_pc_o,          // 提交指令的 PC。
    output logic [core_pkg::ILEN-1:0]     commit_instr_o,       // 提交指令的原始 instruction。
    output logic                          commit_reg_we_o,      // 提交指令是否写 rd。
    output logic [4:0]                    commit_rd_addr_o,     // 提交指令写回的 rd 编号。
    output logic [core_pkg::XLEN-1:0]     commit_rd_wdata_o,    // 提交指令写回 rd 的数据。
    output logic                          illegal_instr_o,      // 当前指令是否非法或暂未支持。
    output logic                          mem_misaligned_o      // 当前 load/store 是否地址不对齐。
);
    import core_pkg::*;

endmodule

`default_nettype wire
