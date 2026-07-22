//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/agent/simple_bus_monitor.svh
// 用途      : v6.0 simple data bus UVM agent 的被动 monitor。
//
// 规范：
//   - 只通过 `mon_cb` 采样 DUT 引脚，不驱动任何 simple bus 信号。
//   - 以 accepted request 和对应 response 重建一笔 transaction，并通过 analysis
//     port 广播给后续 scoreboard、coverage 或专用 checker。
//   - 当前总线只允许 single outstanding；response 必须对应一笔 pending request。
//
// 功能：
//   - 记录 request payload、response 数据/错误，以及观察到的 response delay。
//   - 记录 request 前的 idle 间隔，供后续可选的 driver idle-gap checker 订阅使用。
//------------------------------------------------------------------------------

class simple_bus_monitor extends uvm_component;

    `uvm_component_utils(simple_bus_monitor)

    virtual simple_bus_if.mon_mp vif;
    uvm_analysis_port #(simple_bus_transfer) transfer_ap;   // monitor 使用一对多广播端口，scoreboard/coverage 都可以订阅

    function new(string name = "simple_bus_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual simple_bus_if.mon_mp)::get(this,"","simple_bus_vif",vif)) begin
            `uvm_fatal(get_type_name(), "failed to get bus monitor vif")
        end
        transfer_ap = new("transfer_ap", this);
    endfunction


    task run_phase(uvm_phase phase);
        simple_bus_transfer tr;     // transfer 语柄
        bit pending;
        int unsigned cycle_cnt;     // 记录当前拍数
        int unsigned last_resp_cycle; // 记录上一个 transfer 的响应时间
        // rst 行为
        cycle_cnt  = 0;
        pending    = 1'b0;
        while (vif.rst_n_i !== 1'b1) begin
            @(posedge vif.clk_i);
            cycle_cnt ++;
        end
        tr            = simple_bus_transfer::type_id::create("tr", this); // 创建一个 transfer 对象给 tr 语柄，供第一个 transaction 使用
        last_resp_cycle = cycle_cnt;
        // rst 后每拍监控 dut 端口情况
        forever begin
            @(vif.mon_cb);
            cycle_cnt ++;
            if(vif.rst_n_i !== 1'b1) begin  // 测试过程中再次复位，这里复位不清 cycle_cnt
                pending       = 1'b0;
                tr            = simple_bus_transfer::type_id::create("tr", this);
                last_resp_cycle = cycle_cnt;
                continue;
            end
            // 利用 tr.observed_item.idle_cycles sentinel 值，检测 req.valid 首拍，记录 idle_cycles
            if (vif.mon_cb.req_i.valid && !pending && tr.observed_item.idle_cycles == -1) begin
                tr.req_cycle = cycle_cnt;
                tr.observed_item.idle_cycles = cycle_cnt - last_resp_cycle - 1; // resp 和下一个 req 必然不能同拍
            end
            // 检测 req 握手
            if (vif.mon_cb.req_i.valid && vif.mon_cb.req_ready_o) begin
                if (pending) begin          // bus 响应期间再次接受，违反单 outstanding
                    `uvm_fatal(get_type_name(), "second req accepted while having an outstanding req")
                end
                pending       = 1'b1;
                tr.accept_cycle             = cycle_cnt;
                tr.observed_item.write      = vif.mon_cb.req_i.write;
                tr.observed_item.be         = vif.mon_cb.req_i.be;
                tr.observed_item.addr       = vif.mon_cb.req_i.addr;
                tr.observed_item.wdata      = vif.mon_cb.req_i.wdata;
                tr.resp_delay = 0;
            end
            // 记录 resp_delay
            if (pending && !vif.mon_cb.resp_o.valid) begin
                tr.resp_delay ++;
            end
            // 检测 resp
            if (vif.mon_cb.resp_o.valid) begin
                if (!pending) begin         // 未经 req 握手,就产生了 orphan resp
                    `uvm_fatal(get_type_name(), "orphan resp with null req")
                end
                tr.resp_cycle = cycle_cnt;
                tr.rdata      = vif.mon_cb.resp_o.rdata;
                tr.error      = vif.mon_cb.resp_o.error;
                // 本次 transaction 结束，通过 ap 广播出去
                transfer_ap.write(tr);
                `uvm_info(get_type_name(), {"monitor observed a bus transfer:",tr.transfer2string()}, UVM_MEDIUM)
                // 创建一个新的 transfer 对象并记录本次 resp 拍数，供下一个 transaction 使用
                pending    = 1'b0;
                tr         = simple_bus_transfer::type_id::create("tr", this);
                last_resp_cycle = cycle_cnt;
            end
        end
    endtask

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

endclass
