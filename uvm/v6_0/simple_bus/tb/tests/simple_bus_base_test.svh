//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/tests/simple_bus_base_test.svh
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
        //-------------------临时代码，调试用------------------
        begin
            simple_bus_item tr;
            tr = simple_bus_item::type_id::create("tr");
            tr.write        = 1'b1;
            tr.addr         = core_pkg::DMEM_BASE + 32'h40;
            tr.wdata        = 32'h1234_5678;
            tr.be           = 4'b1111;
            tr.idle_cycles  = 0;
            `uvm_info(get_type_name(), tr.item2string(), UVM_LOW)
        end
        //--------------------------------------------------
        #100ns;
        phase.drop_objection(this);
    endtask
    
endclass
