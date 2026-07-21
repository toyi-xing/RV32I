//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/sva/simple_bus_sva.svh
// 用途      : v6.0 simple data bus 的 interface 级协议断言。
//
// 规范：
//   - 本文件只能在 `simple_bus_if` 内部 include，直接使用其 clk_i、rst_n_i 和
//     simple bus 信号；不作为独立编译单元。
//   - 所有断言与状态逻辑受 `ASSERT_ON` 控制，不依赖 UVM class 或 transaction。
//
// 功能：
//   - 检查 reset、X/Z、backpressure payload stable、single outstanding 和
//     no orphan response 等 simple bus 协议不变量。
//------------------------------------------------------------------------------

`ifdef ASSERT_ON

    //-----------------------------------------------------------------------
    // 基础总线信号检查
    //-----------------------------------------------------------------------

    // 总线握手信号的 rst 行为
    property p_simple_bus_rst_output;
        @(posedge clk_i)
            (!rst_n_i && $past(rst_n_i === 1'b0)) |->   // 上一周期明确就是 0，防止上电可能是 X
                (req_i.valid == 1'b0 && req_ready_o == 1'b1 && resp_o.valid == 1'b0);
    endproperty
    ap_simple_bus_rst_output: assert property(p_simple_bus_rst_output)
        else $error("[SVA] Master or Bus reset output check failed");

    // 复位释放后控制信号不应出现 X/Z
    property p_control_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
            !$isunknown({req_ready_o, req_i.valid, resp_o.valid});
    endproperty
    ap_control_no_x_z: assert property(p_control_no_x_z)
        else $error("[SVA] Master or Bus control signal has X/Z after reset");

    // req 有效时数据不应出现 X/Z
    property p_req_data_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
            req_i.valid |-> !$isunknown({req_i.write, req_i.be, req_i.addr, req_i.wdata});
    endproperty
    ap_req_data_no_x_z: assert property(p_req_data_no_x_z)
        else $error("[SVA] Master req valid but req data has X/Z");

    // resp 有效时 error 不能为 X/Z
    property p_resp_err_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
        resp_o.valid |-> !$isunknown(resp_o.error);
    endproperty
    ap_resp_err_no_x_z: assert property(p_resp_err_no_x_z)
        else $error("[SVA] Bus resp valid but resp_o.error is X/Z");

    // resp 有效且无错误时，rdata 不能为 X/Z
    property p_resp_rdata_no_x_z;
        @(posedge clk_i) disable iff (!rst_n_i)
        resp_o.valid && (resp_o.error == 1'b0) |-> !$isunknown(resp_o.rdata);
    endproperty
    ap_resp_rdata_no_x_z: assert property(p_resp_rdata_no_x_z)
        else $error("[SVA] Bus resp valid & no error, but resp_o.rdata has X/Z");

    //-----------------------------------------------------------------------
    // 总线行为检查
    //-----------------------------------------------------------------------

    // 单 outstanding 状态信号
    logic item_pending_q;
    wire  item_accept_fire = req_i.valid && req_ready_o;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            item_pending_q <= 1'b0;
        end else begin
            if (item_accept_fire) begin
                item_pending_q <= 1'b1;
            end
            if (resp_o.valid) begin
                item_pending_q <= 1'b0;
            end
        end
    end

    // 回压时 master 保持数据不变
    property p_master_holds_when_backpressure;
        @(posedge clk_i) disable iff (!rst_n_i)
            (!req_ready_o && req_i.valid) |=> (req_i.valid && $stable({req_i.write, req_i.be, req_i.addr, req_i.wdata}));
    endproperty
    ap_master_holds_when_backpressure: assert property(p_master_holds_when_backpressure)
        else $error("[SVA] Master req/payload output changed when slave stall");

    // 单 outstanding -> 已有未 resp 的 req 时不接受新的 req
    property p_no_second_outstanding;
        @(posedge clk_i) disable iff (!rst_n_i)
            (item_pending_q) |-> !item_accept_fire;
    endproperty
    ap_no_second_outstanding: assert property(p_no_second_outstanding)
        else $error("[SVA] Bus accepts a new req while there is an outstanding req");
    
    // resp 一定有对应的 req,负责为 orphan
    property p_no_orphan_resp;
        @(posedge clk_i) disable iff (!rst_n_i)
            (!item_pending_q && !item_accept_fire) |-> !resp_o.valid;
    endproperty
    ap_no_orphan_resp: assert property(p_no_orphan_resp)
        else $error("[SVA] Bus return an orphan resp");

`endif
