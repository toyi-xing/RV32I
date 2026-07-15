//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/agent/simple_bus_agent.svh
// 用途      : v6.0 simple data bus UVM active agent。
//
// 规范：
//   - 当前只实现 active agent，统一创建 sequencer、driver 和 monitor。
//   - driver 通过 seq_item_port 与 sequencer 的 seq_item_export 连接。
//   - monitor 保持被动采样，后续由 env 将 analysis port 接至 scoreboard/coverage。
//
// 功能：
//   - 封装 simple bus master 的激励、驱动和观测组件。
//------------------------------------------------------------------------------

class simple_bus_agent extends uvm_agent;

    `uvm_component_utils(simple_bus_agent)

    simple_bus_sequencer seqr;
    simple_bus_driver    drv;
    simple_bus_monitor   mon;

    function new(string name = "simple_bus_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        seqr = simple_bus_sequencer ::type_id::create("sequencer", this);
        drv  = simple_bus_driver    ::type_id::create("driver",    this);
        mon  = simple_bus_monitor   ::type_id::create("monitor",   this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction

endclass
