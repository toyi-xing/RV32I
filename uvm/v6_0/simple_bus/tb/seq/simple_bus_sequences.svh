//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/seq/simple_bus_sequences.svh
// 用途      : v6.0 simple data bus UVM 环境的基础 sequence 和 DMEM smoke sequence。
//
// 规范：
//   - sequence 只构造和发送 `simple_bus_item`，不直接驱动 interface 或等待 DUT
//     response。
//   - smoke sequence 显式设置 word access 和 `idle_cycles`，保持 stimulus 可复现；
//     response delay 由 DUT 配置和后续 driver/monitor 检查。
//
// 功能：
//   - `simple_bus_base_seq` 提供后续定向和随机 sequence 的公共基类。
//   - `simple_bus_smoke_seq` 生成基础 DMEM word 写后读请求，供 driver/scoreboard
//     接入后的最小功能验证使用。
//------------------------------------------------------------------------------

class simple_bus_base_seq extends uvm_sequence #(simple_bus_item);

    `uvm_object_utils(simple_bus_base_seq)

    rand int unsigned num_items;
    constraint c_mum_items{
        num_items inside {[1:100]};
    }

    function new(string name = "simple_bus_base_seq");
        super.new(name);
        num_items = 1;
    endfunction
endclass

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

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    // 0 空拍的写 word master 指令
    protected task automatic send_write32(logic [core_pkg::XLEN-1:0] addr,
                                logic [core_pkg::XLEN-1:0] data);
        req = simple_bus_item::type_id::create("smoke_write32");
        start_item(req);
        req.write = 1'b1;
        req.be    = 4'b1111;
        req.addr  = addr;
        req.wdata = data;
        req.idle_cycles = 0;
        finish_item(req);
    endtask
    
    // 0 空拍的读 word master 指令
    protected task automatic send_read32(logic [core_pkg::XLEN-1:0] addr);
        req = simple_bus_item::type_id::create("smoke_read32");
        start_item(req);
        req.write = 1'b0;
        req.be    = 4'b1111;
        req.addr  = addr;
        req.wdata = '0;
        req.idle_cycles = 0;
        finish_item(req);
    endtask

endclass
