//------------------------------------------------------------------------------
// 文件      : rtl/core/id_stage.sv
// 用途      : RV32I 译码阶段组合数据通路。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块保持纯组合逻辑，不包含时钟或复位。
//   - regfile 作为独立状态模块，本模块只输出读地址并接收读数据。
//   - decoder 和 imm_gen 可在本模块内部例化，也可先在 core_top 中显式连接。
//
// 功能：
//   - 接收 IF/ID 保存的 valid、PC、PC+4 和 instruction。
//   - 输出 rs1/rs2 读地址给 regfile，并接收 regfile 读出的 rs1/rs2 数据。
//   - 生成 ID/EX 后续需要的数据字段、立即数和控制信号。
//   - 部分字段不直接进入 EX 组合逻辑，但需要由顶层或流水线寄存器继续带到 MEM/WB/commit。
//   - 输出 illegal_instr_o，第一版可用于调试、halt 或后续异常路径。
//------------------------------------------------------------------------------

`default_nettype none

module id_stage (
    input  logic                          if_valid_i,        // IF/ID 槽是否有效。
    input  logic [core_pkg::XLEN-1:0]     if_pc_i,           // IF/ID 保存的当前指令 PC。
    input  logic [core_pkg::XLEN-1:0]     if_pc_plus4_i,     // IF/ID 保存的当前指令 PC + 4。
    input  logic [core_pkg::ILEN-1:0]     if_instr_i,        // IF/ID 保存的原始指令。
    input  logic [core_pkg::XLEN-1:0]     rs1_rdata_i,       // regfile 根据 rs1_addr_o 返回的 rs1 数据。
    input  logic [core_pkg::XLEN-1:0]     rs2_rdata_i,       // regfile 根据 rs2_addr_o 返回的 rs2 数据。

    output logic [4:0]                    rs1_addr_o,        // 输出给 regfile 的 rs1 读地址，也会随指令进入 ID/EX。
    output logic [4:0]                    rs2_addr_o,        // 输出给 regfile 的 rs2 读地址，也会随指令进入 ID/EX。
    output logic [4:0]                    rd_addr_o,         // 目的寄存器 rd 编号，随指令进入后级。

    output core_pkg::instr_id_e           instr_id_o,        // decoder 识别出的具体指令，用于调试或后续控制。

    output logic                          uses_rs1_o,        // 当前指令是否实际读取 rs1，用于 hazard/forwarding。
    output logic                          uses_rs2_o,        // 当前指令是否实际读取 rs2，用于 hazard/forwarding。

    output core_pkg::alu_op_e             alu_op_o,          // 送入 EX 的 ALU 运算类型。
    output core_pkg::op_a_sel_e           op_a_sel_o,        // 送入 EX 的 ALU A 操作数选择。
    output core_pkg::op_b_sel_e           op_b_sel_o,        // 送入 EX 的 ALU B 操作数选择。

    output logic                          reg_we_o,          // 当前指令是否有写 rd 的意图。
    output core_pkg::wb_sel_e             wb_sel_o,          // 送入 WB 的写回来源选择。

    output logic                          mem_re_o,          // 当前指令是否执行 load。
    output logic                          mem_we_o,          // 当前指令是否执行 store。
    output core_pkg::mem_size_e           mem_size_o,        // 送入 MEM 的访存宽度。
    output logic                          mem_unsigned_o,    // load 是否零扩展；为 0 时表示符号扩展。

    output core_pkg::branch_op_e          branch_op_o,       // 送入 EX 的条件分支比较类型。
    output logic                          jump_o,            // 当前指令是否为 JAL/JALR。
    output logic                          jalr_o,            // 当前指令是否为 JALR。

    output logic                          illegal_instr_o,   // 当前指令是否非法或暂未支持。

    output logic [core_pkg::XLEN-1:0]     id_imm_o,          // imm_gen 生成的 32 bit 立即数。

    output logic                          id_valid_o,        // 送入 ID/EX 的 valid。
    output logic [core_pkg::XLEN-1:0]     id_pc_o,           // 送入 ID/EX 的 PC。
    output logic [core_pkg::XLEN-1:0]     id_pc_plus4_o,     // 送入后级保存的 PC + 4；主要用于 JAL/JALR 写回和 commit/debug。
    output logic [core_pkg::ILEN-1:0]     id_instr_o,        // 送入后级保存的原始指令；主要用于 commit trace/debug。
    output logic [core_pkg::XLEN-1:0]     id_rs1_rdata_o,    // 送入 ID/EX 的 rs1 原始读值；单周期可直接送 EX，流水线中可先进入 forwarding mux。
    output logic [core_pkg::XLEN-1:0]     id_rs2_rdata_o     // 送入 ID/EX 的 rs2 原始读值；branch、store data 和 forwarding 都会使用。

);
    import core_pkg::*;

    core_pkg::imm_sel_e imm_sel;
    wire decoder_illegal_instr;

    decoder u_decoder (
        .instr_i    (if_instr_i),

        .opcode_o   (),
        .funct3_o   (),
        .funct7_o   (),
        .rs1_addr_o (rs1_addr_o),
        .rs2_addr_o (rs2_addr_o),
        .rd_addr_o  (rd_addr_o),

        .instr_id_o (instr_id_o),

        .uses_rs1_o (uses_rs1_o),
        .uses_rs2_o (uses_rs2_o),

        .imm_sel_o  (imm_sel),
        .alu_op_o   (alu_op_o),
        .op_a_sel_o (op_a_sel_o),
        .op_b_sel_o (op_b_sel_o),

        .reg_we_o   (reg_we_o),
        .wb_sel_o   (wb_sel_o),

        .mem_re_o           (mem_re_o),
        .mem_we_o           (mem_we_o),
        .mem_size_o         (mem_size_o),
        .mem_unsigned_o     (mem_unsigned_o),

        .branch_op_o        (branch_op_o),
        .jump_o             (jump_o),
        .jalr_o             (jalr_o),

        .illegal_instr_o    (decoder_illegal_instr)
    );

    assign illegal_instr_o = if_valid_i & decoder_illegal_instr;

    imm_gen u_imm_gen(
        .instr_i    (if_instr_i),
        .imm_sel_i  (imm_sel),
        .imm_o      (id_imm_o)
    );

    assign id_valid_o = if_valid_i;
    assign id_pc_o = if_pc_i;
    assign id_pc_plus4_o = if_pc_plus4_i;
    assign id_instr_o = if_instr_i;
    assign id_rs1_rdata_o = rs1_rdata_i;
    assign id_rs2_rdata_o = rs2_rdata_i;

endmodule

`default_nettype wire
