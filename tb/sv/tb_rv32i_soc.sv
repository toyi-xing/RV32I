//------------------------------------------------------------------------------
// 文件      : tb/sv/tb_rv32i_soc.sv
// 用途      : RV32I SoC 级定向测试 testbench。
//
// 规范：
//   - 使用简单时钟/复位驱动，不加 UVM 等复杂框架。
//   - simple_rom/axi_lite_ram 在 testbench 内部实例化，通过 +imem=<hex>/+dmem=<hex> 初始化。
//   - SoC 层级路径：tb_rv32i_soc.u_soc.u_core 访问核内信号。
//
// 功能：
//   - 产生 clk/rst 驱动 rv32i_soc，并连接固定响应 IMEM 和 AXI-Lite DMEM 仿真模型。
//   - 监听已成功完成的 DMEM mailbox write，驱动 GPIO/UART 外部激励并完成 PASS/FAIL 判定。
//   - 驱动 gpio0_in 为固定值，供 MMIO GPIO 读取。
//   - 当前 UART0 RX 事件固定拉低；后续 interrupt directed test 会改为 task 注入。
//   - 在每次提交时打印当前指令的 PC、原始指令、指令类型、rd 写使能和写回数据。
//   - 观察 trap/MRET trace 信号，并打印 trap_is_interrupt/trap_cause_code。
//   - 观察结构体形式的 data request/response trace。
//   - 观察 GPIO0/UART0/TIMER0 interrupt 和 MEIP/MTIP 汇总信号。
//   - 观察 UART TX event 并打印字符。
//   - 通过写约定 DMEM 地址作为 PASS/FAIL 标志自动结束仿真。
//------------------------------------------------------------------------------

`default_nettype none

module tb_rv32i_soc;

    import core_pkg::*;
    import pipeline_pkg::*;
    import soc_pkg::*;
    import data_bus_pkg::*;
    import axi_lite_pkg::*;

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

    axi_lite_pkg::axi_lite_req_t   dmem_axi_req;
    axi_lite_pkg::axi_lite_resp_t  dmem_axi_resp;

    logic [31:0]                   gpio0_in;
    logic [31:0]                   gpio0_out;
    logic [31:0]                   gpio0_oe;

    logic                          uart0_tx_valid;
    logic [7:0]                    uart0_tx_data;
    logic                          uart0_rx_valid;
    logic [7:0]                    uart0_rx_data;

    logic                          data_req_ready;
    data_bus_pkg::data_req_t       data_req;
    data_bus_pkg::data_resp_t      data_resp;

    logic                          dmem_access;
    logic                          mmio_access;
    logic                          undefined_access;

    // TB mailbox 只跟踪 single-outstanding simple bus 中已接受的 DMEM write。
    wire                           data_req_fire;
    wire                           dmem_hit;
    wire                           gpio0_hit;
    wire                           uart0_hit;
    wire                           timer0_hit;
    wire                           dmem_write_accept;
    wire                           dmem_write_complete;
    reg                            dmem_write_pending_q;
    reg [core_pkg::XLEN-1:0]       dmem_write_addr_q;
    reg [core_pkg::XLEN-1:0]       dmem_write_data_q;

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
    localparam int unsigned               DMEM_DEPTH               = 1 << core_pkg::DMEM_ADDR_WIDTH;

    // gpio0[31]、gpio0[30] 接时钟信号
    localparam int   TB_GPIO0_FAST_PERIODIC_BIT  = 30;
    localparam int   TB_GPIO0_SLOW_PERIODIC_BIT  = 31;
    localparam int   TB_GPIO0_FAST_TOGGLE_CYCLES = 500;
    localparam int   TB_GPIO0_SLOW_TOGGLE_CYCLES = 2000;

    // -------------------------------------------------------------------------
    // rv32i_soc 实例化
    // -------------------------------------------------------------------------
    rv32i_soc u_soc (
        .clk_i                 (clk),
        .rst_n_i               (rst_n),

        .imem_addr_o           (imem_addr),
        .imem_rdata_i          (imem_rdata),

        .dmem_axi_req_o        (dmem_axi_req),
        .dmem_axi_resp_i       (dmem_axi_resp),

        .gpio0_in_i            (gpio0_in),
        .gpio0_out_o           (gpio0_out),
        .gpio0_oe_o            (gpio0_oe),

        .uart0_tx_valid_o      (uart0_tx_valid),
        .uart0_tx_data_o       (uart0_tx_data),
        .uart0_rx_valid_i      (uart0_rx_valid),
        .uart0_rx_data_i       (uart0_rx_data),

        .data_req_ready_o      (data_req_ready),
        .data_req_o            (data_req),
        .data_resp_o           (data_resp),

        .dmem_access_o         (dmem_access),
        .mmio_access_o         (mmio_access),
        .undefined_access_o    (undefined_access),

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

    axi_lite_ram #(
        .ADDR_WIDTH (core_pkg::DMEM_ADDR_WIDTH)
    ) u_axi_lite_ram (
        .clk_i      (clk),
        .rst_n_i    (rst_n),

        .axi_req_i  (dmem_axi_req),
        .axi_resp_o (dmem_axi_resp)
    );

    // AXI RAM 保持可综合边界，程序数据镜像由 testbench 通过层级数组加载。
    initial begin : DMEM_IMAGE_INIT
        string dmem_file;

        for (int unsigned i = 0; i < DMEM_DEPTH; i++) begin
            u_axi_lite_ram.mem[i] = '0;
        end

        if ($value$plusargs("dmem=%s", dmem_file)) begin
            $readmemh(dmem_file, u_axi_lite_ram.mem);
        end
    end

    // -------------------------------------------------------------------------
    // TB 命令执行：监听已完成的 DMEM store，驱动外部激励
    // -------------------------------------------------------------------------
    assign data_req_fire      = data_req.valid && data_req_ready;
    assign dmem_hit           = (data_req.addr >= DMEM_BASE) &&
                                (data_req.addr < (DMEM_BASE + DMEM_SIZE_BYTES));
    assign gpio0_hit          = (data_req.addr >= GPIO0_BASE) &&
                                (data_req.addr < (GPIO0_BASE + GPIO0_SIZE_BYTES));
    assign uart0_hit          = (data_req.addr >= UART0_BASE) &&
                                (data_req.addr < (UART0_BASE + UART0_SIZE_BYTES));
    assign timer0_hit         = (data_req.addr >= TIMER0_BASE) &&
                                (data_req.addr < (TIMER0_BASE + TIMER0_SIZE_BYTES));
    assign dmem_write_accept  = data_req_fire && dmem_hit && data_req.write;
    assign dmem_write_complete = data_resp.valid && dmem_write_pending_q && !data_resp.error;

    // 缓存 accepted DMEM write payload，等待其 AXI response 成功返回后再执行 TB side effect。
    always_ff @(posedge clk or negedge rst_n) begin : TB_DMEM_WRITE_TRACKER
        if (!rst_n) begin
            dmem_write_pending_q <= 1'b0;
            dmem_write_addr_q    <= '0;
            dmem_write_data_q    <= '0;
        end
        else begin
            if (dmem_write_accept) begin
                dmem_write_pending_q <= 1'b1;
                dmem_write_addr_q    <= data_req.addr;
                dmem_write_data_q    <= data_req.wdata;
            end
            if (data_resp.valid && dmem_write_pending_q) begin
                dmem_write_pending_q <= 1'b0;
            end
        end
    end

    // TB 外部激励任务。
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

    always_ff @(posedge clk) begin : TB_COMMAND_EXECUTE
        if (!rst_n) begin
            gpio0_in[29:0] <= 30'hA5A55A5A;
            uart0_rx_valid <= 1'b0;
            uart0_rx_data  <= '0;
        end
        else if (dmem_write_complete) begin
            unique case (dmem_write_addr_q)
                TB_GPIO0_SET_MASK_ADDR:  gpio0_set(dmem_write_data_q);
                TB_GPIO0_CLR_MASK_ADDR:  gpio0_clear(dmem_write_data_q);
                TB_GPIO0_PULSE_CMD_ADDR: gpio0_pulse(dmem_write_data_q);
                TB_UART0_RX_ADDR:        uart0_rx(dmem_write_data_q);
                default: ;
            endcase
        end
    end

    // gpio0[31]、gpio0[30] 接时钟信号。
    initial begin
        gpio0_in[TB_GPIO0_FAST_PERIODIC_BIT] = 1'b0;
        gpio0_in[TB_GPIO0_SLOW_PERIODIC_BIT] = 1'b0;
        fork
            forever begin
                repeat(TB_GPIO0_FAST_TOGGLE_CYCLES) @(posedge clk);
                gpio0_in[TB_GPIO0_FAST_PERIODIC_BIT] = ~gpio0_in[TB_GPIO0_FAST_PERIODIC_BIT];
            end
            forever begin
                repeat(TB_GPIO0_SLOW_TOGGLE_CYCLES) @(posedge clk);
                gpio0_in[TB_GPIO0_SLOW_PERIODIC_BIT] = ~gpio0_in[TB_GPIO0_SLOW_PERIODIC_BIT];
            end
        join_none;
    end

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
                              && data_req.valid
                              && (data_req.addr != TEST_STATUS_ADDR);
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
                if (!dmem_access_seen || data_req.addr < dmem_min_addr) begin
                    dmem_min_addr <= data_req.addr;
                end
                if (!dmem_access_seen || data_req.addr > dmem_max_addr) begin
                    dmem_max_addr <= data_req.addr;
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

        if (data_req_fire) begin
            $display("^^^^^^^^^^  this cycle accept data_req   ^^^^^^^^^^");
            if (dmem_hit) begin
                $display("################ [REQ] target=DMEM   addr=0x%08h we=%0b be=%04b ################",
                         data_req.addr, data_req.write, data_req.be);
            end
            else if (gpio0_hit) begin
                $display("################ [REQ] target=GPIO0  addr=0x%08h we=%0b be=%04b ################",
                         data_req.addr, data_req.write, data_req.be);
            end
            else if (uart0_hit) begin
                $display("################ [REQ] target=UART0  addr=0x%08h we=%0b be=%04b ################",
                         data_req.addr, data_req.write, data_req.be);
            end
            else if (timer0_hit) begin
                $display("################ [REQ] target=TIMER0 addr=0x%08h we=%0b be=%04b ################",
                         data_req.addr, data_req.write, data_req.be);
            end
            else if (undefined_access) begin
                $display("################ [REQ] target=UNDEF  addr=0x%08h we=%0b be=%04b ################",
                         data_req.addr, data_req.write, data_req.be);
            end
        end
        if (mem_wait) begin
            $display("^^^^^^^^^^        pipeline pausing       ^^^^^^^^^^");
            $display("................ [%0d][MEM_WAIT] req_valid=%0b req_ready=%0b resp_valid=%0b addr=0x%08h ................",
                  cycle_cnt, data_req.valid, data_req_ready, data_resp.valid, data_req.addr);
        end
        if (data_resp.valid) begin
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
        end else if (dmem_write_complete && dmem_write_addr_q == TEST_STATUS_ADDR) begin
            test_done         <= 1'b1;
            test_passed       <= (dmem_write_data_q == TEST_PASS_VALUE);
            test_status_value <= dmem_write_data_q;
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
