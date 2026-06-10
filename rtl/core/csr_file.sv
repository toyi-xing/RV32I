//------------------------------------------------------------------------------
// 文件      : rtl/core/csr_file.sv
// 用途      : RV32I M-mode CSR 寄存器文件。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块保存全部 M-mode CSR 状态，集中处理三类 CSR 写来源：
//       1. 普通 CSR 指令提交。
//       2. trap entry（mepc/mcause/mtval/mstatus 更新）。
//       3. MRET 返回时恢复 mstatus。
//   - 组合读、同步写。同一拍写优先：trap_valid_i > mret_valid_i > normal csr write
//
// 功能：
//   - 保存 6 个 M-mode CSR 状态寄存器：mstatus、mtvec、mscratch、mepc、mcause、mtval。
//   - 提供 5 个只读 CSR 常量：misa、mvendorid、marchid、mimpid、mhartid。
//   - 根据 csr_addr_i 组合读出 CSR 值。
//   - 检测非法 CSR 访问（不存在的 CSR 地址、写只读 CSR），输出 csr_illegal_o。
//   - 接收普通 CSR 指令写请求，按 csr_op_i 计算新值并执行 WARL 处理。
//   - 接收 trap_valid 写请求，自动更新 mepc/mcause/mtval/mstatus。
//   - 接收 mret_valid（MRET指令） 写请求，自动恢复 mstatus.MIE/MPIE/MPP。
//------------------------------------------------------------------------------

`default_nettype none

module csr_file (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    // CSR 指令接口（来自 EX/MEM 流水线寄存器）
    input  logic                      csr_valid_i,           // 当前 MEM 级为有效的六条 Zicsr 指令之一
    input  core_pkg::csr_op_e         csr_op_i,              // CSR 操作类型（RW/RS/RC/RWI/RSI/RCI）
    input  logic [11:0]               csr_addr_i,            // CSR 寄存器地址（12 位）
    input  logic [core_pkg::XLEN-1:0] csr_operand_i,         // CSR 写操作数（EX 级从 rs1 forwarding 或 uimm 扩展生成），按 csr_op_i 与旧值组合后写入 CSR 寄存器
    input  logic                      csr_write_en_i,        // 该 CSR 指令是否实际尝试写 CSR

    output logic [core_pkg::XLEN-1:0] csr_rdata_o,           // CSR 组合读出的旧值
    output logic                      csr_illegal_o,         // 非法 CSR 访问指示

    // trap entry 接口
    input  logic                      trap_valid_i,          // trap 提交，需更新 mepc/mcause/mtval/mstatus
    input  logic [core_pkg::XLEN-1:0] trap_pc_i,             // fault 指令的 PC，写入 mepc
    input  core_pkg::trap_cause_e     trap_cause_i,          // trap 原因，写入 mcause
    input  logic [core_pkg::XLEN-1:0] trap_tval_i,           // 异常附加信息，写入 mtval

    // MRET
    input  logic                      mret_valid_i,                // MRET 提交，恢复 mstatus

    // 输出 CSR 值供 trap_ctrl 和顶层使用
    output logic [core_pkg::XLEN-1:0] mtvec_o,               // mtvec 当前值（trap 跳转基址）
    output logic [core_pkg::XLEN-1:0] mepc_o,                // mepc 当前值（MRET 返回地址）
    output logic [core_pkg::XLEN-1:0] mstatus_o              // mstatus 当前值
);

    import core_pkg::*;

    // 寄存器声明
    // 可读可写
    reg  [core_pkg::XLEN-1:0] mstatus, mtvec, mscratch, mepc, mcause, mtval;
    // 只读
    wire [core_pkg::XLEN-1:0] misa        = 32'h4000_0100;
    wire [core_pkg::XLEN-1:0] mvendorid   = '0;
    wire [core_pkg::XLEN-1:0] marchid     = '0;
    wire [core_pkg::XLEN-1:0] mimpid      = '0;
    wire [core_pkg::XLEN-1:0] mhartid     = '0;

    // CSR 读端口 + 非法地址检测
    logic csr_illegal_r;     // 读 CSR 地址非法，组合输出
    always_comb begin : CSR_READ
        csr_illegal_r = 1'b0;
        csr_rdata_o   = '0;
        if (csr_valid_i) begin  // 当前 CSR 无读副作用，只要是 Zicsr 指令，就读 CSR 寄存器
            unique case (csr_addr_i)
                CSR_ADDR_MSTATUS    : csr_rdata_o = mstatus;
                CSR_ADDR_MTVEC      : csr_rdata_o = mtvec;
                CSR_ADDR_MSCRATCH   : csr_rdata_o = mscratch;
                CSR_ADDR_MEPC       : csr_rdata_o = mepc;
                CSR_ADDR_MCAUSE     : csr_rdata_o = mcause;
                CSR_ADDR_MTVAL      : csr_rdata_o = mtval;
                // 只读
                CSR_ADDR_MISA       : csr_rdata_o = misa;
                CSR_ADDR_MVENDORID  : csr_rdata_o = mvendorid;
                CSR_ADDR_MARCHID    : csr_rdata_o = marchid;
                CSR_ADDR_MIMPID     : csr_rdata_o = mimpid;
                CSR_ADDR_MHARTID    : csr_rdata_o = mhartid;
                default: begin
                    csr_rdata_o     = '0;
                    csr_illegal_r   = 1'b1; // 未支持的 CSR 寄存器读
                end
            endcase
        end
    end

    // CSR 新值计算
    logic [core_pkg::XLEN-1:0] csr_new;
    always_comb begin : CSR_NEW_CAL
        csr_new = '0;
        if (csr_valid_i && csr_write_en_i) begin
            unique case (csr_op_i)
                CSR_OP_RW,  CSR_OP_RWI: csr_new = csr_operand_i;
                CSR_OP_RS,  CSR_OP_RSI: csr_new = csr_rdata_o |  csr_operand_i;
                CSR_OP_RC,  CSR_OP_RCI: csr_new = csr_rdata_o & ~csr_operand_i;
                default: csr_new = csr_rdata_o;
            endcase
        end
    end
    // CSR WARL 处理（Accept Any Write, Store a Legal Value）
    // 按具体 CSR 的可实现字段将 csr_new 收敛到合法值。
    // 后续扩展 vectored mtvec、C 扩展 mepc 对齐或更多 mstatus 字段等时，只需改这个组合块。
    logic [core_pkg::XLEN-1:0] csr_warl;
    always_comb begin : CSR_WARL_CAL
        csr_warl = csr_new;
        unique case (csr_addr_i)
            CSR_ADDR_MSTATUS: begin // 当前 mstatus 仅实现 MIE/MPIE/MPP 这 4 bit，其余 bit 读 0、写忽略。
                csr_warl = mstatus; // 非已实现 bit 保持旧值（不写入）
                csr_warl[MSTATUS_MIE_BIT]                 = csr_new[MSTATUS_MIE_BIT];
                csr_warl[MSTATUS_MPIE_BIT]                = csr_new[MSTATUS_MPIE_BIT];
                csr_warl[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = MSTATUS_MPP_M;
            end
            CSR_ADDR_MTVEC: begin   // 当前只支持 direct mode，MODE 字段 mtvec[1:0]强制为 0。
                csr_warl[core_pkg::XLEN-1:2] = csr_new[core_pkg::XLEN-1:2]; // BASE 可写
                csr_warl[1:0]                = 2'b00;                       // MODE 当前只支持 direct
            end
            CSR_ADDR_MEPC: begin    // 当前不支持 C 扩展，合法 PC 按 4 字节对齐，低 2 bit 强制清 0。
                csr_warl = {csr_new[core_pkg::XLEN-1:2], 2'b00};
            end
            default: begin          // mscratch/mcause/mtval 当前不做字段级限制；非法 CSR 地址不会在写端口更新状态。
                csr_warl = csr_new;
            end
        endcase
    end

    // CSR 写非法地址检测
    logic csr_illegal_w;      // 写 CSR 地址非法（含只读寄存器和未支持寄存器），但也要组合输出
    always_comb begin : CSR_ILLEGAL_W
        csr_illegal_w = 1'b0;
        if (csr_valid_i && csr_write_en_i) begin
            unique case (csr_addr_i)
                CSR_ADDR_MSTATUS,   CSR_ADDR_MTVEC,
                CSR_ADDR_MSCRATCH,  CSR_ADDR_MEPC,
                CSR_ADDR_MCAUSE,    CSR_ADDR_MTVAL      : csr_illegal_w = 1'b0;
                CSR_ADDR_MISA,      CSR_ADDR_MVENDORID,
                CSR_ADDR_MARCHID,   CSR_ADDR_MIMPID,
                CSR_ADDR_MHARTID    : csr_illegal_w = 1'b1;// 只读的 CSR 寄存器非法写
                default:    csr_illegal_w = 1'b1;  // 未支持的 CSR 寄存器写
            endcase
        end
    end
    // CSR 写端口： Zicsr 指令写 + trap & MRET CSR 硬件写
    always_ff @(posedge clk_i or negedge rst_n_i) begin : CSR_WRITE
        if (!rst_n_i) begin
            mstatus        <= '0;
            mstatus[12:11] <= MSTATUS_MPP_M;    // 当前仅实现 4 bit+M mode，MIE/MPIE 清 0，MPP 固定为 M-mode。
            mtvec          <= MTVEC_RESET;      // mtvec 指向默认 trap 入口，其余 CSR 清 0。
            mscratch       <= '0;
            mepc           <= '0;
            mcause         <= '0;
            mtval          <= '0;
        end else begin
            // CSR 写优先级：trap > mret > normal csr write
            if (trap_valid_i) begin         // trap：该情况 pc <- trap handler
                mepc                                      <= trap_pc_i;
                mcause                                    <= core_pkg::XLEN'(trap_cause_i);
                mtval                                     <= trap_tval_i;
                mstatus[MSTATUS_MIE_BIT]               <= 1'b0;
                mstatus[MSTATUS_MPIE_BIT]                 <= mstatus[MSTATUS_MIE_BIT];
                mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB]  <= MSTATUS_MPP_M;
            end
            else if (mret_valid_i) begin    // mret:该情况 pc <- mepc
                mstatus[MSTATUS_MIE_BIT]                              <= mstatus[MSTATUS_MPIE_BIT];
                mstatus[MSTATUS_MPIE_BIT]                             <= 1'b1;      // MPIE 复位
                mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB]  <= MSTATUS_MPP_M;
            end
            else if (csr_valid_i && csr_write_en_i) begin   // CSR 指令写，该情况 pc 不重定向
                unique case (csr_addr_i)
                    CSR_ADDR_MSTATUS    : mstatus    <= csr_warl;
                    CSR_ADDR_MTVEC      : mtvec      <= csr_warl;
                    CSR_ADDR_MSCRATCH   : mscratch   <= csr_warl;
                    CSR_ADDR_MEPC       : mepc       <= csr_warl;
                    CSR_ADDR_MCAUSE     : mcause     <= csr_warl;
                    CSR_ADDR_MTVAL      : mtval      <= csr_warl;
                    default: ;  // 写端口只负责合法地址的状态更新；非法写由组合 csr_illegal_o 上报。
                endcase
            end
        end
    end

    assign csr_illegal_o = csr_illegal_r | csr_illegal_w;


    assign mtvec_o      = mtvec;
    assign mepc_o       = mepc;
    assign mstatus_o    = mstatus;


endmodule

`default_nettype wire
