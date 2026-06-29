//------------------------------------------------------------------------------
// 文件      : rtl/core/hazard_unit.sv
// 用途      : 流水线 Hazard 控制单元。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 处理 late-result-use data hazard（load-use、CSR-use）和 EX redirect control hazard。
//   - late-result-use stall 条件：
//     - ID/EX 阶段是一条 rd 晚就绪指令（load 或 CSR）
//     - ID 阶段的指令使用同一 rd 作为 rs1 或 rs2
//     - 解决：stall IF/ID 和 PC，在 ID/EX 插入 bubble
//   - control hazard 条件：
//     - EX 阶段 branch/JAL/JALR 产生 redirect
//     - 解决：flush IF/ID 和 ID/EX，杀掉更年轻的错误路径指令
//   - 控制优先级：EX redirect/flush 高于 late-result-use stall。
//   - trap/MRET redirect 不进入本模块，由 trap_ctrl 使用 kill 口径直接处理。
//
// 功能：
//   - 检测 ID 阶段与 ID/EX 阶段之间的 late-result-use RAW 冲突。
//   - stall_if_o 和 stall_id_o 同时拉高，冻结 PC 和 IF/ID 寄存器。
//   - bubble_ex_o 拉高，在 ID/EX 插入 invalid 空槽，让前一条 late-result 指令继续前进。
//   - redirect_valid_i 拉高时 flush_if_id_o 和 flush_id_ex_o 同时拉高，
//     清掉 EX 中跳转指令之后已经取入/译码的错误路径指令。
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

    output logic                      stall_if_o,             // 冻结 PC 和 IF 阶段。
    output logic                      stall_id_o,             // 冻结 IF/ID 寄存器。
    output logic                      bubble_ex_o,            // 在 ID/EX 插入 invalid 空槽。
    
    // base control hazard（branch 以及 jump 指令的 redirect 后 flush 年轻错误路径指令）
    // trap control hazard 导致的 redirect 由 trap_ctrl 模块使用 kill 口径处理
    input  logic                      redirect_valid_i,       // EX 阶段是否发生 redirect。

    output logic                      flush_if_id_o,          // 清空 IF/ID 中的错误路径指令。
    output logic                      flush_id_ex_o           // 清空 ID/EX 中的错误路径指令。
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
    wire late_result_use_stall = load_use_stall | csr_use_stall;


    // late-result-use：当上一条 load/CSR 的 rd 是本指令的 rs 时，写回数据到 MEM 后才就绪。
    // 因此本指令必须在 EX 前 stall 一拍，等 producer 进入 MEM/WB 后再通过 forwarding 使用新值。
    always_comb begin : HAZARD_CTRL
        stall_if_o = 1'b0;
        stall_id_o = 1'b0;
        bubble_ex_o = 1'b0;
        flush_if_id_o = 1'b0;
        flush_id_ex_o = 1'b0;
        if (redirect_valid_i) begin // EX 重定向了，当前 IF/ID 和即将进入 ID/EX 的年轻指令都属于错误路径，flush 掉。
            flush_if_id_o = 1'b1;
            flush_id_ex_o= 1'b1;
        end
        else if (late_result_use_stall) begin  // redirect 优先于 late-result-use，避免错误路径指令产生的 stall 卡住正确跳转。
            stall_if_o = 1'b1;
            stall_id_o = 1'b1;
            bubble_ex_o = 1'b1;
        end
    end


endmodule

`default_nettype wire


//------------------------------------------------------------------------------
// 对于当前单发射、无 M、无 F扩展的 RV32I 指令集的 data hazard：
//   - 只有 RAW 类型的 data hazard ，且大体上可以分为三类：
//      - 在消费指令 EX 使用前，生产指令已经得到要写回的数据，只是还未写回  <-  forwarding (EX/MEM -> EX, MEM/WB -> EX)
//      - 在消费指令 EX 使用前，生产指令还未得到要写回的数据，必须stall  <- late-result-use hazard (两条紧挨着的指令产生的 load-use, CSR-use)
//      - 本质上属于第一种，但刚好生产与消费差两拍，流水线中已无法获取，gpr也尚未真正写回  <-  gpr 同拍读写旁路
//   - 正如 "<-" 后给出的解决方案，本模块只针对第二种类型进行处理
//------------------------------------------------------------------------------
