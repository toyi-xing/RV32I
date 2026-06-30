//------------------------------------------------------------------------------
// 文件      : rtl/core/pipeline_ctrl.sv
// 用途      : 流水线控制单元，统一整合非 trap 类 stall/flush/redirect 与 memory backpressure。
// 说明      : 本模块只整合非 trap 类流水线控制；exception/interrupt/MRET 的 redirect、kill
//             和 CSR 副作用由 trap_ctrl 负责。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块实例化 hazard_unit 处理 local late-result-use stall。
//   - 本模块将 memory wait backpressure 合并到 PC、IF/ID、ID/EX、EX/MEM 的 stall 信号中。
//   - 本模块汇总并屏蔽非 trap 类 PC redirect；当前第一版来源只有 EX redirect。
//
// 功能：
//   - late-result-use stall 时冻结 PC 和 IF/ID，并向 ID/EX 插入 bubble。
//   - memory wait 时冻结 PC、IF/ID、ID/EX、EX/MEM，避免 younger 指令越过 older MEM 指令。
//   - memory wait 期间屏蔽非 trap redirect 和对应 flush。
//   - EX 边界 non-trap redirect 生效时 flush IF/ID 和 ID/EX。
//   - trap/MRET redirect 不由本模块决定，由 trap_ctrl 使用 kill 口径直接处理。
//------------------------------------------------------------------------------

`default_nettype none

module pipeline_ctrl (
    // ID 阶段信息 —— late-result-use stall 检测
    input  logic                      if_id_valid_i,            // IF/ID 阶段是否有效
    input  logic [4:0]                id_rs1_addr_i,            // ID 阶段译码得到的 rs1 地址
    input  logic [4:0]                id_rs2_addr_i,            // ID 阶段译码得到的 rs2 地址
    input  logic                      id_uses_rs1_i,            // ID 指令是否真实使用 rs1
    input  logic                      id_uses_rs2_i,            // ID 指令是否真实使用 rs2

    // ID/EX 阶段信息 —— late-result-use stall 检测
    input  logic                      id_ex_valid_i,            // ID/EX 阶段是否有有效指令
    input  logic [4:0]                id_ex_rd_addr_i,          // ID/EX 指令的写回 rd 地址
    input  logic                      id_ex_reg_we_i,           // ID/EX 指令是否写 GPR
    input  logic                      id_ex_load_re_i,          // ID/EX 是否为 load
    input  logic                      id_ex_csr_re_i,           // ID/EX 是否为 CSR

    // memory backpressure
    input  logic                      mem_wait_i,               // MEM 阶段因 data transaction 未完成而需冻结前级流水线

    // control hazard
    input  logic                      ex_redirect_valid_i,      // ex 阶段指令是否 redirect
    input  logic [core_pkg::XLEN-1:0] ex_redirect_pc_i,         // ex 阶段指令的 redirect pc

    output logic                      nontrap_redirect_valid_o, // 是否发生非 trap 类的 redirect，当前仅 ex_redirect_valid 的 branch/jump
    output logic [core_pkg::XLEN-1:0] nontrap_redirect_pc_o,    // 非 trap 类的 redirect pc

    // stall 输出
    output logic                      stall_pc_o,
    output logic                      stall_if_id_o,
    output logic                      stall_id_ex_o,
    output logic                      stall_ex_mem_o,

    // bubble/flush 输出
    output logic                      bubble_ex_o,
    output logic                      flush_if_id_o,
    output logic                      flush_id_ex_o
);
    import core_pkg::*;
    import pipeline_pkg::*;

    // stall_mem_backpressure：memory wait 时整条流水线前端暂停
    wire stall_late_result_use;
    wire stall_mem_backpressure = mem_wait_i;

    // hazard_unit：只检测 late-result-use RAW hazard。
    hazard_unit u_hazard_unit (
        .if_id_valid_i              (if_id_valid_i),
        .id_rs1_addr_i              (id_rs1_addr_i),
        .id_rs2_addr_i              (id_rs2_addr_i),
        .id_uses_rs1_i              (id_uses_rs1_i),
        .id_uses_rs2_i              (id_uses_rs2_i),

        .id_ex_valid_i              (id_ex_valid_i),
        .id_ex_rd_addr_i            (id_ex_rd_addr_i),
        .id_ex_reg_we_i             (id_ex_reg_we_i),
        .id_ex_load_re_i            (id_ex_load_re_i),
        .id_ex_csr_re_i             (id_ex_csr_re_i),

        .stall_late_result_use_o    (stall_late_result_use)
    );

    // 目前非 trap 重定向仅 ex 边界得出
    // mem_wait 时按照语义，冻结前级流水
    assign nontrap_redirect_valid_o = ex_redirect_valid_i & !mem_wait_i;
    assign nontrap_redirect_pc_o    = ex_redirect_pc_i;

    assign stall_pc_o     = stall_late_result_use | stall_mem_backpressure;
    assign stall_if_id_o  = stall_late_result_use | stall_mem_backpressure;
    assign stall_id_ex_o  = stall_mem_backpressure;
    assign stall_ex_mem_o = stall_mem_backpressure;

    assign bubble_ex_o    = stall_late_result_use & !mem_wait_i;
    assign flush_if_id_o  = ex_redirect_valid_i   & !mem_wait_i;
    assign flush_id_ex_o  = ex_redirect_valid_i   & !mem_wait_i;

endmodule

`default_nettype wire
