//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/simple_bus_sequences.svh
// 用途      : 定义 v6.0 simple data bus UVM 环境使用的定向、参数化与随机 sequence。
//
// 规范：
//   - sequence 只构造并发送 `simple_bus_item`，不直接访问 virtual interface。
//   - response delay 由 DUT wrapper 配置，实际观察结果由 driver/monitor 记录。
//
// 功能：
//   - 收纳 simple bus 侧可复用的基础 smoke、DMEM raw access 与 constrained-random
//     access-stream sequence。
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


// DMEM constrained-random access stream。
// 每轮独立随机生成一笔 read 或 write，并复用 simple_bus_item 的通用约束以覆盖
// byte enable、write data 与 idle gap。sequence 按 word address 维护已写地址池：
// write 后记录对应 word；read 在地址池非空时高概率选取已写 word、保留随机 byte
// offset，使 DMEM scoreboard 多数情况下可检查 read data，同时保留少量未写 word read
// 覆盖不具备已知参考值的访问路径。
class simple_bus_dmem_random_access_seq extends simple_bus_base_seq;

    `uvm_object_utils(simple_bus_dmem_random_access_seq)

    typedef logic [core_pkg::DMEM_ADDR_WIDTH-1:0] dmem_word_key;
    // 保证大部分 read 是 write 过的 dmem（这样读的数才有 scoreboard 意义）
    // 本 seq 内部维护一个 word 地址池，read 时不完全只依靠默认的 randomize
    dmem_word_key written_word_keys[$];                 // 队列，用来随机抽一个已写过的 word
    bit           written_word_seen[dmem_word_key];     // 关联数组，用来避免同一个 word 被重复加入队列

    function new(string name = "simple_bus_dmem_random_access_seq");
        super.new(name);
        num_items = 20;
    endfunction

    task body();
        repeat (num_items) begin
            req = simple_bus_item::type_id::create("req");
            start_item(req);
            if (!req.randomize() with{
                addr inside {[core_pkg::DMEM_BASE : core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES - 1]};
            }) begin
                `uvm_fatal(get_type_name(), "failed to randomize DMEM req item")
            end
            if (!req.write) begin   // 若为 read 对 addr 进行有效转化
                req.addr = read_word_addr_convert(req.addr);
            end
            finish_item(req);
            // 把 write 的 word addr 加入到地址池中
            if (req.write) begin
                remember_written_word_addr(req.addr);
            end
        end
    endtask

    // helper ---------------------------------------------------------
    // 将 write 的 word 地址记录到队列中
    protected function void remember_written_word_addr(
        logic [core_pkg::XLEN-1:0] addr
    );
        dmem_word_key word_key;
        word_key = addr_2_dmem_word_key(addr);
        if (!written_word_seen.exists(word_key)) begin
            written_word_seen[word_key] = 1'b1;
            written_word_keys.push_back(word_key);
        end
    endfunction

    // 判断传入的地址是否在地址池中，若不在高概率随机为地址池内的数，低概率保持原值
    protected function logic [core_pkg::XLEN-1:0] read_word_addr_convert(
        logic [core_pkg::XLEN-1:0] addr
    );
        dmem_word_key word_key;
        word_key = addr_2_dmem_word_key(addr);
        if (written_word_seen.num() == 0 || written_word_seen.exists(word_key)) begin
            return addr;     // 地址池里还没有有效地址 或 地址本就在地址池中
        end else begin
            int i;
            i = $urandom_range(1,100);
            if (i <= 80) begin
                word_key = written_word_keys[$urandom_range(0,written_word_keys.size()-1)];
                return dmem_word_key_2_addr(word_key, addr[1:0]);   // 80% 概率随机到地址池内，低二位保持不变
            end
            else begin
                return addr;     // 20% 的概率保持原值
            end
        end
    endfunction

    // 将 32bit 的 addr 转化为 dmem 的 word 地址
    protected function dmem_word_key addr_2_dmem_word_key(
        logic [core_pkg::XLEN-1:0] addr
    );
        dmem_word_key word_key;
        word_key = (addr - core_pkg::DMEM_BASE) >> 2;
        return word_key;
    endfunction

    // 将 dmem 的 word 地址转化为 32bit 的 addr
    protected function logic [core_pkg::XLEN-1:0] dmem_word_key_2_addr(
        dmem_word_key word_key,
        logic [1:0] byte_offset
    );
        logic [core_pkg::XLEN-1:0] word_offset;
        word_offset = word_key;
        return core_pkg::DMEM_BASE + (word_offset << 2) + byte_offset;
    endfunction


endclass


// 全 data-side 地址图 constrained-random access stream。
// 每轮独立随机生成一笔 read 或 write，地址、byte enable、write data 与 idle gap 均复用
// simple_bus_item 的通用约束。sequence 只按完整 word address 维护已写地址池，不区分
// DMEM/MMIO/undefined target，也不依赖任何 scoreboard/reference model 的实现范围。
class simple_bus_map_random_access_seq extends simple_bus_base_seq;

    `uvm_object_utils(simple_bus_map_random_access_seq)

    typedef logic [core_pkg::XLEN-1:2] map_word_key;
    // 保证大部分 read 指向 write 过的 word，提高已实现 reference model 的有效比较概率。
    // 地址池覆盖整个 data-side 地址图，是否具备完整 expected behavior 由 scoreboard 决定。
    map_word_key written_word_keys[$];
    bit          written_word_seen[map_word_key];

    function new(string name = "simple_bus_map_random_access_seq");
        super.new(name);
        num_items = 20;
    endfunction

    task body();
        repeat (num_items) begin
            req = simple_bus_item::type_id::create("req");
            start_item(req);
            if (!req.randomize()) begin
                `uvm_fatal(get_type_name(), "failed to randomize data-side map req item")
            end
            if (!req.write) begin
                req.addr = read_word_addr_convert(req.addr);
            end
            finish_item(req);
            if (req.write) begin
                remember_written_word_addr(req.addr);
            end
        end
    endtask

    // helper ---------------------------------------------------------
    // 将 write 的完整 word address 记录到队列中。
    protected function void remember_written_word_addr(
        logic [core_pkg::XLEN-1:0] addr
    );
        map_word_key word_key;
        word_key = addr_2_map_word_key(addr);
        if (!written_word_seen.exists(word_key)) begin
            written_word_seen[word_key] = 1'b1;
            written_word_keys.push_back(word_key);
        end
    endfunction

    // read 高概率复用任一已写 word，低两位保持原随机值；其余情况保留原随机地址。
    protected function logic [core_pkg::XLEN-1:0] read_word_addr_convert(
        logic [core_pkg::XLEN-1:0] addr
    );
        map_word_key word_key;
        word_key = addr_2_map_word_key(addr);
        if (written_word_seen.num() == 0 || written_word_seen.exists(word_key)) begin
            return addr;
        end else begin
            int i;
            i = $urandom_range(1,100);
            if (i <= 80) begin
                word_key = written_word_keys[$urandom_range(0, written_word_keys.size()-1)];
                return map_word_key_2_addr(word_key, addr[1:0]);
            end
            else begin
                return addr;
            end
        end
    endfunction

    // 将 byte address 转化为覆盖整个 32-bit 地址图的 word key。
    protected function map_word_key addr_2_map_word_key(
        logic [core_pkg::XLEN-1:0] addr
    );
        return addr[core_pkg::XLEN-1:2];
    endfunction

    // 将完整 word key 和 byte offset 还原为 byte address。
    protected function logic [core_pkg::XLEN-1:0] map_word_key_2_addr(
        map_word_key word_key,
        logic [1:0]  byte_offset
    );
        return {word_key, byte_offset};
    endfunction

endclass
