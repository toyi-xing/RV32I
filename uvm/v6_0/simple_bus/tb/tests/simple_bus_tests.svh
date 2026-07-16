//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/tests/simple_bus_tests.svh
// 用途      : v6.0 simple data bus UVM 环境的 DMEM smoke test 集合。
//
// 规范：
//   - 派生 test 只组织验证场景，env/agent 由 simple_bus_base_test 创建。
//   - sequence 由 test 在 run_phase 启动，并使用 objection 管理 test 生命周期。
//
// 功能：
//   - `simple_bus_smoke_test` 启动固定 DMEM write/read sequence，验证 UVM master
//     到 data_subsystem/simple_ram 的最小端到端访问链路。
//------------------------------------------------------------------------------

class simple_bus_smoke_test extends simple_bus_base_test;

    `uvm_component_utils(simple_bus_smoke_test)

    function new(string name = "simple_bus_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        simple_bus_smoke_seq seq;
        seq = simple_bus_smoke_seq::type_id::create("seq");

        phase.raise_objection(this);
        seq.start(env.agent.seqr);
        phase.drop_objection(this);
    endtask
endclass
