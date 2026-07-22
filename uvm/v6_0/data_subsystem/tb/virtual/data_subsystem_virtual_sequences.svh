//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_virtual_sequences.svh
// 用途      : 定义 data_subsystem 的具体跨 agent virtual sequence。
//
// 说明：
//   - 各场景 sequence 继承 `data_subsystem_base_vseq`，并在 `body()` 开始调用
//     `super.body()` 完成 virtual sequencer 连接检查。
//   - 场景 sequence 通过 `p_sequencer` 显式启动 wrapper 与 simple bus 的 physical
//     sequence，不直接访问 virtual interface。
//   - 本文件收纳固定 delay、逐笔变化和随机 wrapper/bus 协同场景。
//------------------------------------------------------------------------------

// data_subsystem 的 wrapper-delay smoke：依次执行若干固定 delay 场景，并追加一组
// 随机 wrapper delay 场景；每组均对随机 DMEM 地址执行一笔 write/read。
class data_subsystem_smoke_vseq extends data_subsystem_base_vseq;

    `uvm_object_utils(data_subsystem_smoke_vseq)

    function new(string name = "data_subsystem_smoke_vseq");
        super.new(name);
    endfunction

    task body();
        super.body();
        // delay n -> write/read
        dmem_def_resp_delay_rand_raw(0);
        dmem_def_resp_delay_rand_raw(3);
        dmem_def_resp_delay_rand_raw(1);
        dmem_def_resp_delay_rand_raw(7);
        // delay randomize -> write/read
        dmem_rand_resp_delay_rand_raw();
    endtask

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    // 先配置 dmem 访问的 delay_cycles，然后对随机地址先写后读
    task automatic dmem_def_resp_delay_rand_raw(int delay_cycles);
        apply_wrapper_cfg_seq   wrp_seq;
        simple_bus_dmem_raw_seq bus_seq;
        wrp_seq = apply_wrapper_cfg_seq::type_id::create($sformatf("wrp_seq_delay%0d", delay_cycles));
        wrp_seq.target       = TARGET_DMEM;
        wrp_seq.delay_cycles = delay_cycles;
        wrp_seq.start(p_sequencer.wrp_sequencer);
        bus_seq = simple_bus_dmem_raw_seq::type_id::create($sformatf("bus_seq_delay%0d", delay_cycles));
        if (!bus_seq.randomize()) begin
            `uvm_fatal(get_type_name, $sformatf("failed to randomize bus_seq_delay%0d", delay_cycles))
        end
        bus_seq.start(p_sequencer.bus_sequencer);
    endtask

    // 利用已有的 item 随机规则配置 dmem 访问的 delay_cycles，然后对随机地址先写后读
    task automatic dmem_rand_resp_delay_rand_raw();
        wrapper_item    rand_wrp_item;
        rand_wrp_item = wrapper_item::type_id::create("rand_wrp_item");
        if (!rand_wrp_item.randomize()) begin
            `uvm_fatal(get_type_name, "failed to randomize rand_wrp_item")
        end
        dmem_def_resp_delay_rand_raw(rand_wrp_item.delay_cycles);
    endtask

endclass


//
class data_subsystem_dmem_random_vseq extends data_subsystem_base_vseq;

    `uvm_object_utils(data_subsystem_dmem_random_vseq)

    simple_bus_dmem_random_access_seq bus_seq;
    wrapper_dmem_cfg_random_seq       wrp_seq;


    function new(string name = "data_subsystem_dmem_random_vseq");
        super.new(name);
        num_items = 200;
    endfunction

    task body();
        super.body();
        repeat (num_items) begin
            bus_seq = simple_bus_dmem_random_access_seq::type_id::create("bus_seq");
            wrp_seq = wrapper_dmem_cfg_random_seq::type_id::create("wrp_seq");
            bus_seq.num_items = 1;
            wrp_seq.num_items = 1;
            wrp_seq.start(p_sequencer.wrp_sequencer);   // 由 seq 新建 item 对象，seq 保持为本身
            bus_seq.start(p_sequencer.bus_sequencer);   // 维护同一个地址池，因此 bus_seq 需要保持同一个对象
        end
    endtask
    
endclass
