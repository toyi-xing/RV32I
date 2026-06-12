//------------------------------------------------------------------------------
// 文件      : rtl/core/decoder.sv
// 用途      : RV32I 指令译码器。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块是纯组合逻辑，不包含时钟或复位。
//   - 控制信号类型统一使用 core_pkg.sv 中定义的枚举。
//   - 译码器只负责“看懂指令并输出控制信号”，不读写寄存器堆，不改 PC，
//     不访问存储器，也不处理前递、停顿、冲刷。
//
// 功能：
//   - 从 instr_i 中拆出 opcode、funct3、funct7、rs1、rs2、rd。
//   - 根据指令编码生成立即数类型、ALU 操作、操作数选择、访存控制、
//     写回控制、分支比较类型和非法指令标记。
//   - 第一轮练习建议先实现 ADDI、ADD、SW，再逐步扩展 RV32I 主线指令。
//
// CSR、trap 相关功能：
//   - 支持 FENCE、ECALL、EBREAK、MRET 及 6 条 Zicsr 指令的译码。
//   - 输出 CSR 指令相关控制字段（csr_op、csr_addr、csr_uimm 等）。
//   - 产生基础 illegal instruction、EBREAK、ECALL 的 exception cause 和 tval。
//------------------------------------------------------------------------------

`default_nettype none

module decoder (
    input  logic [core_pkg::ILEN-1:0] instr_i,          // 当前需要译码的 32 bit 原始指令。

    output logic [6:0]                opcode_o,         // 指令 opcode 字段，来自 instr_i[6:0]。
    output logic [2:0]                funct3_o,         // 指令 funct3 字段，来自 instr_i[14:12]。
    output logic [6:0]                funct7_o,         // 指令 funct7 字段，来自 instr_i[31:25]。
    output logic [4:0]                rs1_addr_o,       // 源寄存器 rs1 编号，来自 instr_i[19:15]。
    output logic [4:0]                rs2_addr_o,       // 源寄存器 rs2 编号，来自 instr_i[24:20]。
    output logic [4:0]                rd_addr_o,        // 目的寄存器 rd 编号，来自 instr_i[11:7]。

    output core_pkg::instr_id_e       instr_id_o,       // 译码出的具体 RV32I 指令标识，用于后续控制信号生成或波形调试。

    output logic                      uses_rs1_o,       // 当前指令是否真的读取 rs1，用于 hazard 判断。
    output logic                      uses_rs2_o,       // 当前指令是否真的读取 rs2，用于 hazard 判断。

    output core_pkg::imm_sel_e        imm_sel_o,        // 立即数格式选择，控制 imm_gen 生成 I/S/B/U/J 立即数。
    output core_pkg::alu_op_e         alu_op_o,         // ALU 运算类型，控制 alu.sv 执行哪种运算。
    output core_pkg::op_a_sel_e       op_a_sel_o,       // ALU 第一个操作数选择，例如 rs1、PC 或 0。
    output core_pkg::op_b_sel_e       op_b_sel_o,       // ALU 第二个操作数选择，例如 rs2或立即数。对于 PC+4 使用单独的计算单元，不复用ALU

    output logic                      reg_we_o,         // 当前指令是否有写回通用寄存器 rd 的意图。
    output core_pkg::wb_sel_e         wb_sel_o,         // 写回数据来源选择，例如 ALU、load 数据、PC+4 或立即数。

    output logic                      mem_re_o,         // 当前指令是否是访存读指令。
    output logic                      mem_we_o,         // 当前指令是否是访存写指令。
    output core_pkg::mem_size_e       mem_size_o,       // 访存宽度选择，表示 byte、halfword 或 word。
    output logic                      mem_unsigned_o,   // load 数据是否零扩展；为 0 时表示符号扩展。

    output core_pkg::branch_op_e      branch_op_o,      // 条件分支比较类型；BR_NONE 表示不是条件分支。

    // CSR、trap 相关
    output logic                      csr_o,                    // 当前译码结果是否为 6 条 Zicsr CSR 指令之一；只是指令属性，不表示已经访问 CSR 文件。
    output core_pkg::csr_op_e         csr_op_o,                 // CSR 操作类型：RW/RS/RC/RWI/RSI/RCI。
    output logic [11:0]               csr_addr_o,               // CSR 地址字段，来自 instr_i[31:20]。
    output logic [4:0]                csr_uimm_o,               // CSR uimm 字段，来自 instr_i[19:15]。
    output logic                      csr_uses_rs1_o,           // CSR register 形式是否读取 rs1，用于 hazard/forwarding。
    output logic                      csr_writes_rd_o,          // CSR 指令是否把旧 CSR 值写回 GPR rd，通常为 rd_addr_o != 5'b0。
    output logic                      csr_write_en_o,           // CSR 指令是否尝试写 CSR，用于 CSR 文件写使能和只读 CSR 非法写判断。

    output logic                      exception_valid_o,        // decoder/ID 已能确认的 synchronous exception 是否有效。
    output core_pkg::trap_cause_e     exception_cause_o,        // decoder/ID exception 的 cause。
    output logic [core_pkg::XLEN-1:0] exception_tval_o,         // decoder/ID exception 的 tval。非法指令通常为原始指令，ECALL/EBREAK 为 0。

    output logic                      illegal_instr_o   // 当前指令是否非法或暂未支持。
);
    import core_pkg::*;

    assign opcode_o   = instr_i[6:0];
    assign rd_addr_o  = instr_i[11:7];
    assign funct3_o   = instr_i[14:12];
    assign rs1_addr_o = instr_i[19:15];
    assign rs2_addr_o = instr_i[24:20];
    assign funct7_o   = instr_i[31:25];

    // 查表 0821 文档 5.2 大类控制表
    wire base_uses_rs1    = ~illegal_instr_o & {((opcode_o == OPCODE_OP_IMM) || // I-type ALU (OP-IMM)
                                                 (opcode_o == OPCODE_OP)     || // R-type ALU
                                                 (opcode_o == OPCODE_LOAD)   || // load
                                                 (opcode_o == OPCODE_STORE)  || // store
                                                 (opcode_o == OPCODE_BRANCH) || // branch
                                                 (opcode_o == OPCODE_JALR))};   // jalr
    assign uses_rs1_o     =  base_uses_rs1 | csr_uses_rs1_o;        // uses_rs1 补充 CSR 指令
    wire base_uses_rs2    = ~illegal_instr_o & {((opcode_o == OPCODE_OP)     || // R-type ALU
                                                 (opcode_o == OPCODE_STORE)  || // store
                                                 (opcode_o == OPCODE_BRANCH))}; // branch
    assign uses_rs2_o     =  base_uses_rs2;

    // 查表 0821 文档 2.2 立即数生成规则
    assign imm_sel_o      = imm_sel_e'(((opcode_o == OPCODE_OP_IMM)     ||
                                        (opcode_o == OPCODE_LOAD)       ||
                                        (opcode_o == OPCODE_JALR))      ?   IMM_I :
                                        (opcode_o == OPCODE_STORE)      ?   IMM_S :
                                        (opcode_o == OPCODE_BRANCH)     ?   IMM_B :
                                       ((opcode_o == OPCODE_LUI)        ||
                                        (opcode_o == OPCODE_AUIPC))     ?   IMM_U :
                                        (opcode_o == OPCODE_JAL)         ?  IMM_J :
                                                                            IMM_NONE);
    // 查表 0821 文档 5.3 alu_op 译码查表。
    // 当前 instr_id_e 中共有 37 条有效主线指令，不包含 INSTR_INVALID。
    // 本 case 显式覆盖 36 条指令；唯一落入 default 的有效指令是 INSTR_LUI。
    // INSTR_LUI 后续可由 WB 直接选择立即数写回，不需要主 ALU 参与。
    // 非法指令或暂未识别的编码也会落入 default，使 ALU 输出 ALU_NONE。
    always_comb begin
        case (instr_id_o)
            INSTR_ADDI,  INSTR_ADD,
            INSTR_AUIPC,
            INSTR_LB,    INSTR_LH,    INSTR_LW,    INSTR_LBU,  INSTR_LHU,
            INSTR_SB,    INSTR_SH,    INSTR_SW,
            INSTR_BEQ,   INSTR_BNE,   INSTR_BLT,   INSTR_BGE,  INSTR_BLTU,
            INSTR_BGEU,
            INSTR_JAL,
            INSTR_JALR:                  alu_op_o = ALU_ADD;
            INSTR_SUB:                   alu_op_o = ALU_SUB;
            INSTR_SLTI,  INSTR_SLT:      alu_op_o = ALU_SLT;
            INSTR_SLTIU, INSTR_SLTU:     alu_op_o = ALU_SLTU;
            INSTR_XORI,  INSTR_XOR:      alu_op_o = ALU_XOR;
            INSTR_ORI,   INSTR_OR:       alu_op_o = ALU_OR;
            INSTR_ANDI,  INSTR_AND:      alu_op_o = ALU_AND;
            INSTR_SLLI,  INSTR_SLL:      alu_op_o = ALU_SLL;
            INSTR_SRLI,  INSTR_SRL:      alu_op_o = ALU_SRL;
            INSTR_SRAI,  INSTR_SRA:      alu_op_o = ALU_SRA;
            default:                     alu_op_o = ALU_NONE;
        endcase
    end
    // 查表 0821 文档 5.2 大类控制表
    always_comb begin
        case (opcode_o)
            OPCODE_LUI:                     op_a_sel_o = OP_A_ZERO;
            OPCODE_AUIPC,   OPCODE_JAL,     
            OPCODE_BRANCH:                  op_a_sel_o = OP_A_PC;
            OPCODE_OP_IMM,  OPCODE_OP,      OPCODE_LOAD,    
            OPCODE_STORE,   OPCODE_JALR:    op_a_sel_o = OP_A_RS1;
            default: op_a_sel_o = OP_A_ZERO;
        endcase
    end
    always_comb begin
        case (opcode_o)
            OPCODE_OP:                                                          op_b_sel_o = OP_B_RS2;
            OPCODE_LUI,     OPCODE_AUIPC,   OPCODE_OP_IMM,      OPCODE_LOAD,
            OPCODE_STORE,   OPCODE_JAL,     OPCODE_JALR,        OPCODE_BRANCH:  op_b_sel_o = OP_B_IMM;
            default: op_b_sel_o = OP_B_RS2;
        endcase
    end

    // 查表 0821 文档 5.2 大类控制表
    wire  base_writes_rd  = ~illegal_instr_o & {((opcode_o == OPCODE_LUI)    ||
                                                 (opcode_o == OPCODE_AUIPC)  ||
                                                 (opcode_o == OPCODE_OP_IMM) ||
                                                 (opcode_o == OPCODE_OP)     ||
                                                 (opcode_o == OPCODE_LOAD)   ||
                                                 (opcode_o == OPCODE_JAL)    ||
                                                 (opcode_o == OPCODE_JALR))};
    assign reg_we_o      = base_writes_rd | csr_writes_rd_o;  // rd 写回补充 CSR 指令
    // 查表 0821 文档 5.2 大类控制表
    always_comb begin
        case (opcode_o)
            OPCODE_LUI:                                 wb_sel_o = WB_IMM;
            OPCODE_LOAD:                                wb_sel_o = WB_MEM;
            OPCODE_OP_IMM,  OPCODE_AUIPC,   OPCODE_OP:  wb_sel_o = WB_ALU; 
            OPCODE_JAL,     OPCODE_JALR:                wb_sel_o = WB_PC4;
            OPCODE_SYSTEM:                              wb_sel_o = WB_CSR;  // system 指令只有 csr 写回 rd，其他 SYSTEM 指令不写回，wb_sel 无实意
            default: wb_sel_o = WB_ALU; 
        endcase
    end

    assign mem_re_o       = ~illegal_instr_o & {(opcode_o == OPCODE_LOAD)};
    assign mem_we_o       = ~illegal_instr_o & {(opcode_o == OPCODE_STORE)};
    always_comb begin
        case (instr_id_o)
            INSTR_LB, INSTR_LBU, INSTR_SB:  mem_size_o = MEM_BYTE;
            INSTR_LH, INSTR_LHU, INSTR_SH:  mem_size_o = MEM_HALF;
            INSTR_LW, INSTR_SW :            mem_size_o = MEM_WORD;
            default: mem_size_o = MEM_WORD;
        endcase
    end
    assign mem_unsigned_o = (instr_id_o == INSTR_LBU) || (instr_id_o == INSTR_LHU);

    always_comb begin
        case (instr_id_o)
            INSTR_BEQ:  branch_op_o = BR_EQ;
            INSTR_BNE:  branch_op_o = BR_NE;
            INSTR_BLT:  branch_op_o = BR_LT;
            INSTR_BGE:  branch_op_o = BR_GE;
            INSTR_BLTU: branch_op_o = BR_LTU;
            INSTR_BGEU: branch_op_o = BR_GEU;
            default:    branch_op_o = BR_NONE;
        endcase
    end

    // csr、trap 相关---------------------------------------------------------------------
    assign csr_o            = instr_id_o == INSTR_CSRRW  || instr_id_o == INSTR_CSRRS  || instr_id_o == INSTR_CSRRC  ||
                              instr_id_o == INSTR_CSRRWI || instr_id_o == INSTR_CSRRSI || instr_id_o == INSTR_CSRRCI;
    assign csr_op_o         = instr_id_o == INSTR_CSRRW  ? CSR_OP_RW  :
                              instr_id_o == INSTR_CSRRS  ? CSR_OP_RS  :
                              instr_id_o == INSTR_CSRRC  ? CSR_OP_RC  :
                              instr_id_o == INSTR_CSRRWI ? CSR_OP_RWI :
                              instr_id_o == INSTR_CSRRSI ? CSR_OP_RSI :
                              instr_id_o == INSTR_CSRRCI ? CSR_OP_RCI : CSR_OP_NONE;
    assign csr_addr_o       = instr_i[31:20];
    assign csr_uimm_o       = instr_i[19:15];

    wire   csr_op_reg      = instr_id_o == INSTR_CSRRW  || instr_id_o == INSTR_CSRRS || instr_id_o == INSTR_CSRRC;
    wire   csr_op_uimm     = instr_id_o == INSTR_CSRRWI || instr_id_o == INSTR_CSRRSI || instr_id_o == INSTR_CSRRCI;
    assign csr_uses_rs1_o  = csr_op_reg;
    assign csr_writes_rd_o = csr_o && (rd_addr_o != '0);
    assign csr_write_en_o  = instr_id_o == INSTR_CSRRW            ||
                             (csr_op_reg  && rs1_addr_o  != '0)   ||
                             instr_id_o == INSTR_CSRRWI           ||
                             (csr_op_uimm && csr_uimm_o != '0);

    // 识别异常： 基础非法指令（不包含非法CSR指令），EBREAK，ECALL
    assign exception_valid_o  = instr_id_o == INSTR_INVALID || instr_id_o == INSTR_EBREAK || instr_id_o == INSTR_ECALL;
    assign exception_cause_o  = instr_id_o == INSTR_EBREAK ? TRAP_CAUSE_BREAKPOINT      :
                                instr_id_o == INSTR_ECALL  ? TRAP_CAUSE_ECALL_M         :
                                                            TRAP_CAUSE_ILLEGAL_INSTR;
    assign exception_tval_o   = exception_cause_o == TRAP_CAUSE_ILLEGAL_INSTR ? instr_i : '0;


    assign illegal_instr_o = instr_id_o == INSTR_INVALID;

    // 根据 opcode、funct3、funct7 译码出具体 RV32I 指令标识-----------------------
    always_comb begin : INSTR_ID_GEN
        instr_id_o = INSTR_INVALID;

        unique case (opcode_o)
            OPCODE_LUI: begin
                instr_id_o = INSTR_LUI;
            end

            OPCODE_AUIPC: begin
                instr_id_o = INSTR_AUIPC;
            end

            OPCODE_JAL: begin
                instr_id_o = INSTR_JAL;
            end

            OPCODE_JALR: begin
                if (funct3_o == 3'b000) begin
                    instr_id_o = INSTR_JALR;
                end
            end

            OPCODE_BRANCH: begin
                unique case (funct3_o)
                    3'b000: instr_id_o = INSTR_BEQ;
                    3'b001: instr_id_o = INSTR_BNE;
                    3'b100: instr_id_o = INSTR_BLT;
                    3'b101: instr_id_o = INSTR_BGE;
                    3'b110: instr_id_o = INSTR_BLTU;
                    3'b111: instr_id_o = INSTR_BGEU;
                    default: instr_id_o = INSTR_INVALID;
                endcase
            end

            OPCODE_LOAD: begin
                unique case (funct3_o)
                    3'b000: instr_id_o = INSTR_LB;
                    3'b001: instr_id_o = INSTR_LH;
                    3'b010: instr_id_o = INSTR_LW;
                    3'b100: instr_id_o = INSTR_LBU;
                    3'b101: instr_id_o = INSTR_LHU;
                    default: instr_id_o = INSTR_INVALID;
                endcase
            end

            OPCODE_STORE: begin
                unique case (funct3_o)
                    3'b000: instr_id_o = INSTR_SB;
                    3'b001: instr_id_o = INSTR_SH;
                    3'b010: instr_id_o = INSTR_SW;
                    default: instr_id_o = INSTR_INVALID;
                endcase
            end

            OPCODE_OP_IMM: begin
                unique case (funct3_o)
                    3'b000: instr_id_o = INSTR_ADDI;
                    3'b010: instr_id_o = INSTR_SLTI;
                    3'b011: instr_id_o = INSTR_SLTIU;
                    3'b100: instr_id_o = INSTR_XORI;
                    3'b110: instr_id_o = INSTR_ORI;
                    3'b111: instr_id_o = INSTR_ANDI;
                    3'b001: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_SLLI;
                        end
                    end
                    3'b101: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_SRLI;
                        end else if (funct7_o == 7'b0100000) begin
                            instr_id_o = INSTR_SRAI;
                        end
                    end
                    default: instr_id_o = INSTR_INVALID;
                endcase
            end

            OPCODE_OP: begin
                unique case (funct3_o)
                    3'b000: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_ADD;
                        end else if (funct7_o == 7'b0100000) begin
                            instr_id_o = INSTR_SUB;
                        end
                    end
                    3'b001: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_SLL;
                        end
                    end
                    3'b010: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_SLT;
                        end
                    end
                    3'b011: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_SLTU;
                        end
                    end
                    3'b100: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_XOR;
                        end
                    end
                    3'b101: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_SRL;
                        end else if (funct7_o == 7'b0100000) begin
                            instr_id_o = INSTR_SRA;
                        end
                    end
                    3'b110: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_OR;
                        end
                    end
                    3'b111: begin
                        if (funct7_o == 7'b0000000) begin
                            instr_id_o = INSTR_AND;
                        end
                    end
                    default: instr_id_o = INSTR_INVALID;
                endcase
            end

            OPCODE_MISC_MEM: begin
                unique case (funct3_o)
                    3'b000:  instr_id_o = INSTR_FENCE;  // 忽略 rs1、rd 不为 x0
                    // 3'b001 :  instr_id_o = INSTR_FENCE_I;    // 当前不支持 FENCE.I
                    default: instr_id_o = INSTR_INVALID;
                endcase
            end

            OPCODE_SYSTEM: begin
                unique case (funct3_o)
                    3'b000: begin
                        if      (instr_i == 32'h0000_0073) begin
                            instr_id_o = INSTR_ECALL;
                        end
                        else if (instr_i == 32'h0010_0073) begin
                            instr_id_o = INSTR_EBREAK;
                        end
                        else if (instr_i == 32'h3020_0073) begin
                            instr_id_o = INSTR_MRET;
                        end
                        else begin
                            instr_id_o = INSTR_INVALID;
                        end
                    end
                    3'b001: instr_id_o = INSTR_CSRRW;
                    3'b010: instr_id_o = INSTR_CSRRS;
                    3'b011: instr_id_o = INSTR_CSRRC;
                    3'b101: instr_id_o = INSTR_CSRRWI;
                    3'b110: instr_id_o = INSTR_CSRRSI;
                    3'b111: instr_id_o = INSTR_CSRRCI;
                    default:instr_id_o = INSTR_INVALID;
                endcase
            end

            default: begin
                instr_id_o = INSTR_INVALID;
            end
        endcase
    end

endmodule

`default_nettype wire
