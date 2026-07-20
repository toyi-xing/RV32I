//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/env/simple_bus_env.svh
// 用途      : v6.0 simple data bus UVM 验证环境。
//
// 规范：
//   - 当前 env 包含 active simple bus agent、response-delay wrapper cfg agent 和
//     基础 DMEM scoreboard。
//   - 后续在本层接入 response-delay checker 和 coverage，避免把 DUT 专用检查逻辑
//     放入通用 agent。
//
// 功能：
//   - 创建 simple bus agent、wrapper cfg agent、DMEM scoreboard，并连接 bus monitor
//     analysis port 到 scoreboard。
//------------------------------------------------------------------------------

class simple_bus_env extends uvm_env;

    `uvm_component_utils(simple_bus_env)

    simple_bus_agent        bus_agent;
    simple_bus_scoreboard   bus_scoreboard;
    resp_delay_cfg_agent    wrapper_agent;

    function new(string name = "simple_bus_env", uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        bus_agent       = simple_bus_agent::        type_id::create("bus_agent",        this);
        bus_scoreboard  = simple_bus_scoreboard::   type_id::create("bus_scoreboard",   this);
        wrapper_agent   = resp_delay_cfg_agent::    type_id::create("wrapper_agent",    this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        bus_agent.monitor.transfer_ap.connect(bus_scoreboard.transfer_imp);
    endfunction

endclass
