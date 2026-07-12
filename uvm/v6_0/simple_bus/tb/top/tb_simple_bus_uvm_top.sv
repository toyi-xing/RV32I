//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/top/tb_simple_bus_uvm_top.sv
// 用途      : v6.0 simple data bus UVM 验证平台顶层。
//
// 规范：
//   - 负责 module/interface/DUT 等静态验证结构，UVM class 由 run_test 创建。
//   - 全局 timeout 在 run_test 前设置，防止 objection 或总线等待导致仿真挂死。
//
// 功能：
//   - 产生 100 MHz 时钟和低有效复位。
//   - 设置 UVM 全局超时并启动命令行指定的 test。
//   - 已例化 simple_bus_if，后续在本模块中接入 DUT 和 virtual interface 配置。
//------------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_simple_bus_uvm_top;

    import uvm_pkg::*;
    import simple_bus_pkg::*;

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


    // -------------------------------------------------------------------------
    // UVM test 启动
    // -------------------------------------------------------------------------
    initial begin
        uvm_top.set_timeout(1ms,1'b0);
        run_test();
    end
    
endmodule

`default_nettype wire
