//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/seq/simple_bus_sequences.svh
// 用途      : v6.0 simple data bus UVM 环境的 DMEM smoke sequence。
//
// 规范：
//   - smoke sequence 显式设置 word access 和 `idle_cycles`，保持 stimulus 可复现；
//     response delay 由 DUT 配置，实际观察结果由 driver/monitor 记录。
//
// 功能：
//   - `simple_bus_smoke_seq` 生成基础 DMEM word 写后读请求，作为最小端到端 smoke。
//------------------------------------------------------------------------------

class simple_bus_smoke_seq extends simple_bus_base_seq;
    
    `uvm_object_utils(simple_bus_smoke_seq)

    function new(string name = "simple_bus_smoke_seq");
        super.new(name);
    endfunction

    task body();
        send_write32(core_pkg::DMEM_BASE + 32'h0000_0040, 32'h1122_3344);
        send_read32 (core_pkg::DMEM_BASE + 32'h0000_0040);
        send_write32(core_pkg::DMEM_BASE + 32'h0000_0044, 32'ha5a5_5a5a);
        send_read32 (core_pkg::DMEM_BASE + 32'h0000_0044);
    endtask

endclass
