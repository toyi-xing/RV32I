//------------------------------------------------------------------------------
// 文件      : rtl/core/csr_file.sv
// 用途      : RV32I M-mode CSR 寄存器文件。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块保存最小 M-mode CSR 状态，集中处理 CSR 状态更新：
//       1. 普通 CSR 指令提交。
//       2. trap entry（mepc/mcause/mtval/mstatus 更新）。
//       3. MRET 返回时恢复 mstatus。
//   - 组合读、同步写。写端口支持 MRET/CSR 写与 interrupt 同拍提交的复合语义。
//
// 功能：
//   - 保存 7 个 M-mode CSR 状态寄存器：mstatus、mie、mtvec、mscratch、mepc、mcause、mtval。
//   - 组合生成 mip：MTIP/MEIP 来自硬件 pending 输入，其余 bit 读 0。
//   - 提供 5 个固定只读 CSR 常量：misa、mvendorid、marchid、mimpid、mhartid。
//   - 根据 csr_addr_i 组合读出 CSR 值。
//   - 检测非法 CSR 访问（不存在的 CSR 地址、写只读 CSR），输出 csr_illegal_o。
//   - 接收普通 CSR 指令写请求，按 csr_op_i 计算新值并执行 WARL 处理。
//   - 接收 trap_valid 写请求，自动更新 mepc/mcause/mtval/mstatus。
//   - 接收 mret_valid（MRET指令） 写请求，自动恢复 mstatus.MIE/MPIE/MPP。
//   - 输出普通 CSR 写提交后的 commit view，供 trap_ctrl 判断 CSR 写同拍 interrupt。
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

    // trap entry 接口，非指令，而是系统 trap 时，csr 自动做的事情
    input  logic                      trap_valid_i,          // trap 提交，需更新 mepc/mcause/mtval/mstatus
    input  logic [core_pkg::XLEN-1:0] trap_pc_i,             // 写入 mepc；异常时为 fault PC，中断时为 return PC
    input  logic                      trap_is_interrupt_i,   // 1 为中断，0 为异常
    input  logic [4:0]                trap_cause_code_i,     // exception/interrupt cause code，写入 mcause 低位
    input  logic [core_pkg::XLEN-1:0] trap_tval_i,           // 异常附加信息；中断时写入 mtval 的值由本模块清 0

    // MRET，同上，csr 自动做的事情
    input  logic                      mret_valid_i,          // MRET 提交，恢复 mstatus

    // 中断源 pending 请求
    input  logic                      mtip_i,
    input  logic                      meip_i,

    // 输出 CSR 值供 trap_ctrl 和顶层使用。
    // commit view 只表示普通 CSR 写提交后的值，用于 CSR 写同拍 interrupt 的判断和 redirect。
    output logic [core_pkg::XLEN-1:0] mstatus_o,             // mstatus 当前值（特权级、全局中断备份与开关）
    output logic [core_pkg::XLEN-1:0] mstatus_commit_o,      // 普通 CSR 写提交后的 mstatus；无合法 mstatus 写时等于当前值
    output logic [core_pkg::XLEN-1:0] mie_o,                 // mie 当前值
    output logic [core_pkg::XLEN-1:0] mie_commit_o,          // 普通 CSR 写提交后的 mie；无合法 mie 写时等于当前值
    output logic [core_pkg::XLEN-1:0] mtvec_o,               // mtvec 当前值
    output logic [core_pkg::XLEN-1:0] mtvec_commit_o,        // 普通 CSR 写提交后的 mtvec；无合法 mtvec 写时等于当前值
    output logic [core_pkg::XLEN-1:0] mepc_o,                // mepc 当前值（MRET 返回地址）
    output logic [core_pkg::XLEN-1:0] mip_o                  // mip 当前值（中断 pending）

);

    import core_pkg::*;

    // 寄存器声明
    // 可读可写
    reg   [core_pkg::XLEN-1:0] mstatus, mie, mtvec, mscratch, mepc, mcause, mtval;
    // 只读，硬件自动写
    logic [core_pkg::XLEN-1:0] mip;
    // 只读，固定值
    wire  [core_pkg::XLEN-1:0] misa        = 32'h4000_0100;
    wire  [core_pkg::XLEN-1:0] mvendorid   = '0;
    wire  [core_pkg::XLEN-1:0] marchid     = '0;
    wire  [core_pkg::XLEN-1:0] mimpid      = '0;
    wire  [core_pkg::XLEN-1:0] mhartid     = '0;

    // CSR 读端口 + 非法地址检测
    logic csr_illegal_r;     // 读 CSR 地址非法，组合输出
    always_comb begin : CSR_READ
        csr_illegal_r = 1'b0;
        csr_rdata_o   = '0;
        if (csr_valid_i) begin  // 当前 CSR 无读副作用，只要是 Zicsr 指令，就读 CSR 寄存器
            unique case (csr_addr_i)
                CSR_ADDR_MSTATUS    : csr_rdata_o = mstatus;
                CSR_ADDR_MIE        : csr_rdata_o = mie;
                CSR_ADDR_MTVEC      : csr_rdata_o = mtvec;
                CSR_ADDR_MSCRATCH   : csr_rdata_o = mscratch;
                CSR_ADDR_MEPC       : csr_rdata_o = mepc;
                CSR_ADDR_MCAUSE     : csr_rdata_o = mcause;
                CSR_ADDR_MTVAL      : csr_rdata_o = mtval;
                // 只读
                CSR_ADDR_MIP        : csr_rdata_o = mip;
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
                csr_warl                                  = '0;     // 非已实现 bit 保持 0（不写入）
                csr_warl[MSTATUS_MIE_BIT]                 = csr_new[MSTATUS_MIE_BIT];
                csr_warl[MSTATUS_MPIE_BIT]                = csr_new[MSTATUS_MPIE_BIT];
                csr_warl[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = MSTATUS_MPP_M;
            end
            CSR_ADDR_MIE:begin
                csr_warl                = '0;     // 非已实现 bit 保持 0（不写入）
                csr_warl[MIE_MTIE_BIT]  = csr_new[MIE_MTIE_BIT];
                csr_warl[MIE_MEIE_BIT]  = csr_new[MIE_MEIE_BIT];
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
    logic csr_illegal_w;      // 写 CSR 地址非法（含只读寄存器和未支持寄存器），但也要组合输出，不然差一拍
    always_comb begin : CSR_ILLEGAL_W
        csr_illegal_w = 1'b0;
        if (csr_valid_i && csr_write_en_i) begin
            unique case (csr_addr_i)
                CSR_ADDR_MSTATUS,   CSR_ADDR_MIE,       CSR_ADDR_MTVEC,
                CSR_ADDR_MSCRATCH,  CSR_ADDR_MEPC,
                CSR_ADDR_MCAUSE,    CSR_ADDR_MTVAL      : csr_illegal_w = 1'b0;
                CSR_ADDR_MIP,       CSR_ADDR_MISA,      CSR_ADDR_MVENDORID,
                CSR_ADDR_MARCHID,   CSR_ADDR_MIMPID,
                CSR_ADDR_MHARTID    : csr_illegal_w = 1'b1;// 只读的 CSR 寄存器非法写
                default:    csr_illegal_w = 1'b1;  // 未支持的 CSR 寄存器写
            endcase
        end
    end
    // CSR 写端口：Zicsr 指令写 + trap & MRET CSR 硬件写
    // CSR 写分为以下情况：硬件自动写——trap（exception/interrupt）、MRET；软件写——CSR 指令写
    // 由于中断可能在任意指令（MRET、CSR 写）发生，仅异常时只需处理异常，其他时候都要考虑与中断同时发生
    // 优先级排序：exception trap > MRET+interrupt > CSR 写+interrupt > interrupt trap > MRET > normal CSR write
    wire exception_trap =  trap_valid_i & !trap_is_interrupt_i;
    wire irq_and_mret   =  trap_valid_i &  trap_is_interrupt_i &  mret_valid_i;
    wire irq_and_csr_we =  trap_valid_i &  trap_is_interrupt_i &  csr_valid_i  &  csr_write_en_i;
    wire irq_only       =  trap_valid_i &  trap_is_interrupt_i & !mret_valid_i & !csr_write_en_i;    // 根据 decoder 规则，其实只看 csr_write_en_i 就够了，其他地方是双重保险
    wire mret_only      = !trap_valid_i &  mret_valid_i;
    wire csr_we_only    = !trap_valid_i &  csr_valid_i  &  csr_write_en_i;
    always_ff @(posedge clk_i or negedge rst_n_i) begin : CSR_WRITE
        if (!rst_n_i) begin
            mstatus        <= '0;
            mstatus[12:11] <= MSTATUS_MPP_M;    // 当前仅实现 4 bit+M mode，MIE/MPIE 清 0，MPP 固定为 M-mode。
            mie            <= '0;               // 关闭所有中断开关，软件需自行打开
            mtvec          <= MTVEC_RESET;      // mtvec 指向默认 trap 入口，其余 CSR 清 0。
            mscratch       <= '0;
            mepc           <= '0;
            mcause         <= '0;
            mtval          <= '0;
        end else begin
            if (exception_trap) begin       // trap entry：PC redirect 到 trap handler
                mepc     <= trap_pc_i;      // 异常 pc
                mcause   <= {1'b0, (XLEN-1)'(trap_cause_code_i)};
                mtval    <= trap_tval_i;
                mstatus[MSTATUS_MIE_BIT]                  <= 1'b0;
                mstatus[MSTATUS_MPIE_BIT]                 <= mstatus[MSTATUS_MIE_BIT];
                mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB]  <= MSTATUS_MPP_M;
            end
            else if (irq_and_mret) begin    // mstatus 等价于先 MRET 再 interrupt entry,其他 CSR 等价于一次 irq
                // mepc 本就是 MRET 要返回的 pc,因此保持不变，中断处理完后再回去
                mcause   <= {1'b1, (XLEN-1)'(trap_cause_code_i)};
                mtval    <= '0;             // tval 中断写 0
                mstatus[MSTATUS_MIE_BIT]                  <= 1'b0;                      // MIE 清 0
                mstatus[MSTATUS_MPIE_BIT]                 <= mstatus[MSTATUS_MPIE_BIT]; // MPIE 保持旧值
                mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB]  <= MSTATUS_MPP_M;
            end
            else if (irq_and_csr_we) begin  // 普通 CSR 写先提交，再执行 interrupt trap entry
                unique case (csr_addr_i)
                    CSR_ADDR_MSTATUS    : mstatus    <= csr_warl;
                    CSR_ADDR_MIE        : mie        <= csr_warl;
                    CSR_ADDR_MTVEC      : mtvec      <= csr_warl;
                    CSR_ADDR_MSCRATCH   : mscratch   <= csr_warl;
                    CSR_ADDR_MEPC       : mepc       <= csr_warl;
                    CSR_ADDR_MCAUSE     : mcause     <= csr_warl;
                    CSR_ADDR_MTVAL      : mtval      <= csr_warl;
                    default: ;  // 写端口只负责合法地址的状态更新；非法写由组合 csr_illegal_o 上报。
                endcase
                mepc     <= trap_pc_i;      // 中断返回 pc
                mcause   <= {1'b1, (XLEN-1)'(trap_cause_code_i)};
                mtval    <= '0;             // tval 中断写 0
                mstatus[MSTATUS_MIE_BIT]                  <= 1'b0;
                mstatus[MSTATUS_MPIE_BIT]                 <= mstatus_commit_o[MSTATUS_MIE_BIT];     // 使用普通 CSR 写提交后的 MIE
                mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB]  <= MSTATUS_MPP_M;

            end
            else if (irq_only) begin
                mepc     <= trap_pc_i;      // 中断返回 pc
                mcause   <= {1'b1, (XLEN-1)'(trap_cause_code_i)};
                mtval    <= '0;             // tval 中断写 0
                mstatus[MSTATUS_MIE_BIT]                  <= 1'b0;
                mstatus[MSTATUS_MPIE_BIT]                 <= mstatus[MSTATUS_MIE_BIT];
                mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB]  <= MSTATUS_MPP_M;
            end
            else if (mret_only) begin     // mret:该情况 pc <- mepc
                mstatus[MSTATUS_MIE_BIT]                  <= mstatus[MSTATUS_MPIE_BIT];
                mstatus[MSTATUS_MPIE_BIT]                 <= 1'b1;      // MPIE 复位
                mstatus[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB]  <= MSTATUS_MPP_M;
            end
            else if (csr_we_only) begin   // CSR 指令写，该情况 pc 不重定向
                unique case (csr_addr_i)
                    CSR_ADDR_MSTATUS    : mstatus    <= csr_warl;
                    CSR_ADDR_MIE        : mie        <= csr_warl;
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
    // MIP 由硬件自动写，组合逻辑，中断源自行负责保持 pending
    always_comb begin : MIP
        mip               = '0;     // 非已实现 bit 保持 0
        mip[MIP_MTIP_BIT] = mtip_i;
        mip[MIP_MEIP_BIT] = meip_i;
    end

    assign csr_illegal_o = csr_illegal_r | csr_illegal_w;

    // 无需看 MRET 后的 commit 寄存器，因为 MRET 只会改变 mstatus，而 mstatus_o 的 MPIE 就可以确定 MRET 后还是否会中断（irq_and_mret）
    // 这里添加了 MRET 的 commit 反而容易构成组合环
    always_comb begin : CSR_STATUS_OUT
        mstatus_o           = mstatus;
        mstatus_commit_o    = mstatus;
        mie_o               = mie;
        mie_commit_o        = mie;
        mtvec_o             = mtvec;
        mtvec_commit_o      = mtvec;
        mepc_o              = mepc;
        mip_o               = mip;
        if(csr_valid_i  &  csr_write_en_i & !csr_illegal_o) begin    // 合法普通 CSR 写提交后的对应寄存器
            unique case (csr_addr_i)
                CSR_ADDR_MSTATUS:   mstatus_commit_o = csr_warl;
                CSR_ADDR_MIE:       mie_commit_o     = csr_warl;
                CSR_ADDR_MTVEC:     mtvec_commit_o   = csr_warl;
                default: ;
            endcase
        end
    end

endmodule

// =============================================================================
// CSR commit view 与同拍 interrupt 说明
// =============================================================================
// 本模块有两类容易混在一起的“本拍之后”概念：
//
//   1. 普通 CSR 指令提交后的 CSR 视图：
//        mstatus_commit_o / mie_commit_o / mtvec_commit_o
//
//      这几个信号只描述“如果当前 MEM 指令是一条合法 CSR 写，那么这条 CSR 写
//      自己提交后，相关 CSR 会是什么值”。它们不包含 trap entry 的硬件写，也不包含
//      MRET 的硬件写。这样可以避免形成：
//
//        csr_file commit view -> trap_ctrl -> trap_valid/mret_valid -> csr_file commit view
//
//      这种组合闭环。
//
//      CSR 写+ interrupt 使用这几个信号。语义是：
//        - 先提交当前 CSR 写；
//        - trap_ctrl 用提交后的 mstatus/mie 判断 interrupt 是否真正可接受；
//        - 若同拍接受 interrupt，redirect 目标使用提交后的 mtvec；
//        - csr_file 在时钟沿合并“CSR 写 + interrupt trap entry”的最终状态。
//
//      因此，如果本拍写 mstatus 清掉 MIE，就不应再按旧 MIE 接受 interrupt；
//      如果本拍写 mtvec 后同拍接受 interrupt，就应跳到新 mtvec。
//
//   2. MRET 提交后的 mstatus：
//
//      MRET 也会改变 mstatus，但它不放进 commit view。原因是 MRET + interrupt
//      不需要完整构造“mstatus_after_mret”，只需要知道 MRET 后的 MIE 是否为 1。
//      根据 MRET 语义：
//
//        MIE <= old MPIE
//
//      所以 trap_ctrl 直接看 mstatus_o[MSTATUS_MPIE_BIT]，就等价于判断
//      “MRET 返回后是否开中断”。若 MRET+interrupt 成立，最终 mstatus 不是单纯
//      的 MRET 后状态，而是“先 MRET，再 interrupt trap entry”的结果：
//
//        MIE  <= 0
//        MPIE <= old MPIE
//        MPP  <= M
//
//      这就是为什么 commit view 只管普通 CSR 写，而 MRET + interrupt 走单独口径。
// =============================================================================

`default_nettype wire
