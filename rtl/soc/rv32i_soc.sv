//------------------------------------------------------------------------------
// 文件      : rtl/soc/rv32i_soc.sv
// 用途      : RV32I 教学核最小 SoC 平台顶层。
//
// 规范：
//   - 普通输入端口使用 _i 后缀，普通输出端口使用 _o 后缀。
//   - 本模块集成固定响应 IMEM、data-side simple bus 和最小 MMIO 外设。
//   - CPU core、外置 IMEM、外置 DMEM/MMIO 数据子系统在本层连接，具体 data 地址译码和 wait-state 注入由 data_subsystem 完成。
//   - data 观察口按 request/response 分组命名，避免混淆 request 意图和 response completion。
//
// 功能：
//   - 实例化 core 作为 CPU core。
//   - 透出固定响应 IMEM 端口，由 testbench 或上层 wrapper 连接 simple_rom/ROM model。
//   - 实例化 data_subsystem 作为数据侧 simple bus 译码/响应包装层，连接外置 DMEM，并包含 GPIO0、UART0、TIMER0。
//   - 将 data_subsystem response valid/rdata/error 接回 core LSU response 端口。
//   - 透出 DMEM/GPIO0/UART0/TIMER0 四个 response delay 配置输入，用于 testbench 注入 wait-state。
//   - 汇总 GPIO0/UART0 中断为 MEIP，将 TIMER0 中断作为 MTIP 接入 core。
//   - 透传 commit/trap、GPIO、UART、interrupt 和 data access 观察信号给 testbench。
//------------------------------------------------------------------------------

`default_nettype none

module rv32i_soc (
    input  logic                          clk_i,
    input  logic                          rst_n_i,

    output logic [core_pkg::XLEN-1:0]     imem_addr_o,           // 取指 byte address，连接外置固定响应 IMEM。
    input  logic [core_pkg::ILEN-1:0]     imem_rdata_i,          // 外置 IMEM 返回的 instruction。

    // ----------------------------以下连接外置 DMEM 和外设激励-----------------------------------
    output logic                          dmem_we_o,             // 外置 DMEM store 写使能。
    output logic [3:0]                    dmem_be_o,             // 外置 DMEM byte enable。
    output logic [core_pkg::XLEN-1:0]     dmem_addr_o,           // 外置 DMEM byte address。
    output logic [core_pkg::XLEN-1:0]     dmem_wdata_o,          // 外置 DMEM store 写数据。
    input  logic [core_pkg::XLEN-1:0]     dmem_rdata_i,          // 外置 DMEM load 原始 word 数据。

    input  logic [31:0]                   gpio0_in_i,            // GPIO0 输入引脚采样值。
    output logic [31:0]                   gpio0_out_o,           // GPIO0 输出寄存器值。
    output logic [31:0]                   gpio0_oe_o,            // GPIO0 输出使能寄存器值。

    output logic                          uart0_tx_valid_o,      // UART0 TX event 有效脉冲。
    output logic [7:0]                    uart0_tx_data_o,       // UART0 TX event 对应字节。
    input  logic                          uart0_rx_valid_i,      // UART0 RX event 脉冲。
    input  logic [7:0]                    uart0_rx_data_i,       // UART0 RX event 对应字节。

    input  logic [6:0]                    dmem_resp_delay_cycles_i,   // DMEM 响应延迟拍数（0=固定响应）。
    input  logic [6:0]                    gpio0_resp_delay_cycles_i,  // GPIO0 响应延迟拍数。
    input  logic [6:0]                    uart0_resp_delay_cycles_i,  // UART0 响应延迟拍数。
    input  logic [6:0]                    timer0_resp_delay_cycles_i, // TIMER0 响应延迟拍数。

    // ----------------------------以下为 commit/观察口-----------------------------------------
    // data request/response 观察口；load/store 既可能访问 DMEM，也可能访问外设寄存器。
    output logic                          data_req_ready_o,      // data-side 握手：本拍可接受 request。
    output logic                          data_req_valid_o,      // core 发起 LSU request。
    output logic                          data_req_write_o,      // 1=store，0=load。
    output logic [3:0]                    data_req_be_o,         // LSU request byte enable。
    output logic [core_pkg::XLEN-1:0]     data_req_addr_o,       // LSU request 地址。
    output logic [core_pkg::XLEN-1:0]     data_req_wdata_o,      // LSU request store 写数据。

    output logic                          data_resp_valid_o,     // data-side response 有效。
    output logic [core_pkg::XLEN-1:0]     data_resp_rdata_o,     // data-side response 读数据。
    output logic                          data_resp_error_o,     // data-side response 错误（未映射/非法）。


    output logic                          dmem_access_o,         // 本拍 data access 是否命中 DMEM。
    output logic                          mmio_access_o,         // 本拍 data access 是否命中已实现 MMIO。

    // 指令提交
    output logic                          commit_valid_o,        // 当前拍是否有有效指令提交。
    output logic [core_pkg::XLEN-1:0]     commit_pc_o,           // 提交指令的 PC。
    output logic [core_pkg::ILEN-1:0]     commit_instr_o,        // 提交指令的原始 instruction。
    output core_pkg::instr_id_e           commit_instr_id_o,     // 提交指令类型。
    output logic                          commit_reg_we_o,       // 提交指令是否写 rd。
    output logic [4:0]                    commit_rd_addr_o,      // 提交指令写回的 rd 编号。
    output logic [core_pkg::XLEN-1:0]     commit_rd_wdata_o,     // 提交指令写回 rd 的数据。

    // trap 提交
    output logic                          trap_valid_o,          // trap entry 有效（异常/中断），不含 MRET。
    output logic [core_pkg::XLEN-1:0]     trap_pc_o,             // 发生异常/中断时的指令 PC。
    output logic                          trap_is_interrupt_o,   // 该 trap 是中断。
    output logic [4:0]                    trap_cause_code_o,     // 当前 trap entry 的 cause code，配合 trap_is_interrupt_o 区分异常和中断。
    output logic [core_pkg::XLEN-1:0]     trap_tval_o,           // 异常相关附加值。
    output logic                          trap_return_o,         // MRET 返回事件有效。
    output logic [core_pkg::XLEN-1:0]     trap_redirect_pc_o,    // trap 或 MRET 的跳转目标 PC。

    // 流水线暂停观察
    output logic                          mem_wait_o,            // 因 mem wait 导致的流水线暂停

    // 中断观察
    output logic                          gpio0_irq_o,           // GPIO0 中断。
    output logic                          uart0_irq_o,           // UART0 中断。
    output logic                          timer0_irq_o,          // TIMER0 中断（MTIP）。
    output logic                          meip_o,                // MEIP = gpio0_irq_o | uart0_irq_o。
    output logic                          mtip_o                 // MTIP = timer0_irq_o。
);

    // interrupt 汇总
    wire   meip   = gpio0_irq_o | uart0_irq_o;
    wire   mtip   = timer0_irq_o;
    assign meip_o = meip;
    assign mtip_o = mtip;

    core u_core (
        .clk_i                  (clk_i),
        .rst_n_i                (rst_n_i),

        .imem_rdata_i           (imem_rdata_i),
        .imem_addr_o            (imem_addr_o),

        .lsu_req_ready_i        (data_req_ready_o),
        .lsu_req_valid_o        (data_req_valid_o),
        .lsu_req_write_o        (data_req_write_o),
        .lsu_req_be_o           (data_req_be_o),
        .lsu_req_addr_o         (data_req_addr_o),
        .lsu_req_wdata_o        (data_req_wdata_o),

        .lsu_resp_valid_i       (data_resp_valid_o),
        .lsu_resp_rdata_i       (data_resp_rdata_o),
        .lsu_resp_error_i       (data_resp_error_o),

        .mtip_i                 (mtip),
        .meip_i                 (meip),

        .commit_valid_o         (commit_valid_o),
        .commit_pc_o            (commit_pc_o),
        .commit_instr_o         (commit_instr_o),
        .commit_instr_id_o      (commit_instr_id_o),
        .commit_reg_we_o        (commit_reg_we_o),
        .commit_rd_addr_o       (commit_rd_addr_o),
        .commit_rd_wdata_o      (commit_rd_wdata_o),

        .trap_valid_o           (trap_valid_o),
        .trap_pc_o              (trap_pc_o),
        .trap_is_interrupt_o    (trap_is_interrupt_o),
        .trap_cause_code_o      (trap_cause_code_o),
        .trap_tval_o            (trap_tval_o),
        .trap_return_o          (trap_return_o),
        .trap_redirect_pc_o     (trap_redirect_pc_o),

        .mem_wait_o             (mem_wait_o)
    );

    data_subsystem u_data_subsystem (
        .clk_i                 (clk_i),
        .rst_n_i               (rst_n_i),

        .core_req_ready_o      (data_req_ready_o),
        .core_req_valid_i      (data_req_valid_o),
        .core_req_write_i      (data_req_write_o),
        .core_req_be_i         (data_req_be_o),
        .core_req_addr_i       (data_req_addr_o),
        .core_req_wdata_i      (data_req_wdata_o),
        
        .core_resp_valid_o     (data_resp_valid_o),
        .core_resp_rdata_o     (data_resp_rdata_o),
        .core_resp_error_o     (data_resp_error_o),

        .dmem_we_o             (dmem_we_o),
        .dmem_be_o             (dmem_be_o),
        .dmem_addr_o           (dmem_addr_o),
        .dmem_wdata_o          (dmem_wdata_o),
        .dmem_rdata_i          (dmem_rdata_i),

        .gpio0_in_i            (gpio0_in_i),
        .gpio0_out_o           (gpio0_out_o),
        .gpio0_oe_o            (gpio0_oe_o),

        .uart0_tx_valid_o      (uart0_tx_valid_o),
        .uart0_tx_data_o       (uart0_tx_data_o),
        .uart0_rx_valid_i      (uart0_rx_valid_i),
        .uart0_rx_data_i       (uart0_rx_data_i),

        .gpio0_irq_o           (gpio0_irq_o),
        .uart0_irq_o           (uart0_irq_o),
        .timer0_irq_o          (timer0_irq_o),

        .dmem_resp_delay_cycles_i   (dmem_resp_delay_cycles_i),
        .gpio0_resp_delay_cycles_i  (gpio0_resp_delay_cycles_i),
        .uart0_resp_delay_cycles_i  (uart0_resp_delay_cycles_i),
        .timer0_resp_delay_cycles_i (timer0_resp_delay_cycles_i),

        .dmem_access_o         (dmem_access_o),
        .mmio_access_o         (mmio_access_o)
    );

endmodule

`default_nettype wire
