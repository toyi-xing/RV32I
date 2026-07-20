//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/agent/wrapper_sequencer.svh
// 用途      : response-delay wrapper cfg agent 的 transaction sequencer。
//
// 说明：
//   - 仅负责仲裁并向 cfg driver 提供 `wrapper_item`，不保存 delay 配置状态。
//   - 配置值由 cfg sequence 或后续 virtual sequence 决定；实际配置动作由 cfg driver
//     执行，实际 response delay 由 wrapper checker 通过 bus transfer 检查。
//------------------------------------------------------------------------------

class wrapper_sequencer extends uvm_sequencer #(wrapper_item);

    `uvm_component_utils(wrapper_sequencer)

    function new(string name = "wrapper_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction

endclass
