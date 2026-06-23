//------------------------------------------------------------------------------
// 文件      : tb/sv/tb_rv32i_soc.sv
// 用途      : RV32I SoC 级定向测试 testbench。
//
// 规范：
//   - 使用简单时钟/复位驱动，不加 UVM 等复杂框架。
//   - simple_rom/simple_ram 在 SoC 内部，通过 +imem=<hex>/+dmem=<hex> 初始化。
//   - SoC 层级路径：tb_rv32i_soc.u_soc.u_core 访问核内信号。
//
// 功能：
//   - 产生 clk/rst 驱动 rv32i_soc。
//   - 驱动 gpio0_in 为固定值，供 MMIO GPIO 读取。
//   - 当前 UART0 RX 事件固定拉低；后续 interrupt directed test 会改为 task 注入。
//   - 在每次提交时打印当前指令的 PC、原始指令、指令类型、rd 写使能和写回数据。
//   - 观察 trap/MRET trace 信号，并打印 trap_is_interrupt/trap_cause_code。
//   - 观察 GPIO0/UART0/TIMER0 interrupt 和 MEIP/MTIP 汇总信号。
//   - 观察 UART TX event 并打印字符。
//   - 通过写约定 DMEM 地址作为 PASS/FAIL 标志自动结束仿真。
//------------------------------------------------------------------------------

`default_nettype none

module tb_rv32i_soc;

    import core_pkg::*;
    import pipeline_pkg::*;
    import soc_pkg::*;

    // -------------------------------------------------------------------------
    // 时钟和复位
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever begin
            #5
            clk = ~clk;
        end
    end

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
    end

    // -------------------------------------------------------------------------
    // rv32i_soc 接口信号
    // -------------------------------------------------------------------------

    logic [31:0]                   gpio0_in;
    logic [31:0]                   gpio0_out;
    logic [31:0]                   gpio0_oe;

    logic                          uart0_tx_valid;
    logic [7:0]                    uart0_tx_data;
    logic                          uart0_rx_valid;
    logic [7:0]                    uart0_rx_data;

    logic                          data_re;
    logic                          data_we;
    logic [3:0]                    data_be;
    logic [core_pkg::XLEN-1:0]     data_addr;
    logic [core_pkg::XLEN-1:0]     data_wdata;
    logic [core_pkg::XLEN-1:0]     data_rdata;
    logic                          data_access_fault;

    logic                          dmem_access;
    logic                          mmio_access;

    logic                          commit_valid;
    logic [core_pkg::XLEN-1:0]     commit_pc;
    logic [core_pkg::ILEN-1:0]     commit_instr;
    core_pkg::instr_id_e           commit_instr_id;
    logic                          commit_reg_we;
    logic [4:0]                    commit_rd_addr;
    logic [core_pkg::XLEN-1:0]     commit_rd_wdata;

    logic                          trap_valid;
    logic [core_pkg::XLEN-1:0]     trap_pc;
    logic                          trap_is_interrupt;
    logic [4:0]                    trap_cause_code;
    logic [core_pkg::XLEN-1:0]     trap_tval;
    logic                          trap_return;
    logic [core_pkg::XLEN-1:0]     trap_redirect_pc;

    logic                          gpio0_irq;
    logic                          uart0_irq;
    logic                          timer0_irq;
    logic                          meip;
    logic                          mtip;

    // -------------------------------------------------------------------------
    // rv32i_soc 实例化
    // -------------------------------------------------------------------------
    rv32i_soc u_soc (
        .clk_i                 (clk),
        .rst_n_i               (rst_n),

        .gpio0_in_i            (gpio0_in),
        .gpio0_out_o           (gpio0_out),
        .gpio0_oe_o            (gpio0_oe),

        .uart0_tx_valid_o      (uart0_tx_valid),
        .uart0_tx_data_o       (uart0_tx_data),
        .uart0_rx_valid_i      ('0),
        .uart0_rx_data_i       ('0),

        .data_re_o             (data_re),
        .data_we_o             (data_we),
        .data_be_o             (data_be),
        .data_addr_o           (data_addr),
        .data_wdata_o          (data_wdata),
        .data_rdata_o          (data_rdata),
        .data_access_fault_o   (data_access_fault),

        .dmem_access_o         (dmem_access),
        .mmio_access_o         (mmio_access),

        .commit_valid_o        (commit_valid),
        .commit_pc_o           (commit_pc),
        .commit_instr_o        (commit_instr),
        .commit_instr_id_o     (commit_instr_id),
        .commit_reg_we_o       (commit_reg_we),
        .commit_rd_addr_o      (commit_rd_addr),
        .commit_rd_wdata_o     (commit_rd_wdata),

        .trap_valid_o          (trap_valid),
        .trap_pc_o             (trap_pc),
        .trap_is_interrupt_o   (trap_is_interrupt),
        .trap_cause_code_o     (trap_cause_code),
        .trap_tval_o           (trap_tval),
        .trap_return_o         (trap_return),
        .trap_redirect_pc_o    (trap_redirect_pc),

        .gpio0_irq_o           (gpio0_irq),
        .uart0_irq_o           (uart0_irq),
        .timer0_irq_o          (timer0_irq),
        .meip_o                (meip),
        .mtip_o                (mtip)
    );

    // -------------------------------------------------------------------------
    // GPIO0 与变动打印
    // -------------------------------------------------------------------------
    assign gpio0_in = 32'hA5A5_5A5A;

    wire  [31:0] gpio0_driven   = gpio0_out & gpio0_oe;
    logic [31:0] gpio0_driven_last;
    always_ff @(posedge clk) begin
        gpio0_driven_last <= gpio0_driven;
        if (gpio0_driven != gpio0_driven_last) begin // OE 为 1 的 bit 发生变化
            $display("--------------[%0d][GPIO_CHANGE_EVENT] gpio0_driven:0x%08h (gpio0_driven_last:0x%08h)--------------", cycle_cnt, gpio0_driven, gpio0_driven_last);
        end
    end


    // -------------------------------------------------------------------------
    // UART0 TX 字符打印
    // -------------------------------------------------------------------------
    string uart0_tx_buffer;
    always_ff @(posedge clk) begin
        if (rst_n && uart0_tx_valid) begin
            $display("**************[%0d][UART_TX_EVENT] uart0_tx_data:0x%02h('%c')**************", cycle_cnt, uart0_tx_data, uart0_tx_data);
            uart0_tx_buffer = {uart0_tx_buffer,string'(uart0_tx_data[7:0])};
        end
    end

    // -------------------------------------------------------------------------
    // cycle 计数器
    // -------------------------------------------------------------------------
    logic [31:0] cycle_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_cnt <= '0;
        end else begin
            cycle_cnt <= cycle_cnt + 1'b1;
        end
    end

    localparam logic [core_pkg::XLEN-1:0] TEST_STATUS_ADDR = core_pkg::DMEM_BASE + 32'h0000_0100;
    localparam logic [core_pkg::XLEN-1:0] TEST_PASS_VALUE  = 32'h0000_0001;

    // -------------------------------------------------------------------------
    // DMEM/stack 使用统计
    // -------------------------------------------------------------------------
    localparam logic [core_pkg::XLEN-1:0] DMEM_END_ADDR   = core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES;
    localparam logic [core_pkg::XLEN-1:0] STACK_TOP_ADDR  = DMEM_END_ADDR;
    logic                                dmem_access_seen;
    logic [core_pkg::XLEN-1:0]           dmem_min_addr;
    logic [core_pkg::XLEN-1:0]           dmem_max_addr;
    logic                                stack_active;
    logic                                sp_min_seen;
    logic [core_pkg::XLEN-1:0]           sp_min_addr;

    wire [core_pkg::XLEN-1:0] current_sp = u_soc.u_core.u_regfile.gpr_q[2];
    wire dmem_access_for_stats = rst_n
                              && dmem_access
                              && (data_re || data_we)
                              && (data_addr != TEST_STATUS_ADDR);
    wire sp_in_dmem_range = (current_sp >= core_pkg::DMEM_BASE) && (current_sp <= STACK_TOP_ADDR);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_access_seen <= 1'b0;
            dmem_min_addr    <= '1;
            dmem_max_addr    <= '0;
            stack_active     <= 1'b0;
            sp_min_seen      <= 1'b0;
            sp_min_addr      <= '1;
        end else begin
            if (dmem_access_for_stats) begin
                dmem_access_seen <= 1'b1;
                if (!dmem_access_seen || data_addr < dmem_min_addr) begin
                    dmem_min_addr <= data_addr;
                end
                if (!dmem_access_seen || data_addr > dmem_max_addr) begin
                    dmem_max_addr <= data_addr;
                end
            end

            if (current_sp == STACK_TOP_ADDR) begin
                stack_active <= 1'b1;
            end

            if ((stack_active || current_sp == STACK_TOP_ADDR) && sp_in_dmem_range) begin
                sp_min_seen <= 1'b1;
                if (!sp_min_seen || current_sp < sp_min_addr) begin
                    sp_min_addr <= current_sp;
                end
            end
        end
    end

    task automatic print_memory_usage;
        logic [core_pkg::XLEN-1:0] stack_used;
        begin
            if (dmem_access_seen) begin
                $display("DMEM access range: 0x%08h - 0x%08h", dmem_min_addr, dmem_max_addr);
            end else begin
                $display("DMEM access range: no program DMEM access");
            end

            if (sp_min_seen) begin
                stack_used = STACK_TOP_ADDR - sp_min_addr;
                $display("Stack max used:    %0d bytes", stack_used);
            end else begin
                $display("Stack max used:    SP not initialized to stack top");
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 提交监控：在每次提交时打印指令执行情况
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (commit_valid) begin
            $write("[%0d] @ %0t: PC=0x%08h Instr=0x%08h", cycle_cnt, $time, commit_pc, commit_instr);
            if (commit_reg_we) begin
                $write("   rd=x%0d <= 0x%08h", commit_rd_addr, commit_rd_wdata);
            end
            else begin
                $write("   noWB            ");
            end
            $display(" %s", commit_instr_id.name());
        end
        else begin
            $display("[%0d] @ %0t: PC=0x%08h Instr_invalid", cycle_cnt, $time, commit_pc);
        end

        if (trap_valid) begin
            $display("^^^^^^^^^^ this cycle happen trap_entry  ^^^^^^^^^^");
            $display("[TRAP_ENTRY] trap_pc   :0x%08h;    trap_redirect_pc:0x%08h", trap_pc, trap_redirect_pc);
            $display("[TRAP_ENTRY] trap_tval :0x%08h;    trap_is_interrupt:%0d;    trap_cause_code:%0d", trap_tval, trap_is_interrupt, trap_cause_code);
        end
        else if (trap_return) begin
            $display("^^^^^^^^^^ this cycle happen trap_return ^^^^^^^^^^");
            $display("[TRAP_RETURN] trap_redirect_pc:0x%08h", trap_redirect_pc);
        end

        if (test_done) begin
            if (test_passed) begin
                $display("PASS after %0d cycles", cycle_cnt);
            end
            else begin
                $display("FAIL after %0d cycles, status=0x%08h", cycle_cnt, test_status_value);
            end
            print_memory_usage();
            $display("************UART0 TX log:************\n%s\n*************************************", uart0_tx_buffer);
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // PASS/FAIL 自动检测
    // -------------------------------------------------------------------------
    logic test_done;
    logic test_passed;
    logic [core_pkg::XLEN-1:0] test_status_value;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_done         <= 1'b0;
            test_passed       <= 1'b0;
            test_status_value <= '0;
        end else if (data_we && dmem_access && data_addr == TEST_STATUS_ADDR) begin
            test_done         <= 1'b1;
            test_passed       <= (data_wdata == TEST_PASS_VALUE);
            test_status_value <= data_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // 超时保护
    // -------------------------------------------------------------------------
    initial begin
        repeat (20010) @(posedge clk);
        $display("TIMEOUT: simulation exceeded [%0d] cycles", cycle_cnt);
        $finish;
    end

endmodule

`default_nettype wire
