//------------------------------------------------------------------------------
// 文件      : rtl/core/trap_ctrl.sv
// 用途      : 五级流水线 trap/MRET 控制选择模块。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块只做组合控制选择，不保存 CSR 状态。
//   - 汇总 MEM/commit 边界的同步 exception、CSR illegal、MRET 和 machine interrupt。
//   - 输出 trap/MRET valid、PC redirect 和流水线 kill 控制。
//   - 控制优先级：trap entry / MRET > EX branch/JAL/JALR redirect > load-use stall。
//
// 功能：
//   - 当前支持 trap 范围见 0831 文档 4.1 小节表格和 0833 interrupt 规划。
//   - 将非法 CSR 访问转换为 illegal instruction exception。
//   - 接受随流水线传到 MEM 的 exception，并生成 trap entry。
//   - 接受 MEM 阶段提交的 MRET，并生成返回 redirect。
//   - 在 MEM/commit 边界按 MIE/MPIE、mie、mip 判断并接受 machine interrupt。
//   - 支持 CSR 写+interrupt、MRET+interrupt 的同拍提交语义。
//   - trap entry/interrupt 时跳转到 mtvec，MRET 时跳转到 mepc。
//   - exception/MRET 会终止当前 MEM 指令的 WB 生命周期；interrupt 不 kill 当前旧指令写回。
//------------------------------------------------------------------------------

`default_nettype none

module trap_ctrl (
    input  logic                      mem_valid_i,               // MEM 阶段指令是否有效。
    input  logic [core_pkg::XLEN-1:0] mem_pc_i,                  // MEM 指令 PC，trap 时写入 mepc。
    input  logic [core_pkg::ILEN-1:0] mem_instr_i,               // MEM 指令原始编码，非法 CSR 访问时写入 mtval。
    input  logic                      mem_mret_i,                // MEM 指令是否为 MRET。

    // trap 源 1：随流水线传到 MEM 的 exception：
    // pc跳转地址未对齐、普通非法指令、EBREAK、load 地址未对齐、store 地址未对齐、ECALL
    input  logic                      mem_exception_valid_i,     // 随流水线传到 MEM 的 exception 是否有效。
    input  core_pkg::excp_cause_e     mem_exception_cause_i,     // 随流水线传到 MEM 的 exception cause。
    input  logic [core_pkg::XLEN-1:0] mem_exception_tval_i,      // 随流水线传到 MEM 的 exception tval。

    // trap 源 2：非法 CSR 指令访问。
    input  logic                      mem_csr_valid_i,           // MEM 指令是否为 CSR 指令。
    input  logic                      mem_csr_illegal_i,         // CSR 文件判断出的非法 CSR 访问。

    input  logic [core_pkg::XLEN-1:0] csr_mtvec_i,               // 当前 mtvec，trap/interrupt redirect 目标。
    input  logic [core_pkg::XLEN-1:0] csr_mepc_i,                // 当前 mepc，MRET redirect 目标；MRET+interrupt 时作为中断返回 PC。

    // trap 源 3：异步中断
    input  logic [core_pkg::XLEN-1:0] mem_interrupt_return_pc_i, // 普通 interrupt 写入 mepc 的返回 PC。
    input  logic [core_pkg::XLEN-1:0] csr_mstatus_i,             // 当前 mstatus，用于普通 interrupt 和 MRET+interrupt 判断。
    input  logic [core_pkg::XLEN-1:0] csr_mie_i,                 // 当前 mie，用于普通 interrupt 和 MRET+interrupt 判断。
    input  logic [core_pkg::XLEN-1:0] csr_mip_i,                 // 当前 mip，中断 pending 位。
    input  logic                      mem_csr_write_en_i,        // MEM CSR 指令是否实际写 CSR，与 mem_csr_valid_i 一起使用。
    input  logic [core_pkg::XLEN-1:0] csr_mstatus_commit_i,      // 普通 CSR 写提交后的 mstatus 视图。
    input  logic [core_pkg::XLEN-1:0] csr_mie_commit_i,          // 普通 CSR 写提交后的 mie 视图。
    input  logic [core_pkg::XLEN-1:0] csr_mtvec_commit_i,        // 普通 CSR 写提交后的 mtvec 视图。

    // trap entry 接口
    output logic                      trap_valid_o,              // exception 或 interrupt 被接受，驱动 csr_file 更新 trap CSR。
    output logic [core_pkg::XLEN-1:0] trap_pc_o,                 // 写入 mepc 的 PC：exception=fault PC，interrupt=return PC。
    output logic                      trap_is_interrupt_o,       // 1 表示 interrupt，0 表示 exception。
    output logic [4:0]                trap_cause_code_o,         // exception/interrupt cause code，写入 mcause 低位。
    output logic [core_pkg::XLEN-1:0] trap_tval_o,               // exception tval；interrupt 时为 0。

    output logic                      mret_valid_o,              // MRET 被接受，驱动 csr_file 恢复 mstatus。

    output logic                      redirect_valid_o,          // trap/MRET redirect 是否有效。
    output logic [core_pkg::XLEN-1:0] redirect_pc_o,             // trap/MRET redirect 目标 PC。

    // trap/MRET 导致的 control hazard，使用 kill 口径，与普通跳转的 flush 口径区分。
    output logic                      kill_if_id_o,              // 清掉 IF/ID 年轻指令。
    output logic                      kill_id_ex_o,              // 清掉 ID/EX 年轻指令。
    output logic                      kill_ex_mem_o,             // 阻止当前 EX 阶段年轻指令进入 EX/MEM。
    output logic                      kill_mem_wb_o              // exception/MRET 阻止当前 MEM 指令进入 MEM/WB；interrupt 不阻止。
);

    import core_pkg::*;

    // trap 优先级：exception > MRET+interrupt > CSR写+interrupt > MRET > interrupt
    // 异常 trap，优先级：pipeline_exception > csr_illegal_exception
    wire pipeline_exception    = mem_valid_i & mem_exception_valid_i;
    wire csr_illegal_exception = mem_valid_i & mem_csr_valid_i & mem_csr_illegal_i;
    wire exception_valid       = pipeline_exception | csr_illegal_exception;

    // interrupt 请求条件，优先级：MEIP > MTIP。request 只表示条件成立，最终是否接受还要看 MEM/commit 边界。
    // mip 只读，三种路径公用；MRET+interrupt 看旧 MPIE，CSR写+interrupt 看 commit view。
    wire mret_irq_global_en = csr_mstatus_i[MSTATUS_MPIE_BIT];
    wire csr_irq_global_en  = csr_mstatus_commit_i[MSTATUS_MIE_BIT];
    wire irq_global_en      = csr_mstatus_i[MSTATUS_MIE_BIT];
    wire csr_irq_meip_en    = csr_mie_commit_i[MIE_MEIE_BIT];
    wire csr_irq_mtip_en    = csr_mie_commit_i[MIE_MTIE_BIT];
    wire irq_meip_en        = csr_mie_i[MIE_MEIE_BIT];
    wire irq_mtip_en        = csr_mie_i[MIE_MTIE_BIT];
    wire irq_meip_pending   = csr_mip_i[MIP_MEIP_BIT];
    wire irq_mtip_pending   = csr_mip_i[MIP_MTIP_BIT];
    // irq + MRET
    wire mret_irq_meip_request = mret_accept & (mret_irq_global_en & irq_meip_en & irq_meip_pending);
    wire mret_irq_mtip_request = mret_accept & (mret_irq_global_en & irq_mtip_en & irq_mtip_pending);
    wire mret_irq_request      = mret_irq_meip_request | mret_irq_mtip_request;
    // irq + CSR 写
    wire csr_irq_meip_request  = csr_we_accept & (csr_irq_global_en & csr_irq_meip_en & irq_meip_pending);
    wire csr_irq_mtip_request  = csr_we_accept & (csr_irq_global_en & csr_irq_mtip_en & irq_mtip_pending);
    wire csr_irq_request       = csr_irq_meip_request | csr_irq_mtip_request;
    // irq_only
    wire irq_only_meip_request = !mret_accept & !csr_we_accept & (irq_global_en & irq_meip_en & irq_meip_pending);
    wire irq_only_mtip_request = !mret_accept & !csr_we_accept & (irq_global_en & irq_mtip_en & irq_mtip_pending);
    wire irq_only_request      = irq_only_meip_request | irq_only_mtip_request;
    // 总
    wire irq_meip_request = mret_irq_meip_request | csr_irq_meip_request | irq_only_meip_request;
    wire irq_mtip_request = mret_irq_mtip_request | csr_irq_mtip_request | irq_only_mtip_request;
    wire irq_request      = mret_irq_request | csr_irq_request | irq_only_request;

    // trap_cause MUX
    core_pkg::excp_cause_e exception_cause;
    core_pkg::irq_cause_e  irq_cause;
    // exception_cause 赋值块
    always_comb begin : EXCEPTION_CAUSE_MUX
        exception_cause = EXCEPTION_CAUSE_ILLEGAL_INSTR;  // 默认值，exception_valid = 0 时无实意
        if (pipeline_exception) begin
            exception_cause = mem_exception_cause_i;
        end
        else if (csr_illegal_exception) begin
            exception_cause = EXCEPTION_CAUSE_ILLEGAL_INSTR;
        end
    end
    // irq_cause 赋值块
    // irq 优先级 MEIP > MTIP，但硬件在中断做的事情都是跳到 handler，软件通过看 mcause 才知道是什么 trap
    always_comb begin : IRQ_CAUSE_MUX
        irq_cause = IRQ_CAUSE_M_TIMER;  // 默认值，irq_accept = 0 时无实意
        if (irq_meip_request) begin
            irq_cause = IRQ_CAUSE_M_EXTERNAL;
        end
        else if (irq_mtip_request) begin
            irq_cause = IRQ_CAUSE_M_TIMER;
        end
    end

    // 优先级控制信号
    // 当前 MEM 指令提交类型。exception 已在这里屏蔽，避免异常指令继续完成 MRET/CSR 写语义。
    wire exception_trap = mem_valid_i &  exception_valid;
    wire irq_accept     = mem_valid_i & !exception_valid &  irq_request;
    wire mret_accept    = mem_valid_i & !exception_valid &  mem_mret_i;
    wire csr_we_accept  = mem_valid_i & !exception_valid &  mem_csr_valid_i &  mem_csr_write_en_i;
    always_comb begin : TRAP_CTRL
        trap_valid_o        = exception_trap | irq_accept;
        // 以下默认中断，trap_valid_o = 0 时无实意
        trap_pc_o           = exception_trap ? mem_pc_i : mem_interrupt_return_pc_i;
        trap_is_interrupt_o = exception_trap ? 1'b0 : 1'b1;
        trap_cause_code_o   = exception_trap ? 5'(exception_cause) : 5'(irq_cause);
        trap_tval_o         = '0;

        mret_valid_o        = 1'b0;

        redirect_valid_o    = 1'b0;         // 副作用默认为 0，避免忘赋值导致副作用
        redirect_pc_o       = csr_mtvec_i;  // 默认 trap,仅 redirect_valid_o = 1 有意义，MRET 时改为 csr_mepc_i
        if (exception_trap) begin
            redirect_valid_o = 1'b1;
            // 防御性优先级
            if (pipeline_exception) begin
                trap_tval_o     = mem_exception_tval_i;
            end
            else if (csr_illegal_exception) begin
                // CSR 访问非法：cause - 非法指令，tval - 原始指令编码
                trap_tval_o     = mem_instr_i;
            end
        end
        else if (irq_accept & (mret_accept | csr_we_accept)) begin
            redirect_valid_o = 1'b1;
            if (mret_accept) begin
                trap_pc_o     = csr_mepc_i;     // MRET+interrupt：中断返回地址是 MRET 原本要跳回的 mepc。
                mret_valid_o  = 1'b1;
            end
            else if (csr_we_accept) begin
                redirect_pc_o = csr_mtvec_commit_i; // CSR写+interrupt：下拍跳到可能被写入的新 mtvec。
            end
        end
        else if (mret_accept) begin
            redirect_valid_o = 1'b1;
            redirect_pc_o    = csr_mepc_i;
            mret_valid_o     = 1'b1;
        end
        // irq_accept 分支拆开是为了保证和 csr_ctrl 优先级实现一致
        else if (irq_accept) begin
            redirect_valid_o = 1'b1;
        end
    end


    // exception/MRET 终止当前 MEM 指令生命周期；interrupt 接在当前旧指令之后，只 kill younger 指令。
    assign kill_if_id_o     = exception_trap | irq_accept | mret_accept;
    assign kill_id_ex_o     = exception_trap | irq_accept | mret_accept;
    assign kill_ex_mem_o    = exception_trap | irq_accept | mret_accept;
    assign kill_mem_wb_o    = exception_trap | mret_accept;

endmodule

`default_nettype wire
