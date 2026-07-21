//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/wrapper_sequences.svh
// 用途      : 定义 response-delay wrapper agent 使用的 physical sequence。
//
// 说明：
//   - 各 sequence 只构造并发送 `wrapper_item`，不直接访问 virtual interface 或驱动
//     simple bus transaction。
//   - 跨 agent 的 wrapper/bus 时序关联由 virtual sequence 负责。
//   - 后续确定性、边界值和随机配置 sequence 可继续定义在本文件，并复用
//     `wrapper_base_seq` 提供的 item 发送 helper。
//------------------------------------------------------------------------------

// 使用继承的 target/delay_cycles 发送一笔 wrapper 配置；调用者在启动前负责赋值，
// 未初始化值由 wrapper driver 的最终合法性检查捕获。
class apply_wrapper_cfg_seq extends wrapper_base_seq;

    `uvm_object_utils(apply_wrapper_cfg_seq)

    function new(string name = "apply_wrapper_cfg_seq");
        super.new(name);
    endfunction

    task body();
        apply_wrapper_cfg();
    endtask

endclass
