//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/agent/resp_delay_cfg_sequencer.svh
// 用途      : response-delay wrapper cfg agent 的 transaction sequencer。
//
// 说明：
//   - 仅负责仲裁并向 cfg driver 提供 `resp_delay_cfg_item`，不保存 delay 配置状态。
//   - 配置值由 cfg sequence 或后续 virtual sequence 决定；实际配置动作由 cfg driver
//     执行，实际 response delay 由 wrapper checker 通过 bus transfer 检查。
//------------------------------------------------------------------------------

class resp_delay_cfg_sequencer extends uvm_sequencer #(resp_delay_cfg_item);

    `uvm_component_utils(resp_delay_cfg_sequencer)

    function new(string name = "resp_delay_cfg_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction

endclass
