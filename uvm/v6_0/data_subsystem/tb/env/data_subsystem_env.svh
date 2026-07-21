//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/env/data_subsystem_env.svh
// 用途      : v6.0 data_subsystem UVM 验证环境。
//
// 规范：
//   - 当前 env 包含 active simple bus agent、response-delay wrapper agent、
//     data_subsystem virtual sequencer 和基础 DMEM scoreboard。
//   - 后续在本层接入 response-delay checker 和 coverage，避免把 DUT 专用检查逻辑
//     放入通用 agent。
//
// 功能：
//   - 创建 simple bus agent、wrapper agent、virtual sequencer、DMEM scoreboard；
//     连接 bus monitor analysis port 到 scoreboard，并向 virtual sequencer 提供两个
//     physical sequencer 句柄。
//------------------------------------------------------------------------------

class data_subsystem_env extends uvm_env;

    `uvm_component_utils(data_subsystem_env)

    simple_bus_agent                 bus_agent;
    wrapper_agent                    wrp_agent;
    data_subsystem_virtual_sequencer vseqr;
    simple_bus_scoreboard            bus_scoreboard;

    function new(string name = "data_subsystem_env", uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        bus_agent       = simple_bus_agent::                type_id::create("bus_agent",        this);
        wrp_agent       = wrapper_agent::                   type_id::create("wrp_agent",        this);
        vseqr           = data_subsystem_virtual_sequencer::type_id::create("vseqr",            this);
        bus_scoreboard  = simple_bus_scoreboard::           type_id::create("bus_scoreboard",   this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        vseqr.bus_sequencer = bus_agent.sequencer;
        vseqr.wrp_sequencer = wrp_agent.sequencer;
        bus_agent.monitor.transfer_ap.connect(bus_scoreboard.transfer_imp);
    endfunction

endclass
