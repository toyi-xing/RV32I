//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/tests/simple_bus_base_test.svh
// 用途      : v6.0 simple data bus UVM 环境的最小 base test。
//
// 规范：
//   - 继承 uvm_test，并通过 factory 宏注册。
//   - build_phase 创建 env；DUT 配置仍由 top 和后续派生 test 负责。
//   - run_phase 使用 objection 管理 test 生命周期，避免仿真在启动后立即结束。
//
// 功能：
//   - 提供 env/agent 已创建、但尚未启动 sequence 的最小可运行 test。
//   - 当前保持 100 ns objection；后续由派生 test 启动 sequence 和实际检查。
//------------------------------------------------------------------------------

class simple_bus_base_test extends uvm_test;
    
    `uvm_component_utils(simple_bus_base_test)

    simple_bus_env env;
    
    function new(string name = "simple_bus_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = simple_bus_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        //-------------------临时代码，调试用------------------
        // 测试 simple_bus_item 能过编译
        // begin
        //     simple_bus_item tr;
        //     tr = simple_bus_item::type_id::create("tr");
        //     tr.write        = 1'b1;
        //     tr.addr         = core_pkg::DMEM_BASE + 32'h40;
        //     tr.wdata        = 32'h1234_5678;
        //     tr.be           = 4'b1111;
        //     tr.idle_cycles  = 0;
        //     `uvm_info(get_type_name(), tr.item2string(), UVM_LOW)
        // end
        // // 测试 seq、seqr 能过编译
        // begin
        //     simple_bus_smoke_seq seq;
        //     seq = simple_bus_smoke_seq::type_id::create("seq");
        //     `uvm_info(get_type_name(), "smoke seq object created", UVM_LOW)
        // end
        //--------------------------------------------------
        `uvm_info(get_type_name(), "base test created env", UVM_LOW)
        #100ns;
        phase.drop_objection(this);
    endtask
    
endclass
