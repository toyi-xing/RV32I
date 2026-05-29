//------------------------------------------------------------------------------
// 文件      : rtl/common/core_pkg.sv
// 用途      : RV32I 教学核的公共常量和类型定义。
//
// 规范：
//   - RTL 使用 SystemVerilog，优先采用 logic、always_comb、always_ff 风格。
//   - 本包中的参数和枚举由译码器、数据通路、流水线寄存器、存储器封装模块和测试平台共享。
//   - 架构假设集中放在这里，避免在核心里散落硬编码常量。
//------------------------------------------------------------------------------

package core_pkg;
    // XLEN 表示整数寄存器、ALU 操作数、数据存储器字，以及大多数架构数据通路信号的宽度。
    parameter int unsigned XLEN = 32;

    // ILEN 表示指令宽度。第一版只支持 32 bit 基础指令，不支持 C 压缩指令扩展。
    parameter int unsigned ILEN = 32;

    // RESET_PC 表示复位后取指阶段使用的第一条指令地址。
    parameter logic [XLEN-1:0] RESET_PC = 32'h0000_0000;

    // IMEM_BASE 表示软件可见的指令存储器起始地址。测试平台和链接脚本应把 .text 放在这里。
    parameter logic [XLEN-1:0] IMEM_BASE = 32'h0000_0000;

    // DMEM_BASE 表示软件可见的数据存储器起始地址。简单 RAM 封装模块可把它映射到内部 mem[0]。
    parameter logic [XLEN-1:0] DMEM_BASE = 32'h0001_0000;

    // opcode_e 按 0821 第 3 章的 opcode 速查表划分指令大类。
    // decoder 可以先根据 opcode 进入大类，再根据 funct3/funct7 区分具体指令。
    //
    // 注意：以下 opcode 在 RV32I 中全部正确。但在其他标准扩展下，
    // 部分 opcode 会新增指令（用 funct3/funct7 区分），仅靠 opcode 无法唯一确定指令。
    // 新增指令的列说明在其余扩展下需要检查 funct3/funct7 才能正确译码。
    //
    // RV64 会额外引入 OP-IMM-32 (7'b0011011) 和 OP-32 (7'b0111011) 两个 opcode，
    // 见下方注释掉的条目。
    typedef enum logic [6:0] {
        OPCODE_LOAD     = 7'b0000011,  // LOAD：LB、LH、LW、LBU、LHU。
                                       //   加扩展：F→FLW/FLD，D→FLD。
        // OPCODE_MISC_MEM = 7'b0001111,  // MISC-MEM：FENCE 等。暂不实现
                                       //   加扩展：Zihintpause→PAUSE 等。
        OPCODE_OP_IMM   = 7'b0010011,  // OP-IMM：I 类型 ALU 指令。
                                       //   加扩展：Zb*→位操作立即数变体。
        OPCODE_AUIPC    = 7'b0010111,  // AUIPC：rd = PC + U 类型立即数。
        OPCODE_STORE    = 7'b0100011,  // STORE：SB、SH、SW。
                                       //   加扩展：F→FSW/FSD，D→FSD。
        OPCODE_OP       = 7'b0110011,  // OP：R 类型 ALU 指令。
                                       //   加扩展：M→乘除，Zb*→数十条位操作，Zk→密码学。
        OPCODE_LUI      = 7'b0110111,  // LUI：rd = U 类型立即数。
        OPCODE_BRANCH   = 7'b1100011,  // BRANCH：条件分支。
        OPCODE_JALR     = 7'b1100111,  // JALR：寄存器间接跳转。
        OPCODE_JAL      = 7'b1101111   // JAL：PC 相对跳转。
        //OPCODE_SYSTEM   = 7'b1110011   // SYSTEM：ECALL、EBREAK、CSR。暂不实现
                                       //   加扩展：Zicsr→CSRRW/CSRRS/CSRRC 等。
        // RV64 新增：
        // OPCODE_OP_IMM_32 = 7'b0011011,  // OP-IMM-32：ADDIW、SLLIW、SRLIW、SRAIW。
        // OPCODE_OP_32     = 7'b0111011,  // OP-32：ADDW、SUBW、SLLW、SRLW、SRAW。
    } opcode_e;

    // instr_id_e 表示 decoder 识别出的具体 RV32I 主线指令，顺序按 0821 文档 1.1 表格排列。
    typedef enum logic [5:0] {
        INSTR_INVALID,

        INSTR_LUI,  INSTR_AUIPC,

        INSTR_ADDI, INSTR_SLTI, INSTR_SLTIU, INSTR_XORI, INSTR_ORI,
        INSTR_ANDI, INSTR_SLLI, INSTR_SRLI,  INSTR_SRAI,

        INSTR_ADD,  INSTR_SUB,  INSTR_SLT,   INSTR_SLTU, INSTR_XOR,
        INSTR_OR,   INSTR_AND,  INSTR_SLL,   INSTR_SRL,  INSTR_SRA,

        INSTR_LB,   INSTR_LH,   INSTR_LW,    INSTR_LBU,  INSTR_LHU,

        INSTR_SB,   INSTR_SH,   INSTR_SW,

        INSTR_BEQ,  INSTR_BNE,  INSTR_BLT,   INSTR_BGE,  INSTR_BLTU,
        INSTR_BGEU,

        INSTR_JAL,  INSTR_JALR

        // 以下为暂不实现的标准 RV32I 指令：
        // INSTR_FENCE,
        // INSTR_ECALL, INSTR_EBREAK
    } instr_id_e;

    // imm_sel_e 告诉 imm_gen 按哪一种 RISC-V 立即数格式拼接和扩展。
    typedef enum logic [2:0] {
        IMM_NONE,  // 该指令不使用立即数。
        IMM_I,     // I 类型立即数：OP-IMM、LOAD、JALR。
        IMM_S,     // S 类型立即数：STORE。
        IMM_B,     // B 类型分支偏移；最低位已经补 0。
        IMM_U,     // U 类型高位立即数：LUI、AUIPC。
        IMM_J      // J 类型跳转偏移；最低位已经补 0。
    } imm_sel_e;

    // alu_op_e 选择 alu.sv 要执行的运算。访存读写地址计算也使用 ALU_ADD。
    typedef enum logic [3:0] {
        ALU_NONE,  // 不使用 ALU，输出结果固定为 0。
        ALU_ADD,   // 加法：ADD、ADDI、地址计算、AUIPC。
        ALU_SUB,   // 减法：SUB，也可辅助比较逻辑。
        ALU_SLL,   // 逻辑左移。
        ALU_SLT,   // 有符号小于比较；结果为 0 或 1。
        ALU_SLTU,  // 无符号小于比较；结果为 0 或 1。
        ALU_XOR,   // 按位异或。
        ALU_SRL,   // 逻辑右移。
        ALU_SRA,   // 算术右移。
        ALU_OR,    // 按位或。
        ALU_AND    // 按位与。
    } alu_op_e;

    // branch_op_e 描述分支指令需要执行哪种比较。BR_NONE 表示不是条件分支。
    typedef enum logic [2:0] {
        BR_NONE,
        BR_EQ,     // 相等：BEQ。
        BR_NE,     // 不相等：BNE。
        BR_LT,     // 有符号小于：BLT。
        BR_GE,     // 有符号大于等于：BGE。
        BR_LTU,    // 无符号小于：BLTU。
        BR_GEU     // 无符号大于等于：BGEU。
    } branch_op_e;

    // wb_sel_e 选择 WB 阶段写回 rd 的数据来源。
    typedef enum logic [1:0] {
        WB_ALU,    // 写回 ALU 结果。
        WB_MEM,    // 写回数据存储器读出的访存读数据。
        WB_PC4,    // 写回 PC + 4，用于 JAL/JALR link。
        WB_IMM     // 写回立即数，用于 LUI。
    } wb_sel_e;

    // mem_size_e 描述 load/store 的访问宽度。
    typedef enum logic [1:0] {
        MEM_BYTE,  // 8 bit 存储器访问：LB、LBU、SB。
        MEM_HALF,  // 16 bit 存储器访问：LH、LHU、SH。
        MEM_WORD   // 32 bit 存储器访问：LW、SW。
    } mem_size_e;

    // op_a_sel_e 选择 ALU 第一个操作数。
    typedef enum logic [1:0] {
        OP_A_RS1,  // 使用 rs1 寄存器读出的数据。
        OP_A_PC,   // 使用当前指令 PC，AUIPC/branch/JAL 会用到。
        OP_A_ZERO  // 使用 0，可用于常量路径或 NOP 类路径。
    } op_a_sel_e;

    // op_b_sel_e 选择主 ALU 的第二个操作数。普通顺序 PC+4 由 IF 阶段单独计算，不复用主 ALU。
    typedef enum logic {
        OP_B_RS2,  // 使用 rs2 寄存器读出的数据。
        OP_B_IMM   // 使用 imm_gen 生成的立即数。
        // OP_B_FOUR  // 使用常数 4；保留给需要主 ALU 显式计算加 4 的可选实现，第一版不复用 ALU 进行 PC+4,避免结构冒险。
    } op_b_sel_e;

endpackage
