//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/env/simple_bus_env.svh
// 用途      : v6.0 simple data bus UVM 验证环境。
//
// 规范：
//   - 当前 env 包含一个 active simple bus agent 和基础 DMEM scoreboard。
//   - 后续在本层接入 response-delay checker 和 coverage，避免把 DUT 专用检查逻辑
//     放入通用 agent。
//
// 功能：
//   - 创建 simple bus agent、DMEM scoreboard，并连接 monitor analysis port。
//------------------------------------------------------------------------------

class simple_bus_env extends uvm_env;

    `uvm_component_utils(simple_bus_env)

    simple_bus_agent        agent;
    simple_bus_scoreboard   scoreboard;

    function new(string name = "simple_bus_env", uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent       = simple_bus_agent::        type_id::create("agent",        this);
        scoreboard  = simple_bus_scoreboard::   type_id::create("scoreboard",   this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.monitor.transfer_ap.connect(scoreboard.transfer_imp);
    endfunction

endclass
