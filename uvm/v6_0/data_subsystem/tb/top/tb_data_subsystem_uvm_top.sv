//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/top/tb_data_subsystem_uvm_top.sv
// 用途      : v6.0 data_subsystem UVM 验证平台顶层。
//
// 规范：
//   - 负责 module/interface/DUT 等静态验证结构，UVM class 由 run_test 创建。
//   - 全局 timeout 在 run_test 前设置，防止 objection 或总线等待导致仿真挂死。
//
// 功能：
//   - 产生 100 MHz 时钟和低有效复位。
//   - 设置 UVM 全局超时并启动命令行指定的 test。
//   - 例化 simple_bus_if、response-delay wrapper interface、data_subsystem 和 simple_ram。
//   - 将 driver、monitor 和 DUT 专用配置 interface 通过 config_db 提供给 UVM test。
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_data_subsystem_uvm_top;

    import uvm_pkg::*;
    import data_subsystem_pkg::*;

    // -------------------------------------------------------------------------
    // 时钟和复位
    // -------------------------------------------------------------------------
    bit clk;
    bit rst_n;

    initial begin
        clk = 1'b0;
        forever begin
            #5ns clk = !clk;
        end
    end
    initial begin
        rst_n = 1'b0;
        repeat(5)@(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    // vif
    simple_bus_if simple_bus_vif(
        .clk_i(clk),
        .rst_n_i(rst_n)
    );
    // wrapper_vif
    wrapper_if wrapper_vif(
        .clk_i(clk),
        .rst_n_i(rst_n)
    );

    // dut
    logic                      dmem_we;
    logic [3:0]                dmem_be;
    logic [core_pkg::XLEN-1:0] dmem_addr;
    logic [core_pkg::XLEN-1:0] dmem_wdata;
    logic [core_pkg::XLEN-1:0] dmem_rdata;
    data_subsystem u_data_subsystem(
        .clk_i       (clk),
        .rst_n_i     (rst_n),

        .core_req_ready_o (simple_bus_vif.req_ready_o),
        .core_req_i       (simple_bus_vif.req_i),
        .core_resp_o      (simple_bus_vif.resp_o),

        .dmem_resp_delay_cycles_i   (wrapper_vif.dmem_resp_delay_cycles),
        .gpio0_resp_delay_cycles_i  (wrapper_vif.gpio0_resp_delay_cycles),
        .uart0_resp_delay_cycles_i  (wrapper_vif.uart0_resp_delay_cycles),
        .timer0_resp_delay_cycles_i (wrapper_vif.timer0_resp_delay_cycles),

        .dmem_we_o    (dmem_we),
        .dmem_be_o    (dmem_be),
        .dmem_addr_o  (dmem_addr),
        .dmem_wdata_o (dmem_wdata),
        .dmem_rdata_i (dmem_rdata),

        .gpio0_in_i         ('0),
        .uart0_rx_valid_i   (1'b0),
        .uart0_rx_data_i    ('0)
    );
    simple_ram u_simple_ram (
        .clk_i   (clk),
        .we_i    (dmem_we),
        .be_i    (dmem_be),
        .addr_i  (dmem_addr),
        .wdata_i (dmem_wdata),
        .rdata_o (dmem_rdata)
    );


    // -------------------------------------------------------------------------
    // UVM test 启动
    // -------------------------------------------------------------------------
    initial begin
        uvm_config_db#(virtual simple_bus_if.drv_mp)::set(
            null,
            "uvm_test_top.env.bus_agent.driver",
            "simple_bus_vif",
            simple_bus_vif.drv_mp
        );
        uvm_config_db#(virtual simple_bus_if.mon_mp)::set(
            null,
            "uvm_test_top.env.bus_agent.monitor",
            "simple_bus_vif",
            simple_bus_vif.mon_mp
        );
        uvm_config_db#(virtual wrapper_if.drv_mp)::set(
            null,
            "uvm_test_top.env.wrp_agent.driver",
            "wrapper_vif",
            wrapper_vif.drv_mp
        );
        uvm_config_db#(virtual wrapper_if.mon_mp)::set(
            null,
            "uvm_test_top.env.wrp_agent.monitor",
            "wrapper_vif",
            wrapper_vif.mon_mp
        );
        uvm_top.set_timeout(1ms,1'b1);
        run_test();
    end
    
endmodule

`default_nettype wire
