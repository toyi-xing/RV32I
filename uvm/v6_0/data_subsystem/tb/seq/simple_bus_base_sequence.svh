//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/simple_bus_base_sequence.svh
// 用途      : v6.0 simple data bus UVM 环境的基础 sequence。
//
// 规范：
//   - sequence 只构造和发送 `simple_bus_item`，不直接驱动 interface 或等待 DUT response。
//
// 功能：
//   - `simple_bus_base_seq` 提供后续定向和随机 sequence 的公共基类。
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

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    // 0 空拍的写 word master 指令
    protected task automatic send_write32(
        logic [core_pkg::XLEN-1:0] addr,
        logic [core_pkg::XLEN-1:0] data
    );
        req = simple_bus_item::type_id::create("req_write32");
        start_item(req);    // 直接使用 seq 自带的 req 语柄
        req.write = 1'b1;
        req.be    = 4'b1111;
        req.addr  = addr;
        req.wdata = data;
        req.idle_cycles = 0;
        finish_item(req);
    endtask
    
    // 0 空拍的读 word master 指令
    protected task automatic send_read32(
        logic [core_pkg::XLEN-1:0] addr
    );
        req = simple_bus_item::type_id::create("req_read32");
        start_item(req);
        req.write = 1'b0;
        req.be    = 4'b1111;
        req.addr  = addr;
        req.wdata = '0;
        req.idle_cycles = 0;
        finish_item(req);
    endtask

endclass
