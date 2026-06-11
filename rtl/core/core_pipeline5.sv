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

    // 做 data hazard，接 hazard_unit。
    wire stall_if;
    wire stall_id;
    wire bubble_ex;

    // 全流水线暂停（如可变延迟 memory），当前不使用。
    // wire stall_pipeline = 1'b0;

    // 做 control hazard flush/kill，接 hazard_unit。
    wire flush_if_id;
    wire flush_id_ex;

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

    // forwarding 前递结果 -> EX 操作数
    wire [core_pkg::XLEN-1:0] ex_rs1_op_data;
    wire [core_pkg::XLEN-1:0] ex_rs2_op_data;

    // EX
    wire [core_pkg::XLEN-1:0] ex_alu_result;
    wire [core_pkg::XLEN-1:0] ex_store_data;

    // MEM
    wire [core_pkg::XLEN-1:0] mem_load_data;

    // WB 随指令输出 -> commit
    wire [core_pkg::ILEN-1:0] wb_instr          = mem_wb_data_q.instr;
    wire [core_pkg::XLEN-1:0] wb_pc             = mem_wb_data_q.pc;
    wire [4:0]                wb_rd_addr        = mem_wb_data_q.rd_addr;
    wire                      wb_illegal_instr  = mem_wb_data_q.illegal_instr;

    pc_reg u_pc_reg(
        .clk_i              (clk_i),
        .rst_n_i            (rst_n_i),

        .pc_plus4_i         (if_pc_plus4),
        .redirect_pc_i      (ex_redirect_pc),
        .redirect_valid_i   (ex_redirect_valid),
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
        .flush_i    (flush_if_id),
        .stall_i    (stall_id), // id 要 stall 一拍，让 IF/ID 保持不变

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

        .instr_id_o     (),     // 调试用，暂不连

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

    // hazard_unit 统一产生 data hazard stall/bubble 和 control hazard flush/kill。
    hazard_unit u_hazard_unit (
        .if_id_valid_i      (if_id_valid),
        .id_rs1_addr_i      (id_rs1_addr),
        .id_rs2_addr_i      (id_rs2_addr),
        .id_uses_rs1_i      (id_uses_rs1),
        .id_uses_rs2_i      (id_uses_rs2),

        .id_ex_valid_i      (id_ex_valid),
        .id_ex_rd_addr_i    (id_ex_data_q.rd_addr),
        .id_ex_mem_re_i     (id_ex_data_q.mem_re),

        .stall_if_o         (stall_if),
        .stall_id_o         (stall_id),
        .bubble_ex_o        (bubble_ex),

        .redirect_valid_i   (ex_redirect_valid),

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
        .ex_mem_mem_re_i    (ex_mem_data_q.mem_re),

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
        .flush_i    (flush_id_ex),
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

    assign id_ex_data_d.pc            = if_id_data_q.pc;
    assign id_ex_data_d.pc_plus4      = if_id_data_q.pc_plus4;
    assign id_ex_data_d.instr         = if_id_data_q.instr;

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

        .valid_o            (ex_valid),
        .alu_result_o       (ex_alu_result),
        .store_data_o       (ex_store_data),
        .redirect_valid_o   (ex_redirect_valid),
        .redirect_pc_o      (ex_redirect_pc)
    );

    pipe_reg_ex_mem u_pipe_reg_ex_mem (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .data_i     (ex_mem_data_d),
        .valid_i    (ex_valid),
        .stall_i    (1'b0), // 为后续扩展保留

        .data_o     (ex_mem_data_q),
        .valid_o    (ex_mem_valid)
    );

    // EX/MEM 输入组包。EX 结果和仍需后传的控制信号在这里汇总。
    assign ex_mem_data_d.alu_result    = ex_alu_result;
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
    assign ex_mem_data_d.illegal_instr = id_ex_data_q.illegal_instr;

    mem_stage u_mem_stage (
        .valid_i            (ex_mem_valid),
        .alu_result_i       (ex_mem_data_q.alu_result),
        .store_data_i       (ex_mem_data_q.store_data),
        .mem_re_i           (ex_mem_data_q.mem_re),
        .mem_we_i           (ex_mem_data_q.mem_we),
        .mem_size_i         (ex_mem_data_q.mem_size),
        .mem_unsigned_i     (ex_mem_data_q.mem_unsigned),
        .dmem_rdata_i       (dmem_rdata_i),

        .valid_o            (mem_valid),
        .mem_misaligned_o   (mem_misaligned_o),
        .dmem_re_o          (dmem_re_o),
        .dmem_we_o          (dmem_we_o),
        .dmem_be_o          (dmem_be_o),
        .dmem_addr_o        (dmem_addr_o),
        .dmem_wdata_o       (dmem_wdata_o),
        .load_data_o        (mem_load_data)
    );

    pipe_reg_mem_wb u_pipe_reg_mem_wb (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),

        .data_i     (mem_wb_data_d),
        .valid_i    (mem_valid),
        .stall_i    (1'b0), // 为后续扩展保留

        .data_o     (mem_wb_data_q),
        .valid_o    (mem_wb_valid)
    );

    // MEM/WB 输入组包。WB 使用这里保存的最终写回选择和数据。
    assign mem_wb_data_d.load_data     = mem_load_data;

    assign mem_wb_data_d.reg_we        = ex_mem_data_q.reg_we;
    assign mem_wb_data_d.wb_sel        = ex_mem_data_q.wb_sel;
    assign mem_wb_data_d.alu_result    = ex_mem_data_q.alu_result;
    assign mem_wb_data_d.pc_plus4      = ex_mem_data_q.pc_plus4;
    assign mem_wb_data_d.imm           = ex_mem_data_q.imm;
    assign mem_wb_data_d.rd_addr       = ex_mem_data_q.rd_addr;
    assign mem_wb_data_d.instr         = ex_mem_data_q.instr;
    assign mem_wb_data_d.pc            = ex_mem_data_q.pc;
    assign mem_wb_data_d.illegal_instr = ex_mem_data_q.illegal_instr;

    wb_stage u_wb_stage (
        .valid_i        (mem_wb_valid),
        .reg_we_i       (mem_wb_data_q.reg_we),
        .wb_sel_i       (mem_wb_data_q.wb_sel),
        .alu_result_i   (mem_wb_data_q.alu_result),
        .load_data_i    (mem_wb_data_q.load_data),
        .pc_plus4_i     (mem_wb_data_q.pc_plus4),
        .imm_i          (mem_wb_data_q.imm),

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
