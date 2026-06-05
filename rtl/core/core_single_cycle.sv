//------------------------------------------------------------------------------
// 文件      : rtl/core/core_single_cycle.sv
// 用途      : RV32I 单周期教学 demo 顶层。
//
// 综合PPA：
//   - 该顶层使用 yoysy 综合器 + 浙芯 55nm 开源工艺库综合结果：
//   - 最终面积 17046.4，其中时序单元 8036.0 (47.14%)
//   - Setup (max) Worst Slack = 17.984 ns  理论上可以跑到 ~540MHz
//   -  Hold (min) Worst Slack = 0.178 ns  
//   - Total Power = 0.484 W (约 484 mW)
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

    input  logic [core_pkg::ILEN-1:0]     imem_rdata_i,         // imem 返回的 32 bit instruction。
    output logic [core_pkg::XLEN-1:0]     imem_addr_o,          // 输出给 imem 的取指地址。

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

    // pc相关信号
    wire [core_pkg::XLEN-1:0] pc;
    wire [core_pkg::XLEN-1:0] ex_redirect_pc;
    wire                      ex_redirect_valid;
    wire stall_pc = 1'b0;       // 单周期demo不存在阻塞

    // 各valid信号
    wire pc_valid, if_valid, id_valid, ex_valid, mem_valid, wb_valid;

    // GPR
    wire [4:0]                id_rs1_addr;
    wire [4:0]                id_rs2_addr;
    wire [core_pkg::XLEN-1:0] gpr_rs1_rdata;
    wire [core_pkg::XLEN-1:0] gpr_rs2_rdata;
    wire [core_pkg::XLEN-1:0] wb_rd_wdata;
    wire                      wb_rd_we;

    // IF/ID
    wire [core_pkg::XLEN-1:0] if_pc;        // 必须传下来，EX可能会用
    wire [core_pkg::ILEN-1:0] if_instr;
    wire [core_pkg::XLEN-1:0] if_pc_plus4;

    // ID/EX
    wire [4:0]                id_rd_addr;
    core_pkg::alu_op_e        id_alu_op;
    core_pkg::op_a_sel_e      id_op_a_sel;
    core_pkg::op_b_sel_e      id_op_b_sel;
    wire                      id_rd_we;
    core_pkg::wb_sel_e        id_wb_sel;
    wire                      id_mem_re;
    wire                      id_mem_we;
    core_pkg::mem_size_e      id_mem_size;
    wire                      id_mem_unsigned;
    core_pkg::branch_op_e     id_branch_op;
    wire                      id_jump;
    wire                      id_jalr;
    wire [core_pkg::XLEN-1:0] id_imm;
    wire [core_pkg::XLEN-1:0] id_rs1_rdata, id_rs2_rdata;

    wire [core_pkg::XLEN-1:0] id_pc = if_pc;
    wire [core_pkg::XLEN-1:0] id_pc_plus4 = if_pc_plus4;
    wire [core_pkg::ILEN-1:0] id_instr = if_instr;

    // EX/MEM
    wire [core_pkg::XLEN-1:0] ex_alu_result;
    wire [core_pkg::XLEN-1:0] ex_store_data;

    wire                      ex_mem_re = id_mem_re;
    wire                      ex_mem_we = id_mem_we;
    core_pkg::mem_size_e      ex_mem_size = id_mem_size;
    wire                      ex_mem_unsigned = id_mem_unsigned;
    core_pkg::wb_sel_e        ex_wb_sel = id_wb_sel;
    wire                      ex_rd_we = id_rd_we;
    wire [core_pkg::XLEN-1:0] ex_pc_plus4 = id_pc_plus4;
    wire [core_pkg::XLEN-1:0] ex_imm = id_imm;
    wire [4:0]                ex_rd_addr = id_rd_addr;
    wire [core_pkg::ILEN-1:0] ex_instr = id_instr;
    wire [core_pkg::XLEN-1:0] ex_pc = id_pc;
    
    // MEM/WB
    wire [core_pkg::XLEN-1:0] mem_load_data;

    wire                      mem_rd_we = ex_rd_we;
    core_pkg::wb_sel_e        mem_wb_sel = ex_wb_sel;
    wire [core_pkg::XLEN-1:0] mem_alu_result = ex_alu_result;
    wire [core_pkg::XLEN-1:0] mem_pc_plus4 = ex_pc_plus4;
    wire [core_pkg::XLEN-1:0] mem_imm = ex_imm;
    wire [4:0]                mem_rd_addr = ex_rd_addr;
    wire [core_pkg::ILEN-1:0] mem_instr = ex_instr;
    wire [core_pkg::XLEN-1:0] mem_pc = ex_pc;

    // WB/commit
    wire [core_pkg::ILEN-1:0] wb_instr = mem_instr;
    wire [core_pkg::XLEN-1:0] wb_pc = mem_pc;
    wire [4:0]                wb_rd_addr = mem_rd_addr;
    

    pc_reg u_pc_reg(
        .clk_i              (clk_i),
        .rst_n_i            (rst_n_i),

        .pc_plus4_i         (if_pc_plus4),  // if取指后的下一条指令，必须用if的数据
        .redirect_pc_i      (ex_redirect_pc),
        .redirect_valid_i   (ex_redirect_valid),
        .stall_pc_i         (stall_pc),

        .pc_o               (pc),
        .pc_valid_o         (pc_valid)
    );

    if_stage u_if_stage (
        .pc_i           (pc),
        .imem_rdata_i   (imem_rdata_i),
        .pc_valid_i     (pc_valid),

        .imem_addr_o    (imem_addr_o),
        .if_pc_o        (if_pc),
        .if_pc_plus4_o  (if_pc_plus4),
        .if_instr_o     (if_instr),
        .if_valid_o     (if_valid)
    );

    id_stage u_id_stage (
        .if_valid_i     (if_valid),
        .if_instr_i     (if_instr),
        .rs1_rdata_i    (gpr_rs1_rdata),
        .rs2_rdata_i    (gpr_rs2_rdata),

        .rs1_addr_o     (id_rs1_addr),
        .rs2_addr_o     (id_rs2_addr),
        .rd_addr_o      (id_rd_addr),

        .instr_id_o     (),

        .uses_rs1_o     (), //单周期demo先不连
        .uses_rs2_o     (),

        .alu_op_o       (id_alu_op),
        .op_a_sel_o     (id_op_a_sel),
        .op_b_sel_o     (id_op_b_sel),

        .reg_we_o       (id_rd_we),
        .wb_sel_o       (id_wb_sel),

        .mem_re_o       (id_mem_re),
        .mem_we_o       (id_mem_we),
        .mem_size_o     (id_mem_size),
        .mem_unsigned_o (id_mem_unsigned),

        .branch_op_o    (id_branch_op),
        .jump_o         (id_jump),
        .jalr_o         (id_jalr),

        .illegal_instr_o(illegal_instr_o),  // 先不靠考虑指令非法，单周期直接接

        .id_imm_o       (id_imm),

        .id_valid_o     (id_valid),
        .id_rs1_rdata_o (id_rs1_rdata),
        .id_rs2_rdata_o (id_rs2_rdata)
    );

    regfile #(.BYPASS_EN(0)) u_regfile (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),

        .rs1_addr_i     (id_rs1_addr),
        .rs1_rdata_o    (gpr_rs1_rdata),

        .rs2_addr_i     (id_rs2_addr),
        .rs2_rdata_o    (gpr_rs2_rdata),

        .we_i           (wb_rd_we),
        .rd_addr_i      (wb_rd_addr),
        .rd_wdata_i     (wb_rd_wdata)
    );

    ex_stage u_ex_stage (
        .valid_i            (id_valid),
        .pc_i               (id_pc),
        .rs1_data_i         (id_rs1_rdata),
        .rs2_data_i         (id_rs2_rdata),
        .imm_i              (id_imm),
        .alu_op_i           (id_alu_op),
        .op_a_sel_i         (id_op_a_sel),
        .op_b_sel_i         (id_op_b_sel),
        .branch_op_i        (id_branch_op),
        .jump_i             (id_jump),
        .jalr_i             (id_jalr),

        .valid_o            (ex_valid),
        .alu_result_o       (ex_alu_result),
        .store_data_o       (ex_store_data),
        .redirect_valid_o   (ex_redirect_valid),
        .redirect_pc_o      (ex_redirect_pc)
    );

    mem_stage u_mem_stage (
        .valid_i            (ex_valid),
        .alu_result_i       (ex_alu_result),
        .store_data_i       (ex_store_data),
        .mem_re_i           (ex_mem_re),
        .mem_we_i           (ex_mem_we),
        .mem_size_i         (ex_mem_size),
        .mem_unsigned_i     (ex_mem_unsigned),
        .dmem_rdata_i       (dmem_rdata_i),

        .valid_o            (mem_valid),
        .mem_misaligned_o   (mem_misaligned_o),     // 先不考虑指令错误
        .dmem_re_o          (dmem_re_o), 
        .dmem_we_o          (dmem_we_o),
        .dmem_be_o          (dmem_be_o),
        .dmem_addr_o        (dmem_addr_o),
        .dmem_wdata_o       (dmem_wdata_o),
        .load_data_o        (mem_load_data)
    );

    wb_stage u_wb_stage (
        .valid_i        (mem_valid),
        .reg_we_i       (mem_rd_we),
        .wb_sel_i       (mem_wb_sel),
        .alu_result_i   (mem_alu_result),
        .load_data_i    (mem_load_data),
        .pc_plus4_i     (mem_pc_plus4),
        .imm_i          (mem_imm),

        .valid_o        (wb_valid),
        .reg_we_o       (wb_rd_we),
        .wb_wdata_o     (wb_rd_wdata)
    );

    assign commit_valid_o    = wb_valid;
    assign commit_pc_o       = wb_pc;
    assign commit_instr_o    = wb_instr;
    assign commit_reg_we_o   = wb_rd_we;
    assign commit_rd_addr_o  = wb_rd_addr;
    assign commit_rd_wdata_o = wb_rd_wdata;

endmodule

`default_nettype wire
