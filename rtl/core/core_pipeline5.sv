//------------------------------------------------------------------------------
// 文件      : rtl/core/core_pipeline5.sv
// 用途      : RV32I 五级流水线教学核顶层。
//
// 综合PPA：
//   - 该顶层使用 yosys 综合器 + 浙芯 55nm 开源工艺库综合结果：
//   - 最终面积 21949.76，其中时序单元 13555.36 (61.76%)
//   - Setup (max) Worst Slack = 18.508 ns  理论上可以跑到 ~670MHz
//   -  Hold (min) Worst Slack = 0.088 ns
//   - Total Power = 0.163 W (约 163 mW)
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块用于搭建 IF/ID/EX/MEM/WB 五级流水线结构。
//   - 第一版外接 imem/dmem，不在 core 内部实例化具体 memory。
//   - 第一版假设 imem/dmem 固定响应，没有 valid/ready 握手。
//
// 功能：
//   - 连接 pc_reg、if_stage、id_stage、ex_stage、mem_stage、wb_stage 和 regfile。
//   - 使用 pipeline_pkg 中的 struct 描述四组流水线寄存器承载的数据和控制。
//   - 处理 forwarding、load-use stall 和 branch/JAL/JALR redirect flush/kill。
//------------------------------------------------------------------------------

`default_nettype none

module core_pipeline5 (
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
    import pipeline_pkg::*;

    // pc相关信号
    wire [core_pkg::XLEN-1:0] pc;
    wire [core_pkg::XLEN-1:0] ex_redirect_pc;
    wire                      ex_redirect_valid;
    wire                      trap_redirect_valid;
    wire [core_pkg::XLEN-1:0] trap_redirect_pc;
    wire                      redirect_valid = trap_redirect_valid | ex_redirect_valid;
    wire [core_pkg::XLEN-1:0] redirect_pc    = trap_redirect_valid ? trap_redirect_pc : ex_redirect_pc;

    // 做 data hazard，接 hazard_unit。
    wire stall_if;
    wire stall_id;
    wire bubble_ex;

    // 全流水线暂停（如可变延迟 memory），当前不使用。
    // wire stall_pipeline = 1'b0;

    // 做 control hazard flush/kill，接 hazard_unit。
    wire flush_if_id;
    wire flush_id_ex;

    // trap/MRET kill 信号
    wire kill_if_id;
    wire kill_id_ex;
    wire kill_ex_mem;
    wire kill_mem_wb;

    // 各 valid 信号，中间 data。由中间寄存器寄存
    wire pc_valid;
    wire if_valid, if_id_valid;
    wire id_valid, id_ex_valid;
    wire ex_valid, ex_mem_valid;
    wire mem_valid, mem_wb_valid;
    wire wb_valid;
    pipeline_pkg::if_id_reg_t if_id_data_d;
    pipeline_pkg::if_id_reg_t if_id_data_q;
    pipeline_pkg::id_ex_reg_t id_ex_data_d;
    pipeline_pkg::id_ex_reg_t id_ex_data_q;
    pipeline_pkg::ex_mem_reg_t ex_mem_data_d;
    pipeline_pkg::ex_mem_reg_t ex_mem_data_q;
    pipeline_pkg::mem_wb_reg_t mem_wb_data_d;
    pipeline_pkg::mem_wb_reg_t mem_wb_data_q;

    // GPR
    wire [4:0]                id_rs1_addr;
    wire [4:0]                id_rs2_addr;
    wire [core_pkg::XLEN-1:0] gpr_rs1_rdata;
    wire [core_pkg::XLEN-1:0] gpr_rs2_rdata;
    wire [core_pkg::XLEN-1:0] wb_rd_wdata;
    wire                      wb_rd_we;

    // IF
    wire [core_pkg::XLEN-1:0] if_pc;
    wire [core_pkg::ILEN-1:0] if_instr;
    wire [core_pkg::XLEN-1:0] if_pc_plus4;

    // ID
    wire [4:0]                id_rd_addr;
    wire                      id_uses_rs1;
    wire                      id_uses_rs2;
    wire                      id_illegal_instr;
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
    core_pkg::instr_id_e      id_instr_id;
    wire                      id_fence;
    wire                      id_mret;
    wire                      id_csr;
    core_pkg::csr_op_e        id_csr_op;
    wire [11:0]               id_csr_addr;
    wire [4:0]                id_csr_uimm;
    wire                      id_csr_uses_rs1;
    wire                      id_csr_writes_rd;
    wire                      id_csr_write_en;
    wire                      id_exception_valid;
    core_pkg::trap_cause_e    id_exception_cause;
    wire [core_pkg::XLEN-1:0] id_exception_tval;

    // forwarding 前递结果 -> EX 操作数
    wire [core_pkg::XLEN-1:0] ex_rs1_op_data;
    wire [core_pkg::XLEN-1:0] ex_rs2_op_data;

    // EX
    wire [core_pkg::XLEN-1:0] ex_alu_result;
    wire [core_pkg::XLEN-1:0] ex_store_data;
    wire                      ex_exception_valid;
    core_pkg::trap_cause_e    ex_exception_cause;
    wire [core_pkg::XLEN-1:0] ex_exception_tval;
    wire [core_pkg::XLEN-1:0] ex_csr_operand;
    wire                      ex_mret;

    // MEM
    wire [core_pkg::XLEN-1:0] mem_load_data;
    wire                      mem_load_misaligned;
    wire                      mem_store_misaligned;
    wire                      mem_exception_valid;
    core_pkg::trap_cause_e    mem_exception_cause;
    wire [core_pkg::XLEN-1:0] mem_exception_tval;

    // CSR 信号
    wire                      mem_csr_valid;    // 当前 MEM 阶段的 csr 指令控制信号
    wire [core_pkg::XLEN-1:0] mem_csr_rdata;
    wire                      mem_csr_illegal;
    wire [core_pkg::XLEN-1:0] csr_mtvec;        // 恒为当前对于 csr 寄存器值
    wire [core_pkg::XLEN-1:0] csr_mepc;
    wire [core_pkg::XLEN-1:0] csr_mstatus;

    // 系统级 trap 信号
    wire                      trap_valid;
    wire [core_pkg::XLEN-1:0] trap_pc;
    core_pkg::trap_cause_e    trap_cause;
    wire [core_pkg::XLEN-1:0] trap_tval;
    wire                      mret_valid;

    // WB 随指令输出 -> commit
    wire [core_pkg::ILEN-1:0] wb_instr          = mem_wb_data_q.instr;
    wire [core_pkg::XLEN-1:0] wb_pc             = mem_wb_data_q.pc;
    wire [4:0]                wb_rd_addr        = mem_wb_data_q.rd_addr;
    wire                      wb_illegal_instr  = mem_wb_data_q.illegal_instr;

    pc_reg u_pc_reg(
        .clk_i              (clk_i),
        .rst_n_i            (rst_n_i),

        .pc_plus4_i         (if_pc_plus4),
        .redirect_pc_i      (redirect_pc),
        .redirect_valid_i   (redirect_valid),
        .stall_pc_i         (stall_if), // if 要 stall 一拍，让 pc 保持不变

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

    pipe_reg_if_id u_pipe_reg_if_id (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .data_i     (if_id_data_d),
        .valid_i    (if_valid),
        .kill_i     (kill_if_id),       // trap control hazard
        .flush_i    (flush_if_id),      // base control hazard
        .stall_i    (stall_id), // late_result_use_stall 时 id 要 stall 一拍

        .data_o     (if_id_data_q),
        .valid_o    (if_id_valid)
    );

    // IF/ID 输入组包。后续若取指侧增加 kill/valid 修正，在这里改。
    assign if_id_data_d.pc       = if_pc;
    assign if_id_data_d.instr    = if_instr;
    assign if_id_data_d.pc_plus4 = if_pc_plus4;

    id_stage u_id_stage (
        .if_valid_i     (if_id_valid),
        .if_instr_i     (if_id_data_q.instr),
        .rs1_rdata_i    (gpr_rs1_rdata),
        .rs2_rdata_i    (gpr_rs2_rdata),

        .rs1_addr_o     (id_rs1_addr),
        .rs2_addr_o     (id_rs2_addr),
        .rd_addr_o      (id_rd_addr),

        .instr_id_o     (id_instr_id),     // 调试用,送到流水线结束

        .uses_rs1_o     (id_uses_rs1),
        .uses_rs2_o     (id_uses_rs2),

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
        .fence_o        (id_fence),
        .mret_o         (id_mret),

        .csr_o              (id_csr),
        .csr_op_o           (id_csr_op),
        .csr_addr_o         (id_csr_addr),
        .csr_uimm_o         (id_csr_uimm),
        .csr_uses_rs1_o     (id_csr_uses_rs1),
        .csr_writes_rd_o    (id_csr_writes_rd),     // csr 指令写 gpr
        .csr_write_en_o     (id_csr_write_en),      // csr 指令写 csr

        .exception_valid_o  (id_exception_valid),
        .exception_cause_o  (id_exception_cause),
        .exception_tval_o   (id_exception_tval),

        .illegal_instr_o(id_illegal_instr),

        .id_imm_o       (id_imm),

        .id_valid_o     (id_valid),
        .id_rs1_rdata_o (id_rs1_rdata),
        .id_rs2_rdata_o (id_rs2_rdata)
    );

    regfile #(.BYPASS_EN(1)) u_regfile (
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

    // hazard_unit 统一产生 data hazard stall/bubble 和 base control hazard flush/kill。
    hazard_unit u_hazard_unit (
        .if_id_valid_i      (if_id_valid),
        .id_rs1_addr_i      (id_rs1_addr),
        .id_rs2_addr_i      (id_rs2_addr),
        .id_uses_rs1_i      (id_uses_rs1),
        .id_uses_rs2_i      (id_uses_rs2),

        .id_ex_valid_i      (id_ex_valid),
        .id_ex_rd_addr_i    (id_ex_data_q.rd_addr),
        .id_ex_reg_we_i     (id_ex_data_q.reg_we),
        .id_ex_load_re_i    (id_ex_data_q.mem_re),
        .id_ex_csr_re_i     (id_ex_data_q.csr_writes_rd),

        .stall_if_o         (stall_if),
        .stall_id_o         (stall_id),
        .bubble_ex_o        (bubble_ex),

        .redirect_valid_i   (ex_redirect_valid),    // hazard_unit 只负责 branch/jump 产生的 control hazard

        .flush_if_id_o      (flush_if_id),
        .flush_id_ex_o      (flush_id_ex)
    );

    // forwarding，处理 RAW 时 EX/MEM -> EX 和 MEM/WB -> EX
    forwarding_unit u_forwarding_unit (
        .id_ex_valid_i      (id_ex_valid),
        .id_ex_rs1_addr_i   (id_ex_data_q.rs1_addr),
        .id_ex_rs2_addr_i   (id_ex_data_q.rs2_addr),
        .id_ex_uses_rs1_i   (id_ex_data_q.uses_rs1),
        .id_ex_uses_rs2_i   (id_ex_data_q.uses_rs2),

        .ex_mem_valid_i     (ex_mem_valid),
        .ex_mem_rd_addr_i   (ex_mem_data_q.rd_addr),
        .ex_mem_reg_we_i    (ex_mem_data_q.reg_we),
        .ex_mem_load_re_i   (ex_mem_data_q.mem_re),
        .ex_mem_csr_re_i    (ex_mem_data_q.csr_writes_rd),

        .mem_wb_valid_i     (mem_wb_valid),
        .mem_wb_rd_addr_i   (mem_wb_data_q.rd_addr),
        .mem_wb_reg_we_i    (mem_wb_data_q.reg_we),

        .id_ex_rs1_rdata_i  (id_ex_data_q.rs1_rdata),
        .id_ex_rs2_rdata_i  (id_ex_data_q.rs2_rdata),
        .ex_mem_wb_sel_i    (ex_mem_data_q.wb_sel),
        .ex_mem_alu_result_i(ex_mem_data_q.alu_result),
        .ex_mem_pc_plus4_i  (ex_mem_data_q.pc_plus4),
        .ex_mem_imm_i       (ex_mem_data_q.imm),
        .mem_wb_wdata_i     (wb_rd_wdata),

        .rs1_fwd_o          (ex_rs1_op_data),
        .rs2_fwd_o          (ex_rs2_op_data)
    );

    pipe_reg_id_ex u_pipe_reg_id_ex (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .data_i     (id_ex_data_d),
        .valid_i    (id_valid),
        .kill_i     (kill_id_ex),     // trap control hazard
        .flush_i    (flush_id_ex),    // base control hazard
        .bubble_i   (bubble_ex),
        .stall_i    (1'b0), // EX 在当前设计不会 stall，为后续扩展保留（比如可变延迟 memory 需要全流水线暂停时）

        .data_o     (id_ex_data_q),
        .valid_o    (id_ex_valid)
    );

    // ID/EX 输入组包。控制信号从 ID 生成，随指令进入 EX。
    assign id_ex_data_d.rs1_addr      = id_rs1_addr;
    assign id_ex_data_d.rs2_addr      = id_rs2_addr;
    assign id_ex_data_d.uses_rs1      = id_uses_rs1;
    assign id_ex_data_d.uses_rs2      = id_uses_rs2;
    assign id_ex_data_d.illegal_instr = id_illegal_instr;
    assign id_ex_data_d.instr_id      = id_instr_id;

    assign id_ex_data_d.rd_addr       = id_rd_addr;
    assign id_ex_data_d.alu_op        = id_alu_op;
    assign id_ex_data_d.op_a_sel      = id_op_a_sel;
    assign id_ex_data_d.op_b_sel      = id_op_b_sel;
    assign id_ex_data_d.reg_we        = id_rd_we;
    assign id_ex_data_d.wb_sel        = id_wb_sel;
    assign id_ex_data_d.mem_re        = id_mem_re;
    assign id_ex_data_d.mem_we        = id_mem_we;
    assign id_ex_data_d.mem_size      = id_mem_size;
    assign id_ex_data_d.mem_unsigned  = id_mem_unsigned;
    assign id_ex_data_d.branch_op     = id_branch_op;
    assign id_ex_data_d.jump          = id_jump;
    assign id_ex_data_d.jalr          = id_jalr;
    assign id_ex_data_d.imm           = id_imm;
    assign id_ex_data_d.rs1_rdata     = id_rs1_rdata;
    assign id_ex_data_d.rs2_rdata     = id_rs2_rdata;

    assign id_ex_data_d.pc            = if_id_data_q.pc;        // 此类为中间寄存器直接透传
    assign id_ex_data_d.pc_plus4      = if_id_data_q.pc_plus4;
    assign id_ex_data_d.instr         = if_id_data_q.instr;

    assign id_ex_data_d.exception_valid = id_exception_valid;
    assign id_ex_data_d.exception_cause = id_exception_cause;
    assign id_ex_data_d.exception_tval  = id_exception_tval;
    assign id_ex_data_d.fence           = id_fence;
    assign id_ex_data_d.mret            = id_mret;
    assign id_ex_data_d.csr             = id_csr;
    assign id_ex_data_d.csr_op          = id_csr_op;
    assign id_ex_data_d.csr_addr        = id_csr_addr;
    assign id_ex_data_d.csr_uimm        = id_csr_uimm;
    assign id_ex_data_d.csr_uses_rs1    = id_csr_uses_rs1;
    assign id_ex_data_d.csr_writes_rd   = id_csr_writes_rd;
    assign id_ex_data_d.csr_write_en    = id_csr_write_en;

    ex_stage u_ex_stage (
        .valid_i            (id_ex_valid),
        .pc_i               (id_ex_data_q.pc),
        .rs1_data_i         (ex_rs1_op_data),
        .rs2_data_i         (ex_rs2_op_data),
        .imm_i              (id_ex_data_q.imm),
        .alu_op_i           (id_ex_data_q.alu_op),
        .op_a_sel_i         (id_ex_data_q.op_a_sel),
        .op_b_sel_i         (id_ex_data_q.op_b_sel),
        .branch_op_i        (id_ex_data_q.branch_op),
        .jump_i             (id_ex_data_q.jump),
        .jalr_i             (id_ex_data_q.jalr),

        .exception_valid_i  (id_ex_data_q.exception_valid),
        .exception_cause_i  (id_ex_data_q.exception_cause),
        .exception_tval_i   (id_ex_data_q.exception_tval),
        .csr_i              (id_ex_data_q.csr),
        .csr_op_i           (id_ex_data_q.csr_op),
        .csr_uimm_i         (id_ex_data_q.csr_uimm),
        .mret_i             (id_ex_data_q.mret),

        .valid_o            (ex_valid),
        .alu_result_o       (ex_alu_result),
        .store_data_o       (ex_store_data),
        .redirect_valid_o   (ex_redirect_valid),
        .redirect_pc_o      (ex_redirect_pc),

        .exception_valid_o  (ex_exception_valid),
        .exception_cause_o  (ex_exception_cause),
        .exception_tval_o   (ex_exception_tval),
        .csr_operand_o      (ex_csr_operand),
        .mret_o             (ex_mret)
    );

    pipe_reg_ex_mem u_pipe_reg_ex_mem (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .data_i     (ex_mem_data_d),
        .valid_i    (ex_valid),
        .kill_i     (kill_ex_mem),     // trap control hazard
        .stall_i    (1'b0), // 为后续扩展保留

        .data_o     (ex_mem_data_q),
        .valid_o    (ex_mem_valid)
    );

    // EX/MEM 输入组包。EX 结果和仍需后传的控制信号在这里汇总。
    assign ex_mem_data_d.illegal_instr = id_ex_data_q.illegal_instr;    // 此类为中间寄存器透传
    assign ex_mem_data_d.instr_id      = id_ex_data_q.instr_id;

    assign ex_mem_data_d.alu_result    = ex_alu_result;     // 此类为上一阶段结果
    assign ex_mem_data_d.store_data    = ex_store_data;

    assign ex_mem_data_d.mem_re        = id_ex_data_q.mem_re;
    assign ex_mem_data_d.mem_we        = id_ex_data_q.mem_we;
    assign ex_mem_data_d.mem_size      = id_ex_data_q.mem_size;
    assign ex_mem_data_d.mem_unsigned  = id_ex_data_q.mem_unsigned;
    assign ex_mem_data_d.wb_sel        = id_ex_data_q.wb_sel;
    assign ex_mem_data_d.reg_we        = id_ex_data_q.reg_we;
    assign ex_mem_data_d.pc_plus4      = id_ex_data_q.pc_plus4;
    assign ex_mem_data_d.imm           = id_ex_data_q.imm;
    assign ex_mem_data_d.rd_addr       = id_ex_data_q.rd_addr;
    assign ex_mem_data_d.instr         = id_ex_data_q.instr;
    assign ex_mem_data_d.pc            = id_ex_data_q.pc;

    assign ex_mem_data_d.exception_valid = ex_exception_valid;
    assign ex_mem_data_d.exception_cause = ex_exception_cause;
    assign ex_mem_data_d.exception_tval  = ex_exception_tval;
    assign ex_mem_data_d.fence           = id_ex_data_q.fence;
    assign ex_mem_data_d.mret            = ex_mret;
    assign ex_mem_data_d.csr             = id_ex_data_q.csr;
    assign ex_mem_data_d.csr_op          = id_ex_data_q.csr_op;
    assign ex_mem_data_d.csr_addr        = id_ex_data_q.csr_addr;
    assign ex_mem_data_d.csr_operand     = ex_csr_operand;
    assign ex_mem_data_d.csr_writes_rd   = id_ex_data_q.csr_writes_rd;
    assign ex_mem_data_d.csr_write_en    = id_ex_data_q.csr_write_en;

    mem_stage u_mem_stage (
        .valid_i            (ex_mem_valid),
        .alu_result_i       (ex_mem_data_q.alu_result),
        .store_data_i       (ex_mem_data_q.store_data),
        .mem_re_i           (ex_mem_data_q.mem_re),
        .mem_we_i           (ex_mem_data_q.mem_we),
        .mem_size_i         (ex_mem_data_q.mem_size),
        .mem_unsigned_i     (ex_mem_data_q.mem_unsigned),
        .dmem_rdata_i       (dmem_rdata_i),

        .exception_valid_i  (ex_mem_data_q.exception_valid),
        .exception_cause_i  (ex_mem_data_q.exception_cause),
        .exception_tval_i   (ex_mem_data_q.exception_tval),

        .valid_o            (mem_valid),
        .dmem_re_o          (dmem_re_o),

        .dmem_we_o          (dmem_we_o),
        .dmem_be_o          (dmem_be_o),
        .dmem_addr_o        (dmem_addr_o),
        .dmem_wdata_o       (dmem_wdata_o),
        .load_data_o        (mem_load_data),

        .mem_misaligned_o   (mem_misaligned_o),
        .load_misaligned_o  (mem_load_misaligned),
        .store_misaligned_o (mem_store_misaligned),
        .exception_valid_o  (mem_exception_valid),
        .exception_cause_o  (mem_exception_cause),
        .exception_tval_o   (mem_exception_tval)
    );

    // 与 mem_stage “并连”
    assign mem_csr_valid = ex_mem_valid & ex_mem_data_q.csr & ~mem_exception_valid;
    csr_file u_csr_file (
        .clk_i              (clk_i),
        .rst_n_i            (rst_n_i),

        .csr_valid_i        (mem_csr_valid),
        .csr_op_i           (ex_mem_data_q.csr_op),
        .csr_addr_i         (ex_mem_data_q.csr_addr),
        .csr_operand_i      (ex_mem_data_q.csr_operand),
        .csr_write_en_i     (ex_mem_data_q.csr_write_en),

        .csr_rdata_o        (mem_csr_rdata),
        .csr_illegal_o      (mem_csr_illegal),

        .trap_valid_i       (trap_valid),
        .trap_pc_i          (trap_pc),
        .trap_cause_i       (trap_cause),
        .trap_tval_i        (trap_tval),

        .mret_valid_i       (mret_valid),

        .mtvec_o            (csr_mtvec),
        .mepc_o             (csr_mepc),
        .mstatus_o          (csr_mstatus)
    );

    trap_ctrl u_trap_ctrl (
        .mem_valid_i            (ex_mem_valid),
        .mem_pc_i               (ex_mem_data_q.pc),
        .mem_instr_i            (ex_mem_data_q.instr),
        .mem_mret_i             (ex_mem_data_q.mret),

        .mem_exception_valid_i  (mem_exception_valid),
        .mem_exception_cause_i  (mem_exception_cause),
        .mem_exception_tval_i   (mem_exception_tval),

        .mem_csr_valid_i        (mem_csr_valid),
        .mem_csr_illegal_i      (mem_csr_illegal),

        .csr_mtvec_i            (csr_mtvec),
        .csr_mepc_i             (csr_mepc),

        .trap_valid_o           (trap_valid),
        .trap_pc_o              (trap_pc),
        .trap_cause_o           (trap_cause),
        .trap_tval_o            (trap_tval),

        .mret_valid_o           (mret_valid),

        .redirect_valid_o       (trap_redirect_valid),
        .redirect_pc_o          (trap_redirect_pc),

        .kill_if_id_o           (kill_if_id),
        .kill_id_ex_o           (kill_id_ex),
        .kill_ex_mem_o          (kill_ex_mem),
        .kill_mem_wb_o          (kill_mem_wb)
    );

    pipe_reg_mem_wb u_pipe_reg_mem_wb (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .data_i     (mem_wb_data_d),
        .valid_i    (mem_valid),
        .kill_i     (kill_mem_wb),     // trap control hazard，终止改指令生命周期（已被 trap 提交）
        .stall_i    (1'b0), // 为后续扩展保留

        .data_o     (mem_wb_data_q),
        .valid_o    (mem_wb_valid)
    );

    // MEM/WB 输入组包。WB 使用这里保存的最终写回选择和数据。
    assign mem_wb_data_d.illegal_instr = ex_mem_data_q.illegal_instr;
    assign mem_wb_data_d.instr_id      = ex_mem_data_q.instr_id;

    assign mem_wb_data_d.load_data     = mem_load_data;

    assign mem_wb_data_d.reg_we        = ex_mem_data_q.reg_we;
    assign mem_wb_data_d.wb_sel        = ex_mem_data_q.wb_sel;
    assign mem_wb_data_d.alu_result    = ex_mem_data_q.alu_result;
    assign mem_wb_data_d.pc_plus4      = ex_mem_data_q.pc_plus4;
    assign mem_wb_data_d.imm           = ex_mem_data_q.imm;
    assign mem_wb_data_d.rd_addr       = ex_mem_data_q.rd_addr;
    assign mem_wb_data_d.instr         = ex_mem_data_q.instr;
    assign mem_wb_data_d.pc            = ex_mem_data_q.pc;

    assign mem_wb_data_d.csr_rdata     = mem_csr_rdata;

    wb_stage u_wb_stage (
        .valid_i        (mem_wb_valid),
        .reg_we_i       (mem_wb_data_q.reg_we),
        .wb_sel_i       (mem_wb_data_q.wb_sel),
        .alu_result_i   (mem_wb_data_q.alu_result),
        .load_data_i    (mem_wb_data_q.load_data),
        .pc_plus4_i     (mem_wb_data_q.pc_plus4),
        .imm_i          (mem_wb_data_q.imm),
        .csr_rdata_i    (mem_wb_data_q.csr_rdata),

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

    // TODO: 后续异常/非法指令处理应随流水线精确提交，这里先随 WB 槽观察。
    assign illegal_instr_o   = wb_valid & wb_illegal_instr;

endmodule

`default_nettype wire
