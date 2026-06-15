//------------------------------------------------------------------------------
// 文件      : rtl/core/trap_ctrl.sv
// 用途      : 五级流水线 trap/MRET 控制选择模块。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块只做组合控制选择，不保存 CSR 状态。
//   - 汇总 MEM 附近的同步 exception、CSR illegal 和 MRET。
//   - 输出 trap/MRET valid、PC redirect 和流水线 kill 控制。
//   - 控制优先级：trap entry / MRET > EX branch/JAL/JALR redirect > load-use stall。
//
// 功能：
//   - 当前支持 trap 范围见 0831 文档 4.1 小节表格
//   - 将非法 CSR 访问转换为 illegal instruction exception。
//   - 接受随流水线传到 MEM 的 exception，并生成 trap entry。
//   - 接受 MEM 阶段提交的 MRET，并生成返回 redirect。
//   - trap entry 时跳转到 mtvec，MRET 时跳转到 mepc。
//   - trap entry 或 MRET 被接受时，kill IF/ID、ID/EX、EX/MEM 和 MEM/WB。
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
    input  core_pkg::trap_cause_e     mem_exception_cause_i,     // 随流水线传到 MEM 的 exception cause。
    input  logic [core_pkg::XLEN-1:0] mem_exception_tval_i,      // 随流水线传到 MEM 的 exception tval。

    // trap 源 2：非法 CSR 指令访问。
    input  logic                      mem_csr_valid_i,           // MEM 指令是否为 CSR 指令。
    input  logic                      mem_csr_illegal_i,         // CSR 文件判断出的非法 CSR 访问。

    input  logic [core_pkg::XLEN-1:0] csr_mtvec_i,               // 当前 mtvec，trap entry redirect 目标。
    input  logic [core_pkg::XLEN-1:0] csr_mepc_i,                // 当前 mepc，MRET redirect 目标。

    // 根据是否异常，请求系统 trap
    output logic                      trap_valid_o,              // trap entry 被接受，驱动 csr_file 更新 trap CSR。
    output logic [core_pkg::XLEN-1:0] trap_pc_o,                 // fault 指令 PC，写入 mepc。
    output core_pkg::trap_cause_e     trap_cause_o,              // trap cause，写入 mcause。
    output logic [core_pkg::XLEN-1:0] trap_tval_o,               // trap tval，写入 mtval。

    output logic                      mret_valid_o,              // MRET 被接受，驱动 csr_file 恢复 mstatus。

    output logic                      redirect_valid_o,          // trap/MRET redirect 是否有效。
    output logic [core_pkg::XLEN-1:0] redirect_pc_o,             // trap/MRET redirect 目标 PC。

    // trap 导致的 control hazard,使用 kill 口径，与普通跳转的 flush 口径区分，且 kill 优先级应当更高
    output logic                      kill_if_id_o,              // 清掉 IF/ID 年轻指令。
    output logic                      kill_id_ex_o,              // 清掉 ID/EX 年轻指令。
    output logic                      kill_ex_mem_o,             // 阻止当前 EX 阶段年轻指令进入 EX/MEM。
    output logic                      kill_mem_wb_o              // 阻止当前 MEM 指令作为普通指令进入 MEM/WB。
);

    import core_pkg::*;

    wire pipeline_exception    = mem_valid_i & mem_exception_valid_i;
    wire csr_illegal_exception = mem_valid_i & mem_csr_valid_i & mem_csr_illegal_i;
    always_comb begin : TRAP_ENTRY
        trap_valid_o = pipeline_exception | csr_illegal_exception;
        trap_pc_o    = mem_pc_i;
        trap_cause_o = TRAP_CAUSE_ILLEGAL_INSTR;    // 用非法指令做统一默认值
        trap_tval_o  = '0;
        // 正常情况下 pipeline_exception 与 csr_illegal_exception 互斥；
        // 若 rtl 错误导致同时为 1，这里确定优先级。（与0831规划文档一致）
        if (pipeline_exception) begin
            trap_cause_o = mem_exception_cause_i;
            trap_tval_o  = mem_exception_tval_i;
        end
        else if (csr_illegal_exception) begin
            // CSR 访问非法：cause - 非法指令，tval - 原始指令编码
            trap_cause_o = TRAP_CAUSE_ILLEGAL_INSTR;
            trap_tval_o  = mem_instr_i;
        end
    end

    // 正常合法 MRET 不会带 exception；这里用 ~trap_valid_o 只是防御性保证 trap entry 优先
    assign mret_valid_o         = mem_valid_i & mem_mret_i & ~trap_valid_o;

    assign redirect_valid_o     = trap_valid_o | mret_valid_o;
    assign redirect_pc_o        = trap_valid_o ? csr_mtvec_i : mret_valid_o ? csr_mepc_i : '0;

    assign kill_if_id_o         = redirect_valid_o;
    assign kill_id_ex_o         = redirect_valid_o;
    assign kill_ex_mem_o        = redirect_valid_o;
    assign kill_mem_wb_o        = redirect_valid_o;

endmodule

`default_nettype wire
