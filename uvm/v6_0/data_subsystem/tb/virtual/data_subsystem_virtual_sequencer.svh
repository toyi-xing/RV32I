//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_virtual_sequencer.svh
// 用途      : data_subsystem 跨 agent virtual sequence 的统一 sequencer 入口。
//
// 说明：
//   - 不驱动 interface，也不产生 simple bus 或 wrapper transaction。
//   - 仅保存 simple bus agent 与 wrapper agent 的物理 sequencer 句柄，供后续
//     virtual sequence 按“先配置 wrapper、再发送 bus item”的时序协调访问。
//   - 物理 sequencer 句柄由 env 在 connect_phase 赋值，virtual sequence 不直接
//     访问任何 virtual interface。
//------------------------------------------------------------------------------

class data_subsystem_virtual_sequencer extends uvm_sequencer;

    `uvm_component_utils(data_subsystem_virtual_sequencer)

    simple_bus_sequencer bus_sequencer;
    wrapper_sequencer    wrp_sequencer;

    function new(string name = "data_subsystem_virtual_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction

endclass
