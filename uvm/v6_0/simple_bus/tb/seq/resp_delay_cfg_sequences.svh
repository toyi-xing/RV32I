//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/seq/resp_delay_cfg_sequences.svh
// 用途      : 定义 response-delay wrapper cfg agent 使用的各类 sequence。
//
// 说明：
//   - 当前 sequence 只生成一个 `resp_delay_cfg_item`，不访问 virtual interface，
//     也不生成或驱动 simple bus transaction。
//   - 后续可在本文件加入确定性、边界值和随机配置 sequence；跨 agent 的配置与 bus
//     transaction 时序关联仍由 virtual sequence 负责。
//   - test 或后续 virtual sequence 在启动前设置 target 和 delay_cycles；virtual
//     sequence 负责将该配置命令与后续的 simple bus sequence 按时序关联。
//   - 参数保持 -1 / TARGET_UNDEFINED 时交由 cfg driver 的最终合法性检查报错，
//     防止遗漏配置被静默当作有效 delay。
//------------------------------------------------------------------------------

class resp_delay_cfg_set_sequence extends uvm_sequence #(resp_delay_cfg_item);

    `uvm_object_utils(resp_delay_cfg_set_sequence)

    soc_pkg::target_e  target;
    int                delay_cycles;

    function new(string name = "resp_delay_cfg_set_sequence");
        super.new(name);
        target       = TARGET_UNDEFINED;
        delay_cycles = -1;
    endfunction

    task body();
        req = resp_delay_cfg_item::type_id::create("req_resp_delay_cfg");
        start_item(req);
        req.target       = target;
        req.delay_cycles = delay_cycles;
        finish_item(req);
    endtask

endclass
