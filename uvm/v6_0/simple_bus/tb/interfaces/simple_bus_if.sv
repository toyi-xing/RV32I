//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/interfaces/simple_bus_if.sv
// 用途      : v6.0 simple data bus UVM driver/monitor 与 DUT 共用的协议接口。
//
// 规范：
//   - request 由 master driver 驱动，ready/response 由 DUT 驱动。
//   - driver 和 monitor 通过独立 clocking block 统一驱动与采样时序。
//   - modport 限制 active master 和 passive monitor 的可见方向。
//
// 功能：
//   - 聚合 simple data bus 的 request、ready 和 response 信号。
//   - 提供 master driver、monitor 及预留 slave clocking block。
//   - 在 ASSERT_ON 打开时检查 reset、X/Z 和 backpressure payload stable。
//------------------------------------------------------------------------------

interface simple_bus_if (
    input logic clk_i,
    input logic rst_n_i
);

    import core_pkg::*;
    import data_bus_pkg::*;

    logic                       req_ready_o;
    data_bus_pkg::data_req_t    req_i;
    data_bus_pkg::data_resp_t   resp_o;

    clocking master_drv_cb @(posedge clk_i);
        default input #1step output #1ns;
        input  req_ready_o;
        output req_i;
        input  resp_o;
    endclocking

    clocking slave_cb @(posedge clk_i);
        default input #1step output #1ns;
        output req_ready_o;
        input  req_i;
        output resp_o;
    endclocking

    clocking mon_cb @(posedge clk_i);
        default input #1step output #1ns;
        input  req_ready_o;
        input  req_i;
        input  resp_o;
    endclocking

    modport master_drv_mp (
        clocking master_drv_cb,
        input    rst_n_i
    );

    modport mon_mp (
        clocking mon_cb,
        input    rst_n_i
    );

    //-----------------------------------------------------------------------
    // 基础总线信号与协议检查
    //-----------------------------------------------------------------------

    `ifdef ASSERT_ON

    // 总线握手信号的 rst 行为
    property p_simple_bus_rst_output;
        @(posedge clk_i)
            (!rst_n_i && $past(rst_n_i === 1'b0)) |->   // 上一周期明确就是 0，防止上电可能是 X
                (req_i.valid == 1'b0 && req_ready_o == 1'b1 && resp_o.valid == 1'b0);
    endproperty
    ap_simple_bus_rst_output: assert property(p_simple_bus_rst_output)
        else $error("simple_bus reset output check failed");

    // 置位控制信号后不应出现 X/Z
    property p_control_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
            !$isunknown({req_ready_o, req_i.valid, resp_o.valid});
    endproperty
    ap_control_no_x_z: assert property(p_control_no_x_z)
        else $error("control signal has X/Z after reset");

    // req 有效时数据不应出现 X/Z
    property p_req_data_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
            req_i.valid |-> !$isunknown({req_i.write, req_i.be, req_i.addr, req_i.wdata});
    endproperty
    ap_req_data_no_x_z: assert property(p_req_data_no_x_z)
        else $error("req valid but req data has X/Z");

    // resp 有效时 error 不能为 X/Z
    property p_resp_err_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
        resp_o.valid |-> !$isunknown(resp_o.error);
    endproperty
    ap_resp_err_no_x_z: assert property(p_resp_err_no_x_z) else
        $error("resp valid but resp_o.error is X/Z");

    // resp 有效且无错误时，rdata 不能为 X/Z
    property p_resp_rdata_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
        resp_o.valid && (resp_o.error == 1'b0) |-> !$isunknown(resp_o.rdata);
    endproperty
    ap_resp_rdata_no_x_z: assert property(p_resp_rdata_no_x_z) else
        $error("resp valid & no error, but resp_o.rdata has X/Z");

    // 回压时 master 保持数据不变
    property p_master_holds_when_backpressure;
        @(posedge clk_i) disable iff (!rst_n_i)
            (!req_ready_o && req_i.valid) |=> (req_i.valid && $stable({req_i.write, req_i.be, req_i.addr, req_i.wdata}));
    endproperty
    ap_master_holds_when_backpressure: assert property(p_master_holds_when_backpressure)
        else $error("master req/payload output changed when slave stall");

    `endif

endinterface
