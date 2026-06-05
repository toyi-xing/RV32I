//------------------------------------------------------------------------------
// 文件      : rtl/core/hazard_unit.sv
// 用途      : 流水线 Hazard 控制单元。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 现阶段 (step 3) 只实现 load-use stall。
//   - load-use stall 条件：
//     - ID/EX 阶段是一条 load 指令（mem_re && valid）
//     - ID 阶段的指令使用同一 rd 作为 rs1 或 rs2
//     - 解决：stall IF/ID 和 PC，在 ID/EX 插入 bubble
//   - step 4 将追加 redirect flush 控制（flush_if_id、flush_id_ex）。
//
// 功能：
//   - 检测 ID 阶段与 ID/EX 阶段之间的 load-use RAW 冲突。
//   - stall_if_o 和 stall_id_o 同时拉高，冻结 PC 和 IF/ID 寄存器。
//   - bubble_ex_o 拉高，在 ID/EX 插入 invalid 空槽，让前一条 load 继续前进。
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
    output logic                      bubble_ex_o             // 在 ID/EX 插入 invalid 空槽。
    
    // control hazard

);

    import core_pkg::*;
    import pipeline_pkg::*;

    // load-use :当上一条指令 load 的 rd 是本指令的 rs 时，不能 MEM/WB -> EX ，因为 MEM 单元是时序单元
    // 这样 forwarding 会取到 mem_load_data (该信号不经过 MEM/WB 寄存器）的旧值
    // 因此此时本指令必须在 EX 前 stall 一拍，即稳定 ID 两拍，等到 rs=rd 真正 wb 的时候再读，进如 EX
    always_comb begin : data_hazard
        stall_if_o = 1'b0;
        stall_id_o = 1'b0;
        bubble_ex_o = 1'b0;
        if (if_id_valid_i && id_ex_valid_i && id_ex_mem_re_i) begin
            // 同 fwd ，写 x0 会被丢弃，不必等待
            if (id_uses_rs1_i && id_rs1_addr_i == id_ex_rd_addr_i && id_rs1_addr_i != '0) begin
                stall_if_o = 1'b1;
                stall_id_o = 1'b1;
                bubble_ex_o = 1'b1;
            end
            if (id_uses_rs2_i && id_rs2_addr_i == id_ex_rd_addr_i && id_rs2_addr_i != '0) begin
                stall_if_o = 1'b1;
                stall_id_o = 1'b1;
                bubble_ex_o = 1'b1;
            end
        end
    end


endmodule

`default_nettype wire
