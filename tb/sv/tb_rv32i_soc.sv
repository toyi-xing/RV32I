//------------------------------------------------------------------------------
// 文件      : tb/sv/tb_rv32i_soc.sv
// 用途      : RV32I SoC 级定向测试 testbench。
//
// 规范：
//   - 使用简单时钟/复位驱动，不加 UVM 等复杂框架。
//   - simple_rom/simple_ram 在 testbench 内部实例化，通过 +imem=<hex>/+dmem=<hex> 初始化。
//   - SoC 层级路径：tb_rv32i_soc.u_soc.u_core 访问核内信号。
//
// 功能：
//   - 产生 clk/rst 驱动 rv32i_soc，并连接固定响应 IMEM/DMEM 仿真模型。
//   - 通过 TB mailbox 配置 data-side target response delay，用于验证 MEM backpressure。
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

    logic [core_pkg::XLEN-1:0]     imem_addr;
    logic [core_pkg::ILEN-1:0]     imem_rdata;

    logic                          dmem_we;
    logic [3:0]                    dmem_be;
    logic [core_pkg::XLEN-1:0]     dmem_addr;
    logic [core_pkg::XLEN-1:0]     dmem_wdata;
    logic [core_pkg::XLEN-1:0]     dmem_rdata;

    logic [31:0]                   gpio0_in;
    logic [31:0]                   gpio0_out;
    logic [31:0]                   gpio0_oe;

    logic                          uart0_tx_valid;
    logic [7:0]                    uart0_tx_data;
    logic                          uart0_rx_valid;
    logic [7:0]                    uart0_rx_data;

    logic [6:0]                    dmem_resp_delay_cycles;
    logic [6:0]                    gpio0_resp_delay_cycles;
    logic [6:0]                    uart0_resp_delay_cycles;
    logic [6:0]                    timer0_resp_delay_cycles;

    logic                          data_req_ready;
    logic                          data_req_valid;
    logic                          data_req_write;
    logic [3:0]                    data_req_be;
    logic [core_pkg::XLEN-1:0]     data_req_addr;
    logic [core_pkg::XLEN-1:0]     data_req_wdata;

    logic                          data_resp_valid;
    logic [core_pkg::XLEN-1:0]     data_resp_rdata;
    logic                          data_resp_error;

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

    logic                          mem_wait;

    logic                          gpio0_irq;
    logic                          uart0_irq;
    logic                          timer0_irq;
    logic                          meip;
    logic                          mtip;

    // -------------------------------------------------------------------------
    // TB command mailbox 地址定义
    // -------------------------------------------------------------------------
    // crt0.S 写此地址通知仿真结束，testbench 检测后打印 PASS/FAIL。
    localparam logic [core_pkg::XLEN-1:0] TEST_STATUS_ADDR = core_pkg::DMEM_BASE + 32'h0000_0100;
    localparam logic [core_pkg::XLEN-1:0] TEST_PASS_VALUE  = 32'h0000_0001;

    // 软件 store 到以下地址时，testbench 驱动对应的外部激励。
    localparam logic [core_pkg::XLEN-1:0] TB_CMD_BASE              = core_pkg::DMEM_BASE + 32'h180;
    localparam logic [core_pkg::XLEN-1:0] TB_GPIO0_SET_MASK_ADDR   = TB_CMD_BASE + 32'h00;
    localparam logic [core_pkg::XLEN-1:0] TB_GPIO0_CLR_MASK_ADDR   = TB_CMD_BASE + 32'h04;
    localparam logic [core_pkg::XLEN-1:0] TB_GPIO0_PULSE_CMD_ADDR  = TB_CMD_BASE + 32'h08;
    localparam logic [core_pkg::XLEN-1:0] TB_UART0_RX_ADDR         = TB_CMD_BASE + 32'h0c;
    localparam logic [core_pkg::XLEN-1:0] TB_RESP_DELAY_CFG0       = TB_CMD_BASE + 32'h10;

    // gpio0[31]、gpio0[30] 接时钟信号
    localparam int   TB_GPIO0_FAST_PERIODIC_BIT  = 30;
    localparam int   TB_GPIO0_SLOW_PERIODIC_BIT  = 31;
    localparam int   TB_GPIO0_FAST_TOGGLE_CYCLES = 200;
    localparam int   TB_GPIO0_SLOW_TOGGLE_CYCLES = 2000;

    // -------------------------------------------------------------------------
    // rv32i_soc 实例化
    // -------------------------------------------------------------------------
    rv32i_soc u_soc (
        .clk_i                 (clk),
        .rst_n_i               (rst_n),

        .imem_addr_o           (imem_addr),
        .imem_rdata_i          (imem_rdata),

        .dmem_we_o             (dmem_we),
        .dmem_be_o             (dmem_be),
        .dmem_addr_o           (dmem_addr),
        .dmem_wdata_o          (dmem_wdata),
        .dmem_rdata_i          (dmem_rdata),

        .gpio0_in_i            (gpio0_in),
        .gpio0_out_o           (gpio0_out),
        .gpio0_oe_o            (gpio0_oe),

        .uart0_tx_valid_o      (uart0_tx_valid),
        .uart0_tx_data_o       (uart0_tx_data),
        .uart0_rx_valid_i      (uart0_rx_valid),
        .uart0_rx_data_i       (uart0_rx_data),

        .dmem_resp_delay_cycles_i   (dmem_resp_delay_cycles),
        .gpio0_resp_delay_cycles_i  (gpio0_resp_delay_cycles),
        .uart0_resp_delay_cycles_i  (uart0_resp_delay_cycles),
        .timer0_resp_delay_cycles_i (timer0_resp_delay_cycles),

        .data_req_ready_o      (data_req_ready),
        .data_req_valid_o      (data_req_valid),
        .data_req_write_o      (data_req_write),
        .data_req_be_o         (data_req_be),
        .data_req_addr_o       (data_req_addr),
        .data_req_wdata_o      (data_req_wdata),

        .data_resp_valid_o     (data_resp_valid),
        .data_resp_rdata_o     (data_resp_rdata),
        .data_resp_error_o     (data_resp_error),

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

        .mem_wait_o            (mem_wait),

        .gpio0_irq_o           (gpio0_irq),
        .uart0_irq_o           (uart0_irq),
        .timer0_irq_o          (timer0_irq),
        .meip_o                (meip),
        .mtip_o                (mtip)
    );

    simple_rom u_simple_rom (
        .addr_i     (imem_addr),
        .rdata_o    (imem_rdata)
    );

    simple_ram #(
        .ADDR_WIDTH (core_pkg::DMEM_ADDR_WIDTH)
    ) u_simple_ram (
        .clk_i   (clk),
        .we_i    (dmem_we),
        .be_i    (dmem_be),
        .addr_i  (dmem_addr),
        .wdata_i (dmem_wdata),
        .rdata_o (dmem_rdata)
    );

    // -------------------------------------------------------------------------
    // TB 命令执行：监听 DMEM store，驱动外部激励
    // -------------------------------------------------------------------------
    localparam logic [XLEN-1:0] RESET_RESP_DELAY_CFG = 32'h0000_0000;   // dmem、外设的默认 resp 响应延迟配置
    logic [31:0] resp_delay_cfg0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin    // soc rst 期间输出无意义
            gpio0_in[29:0]  <= 30'hA5A55A5A;
            uart0_rx_valid  <= 1'b0;
            uart0_rx_data   <= '0;
            resp_delay_cfg0 <= RESET_RESP_DELAY_CFG;
            dmem_resp_delay_cycles   <= RESET_RESP_DELAY_CFG[6:0];
            gpio0_resp_delay_cycles  <= RESET_RESP_DELAY_CFG[14:8];
            uart0_resp_delay_cycles  <= RESET_RESP_DELAY_CFG[22:16];
            timer0_resp_delay_cycles <= RESET_RESP_DELAY_CFG[30:24];
        end
        // 直接使用 dmem 接受的结果，无需再判断握手
        else begin
            random_resp_delay_stimulus();
            if (dmem_we) begin
                unique case (dmem_addr)
                    TB_GPIO0_SET_MASK_ADDR:  gpio0_set(dmem_wdata);
                    TB_GPIO0_CLR_MASK_ADDR:  gpio0_clear(dmem_wdata);
                    TB_GPIO0_PULSE_CMD_ADDR: gpio0_pulse(dmem_wdata);
                    TB_UART0_RX_ADDR:        uart0_rx(dmem_wdata);
                    TB_RESP_DELAY_CFG0:      set_resp_delay_cfg0(dmem_wdata);
                    default: ;
                endcase
            end
        end
    end

    // gpio0[31]、gpio0[30] 接时钟信号
    initial begin
        gpio0_in[TB_GPIO0_FAST_PERIODIC_BIT] = 1'b0;
        gpio0_in[TB_GPIO0_SLOW_PERIODIC_BIT] = 1'b0;
        // 并行开启两个独立线程
        fork
            // 线程1：快速翻转
            forever begin
                repeat(TB_GPIO0_FAST_TOGGLE_CYCLES) @(posedge clk);
                gpio0_in[TB_GPIO0_FAST_PERIODIC_BIT] = ~gpio0_in[TB_GPIO0_FAST_PERIODIC_BIT];
            end
            // 线程2：慢速翻转
            forever begin
                repeat(TB_GPIO0_SLOW_TOGGLE_CYCLES) @(posedge clk);
                gpio0_in[TB_GPIO0_SLOW_PERIODIC_BIT] = ~gpio0_in[TB_GPIO0_SLOW_PERIODIC_BIT];
            end
        join_none;
    end
    
    // tb 驱动任务
    task automatic gpio0_set(input [31:0] mask);
        gpio0_in[29:0] <= gpio0_in[29:0] |  mask[29:0];
    endtask
    task automatic gpio0_clear(input [31:0] mask);
        gpio0_in[29:0] <= gpio0_in[29:0] & ~mask[29:0];
    endtask
    task automatic gpio0_pulse(input [31:0] mask);
        logic [4:0] gpio0_idx     = mask[4:0];
        logic       pulse_level   = mask[8];
        logic [7:0] pulse_cycles  = mask[23:16];
        logic       level_initial = gpio0_in[gpio0_idx];
        gpio0_in[gpio0_idx] <= !pulse_level;
        @(posedge clk);
        gpio0_in[gpio0_idx] <=  pulse_level;
        repeat(int'(pulse_cycles)) @(posedge clk);
        gpio0_in[gpio0_idx] <= !pulse_level;
        @(posedge clk);
        gpio0_in[gpio0_idx] <= level_initial;
    endtask
    task automatic uart0_rx(input [31:0] mask);
        uart0_rx_data  <= mask[7:0];
        uart0_rx_valid <= 1'b1;
        @(posedge clk);
        uart0_rx_valid <= 1'b0;
    endtask
    // 包含 dmem、gpio0、uart0、timer0 的访问延迟设置
        // 随机数函数
    function automatic logic [6:0] random_delay(input logic [6:0] max_delay);
        int unsigned r;
        begin
            if (max_delay == 7'b0) begin
                random_delay = 7'b0;
            end else begin
                r = $urandom_range({25'b0,max_delay},0);
                random_delay = r[6:0];
            end
        end
    endfunction
        // 配置 cfg 与首次驱动激励
    task automatic set_resp_delay_cfg0(input [31:0] cfg);
        resp_delay_cfg0 <= cfg;
        dmem_resp_delay_cycles   <= cfg[7]  ? random_delay(cfg[6:0])   : cfg[6:0];
        gpio0_resp_delay_cycles  <= cfg[15] ? random_delay(cfg[14:8])  : cfg[14:8];
        uart0_resp_delay_cycles  <= cfg[23] ? random_delay(cfg[22:16]) : cfg[22:16];
        timer0_resp_delay_cycles <= cfg[31] ? random_delay(cfg[30:24]) : cfg[30:24];
    endtask
    // dmem、gpio0、uart0、timer0 的随机访问延迟激励
    wire data_req_fire = data_req_valid & data_req_ready;
    wire dmem_hit   = (data_req_addr >= DMEM_BASE)   & (data_req_addr < DMEM_BASE   + DMEM_SIZE_BYTES);
    wire gpio0_hit  = (data_req_addr >= GPIO0_BASE)  & (data_req_addr < GPIO0_BASE  + GPIO0_SIZE_BYTES);
    wire uart0_hit  = (data_req_addr >= UART0_BASE)  & (data_req_addr < UART0_BASE  + UART0_SIZE_BYTES);
    wire timer0_hit = (data_req_addr >= TIMER0_BASE) & (data_req_addr < TIMER0_BASE + TIMER0_SIZE_BYTES);
    task automatic random_resp_delay_stimulus();
        if (data_req_fire) begin
            if (dmem_hit   && resp_delay_cfg0[7]) begin
                dmem_resp_delay_cycles   <= random_delay(resp_delay_cfg0[6:0]);
            end
            if (gpio0_hit  && resp_delay_cfg0[15]) begin
                gpio0_resp_delay_cycles  <= random_delay(resp_delay_cfg0[14:8]);
            end
            if (uart0_hit  && resp_delay_cfg0[23]) begin
                uart0_resp_delay_cycles  <= random_delay(resp_delay_cfg0[22:16]);
            end
            if (timer0_hit && resp_delay_cfg0[31]) begin
                timer0_resp_delay_cycles <= random_delay(resp_delay_cfg0[30:24]);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // GPIO0 与变动打印
    // -------------------------------------------------------------------------
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
    logic [31:0] cycle_cnt, trap_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_cnt <= '0;
            trap_cnt  <= '0;
        end else begin
            cycle_cnt <= cycle_cnt + 1'b1;
            trap_cnt  <= trap_valid ? trap_cnt + 1 : trap_cnt;
        end
    end

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
                              && data_req_valid
                              && (data_req_addr != TEST_STATUS_ADDR);
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
                if (!dmem_access_seen || data_req_addr < dmem_min_addr) begin
                    dmem_min_addr <= data_req_addr;
                end
                if (!dmem_access_seen || data_req_addr > dmem_max_addr) begin
                    dmem_max_addr <= data_req_addr;
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

        if (data_req_valid && data_req_ready) begin
            $display("^^^^^^^^^^  this cycle accept data_req   ^^^^^^^^^^");
        end
        if (mem_wait) begin
            $display("^^^^^^^^^^        pipeline pausing       ^^^^^^^^^^");
            $display("################ [%0d][MEM_WAIT] req_valid=%0b req_ready=%0b resp_valid=%0b addr=0x%08h ################",
                  cycle_cnt, data_req_valid, data_req_ready, data_resp_valid, data_req_addr);
        end
        if (data_resp_valid) begin
            $display("^^^^^^^^^^  this cycle happen data_resp  ^^^^^^^^^^");
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
            $display("trap_cnt:%0d", trap_cnt);
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
        end else if (dmem_we && dmem_addr == TEST_STATUS_ADDR) begin
            test_done         <= 1'b1;
            test_passed       <= (dmem_wdata == TEST_PASS_VALUE);
            test_status_value <= dmem_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // 超时保护
    // -------------------------------------------------------------------------
    initial begin
        repeat (30010) @(posedge clk);
        $display("TIMEOUT: simulation exceeded [%0d] cycles", cycle_cnt);
        $display("trap_cnt:%0d", trap_cnt);
        $finish;
    end

endmodule

`default_nettype wire
