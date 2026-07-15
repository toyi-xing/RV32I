//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/env/simple_bus_env.svh
// 用途      : v6.0 simple data bus UVM 验证环境。
//
// 规范：
//   - 当前 env 只包含一个 active simple bus agent。
//   - 后续在本层接入功能 scoreboard、response-delay checker 和 coverage，避免把
//     DUT 专用检查逻辑放入通用 agent。
//
// 功能：
//   - 创建并持有 simple bus agent，作为 test 与验证组件的组织边界。
//------------------------------------------------------------------------------

class simple_bus_env extends uvm_env;

    `uvm_component_utils(simple_bus_env)

    simple_bus_agent agent;

    function new(string name = "simple_bus_env", uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = simple_bus_agent::type_id::create("agent", this);
    endfunction

endclass
