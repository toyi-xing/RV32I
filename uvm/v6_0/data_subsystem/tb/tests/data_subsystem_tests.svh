//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/tests/data_subsystem_tests.svh
// 用途      : 定义 v6.0 data_subsystem UVM 环境的基础 smoke test。
//
// 规范：
//   - 派生 test 只组织验证场景，env/agent 由 data_subsystem_base_test 创建。
//   - sequence 由 test 在 run_phase 启动，并使用 objection 管理 test 生命周期。
//
// 功能：
//   - 收纳直接启动 simple bus sequence 的 protocol smoke，以及通过 virtual sequencer
//     协调 wrapper/bus agent 的 data_subsystem smoke。
//------------------------------------------------------------------------------

// simple bus protocol smoke，直接在 simple bus physical sequencer 上启动固定 DMEM sequence。
class simple_bus_smoke_test extends data_subsystem_base_test;

    `uvm_component_utils(simple_bus_smoke_test)

    function new(string name = "simple_bus_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        simple_bus_smoke_seq seq;
        seq = simple_bus_smoke_seq::type_id::create("seq");

        phase.raise_objection(this);
        seq.start(env.bus_agent.sequencer);
        phase.drop_objection(this);
    endtask

endclass

// data_subsystem smoke，通过 virtual sequencer 启动 wrapper/bus 协同场景。
class data_subsystem_smoke_test extends data_subsystem_base_test;

    `uvm_component_utils(data_subsystem_smoke_test)

    function new(string name = "data_subsystem_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        data_subsystem_smoke_vseq vseq;
        vseq = data_subsystem_smoke_vseq::type_id::create("vseq");

        phase.raise_objection(this);
        vseq.start(env.vseqr);
        phase.drop_objection(this);
    endtask

endclass


// 
class DS_dmem_random_test extends data_subsystem_base_test;

    `uvm_component_utils(DS_dmem_random_test)

    function new(string name = "DS_dmem_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        data_subsystem_dmem_random_vseq vseq;
        vseq = data_subsystem_dmem_random_vseq::type_id::create("vseq");
        vseq.num_items = 200;

        phase.raise_objection(this);
        vseq.start(env.vseqr);
        phase.drop_objection(this);
    endtask

endclass

class DS_dmem_random_test_200 extends data_subsystem_base_test;

    `uvm_component_utils(DS_dmem_random_test_200)

    function new(string name = "DS_dmem_random_test_200", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        data_subsystem_dmem_random_vseq vseq;
        vseq = data_subsystem_dmem_random_vseq::type_id::create("vseq");
        vseq.num_items = 200;

        phase.raise_objection(this);
        vseq.start(env.vseqr);
        phase.drop_objection(this);
    endtask

endclass

class DS_dmem_random_test_2000 extends data_subsystem_base_test;

    `uvm_component_utils(DS_dmem_random_test_2000)

    function new(string name = "DS_dmem_random_test_2000", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        data_subsystem_dmem_random_vseq vseq;
        vseq = data_subsystem_dmem_random_vseq::type_id::create("vseq");
        vseq.num_items = 2000;

        phase.raise_objection(this);
        vseq.start(env.vseqr);
        phase.drop_objection(this);
    endtask

endclass
