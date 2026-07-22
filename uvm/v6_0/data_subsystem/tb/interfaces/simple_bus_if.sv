//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/interfaces/simple_bus_if.sv
// 用途      : v6.0 simple data bus UVM driver/monitor 与 DUT 共用的协议接口。
//
// 规范：
//   - request 由 driver 驱动，ready/response 由 DUT 驱动。
//   - driver 和 monitor 通过独立 clocking block 统一驱动与采样时序。
//   - modport 限制 active driver 和 passive monitor 的可见方向。
//
// 功能：
//   - 聚合 simple data bus 的 request、ready 和 response 信号。
//   - 提供 driver 和 monitor 的 clocking block。
//   - 在 ASSERT_ON 打开时检查 reset、X/Z 和 backpressure payload stable。
//------------------------------------------------------------------------------
`default_nettype none

interface simple_bus_if (
    input logic clk_i,
    input logic rst_n_i
);

    import core_pkg::*;
    import data_bus_pkg::*;

    logic                       req_ready_o;
    data_bus_pkg::data_req_t    req_i;
    data_bus_pkg::data_resp_t   resp_o;

    // 供 drv 根据 valid 判断实际握手，驱动 idle 的观察信号
    logic  req_valid_observed;
    assign req_valid_observed = req_i.valid;

    clocking drv_cb @(posedge clk_i);
        default input #1step output #1ns;
        input  req_ready_o;
        input  req_valid_observed;
        output req_i;
        input  resp_o;
    endclocking

    clocking mon_cb @(posedge clk_i);
        default input #1step output #1ns;
        input  req_ready_o;
        input  req_i;
        input  resp_o;
    endclocking

    modport drv_mp (
        clocking drv_cb,
        input    clk_i,
        input    rst_n_i
    );

    modport mon_mp (
        clocking mon_cb,
        input    clk_i,
        input    rst_n_i
    );

    `include "simple_bus_sva.svh"

endinterface

`default_nettype wire
