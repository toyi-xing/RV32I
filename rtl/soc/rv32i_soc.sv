//------------------------------------------------------------------------------
// 文件      : rtl/soc/rv32i_soc.sv
// 用途      : RV32I 教学核最小 SoC 平台顶层。
//
// 规范：
//   - 普通输入端口使用 _i 后缀，普通输出端口使用 _o 后缀。
//   - 本模块只做固定响应平台集成，不实现额外总线协议或 ready/valid backpressure。
//   - CPU core、IMEM、DMEM/MMIO 数据子系统在本层连接，具体地址译码由 data_subsystem 完成。
//
// 功能：
//   - 实例化 core 作为 CPU core。
//   - 实例化 simple_rom 作为 IMEM。
//   - 实例化 data_subsystem 作为 DMEM/MMIO 数据侧。
//   - 将 data_subsystem.core_access_fault_o 接回 core.lsu_access_fault_i。
//   - 透传 commit/trap、GPIO、UART 和 data access 观察信号给 testbench。
//------------------------------------------------------------------------------

`default_nettype none

module rv32i_soc (
    input  logic                          clk_i,
    input  logic                          rst_n_i,

    input  logic [31:0]                   gpio0_in_i,            // GPIO0 输入引脚采样值。
    output logic [31:0]                   gpio0_out_o,           // GPIO0 输出寄存器值。
    output logic [31:0]                   gpio0_oe_o,            // GPIO0 输出使能寄存器值。

    output logic                          uart0_tx_valid_o,      // UART0 TX event 有效脉冲。
    output logic [7:0]                    uart0_tx_data_o,       // UART0 TX event 对应字节。

    // load/store 指令既可能是访问 dmem,也可能是访问外设寄存器
    output logic                          data_re_o,             // load 指令观察口。
    output logic                          data_we_o,             // store 指令观察口。
    output logic [3:0]                    data_be_o,             // load/store 指令字节使能观察口。
    output logic [core_pkg::XLEN-1:0]     data_addr_o,           // load/store 指令地址观察口。
    output logic [core_pkg::XLEN-1:0]     data_wdata_o,          // store 指令写数据观察口。
    output logic [core_pkg::XLEN-1:0]     data_rdata_o,          // load 指令读数据观察口。
    output logic                          data_access_fault_o,   // data_subsystem 返回给 core 的 access fault 观察口。

    output logic                          dmem_access_o,         // 本拍 data access 是否命中 DMEM。
    output logic                          mmio_access_o,         // 本拍 data access 是否命中已实现 MMIO。

    output logic                          commit_valid_o,        // 当前拍是否有有效指令提交。
    output logic [core_pkg::XLEN-1:0]     commit_pc_o,           // 提交指令的 PC。
    output logic [core_pkg::ILEN-1:0]     commit_instr_o,        // 提交指令的原始 instruction。
    output core_pkg::instr_id_e           commit_instr_id_o,     // 提交指令类型。
    output logic                          commit_reg_we_o,       // 提交指令是否写 rd。
    output logic [4:0]                    commit_rd_addr_o,      // 提交指令写回的 rd 编号。
    output logic [core_pkg::XLEN-1:0]     commit_rd_wdata_o,     // 提交指令写回 rd 的数据。

    output logic                          trap_valid_o,          // trap entry 有效（异常/中断），不含 MRET。
    output logic [core_pkg::XLEN-1:0]     trap_pc_o,             // 发生异常/中断时的指令 PC。
    output core_pkg::excp_cause_e         trap_cause_o,          // 当前 trap entry 的 exception cause；interrupt 接入后将改为 code+kind。
    output logic [core_pkg::XLEN-1:0]     trap_tval_o,           // 异常相关附加值。
    output logic                          trap_return_o,         // MRET 返回事件有效。
    output logic [core_pkg::XLEN-1:0]     trap_redirect_pc_o     // trap 或 MRET 的跳转目标 PC。
);

    // core <-> IMEM
    wire [core_pkg::ILEN-1:0]     core_imem_rdata;
    wire [core_pkg::XLEN-1:0]     core_imem_addr;

    core u_core (
        .clk_i                  (clk_i),
        .rst_n_i                (rst_n_i),

        .imem_rdata_i           (core_imem_rdata),
        .imem_addr_o            (core_imem_addr),

        .lsu_re_o               (data_re_o),
        .lsu_we_o               (data_we_o),
        .lsu_be_o               (data_be_o),
        .lsu_addr_o             (data_addr_o),
        .lsu_wdata_o            (data_wdata_o),
        .lsu_rdata_i            (data_rdata_o),
        .lsu_access_fault_i     (data_access_fault_o),

        .mtip_i                 (1'b0),// 先接 0，第 10 步统一改
        .meip_i                 (1'b0),// 先接 0，第 10 步统一改

        .commit_valid_o         (commit_valid_o),
        .commit_pc_o            (commit_pc_o),
        .commit_instr_o         (commit_instr_o),
        .commit_instr_id_o      (commit_instr_id_o),
        .commit_reg_we_o        (commit_reg_we_o),
        .commit_rd_addr_o       (commit_rd_addr_o),
        .commit_rd_wdata_o      (commit_rd_wdata_o),

        .trap_valid_o           (trap_valid_o),
        .trap_pc_o              (trap_pc_o),
        .trap_is_interrupt_o    (),// 第 10 步统一改
        .trap_cause_code_o      (5'(trap_cause_o)),// 第 10 步统一改
        .trap_tval_o            (trap_tval_o),
        .trap_return_o          (trap_return_o),
        .trap_redirect_pc_o     (trap_redirect_pc_o)
    );

    simple_rom u_simple_rom (
        .addr_i     (core_imem_addr),
        .rdata_o    (core_imem_rdata)
    );

    data_subsystem u_data_subsystem (
        .clk_i                 (clk_i),
        .rst_n_i               (rst_n_i),

        .core_re_i             (data_re_o),
        .core_we_i             (data_we_o),
        .core_be_i             (data_be_o),
        .core_addr_i           (data_addr_o),
        .core_wdata_i          (data_wdata_o),
        .core_rdata_o          (data_rdata_o),
        .core_access_fault_o   (data_access_fault_o),

        .gpio0_in_i            (gpio0_in_i),
        .gpio0_out_o           (gpio0_out_o),
        .gpio0_oe_o            (gpio0_oe_o),

        .uart0_tx_valid_o      (uart0_tx_valid_o),
        .uart0_tx_data_o       (uart0_tx_data_o),

        .dmem_access_o         (dmem_access_o),
        .mmio_access_o         (mmio_access_o)
    );

endmodule

`default_nettype wire
