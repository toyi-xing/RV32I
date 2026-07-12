//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/tests/simple_bus_base_test.sv
// 用途      : v6.0 simple data bus UVM 环境的最小 base test。
//
// 规范：
//   - 继承 uvm_test，并通过 factory 宏注册。
//   - 当前 build_phase 只保留 UVM 标准父类调用，不创建 env 或 DUT 配置。
//   - run_phase 使用 objection 管理 test 生命周期，避免仿真在启动后立即结束。
//
// 功能：
//   - 提供第一阶段 VCS/UVM 工程骨架的最小可运行 test。
//   - 当前保持 100 ns objection；后续由派生 test 启动 sequence 和实际检查。
//------------------------------------------------------------------------------

class simple_bus_base_test extends uvm_test;
    
    `uvm_component_utils(simple_bus_base_test)
    
    function new(string name = "simple_bus_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        #100ns;
        phase.drop_objection(this);
    endtask
    
endclass
