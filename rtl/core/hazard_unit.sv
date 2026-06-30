//------------------------------------------------------------------------------
// 文件      : rtl/core/hazard_unit.sv
// 用途      : late-result-use hazard 检测单元。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块只检测 ID 阶段 consumer 与 ID/EX 阶段 late-result producer 之间的 RAW 冲突。
//   - late-result-use stall 条件：
//     - ID/EX 阶段是一条 rd 晚就绪指令（load 或 CSR）
//     - ID 阶段的指令使用同一 rd 作为 rs1 或 rs2
//     - 解决动作由 pipeline_ctrl 统一转换为 PC/IF_ID stall 和 ID_EX bubble
//
// 功能：
//   - 检测 ID 阶段与 ID/EX 阶段之间的 late-result-use RAW 冲突。
//   - 对 load-use 和 CSR-use 使用同一套 rd/rs1/rs2 命中判断。
//   - 输出单一 stall_late_result_use_o，由 pipeline_ctrl 与其他控制条件合并。
//------------------------------------------------------------------------------

`default_nettype none

module hazard_unit (
    // late-result-use hazard (load-use stall, CSR-use stall)
    input  logic                      if_id_valid_i,          // IF/ID 阶段是否有效（冻结 IF/ID 时需要）。
    input  logic [4:0]                id_rs1_addr_i,          // ID 阶段译码得到的 rs1 地址。
    input  logic [4:0]                id_rs2_addr_i,          // ID 阶段译码得到的 rs2 地址。
    input  logic                      id_uses_rs1_i,          // ID 指令是否真实使用 rs1。
    input  logic                      id_uses_rs2_i,          // ID 指令是否真实使用 rs2。

    input  logic                      id_ex_valid_i,          // ID/EX 阶段是否有有效指令（load-use 检测的前提）。
    input  logic [4:0]                id_ex_rd_addr_i,        // ID/EX 指令的写回 rd 地址。
    input  logic                      id_ex_reg_we_i,         // ID/EX 指令是否写 GPR。
    input  logic                      id_ex_load_re_i,        // ID/EX 是否为 load（rd 数据尚未就绪）。
    input  logic                      id_ex_csr_re_i,         // ID/EX 是否为 csr（rd 数据尚未就绪）。

    output logic                      stall_late_result_use_o // ID 阶段与 ID/EX 阶段之间存在 late-result-use RAW 冲突
);

    import core_pkg::*;
    import pipeline_pkg::*;

    // load-use stall
    wire load_use_stall_rs1 =   (if_id_valid_i && id_ex_valid_i && id_ex_reg_we_i  && id_ex_load_re_i)      // ID/EX 是 load，ID 指令还没进入 EX。
                              &&(id_uses_rs1_i && id_rs1_addr_i == id_ex_rd_addr_i && id_rs1_addr_i != '0); // load rd 命中 ID 指令 rs1，且 rd 不是 x0。
    wire load_use_stall_rs2 =   (if_id_valid_i && id_ex_valid_i && id_ex_reg_we_i  && id_ex_load_re_i)      // ID/EX 是 load，ID 指令还没进入 EX。
                              &&(id_uses_rs2_i && id_rs2_addr_i == id_ex_rd_addr_i && id_rs2_addr_i != '0); // load rd 命中 ID 指令 rs2，且 rd 不是 x0。
    wire load_use_stall     = load_use_stall_rs1 | load_use_stall_rs2;

    // CSR-use stall
    wire csr_use_stall_rs1  =   (if_id_valid_i && id_ex_valid_i && id_ex_reg_we_i  && id_ex_csr_re_i)       // ID/EX 写回且是 csr，ID 指令还没进入 EX。
                              &&(id_uses_rs1_i && id_rs1_addr_i == id_ex_rd_addr_i && id_rs1_addr_i != '0); // CSR rd 命中 ID 指令 rs1，且 rd 不是 x0。
    wire csr_use_stall_rs2  =   (if_id_valid_i && id_ex_valid_i && id_ex_reg_we_i  && id_ex_csr_re_i)       // ID/EX 写回且是 csr，ID 指令还没进入 EX。
                              &&(id_uses_rs2_i && id_rs2_addr_i == id_ex_rd_addr_i && id_rs2_addr_i != '0); // CSR rd 命中 ID 指令 rs2，且 rd 不是 x0。
    wire csr_use_stall      = csr_use_stall_rs1 | csr_use_stall_rs2;

    // late-result-use
    assign stall_late_result_use_o = load_use_stall | csr_use_stall;

endmodule

`default_nettype wire


//------------------------------------------------------------------------------
// 对于当前单发射、无 M、无 F扩展的 RV32I 指令集的 data hazard：
//   - 只有 RAW 类型的 data hazard ，且大体上可以分为三类：
//      - 在消费指令 EX 使用前，生产指令已经得到要写回的数据，只是还未写回
//        <- forwarding（ALU 等可 EX/MEM -> EX；load/CSR 晚结果通常等 MEM/WB -> EX）
//      - 在消费指令 EX 使用前，生产指令还未得到要写回的数据，必须先阻止 consumer 进入 EX
//        <- late-result-use hazard（紧邻 load-use、CSR-use；后续可变延迟等待由 MEM backpressure 接管）
//      - 本质上属于第一种，但刚好生产与消费差两拍，流水线中已无法获取，gpr也尚未真正写回  <-  gpr 同拍读写旁路
//   - 正如 "<-" 后给出的解决方案，本模块只检测第二种类型，具体 stall/bubble 由 pipeline_ctrl 合成。
//------------------------------------------------------------------------------
