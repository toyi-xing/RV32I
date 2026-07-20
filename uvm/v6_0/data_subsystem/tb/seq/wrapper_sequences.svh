//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/wrapper_sequences.svh
// 用途      : 定义 response-delay wrapper cfg agent 使用的各类 sequence。
//
// 说明：
//   - 当前 sequence 只生成一个 `wrapper_item`，不访问 virtual interface，
//     也不生成或驱动 simple bus transaction。
//   - 后续可在本文件加入确定性、边界值和随机配置 sequence；跨 agent 的配置与 bus
//     transaction 时序关联仍由 virtual sequence 负责。
//   - test 或后续 virtual sequence 在启动前设置 target 和 delay_cycles；virtual
//     sequence 负责将该配置命令与后续的 simple bus sequence 按时序关联。
//   - 参数保持 -1 / TARGET_UNDEFINED 时交由 cfg driver 的最终合法性检查报错，
//     防止遗漏配置被静默当作有效 delay。
//------------------------------------------------------------------------------

class wrapper_set_sequence extends uvm_sequence #(wrapper_item);

    `uvm_object_utils(wrapper_set_sequence)

    soc_pkg::target_e  target;
    int                delay_cycles;

    function new(string name = "wrapper_set_sequence");
        super.new(name);
        target       = TARGET_UNDEFINED;
        delay_cycles = -1;
    endfunction

    task body();
        req = wrapper_item::type_id::create("req_wrapper");
        start_item(req);
        req.target       = target;
        req.delay_cycles = delay_cycles;
        finish_item(req);
    endtask

endclass
