//------------------------------------------------------------------------------
// 文件      : tb/sv/tb_core_pipeline5.sv
// 用途      : RV32I 五级流水线教学 demo testbench。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 使用简单时钟/复位驱动，不加 UVM 等复杂框架。
//   - simple_rom 通过 +imem=<hex> 加载指令，simple_ram 通过 +dmem=<hex> 初始化数据。
//   - testbench 层级路径：tb_core_pipeline5.u_core 访问核内信号。
//
// 功能：
//   - 产生 clk/rst 驱动 core。
//   - 实例化 simple_rom/simple_ram 并连接到 core。
//   - 在每次提交时打印当前指令的 PC、原始指令、指令类型、rd 写使能和写回数据。
//   - 观察 trap/MRET trace 信号，但暂不据此判定 PASS/FAIL。
//   - 通过写约定 DMEM 地址作为 PASS/FAIL 标志自动结束仿真。
//------------------------------------------------------------------------------

`default_nettype none

module tb_core_pipeline5;

    import core_pkg::*;
    import pipeline_pkg::*;

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
    // core 接口信号
    // -------------------------------------------------------------------------
    logic [core_pkg::ILEN-1:0]     imem_rdata;
    logic [core_pkg::XLEN-1:0]     imem_addr;

    logic                          lsu_re;
    logic                          lsu_we;
    logic [3:0]                    lsu_be;
    logic [core_pkg::XLEN-1:0]     lsu_addr;
    logic [core_pkg::XLEN-1:0]     lsu_wdata;
    logic [core_pkg::XLEN-1:0]     lsu_rdata;

    logic                          commit_valid;
    logic [core_pkg::XLEN-1:0]     commit_pc;
    logic [core_pkg::ILEN-1:0]     commit_instr;
    core_pkg::instr_id_e           commit_instr_id;
    logic                          commit_reg_we;
    logic [4:0]                    commit_rd_addr;
    logic [core_pkg::XLEN-1:0]     commit_rd_wdata;

    logic                          trap_valid;
    logic [core_pkg::XLEN-1:0]     trap_pc;
    core_pkg::trap_cause_e         trap_cause;
    logic [core_pkg::XLEN-1:0]     trap_tval;
    logic                          trap_return;
    logic [core_pkg::XLEN-1:0]     trap_redirect_pc;
    // -------------------------------------------------------------------------
    // core 实例化
    // -------------------------------------------------------------------------
    core u_core (
        .clk_i              (clk),
        .rst_n_i            (rst_n),

        .imem_rdata_i       (imem_rdata),
        .imem_addr_o        (imem_addr),

        .lsu_re_o           (lsu_re),
        .lsu_we_o           (lsu_we),
        .lsu_be_o           (lsu_be),
        .lsu_addr_o         (lsu_addr),
        .lsu_wdata_o        (lsu_wdata),
        .lsu_rdata_i        (lsu_rdata),
        .lsu_access_fault_i (1'b0),     // 临时接 0 确保兼容已有仿真，后续会换为 soc 级仿真

        .commit_valid_o     (commit_valid),
        .commit_pc_o        (commit_pc),
        .commit_instr_o     (commit_instr),
        .commit_instr_id_o  (commit_instr_id),
        .commit_reg_we_o    (commit_reg_we),
        .commit_rd_addr_o   (commit_rd_addr),
        .commit_rd_wdata_o  (commit_rd_wdata),

        .trap_valid_o       (trap_valid),
        .trap_pc_o          (trap_pc),
        .trap_cause_o       (trap_cause),
        .trap_tval_o        (trap_tval),
        .trap_return_o      (trap_return),
        .trap_redirect_pc_o (trap_redirect_pc)
    );

    // -------------------------------------------------------------------------
    // simple_rom (指令存储器)
    // -------------------------------------------------------------------------
    simple_rom u_simple_rom(
        .addr_i     (imem_addr),
        .rdata_o    (imem_rdata)
    );

    // -------------------------------------------------------------------------
    // simple_ram (数据存储器)
    // -------------------------------------------------------------------------
    simple_ram u_simple_ram(
        .clk_i  (clk),
        .we_i   (lsu_we),
        .be_i   (lsu_be),
        .addr_i (lsu_addr),
        .wdata_i(lsu_wdata),
        .rdata_o(lsu_rdata)
    );

    // -------------------------------------------------------------------------
    // cycle计数器
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
    // 注意：DMEM 地址范围和**真正“用了多少 RAM”**不是完全等价的，因为程序可能
    // 访问了高地址和低地址，中间未必全用；而栈深度用 min(sp) 统计通常最有价值。
    // TEST_STATUS_ADDR 是 testbench 的结束标志地址，不计入程序自身 DMEM 访问范围。
    localparam logic [core_pkg::XLEN-1:0] DMEM_END_ADDR   = core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES;
    localparam logic [core_pkg::XLEN-1:0] STACK_TOP_ADDR  = DMEM_END_ADDR;
    logic                                dmem_access_seen;
    logic [core_pkg::XLEN-1:0]           dmem_min_addr;
    logic [core_pkg::XLEN-1:0]           dmem_max_addr;
    logic                                stack_active;
    logic                                sp_min_seen;
    logic [core_pkg::XLEN-1:0]           sp_min_addr;

    wire [core_pkg::XLEN-1:0] current_sp = u_core.u_regfile.gpr_q[2];
    wire dmem_access_for_stats = rst_n && (lsu_re || lsu_we) && (lsu_addr != TEST_STATUS_ADDR);
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
                if (!dmem_access_seen || lsu_addr < dmem_min_addr) begin
                    dmem_min_addr <= lsu_addr;
                end
                if (!dmem_access_seen || lsu_addr > dmem_max_addr) begin
                    dmem_max_addr <= lsu_addr;
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
        end
        else if (trap_return) begin
            $display("^^^^^^^^^^ this cycle happen trap_return ^^^^^^^^^^");
        end

        if (test_done) begin
            if (test_passed) begin
                $display("PASS after %0d cycles", cycle_cnt);
            end
            else begin
                $display("FAIL after %0d cycles, status=0x%08h", cycle_cnt, test_status_value);
            end
            print_memory_usage();
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // PASS/FAIL 自动检测（仅设标志，由 commit monitor 统一输出）
    // -------------------------------------------------------------------------
    logic test_done;
    logic test_passed;
    logic [core_pkg::XLEN-1:0] test_status_value;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_done         <= 1'b0;
            test_passed       <= 1'b0;
            test_status_value <= '0;
        end else if (lsu_we && lsu_addr == TEST_STATUS_ADDR) begin
            test_done         <= 1'b1;
            test_passed       <= (lsu_wdata == TEST_PASS_VALUE);
            test_status_value <= lsu_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // 超时保护：防止死循环跑不完
    // -------------------------------------------------------------------------
    initial begin
        repeat (20010) @(posedge clk);
        $display("TIMEOUT: simulation exceeded [%0d] cycles", cycle_cnt);
        $finish;
    end

endmodule

`default_nettype wire
