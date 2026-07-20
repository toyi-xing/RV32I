//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/agent/resp_delay_cfg_agent.svh
// 用途      : 封装 response-delay wrapper 专用配置通道的 active UVM agent。
//
// 说明：
//   - agent 由 cfg sequencer 和 cfg driver 组成，不建立 cfg monitor。
//   - cfg channel 是 TB 到 DUT 的配置侧带，不是待验证的 request/response 协议；配置
//     是否生效由后续 wrapper checker 根据实际 bus transfer 间接检查。
//   - agent 不依赖 simple bus agent；跨 agent 的配置与访问时序由后续 virtual sequence
//     协调。
//------------------------------------------------------------------------------

class resp_delay_cfg_agent extends uvm_agent;

    `uvm_component_utils(resp_delay_cfg_agent)

    resp_delay_cfg_sequencer sequencer;
    resp_delay_cfg_driver    driver;

    function new(string name = "resp_delay_cfg_agent", uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sequencer = resp_delay_cfg_sequencer::type_id::create("sequencer", this);
        driver    = resp_delay_cfg_driver   ::type_id::create("driver",    this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass
