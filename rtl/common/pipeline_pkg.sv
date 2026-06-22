//------------------------------------------------------------------------------
// 文件      : rtl/common/pipeline_pkg.sv
// 用途      : RV32I 五级流水线教学核的流水线专用类型定义。
//
//          用来定义中间寄存器的 data 字段（非 valid 字段），避免在 rtl/core/pipe_reg.sv 中反复定义与连线。
//
// 规范：
//   - 本包中的类型由流水线寄存器模块和 core 共享。
//   - 引用 core_pkg 中的 XLEN、ILEN 和枚举常量。
//   - 结构体成员顺序按 IF/ID、ID/EX、EX/MEM、MEM/WB 的数据流分组维护。
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
    typedef struct packed {
        logic [core_pkg::XLEN-1:0] pc;
        logic [core_pkg::ILEN-1:0] instr;
        logic [core_pkg::XLEN-1:0] pc_plus4;
    } if_id_reg_t;

    // ID/EX 流水线寄存器：锁存 ID 阶段输出的全部控制信号和数据通路值。
    // rs1_addr/rs2_addr 来自 decoder 输出，置于 rd_addr 之前以对应端口顺序。
    typedef struct packed {
        logic [4:0]                 rs1_addr;      // rs_addr本身不会再EX阶段用，但 step 3 加 forwarding_unit 时需要
        logic [4:0]                 rs2_addr;
        logic                       uses_rs1;      // 同样 forwarding 以及 hazard 要用
        logic                       uses_rs2;
        logic                       illegal_instr; // 非法/暂未支持指令标志，随指令传到后级用于调试观察
        core_pkg::instr_id_e        instr_id;

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

        // CSR、trap 相关
        logic                       exception_valid;        // exception：非法指令、非法 CSR 访问、ECALL、EBREAK、地址不对齐时置位
        core_pkg::excp_cause_e      exception_cause;
        logic [core_pkg::XLEN-1:0]  exception_tval;
        logic                       fence;                  // 仅 FENCE 指令时置位，当前 fence 指令实现为 nop
        logic                       mret;                   // 仅 MRET 指令时置位
        logic                       csr;                    // 仅 CSR 指令时置位
        core_pkg::csr_op_e          csr_op;
        logic [11:0]                csr_addr;
        logic [4:0]                 csr_uimm;
        logic                       csr_uses_rs1;           // 用于可能的 EX 阶段 forwarding
        logic                       csr_writes_rd;          // CSR 旧值写回 rd
        logic                       csr_write_en;           // 写 CSR 寄存器

    } id_ex_reg_t;

    // EX/MEM 流水线寄存器：锁存 EX 阶段的 ALU 结果、store 数据和控制信号。
    typedef struct packed {
        logic                       illegal_instr;
        core_pkg::instr_id_e        instr_id;

        logic [core_pkg::XLEN-1:0]  alu_result;
        logic [core_pkg::XLEN-1:0]  store_data;

        logic                       mem_re;     // load 使能，实际用来确定本条为 load 指令
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

        // CSR、trap 相关
        logic                       exception_valid;
        core_pkg::excp_cause_e      exception_cause;
        logic [core_pkg::XLEN-1:0]  exception_tval;
        logic                       fence;
        logic                       mret;
        logic                       csr;
        core_pkg::csr_op_e          csr_op;
        logic [11:0]                csr_addr;
        logic [core_pkg::XLEN-1:0]  csr_operand;
        logic                       csr_writes_rd;
        logic                       csr_write_en;
        logic [core_pkg::XLEN-1:0]  next_pc;        // 记录 ex 后确定的本指令的下条 pc 地址，若中断需存到 mepc 中
    } ex_mem_reg_t;

    // MEM/WB 流水线寄存器：锁存 MEM 阶段的 load 数据、ALU 结果和控制信号。
    typedef struct packed {
        logic                       illegal_instr;
        core_pkg::instr_id_e        instr_id;

        logic [core_pkg::XLEN-1:0]  load_data;

        logic                       reg_we;
        core_pkg::wb_sel_e          wb_sel;
        logic [core_pkg::XLEN-1:0]  alu_result;
        logic [core_pkg::XLEN-1:0]  pc_plus4;
        logic [core_pkg::XLEN-1:0]  imm;
        logic [4:0]                 rd_addr;
        logic [core_pkg::ILEN-1:0]  instr;
        logic [core_pkg::XLEN-1:0]  pc;

        // CSR、trap 相关
        logic [core_pkg::XLEN-1:0]  csr_rdata;      // 原子读的旧值，写回给 rd，到 MEM/WB 之后，CSR 指令已经被“翻译”成普通 WB 行为了，因此不需要其他的控制信号了
    } mem_wb_reg_t;

endpackage
