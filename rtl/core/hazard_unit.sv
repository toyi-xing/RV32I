//------------------------------------------------------------------------------
// 文件      : rtl/core/hazard_unit.sv
// 用途      : 流水线 Hazard 控制单元。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 第一版处理 load-use data hazard 和 EX redirect control hazard。
//   - load-use stall 条件：
//     - ID/EX 阶段是一条 load 指令（mem_re && valid）
//     - ID 阶段的指令使用同一 rd 作为 rs1 或 rs2
//     - 解决：stall IF/ID 和 PC，在 ID/EX 插入 bubble
//   - control hazard 条件：
//     - EX 阶段 branch/JAL/JALR 产生 redirect
//     - 解决：flush IF/ID 和 ID/EX，杀掉更年轻的错误路径指令
//   - 控制优先级：redirect/flush 高于 load-use stall。
//
// 功能：
//   - 检测 ID 阶段与 ID/EX 阶段之间的 load-use RAW 冲突。
//   - stall_if_o 和 stall_id_o 同时拉高，冻结 PC 和 IF/ID 寄存器。
//   - bubble_ex_o 拉高，在 ID/EX 插入 invalid 空槽，让前一条 load 继续前进。
//   - redirect_valid_i 拉高时 flush_if_id_o 和 flush_id_ex_o 同时拉高，
//     清掉 EX 中跳转指令之后已经取入/译码的错误路径指令。
//------------------------------------------------------------------------------

`default_nettype none

module hazard_unit (
    // data hazard （load-use stall）
    input  logic                      if_id_valid_i,          // IF/ID 阶段是否有效（冻结 IF/ID 时需要）。
    input  logic [4:0]                id_rs1_addr_i,          // ID 阶段译码得到的 rs1 地址。
    input  logic [4:0]                id_rs2_addr_i,          // ID 阶段译码得到的 rs2 地址。
    input  logic                      id_uses_rs1_i,          // ID 指令是否真实使用 rs1。
    input  logic                      id_uses_rs2_i,          // ID 指令是否真实使用 rs2。

    input  logic                      id_ex_valid_i,          // ID/EX 阶段是否有有效指令（load-use 检测的前提）。
    input  logic [4:0]                id_ex_rd_addr_i,        // ID/EX 指令的写回 rd。
    input  logic                      id_ex_mem_re_i,         // ID/EX 是否为 load（mem_re=1 时 rd 数据尚未就绪）。

    output logic                      stall_if_o,             // 冻结 PC 和 IF 阶段。
    output logic                      stall_id_o,             // 冻结 IF/ID 寄存器。
    output logic                      bubble_ex_o,            // 在 ID/EX 插入 invalid 空槽。
    
    // control hazard（EX redirect 后 kill 年轻错误路径指令）
    input  logic                      redirect_valid_i,       // EX 阶段是否发生 redirect。

    output logic                      flush_if_id_o,          // 清空 IF/ID 中的错误路径指令。
    output logic                      flush_id_ex_o           // 清空 ID/EX 中的错误路径指令。
);

    import core_pkg::*;
    import pipeline_pkg::*;

    wire load_use_stall_rs1 =   (if_id_valid_i && id_ex_valid_i && id_ex_mem_re_i)      // ID/EX 是 load，ID 指令还没进入 EX。
                              &&(id_uses_rs1_i && id_rs1_addr_i == id_ex_rd_addr_i && id_rs1_addr_i != '0); // load rd 命中 ID 指令 rs1，且 rd 不是 x0。
    wire load_use_stall_rs2 =   (if_id_valid_i && id_ex_valid_i && id_ex_mem_re_i)      // ID/EX 是 load，ID 指令还没进入 EX。
                              &&(id_uses_rs2_i && id_rs2_addr_i == id_ex_rd_addr_i && id_rs2_addr_i != '0); // load rd 命中 ID 指令 rs2，且 rd 不是 x0。

    wire load_use_stall = load_use_stall_rs1 | load_use_stall_rs2;

    // load-use :当上一条指令 load 的 rd 是本指令的 rs 时，不能 MEM/WB -> EX ，因为 MEM 单元是时序单元
    // 这样 forwarding 会取到 mem_load_data (该信号不经过 MEM/WB 寄存器）的旧值
    // 因此此时本指令必须在 EX 前 stall 一拍，即稳定 ID 两拍，等到 rs=rd 真正 wb 的时候再读，进入 EX。
    always_comb begin : data_hazard
        stall_if_o = 1'b0;
        stall_id_o = 1'b0;
        bubble_ex_o = 1'b0;
        flush_if_id_o = 1'b0;
        flush_id_ex_o = 1'b0;
        if (redirect_valid_i) begin // EX 重定向了，当前 IF/ID 和即将进入 ID/EX 的年轻指令都属于错误路径，flush 掉。
            flush_if_id_o = 1'b1;
            flush_id_ex_o= 1'b1;
        end else if (load_use_stall) begin  // redirect 优先于 load-use，避免错误路径指令产生的 stall 卡住正确跳转。
            stall_if_o = 1'b1;
            stall_id_o = 1'b1;
            bubble_ex_o = 1'b1;
        end
    end


endmodule

`default_nettype wire
