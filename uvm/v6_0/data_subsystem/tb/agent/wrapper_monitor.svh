//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/agent/wrapper_monitor.svh
// 用途      : response-delay wrapper 配置状态的被动 UVM monitor。
//
// 说明：
//   - 只从 `wrapper_if` 采样实际进入 DUT 的四路 response-delay 配置，不读取
//     sequence 或 wrapper driver 的计划/applied item。
//   - reset 释放后按统一的时钟周期采样完整配置状态，并通过 analysis port 发布
//     `wrapper_transfer`；transfer 的 sample_cycle 与 simple bus monitor 的
//     accept_cycle 使用同一周期口径。
//   - wrapper checker 通过 FIFO 按时间顺序消费状态快照，并为每笔 simple bus
//     transfer 选择 sample_cycle == accept_cycle 的配置快照。
//------------------------------------------------------------------------------

class wrapper_monitor extends uvm_monitor;

    `uvm_component_utils(wrapper_monitor)

    virtual wrapper_if.mon_mp vif;
    uvm_analysis_port #(wrapper_transfer) transfer_ap;

    function new(string name = "wrapper_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db #(virtual wrapper_if.mon_mp)::get(this,"","wrapper_vif",vif)) begin
            `uvm_fatal(get_type_name(), "failed to get wrapper monitor vif")
        end
        transfer_ap = new("transfer_ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        wrapper_transfer tr;
        int unsigned cycle_cnt;
        // rst 行为
        cycle_cnt  = 0;
        while (vif.rst_n_i !== 1'b1) begin
            @(posedge vif.clk_i);
            cycle_cnt ++;
        end
        forever begin
            @(vif.mon_cb);
            cycle_cnt ++;
            if(vif.rst_n_i !== 1'b1) begin  // 测试过程中再次复位则不发布 tr，这里复位不清 cycle_cnt
                continue;
            end
            tr = wrapper_transfer::type_id::create("tr", this);
            tr.dmem_resp_delay_cycles   = vif.mon_cb.dmem_resp_delay_cycles;
            tr.gpio0_resp_delay_cycles  = vif.mon_cb.gpio0_resp_delay_cycles;
            tr.uart0_resp_delay_cycles  = vif.mon_cb.uart0_resp_delay_cycles;
            tr.timer0_resp_delay_cycles = vif.mon_cb.timer0_resp_delay_cycles;
            tr.sample_cycle             = cycle_cnt;
            transfer_ap.write(tr);
        end
    endtask

endclass
