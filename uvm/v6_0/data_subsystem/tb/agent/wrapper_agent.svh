//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/agent/wrapper_agent.svh
// 用途      : 封装 response-delay wrapper 专用配置通道的 active UVM agent。
//
// 说明：
//   - agent 由 wrapper sequencer、driver 和被动 monitor 组成；monitor 采样实际
//     进入 DUT 的完整 response-delay 配置状态。
//   - wrapper 配置通道是 TB 到 DUT 的配置侧带，不是待验证的 request/response 协议；
//     配置是否生效由 wrapper checker 根据 monitor 快照和实际 bus transfer 间接检查。
//   - agent 不依赖 simple bus agent；跨 agent 的配置与访问时序由后续 virtual sequence
//     协调。
//------------------------------------------------------------------------------

class wrapper_agent extends uvm_agent;

    `uvm_component_utils(wrapper_agent)

    wrapper_sequencer sequencer;
    wrapper_driver    driver;
    wrapper_monitor   monitor;

    function new(string name = "wrapper_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sequencer = wrapper_sequencer::type_id::create("sequencer", this);
        driver    = wrapper_driver   ::type_id::create("driver",    this);
        monitor   = wrapper_monitor  ::type_id::create("monitor",   this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass
