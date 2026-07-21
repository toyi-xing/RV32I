//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/simple_bus_sequences.svh
// 用途      : 定义 v6.0 simple data bus UVM 环境使用的定向与参数化 sequence。
//
// 规范：
//   - sequence 只构造并发送 `simple_bus_item`，不直接访问 virtual interface。
//   - response delay 由 DUT wrapper 配置，实际观察结果由 driver/monitor 记录。
//
// 功能：
//   - 收纳 simple bus 侧可复用的基础 smoke 与 DMEM raw access sequence。
//------------------------------------------------------------------------------

// 固定 DMEM word 写后读序列，作为 simple bus 的最小端到端 smoke。
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

// 参数化 DMEM 写后读序列；addr/wdata 可由调用者赋值或随机化。该 sequence 保留地址低两位，
// 由 DMEM 的实际 byte-address/byte-enable 语义处理，不额外施加 word 对齐限制。
class simple_bus_dmem_raw_seq extends simple_bus_base_seq;

    `uvm_object_utils(simple_bus_dmem_raw_seq)

    rand logic [core_pkg::XLEN-1:0] addr;
    rand logic [core_pkg::XLEN-1:0] wdata;

    constraint c_dmem_addr{
        addr inside {[core_pkg::DMEM_BASE : core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES - 1]};
    }

    function new(string name = "simple_bus_dmem_raw_seq");
        super.new(name);
        // if (!randomize()) begin
        //     `uvm_fatal(get_type_name, "failed to randomize simple_bus_dmem_raw_seq")
        // end
        addr  = core_pkg::DMEM_BASE;
        wdata = 32'h1234_5678;
    endfunction

    task body();
        if (addr < core_pkg::DMEM_BASE || addr >= core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES) begin
            `uvm_fatal(get_type_name(), $sformatf("dmem_raw_seq access addr out of DMEM range: addr=%08x", addr))
        end
        send_write32(addr, wdata);
        send_read32(addr);
    endtask

endclass
