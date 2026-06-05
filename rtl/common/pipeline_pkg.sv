//------------------------------------------------------------------------------
// 文件      : rtl/common/pipeline_pkg.sv
// 用途      : RV32I 五级流水线教学核的流水线专用类型定义。
//
// 规范：
//   - 本包中的类型由流水线寄存器模块和 core_pipeline5 共享。
//   - 引用 core_pkg 中的 XLEN、ILEN 和枚举常量。
//   - 结构体成员顺序与 core_single_cycle.sv 各阶段信号声明顺序一致。
//------------------------------------------------------------------------------

package pipeline_pkg;

    // forwarding 选择枚举。
    // FWD_GPR   不使用前递，直接取 regfile 输出。
    // FWD_EX_MEM  从 EX/MEM 寄存器取前递值。
    // FWD_MEM_WB  从 MEM/WB 寄存器取前递值。
    typedef enum logic [1:0] {
        FWD_GPR,
        FWD_EX_MEM,
        FWD_MEM_WB
    } fwd_sel_e;

    // ── 流水线寄存器结构体 ──

    // IF/ID 流水线寄存器：锁存 IF 阶段的 PC、指令、PC+4。
    // 成员顺序对应 core_single_cycle.sv 的 IF/ID 声明。
    typedef struct packed {
        // 声明顺序和单周期时保持一致
        logic [core_pkg::XLEN-1:0] pc;
        logic [core_pkg::ILEN-1:0] instr;
        logic [core_pkg::XLEN-1:0] pc_plus4;
    } if_id_reg_t;

    // ID/EX 流水线寄存器：锁存 ID 阶段输出的全部控制信号和数据通路值。
    // 成员顺序对应 core_single_cycle.sv 的 ID/EX 声明。
    // rs1_addr/rs2_addr 来自 decoder 输出，置于 rd_addr 之前以对应端口顺序。
    typedef struct packed {
        logic [4:0]                 rs1_addr;      // rs_addr本身不会再EX阶段用，但 step 3 加 forwarding_unit 时需要
        logic [4:0]                 rs2_addr;
        logic                       uses_rs1;      // 同样 forwarding 以及 hazard 要用
        logic                       uses_rs2;
        logic                       illegal_instr; // 单周期直接连了，但现在应随指令传递

        logic [4:0]                 rd_addr;
        core_pkg::alu_op_e          alu_op;
        core_pkg::op_a_sel_e        op_a_sel;
        core_pkg::op_b_sel_e        op_b_sel;
        logic                       reg_we;
        core_pkg::wb_sel_e          wb_sel;
        logic                       mem_re;
        logic                       mem_we;
        core_pkg::mem_size_e        mem_size;
        logic                       mem_unsigned;
        core_pkg::branch_op_e       branch_op;
        logic                       jump;
        logic                       jalr;
        logic [core_pkg::XLEN-1:0]  imm;
        logic [core_pkg::XLEN-1:0]  rs1_rdata;
        logic [core_pkg::XLEN-1:0]  rs2_rdata;

        logic [core_pkg::XLEN-1:0]  pc;
        logic [core_pkg::XLEN-1:0]  pc_plus4;
        logic [core_pkg::ILEN-1:0]  instr;
    } id_ex_reg_t;

    // EX/MEM 流水线寄存器：锁存 EX 阶段的 ALU 结果、store 数据和控制信号。
    // 成员顺序对应 core_single_cycle.sv 的 EX/MEM 声明。
    typedef struct packed {
        logic                       illegal_instr;

        logic [core_pkg::XLEN-1:0]  alu_result;
        logic [core_pkg::XLEN-1:0]  store_data;

        logic                       mem_re;
        logic                       mem_we;
        core_pkg::mem_size_e        mem_size;
        logic                       mem_unsigned;
        core_pkg::wb_sel_e          wb_sel;
        logic                       reg_we;
        logic [core_pkg::XLEN-1:0]  pc_plus4;
        logic [core_pkg::XLEN-1:0]  imm;
        logic [4:0]                 rd_addr;
        logic [core_pkg::ILEN-1:0]  instr;
        logic [core_pkg::XLEN-1:0]  pc;
    } ex_mem_reg_t;

    // MEM/WB 流水线寄存器：锁存 MEM 阶段的 load 数据、ALU 结果和控制信号。
    // 成员顺序对应 core_single_cycle.sv 的 MEM/WB 声明。
    typedef struct packed {
        logic                       illegal_instr;

        logic [core_pkg::XLEN-1:0]  load_data;

        logic                       reg_we;
        core_pkg::wb_sel_e          wb_sel;
        logic [core_pkg::XLEN-1:0]  alu_result;
        logic [core_pkg::XLEN-1:0]  pc_plus4;
        logic [core_pkg::XLEN-1:0]  imm;
        logic [4:0]                 rd_addr;
        logic [core_pkg::ILEN-1:0]  instr;
        logic [core_pkg::XLEN-1:0]  pc;
    } mem_wb_reg_t;

endpackage
