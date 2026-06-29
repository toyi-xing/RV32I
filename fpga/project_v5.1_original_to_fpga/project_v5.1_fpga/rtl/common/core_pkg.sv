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

    // | 区域 | 起始地址 | 结束地址 | 大小 |
    // |---|---:|---:|---:|
    // | IMEM | `0x0000_0000` | `0x0000_3FFF` | 16 KiB |
    // | DMEM | `0x0004_0000` | `0x0004_3FFF` | 16 KiB |
    // | MMIO | `0x0008_0000` | `0x0008_FFFF` | 64 KiB |

    // 当前平台的 IMEM/DMEM 容量。ADDR_WIDTH 表示 32-bit word index 宽度。
    parameter int unsigned IMEM_ADDR_WIDTH = 12;
    parameter int unsigned DMEM_ADDR_WIDTH = 12;

    // RAM、ROM 地址位宽按 word 算，而 CPU 地址按 Byte 算

    // IMEM_BASE 表示软件可见的指令存储器起始地址。测试平台和链接脚本应把 .text 放在这里。
    parameter logic [XLEN-1:0] IMEM_BASE       = 32'h0000_0000;
    parameter logic [XLEN-1:0] IMEM_SIZE_BYTES = 32'h0000_4000;

    // RESET_PC 表示复位后取指阶段使用的第一条指令地址。
    parameter logic [XLEN-1:0] RESET_PC = IMEM_BASE;

    // MTVEC_RESET 表示 M-mode trap vector 的平台默认复位值。
    // 当前采用 direct mode，低 2 bit 必须为 0；软件启动后仍建议显式写 mtvec。
    parameter logic [XLEN-1:0] MTVEC_RESET = IMEM_BASE + 32'h0000_0080;

    // DMEM_BASE 表示软件可见的数据存储器起始地址。简单 RAM 封装模块可把它映射到内部 mem[0]。
    parameter logic [XLEN-1:0] DMEM_BASE       = 32'h0004_0000;
    parameter logic [XLEN-1:0] DMEM_SIZE_BYTES = 32'h0000_4000;

    //-----------------------------------------------
    // OPCODE 与 instr_id 编码及支持情况
    //-----------------------------------------------

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
        OPCODE_JAL      = 7'b1101111,  // JAL：PC 相对跳转。

        OPCODE_MISC_MEM = 7'b0001111,  // MISC-MEM：FENCE 等。
                                       //   加扩展：Zihintpause→PAUSE 等。
        OPCODE_SYSTEM   = 7'b1110011   // SYSTEM：ECALL、EBREAK、MRET、CSR。

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

        INSTR_JAL,  INSTR_JALR,

        // 补齐 40 条 RV32I 全部指令
        INSTR_FENCE,
        INSTR_ECALL, INSTR_EBREAK,

        // 特权架构指令
        INSTR_MRET,

        // Zicsr 扩展指令，用于 CSR 读/写/置位/清位
        INSTR_CSRRW,    INSTR_CSRRS,    INSTR_CSRRC,
        INSTR_CSRRWI,   INSTR_CSRRSI,   INSTR_CSRRCI
    } instr_id_e;

    //-----------------------------------------------
    // RV32I 基础
    //-----------------------------------------------

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
    typedef enum logic [2:0] {
        WB_ALU,    // 写回 ALU 结果。
        WB_MEM,    // 写回数据存储器读出的访存读数据。
        WB_PC4,    // 写回 PC + 4，用于 JAL/JALR link。
        WB_IMM,    // 写回立即数，用于 LUI。
        WB_CSR     // CSR 原子读写回
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

    //-----------------------------------------------
    // CSR 、特权级、trap 相关
    //-----------------------------------------------

    // 本项目规划：
    // CSR 旧值读出：MEM 级（csr_file 内组合读 mux）；
    // CSR 写源数据生成：EX 级（rs1 forwarding 或 uimm 扩展，不涉及 CSR 旧值）；
    // CSR 新值计算 + 写回：MEM 级（csr_file 内读改写原子完成）；
    // CSR 旧值写回 GPR：WB 级（csr_rdata 经 MEM/WB → wb_stage WB_CSR mux）

    // CSR 地址常量（12 位，对应 RISC-V Privileged Spec 定义的 CSR 地址空间）
    // CSR 指令可读可写
    parameter logic [11:0] CSR_ADDR_MSTATUS    = 12'h300;   // 全局中断、特权栈、各种使能
    parameter logic [11:0] CSR_ADDR_MIE        = 12'h304;   // 中断使能
    parameter logic [11:0] CSR_ADDR_MTVEC      = 12'h305;   // trap 跳转地址
    parameter logic [11:0] CSR_ADDR_MSCRATCH   = 12'h340;   // 硬件存在，软件自由读写（便签）
    parameter logic [11:0] CSR_ADDR_MEPC       = 12'h341;   // trap 返回地址
    parameter logic [11:0] CSR_ADDR_MCAUSE     = 12'h342;   // trap 原因（值相同时，异常/中断也代表不同原因）
    parameter logic [11:0] CSR_ADDR_MTVAL      = 12'h343;   // 异常附加信息，不同异常对应不同内容（如非法指令写指令码），中断写 0

    // CSR指令只读，固定或硬件自动写
    parameter logic [11:0] CSR_ADDR_MIP        = 12'h344;   // 中断挂起，硬件自动写
    parameter logic [11:0] CSR_ADDR_MISA       = 12'h301;   // ISA 扩展标识（如 RV32I）
    parameter logic [11:0] CSR_ADDR_MVENDORID  = 12'hF11;   // 厂商 ID
    parameter logic [11:0] CSR_ADDR_MARCHID    = 12'hF12;   // 架构 ID
    parameter logic [11:0] CSR_ADDR_MIMPID     = 12'hF13;   // 实现 ID
    parameter logic [11:0] CSR_ADDR_MHARTID    = 12'hF14;   // 硬件线程 ID

    // mstatus 寄存器关键 bit 位置常量（当前实现部分）。
    parameter int MSTATUS_MIE_BIT   = 3;    // 全局中断总开关
    parameter int MSTATUS_MPIE_BIT  = 7;    // 中断开关备份位
    parameter int MSTATUS_MPP_LSB   = 11;
    parameter int MSTATUS_MPP_MSB   = 12;
    // MPP 特权级编码。
    parameter logic [1:0] MSTATUS_MPP_M = 2'b11;    // 特权级编码，当前仅 M mode，由 mstatus 的 MPP 字段存储

    // mcause 寄存器
    parameter int MCAUSE_INTERRUPT_BIT = XLEN - 1;  // 1 表示中断，0 表示异常

    // mie 寄存器关键 bit 位置常量（当前实现部分）。
    // parameter int MIE_MSIE_BIT  = 3;    // 软件中断开关
    parameter int MIE_MTIE_BIT  = 7;    // Timer 中断开关
    parameter int MIE_MEIE_BIT  = 11;   // 外部中断开关
    // mip 寄存器关键 bit 位置常量（当前实现部分）。
    // parameter int MIP_MSIP_BIT  = 3;
    parameter int MIP_MTIP_BIT  = 7;
    parameter int MIP_MEIP_BIT  = 11;

    // csr_op_e 指示 CSR 指令在 CSR 文件（csr_file.sv）中执行哪种位操作。
    // decoder 根据 funct3 产生，经 ID/EX、EX/MEM 传到 MEM/csr_file 用于计算 CSR 新值：
    //   CSR_OP_RW / RWI：new = wdata
    //   CSR_OP_RS / RSI：new = old | wdata
    //   CSR_OP_RC / RCI：new = old & ~wdata
    typedef enum logic [2:0] {
        CSR_OP_NONE,  // 非 CSR 指令，不写 CSR。
        CSR_OP_RW,    // CSRRW：CSR = rs1（总是写）。
        CSR_OP_RS,    // CSRRS：CSR = CSR | rs1，按位置位；rs1=x0 时不写。
        CSR_OP_RC,    // CSRRC：CSR = CSR & ~rs1，按位清除；rs1=x0 时不写。
        CSR_OP_RWI,   // CSRRWI：CSR = uimm（总是写）。
        CSR_OP_RSI,   // CSRRSI：CSR = CSR | uimm；uimm=0 时不写。
        CSR_OP_RCI    // CSRRCI：CSR = CSR & ~uimm；uimm=0 时不写。
    } csr_op_e;

    // excp_cause_e 和 irq_cause_e 都表示 mcause 低 5 bit code；
    // 最终由 mcause 最高位区分 exception 和 interrupt。
    // 注释掉的是本阶段不实现的条目，保留枚举值便于后续扩展。
    // excp_cause_e 只表示同步 exception 类型，编码对应 RISC-V Privileged Spec 中 mcause 的 Exception Code。
    typedef enum logic [4:0] {
        EXCEPTION_CAUSE_INST_ADDR_MISALIGNED   = 5'd0,    // 触发源：pc 重定向地址非法
        // EXCEPTION_CAUSE_INST_ACCESS_FAULT   = 5'd1,       // 暂不做：无访问错误模型
        EXCEPTION_CAUSE_ILLEGAL_INSTR          = 5'd2,    // 触发源：INSTR_INVALID（包含非法 SYSTEM 编码） + 非法 CSR 访问(访问不存在的 CSR 或写只读 CSR)
        EXCEPTION_CAUSE_BREAKPOINT             = 5'd3,    // 触发源：EBREAK 指令
        EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED   = 5'd4,    // 触发源：load 指令给出的 mem 地址不对齐
        EXCEPTION_CAUSE_LOAD_ACCESS_FAULT      = 5'd5,    // 触发源：load 访问错误（地址不存在 / 不允许读）
        EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED  = 5'd6,    // 触发源：store 指令给出的 mem 地址不对齐
        EXCEPTION_CAUSE_STORE_ACCESS_FAULT     = 5'd7,    // 触发源：store/AMO（原子写）访问错误（AMO目前不涉及，且AMO不允许读也会触发）
        // EXCEPTION_CAUSE_ECALL_U             = 5'd8,       // 暂不做：只有 M-mode
        // EXCEPTION_CAUSE_ECALL_S             = 5'd9,       // 暂不做：只有 M-mode
        // EXCEPTION_CAUSE_RESERVED_10         = 5'd10,   // RISC-V 保留
        EXCEPTION_CAUSE_ECALL_M                = 5'd11    // 触发源：ECALL 指令
        // EXCEPTION_CAUSE_INST_PAGE_FAULT     = 5'd12,      // 暂不做：无 MMU
        // EXCEPTION_CAUSE_LOAD_PAGE_FAULT     = 5'd13,      // 暂不做：无 MMU
        // EXCEPTION_CAUSE_RESERVED_14         = 5'd14,   // RISC-V 保留
        // EXCEPTION_CAUSE_STORE_PAGE_FAULT    = 5'd15,      // 暂不做：无 MMU
    } excp_cause_e;
    typedef enum logic [4:0] {
        // IRQ_CAUSE_U_SOFTWARE           = 5'd0,    // 暂不做：只有 M-mode
        // IRQ_CAUSE_S_SOFTWARE           = 5'd1,    // 暂不做：只有 M-mode
        // IRQ_CAUSE_RESERVED_IRQ_2       = 5'd2,    // RISC-V 保留
        // IRQ_CAUSE_M_SOFTWARE           = 5'd3,    // 暂不做：MSIP 不在本阶段实现
        // IRQ_CAUSE_U_TIMER              = 5'd4,    // 暂不做：只有 M-mode
        // IRQ_CAUSE_S_TIMER              = 5'd5,    // 暂不做：只有 M-mode
        // IRQ_CAUSE_RESERVED_IRQ_6       = 5'd6,    // RISC-V 保留
        IRQ_CAUSE_M_TIMER              = 5'd7,    // 触发源：TIMER0 比较器 match
        // IRQ_CAUSE_U_EXTERNAL           = 5'd8,    // 暂不做：只有 M-mode
        // IRQ_CAUSE_S_EXTERNAL           = 5'd9,    // 暂不做：只有 M-mode
        // IRQ_CAUSE_RESERVED_IRQ_10      = 5'd10,   // RISC-V 保留
        IRQ_CAUSE_M_EXTERNAL           = 5'd11    // 触发源：GPIO/UART 外设中断输入
    } irq_cause_e;




endpackage
