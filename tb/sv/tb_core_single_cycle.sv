//------------------------------------------------------------------------------
// 文件      : sim/tb_core_single_cycle.sv
// 用途      : RV32I 单周期教学 demo testbench。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 使用简单时钟/复位驱动，不加 UVM 等复杂框架。
//   - simple_rom 通过 +imem=<hex> 加载指令，simple_ram 通过 +dmem=<hex> 初始化数据。
//   - testbench 层级路径：tb_core_single_cycle.u_core 访问核内信号。
//
// 功能：
//   - 产生 clk/rst 驱动 core_single_cycle。
//   - 实例化 simple_rom/simple_ram 并连接到 core。
//   - 在每次提交时打印当前指令的 PC、原始指令、rd 写使能和写回数据。
//   - 监控 illegal_instr_o 和 mem_misaligned_o。
//   - 通过写约定 DMEM 地址作为 PASS/FAIL 标志自动结束仿真。
//------------------------------------------------------------------------------

`default_nettype none

module tb_core_single_cycle;

    import core_pkg::*;

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
    // core_single_cycle 接口信号
    // -------------------------------------------------------------------------
    logic [ILEN-1:0]     imem_rdata;
    logic [XLEN-1:0]     imem_addr;

    logic                dmem_re;
    logic                dmem_we;
    logic [3:0]          dmem_be;
    logic [XLEN-1:0]     dmem_addr;
    logic [XLEN-1:0]     dmem_wdata;
    logic [XLEN-1:0]     dmem_rdata;

    logic                commit_valid;
    logic [XLEN-1:0]     commit_pc;
    logic [ILEN-1:0]     commit_instr;
    logic                commit_reg_we;
    logic [4:0]          commit_rd_addr;
    logic [XLEN-1:0]     commit_rd_wdata;
    logic                illegal_instr;
    logic                mem_misaligned;

    // -------------------------------------------------------------------------
    // core 实例化
    // -------------------------------------------------------------------------
    core_single_cycle u_core (
        .clk_i              (clk),
        .rst_n_i            (rst_n),

        .imem_rdata_i       (imem_rdata),
        .imem_addr_o        (imem_addr),

        .dmem_re_o          (dmem_re),
        .dmem_we_o          (dmem_we),
        .dmem_be_o          (dmem_be),
        .dmem_addr_o        (dmem_addr),
        .dmem_wdata_o       (dmem_wdata),
        .dmem_rdata_i       (dmem_rdata),

        .commit_valid_o     (commit_valid),
        .commit_pc_o        (commit_pc),
        .commit_instr_o     (commit_instr),
        .commit_reg_we_o    (commit_reg_we),
        .commit_rd_addr_o   (commit_rd_addr),
        .commit_rd_wdata_o  (commit_rd_wdata),
        .illegal_instr_o    (illegal_instr),
        .mem_misaligned_o   (mem_misaligned)
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
        .we_i   (dmem_we),
        .be_i   (dmem_be),
        .addr_i (dmem_addr),
        .wdata_i(dmem_wdata),
        .rdata_o(dmem_rdata)
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

    // -------------------------------------------------------------------------
    // 提交监控：在每次提交时打印指令执行情况
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (commit_valid) begin
            $write("[%0d] @ %0t: PC=0x%08h Instr=0x%08h", cycle_cnt, $time, commit_pc, commit_instr);
            if (commit_reg_we) begin
                $write("   rd=x%0d <= 0x%08h", commit_rd_addr, commit_rd_wdata);
            end else begin
                $write("   noWB            ");
            end
            //illegal/misaligned 时自动 FAIL （当前版本测试指令保证合法+对齐）
            if (illegal_instr) begin
                $write(" ILLEGAL ");
                $finish;
            end
            if (mem_misaligned) begin
                $write(" MISALIGN");
                $finish;
            end 
            $display("");
        end

        if (test_done) begin
            if (test_passed) begin
                $display("PASS after %0d cycles", cycle_cnt);
            end else begin
                $display("FAIL after %0d cycles, status=0x%08h", cycle_cnt, dmem_wdata);
            end
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // PASS/FAIL 自动检测（仅设标志，由 commit monitor 统一输出）
    // -------------------------------------------------------------------------
    // smoke检测: 约定 dmem 的一个 word 地址作为测试结果标志。
    // 例如：DMEM_BASE + 0x100，写入 1 表示 PASS，写入 2 表示 FAIL。
    // 在 simple_ram 的写路径上加监控，或通过 always_ff @(posedge clk) 轮询 dmem_we 和 dmem_addr。
    // 检测到后打印 "PASS" / "FAIL" 并 $finish。
    // 对应 smoke 程序最后做：
    // lui  x10, 0x10        # x10 = DMEM_BASE = 0x00010000 
    // addi x11, x0, 1       # PASS
    // sw   x11, 0x100(x10)  # 写 TEST_STATUS_ADDR

    localparam logic [core_pkg::XLEN-1:0] TEST_STATUS_ADDR = core_pkg::DMEM_BASE + 32'h0000_0100;
    localparam logic [core_pkg::XLEN-1:0] TEST_PASS_VALUE  = 32'h0000_0001;
    logic test_done;
    logic test_passed;

    always_ff @(posedge clk) begin
        if (rst_n && dmem_we && dmem_addr == TEST_STATUS_ADDR) begin
            test_done   <= 1'b1;
            test_passed <= (dmem_wdata == TEST_PASS_VALUE);
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
