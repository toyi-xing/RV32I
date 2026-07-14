//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/agent/simple_bus_sequencer.svh
// 用途      : v6.0 simple data bus UVM agent 的 transaction sequencer。
//
// 规范：
//   - 使用 `simple_bus_item` 作为 sequence 与 driver 之间传递的唯一 transaction
//     类型。
//   - 本类只提供 UVM sequence arbitration，不驱动 DUT 信号，也不解释 response。
//
// 功能：
//   - 为后续 simple bus driver 提供 sequence item 获取端口。
//   - 作为 smoke、MMIO、byte-enable 和随机 sequence 的统一启动目标。
//------------------------------------------------------------------------------

class simple_bus_sequencer extends uvm_sequencer #(simple_bus_item);

    `uvm_component_utils(simple_bus_sequencer)

    function new(string name = "simple_bus_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction

endclass
