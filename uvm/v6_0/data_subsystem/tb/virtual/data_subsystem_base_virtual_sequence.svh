//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_base_virtual_sequence.svh
// 用途      : data_subsystem 跨 agent virtual sequence 的公共基类。
//
// 说明：
//   - 通过 `p_sequencer` 访问 simple bus 与 wrapper 的物理 sequencer，不直接访问任何
//     virtual interface，也不直接构造或驱动 simple bus transaction。
//   - `body()` 统一检查 virtual sequencer 及其子 sequencer 连接；派生 virtual sequence
//     应先调用 `super.body()`。
//   - 不封装 wrapper 或 simple bus transaction 的启动；派生 virtual sequence 应按场景
//     显式创建并启动对应的 physical sequence，以保持跨 agent 的时序关系可见。
//------------------------------------------------------------------------------

class data_subsystem_base_vseq extends uvm_sequence;

    `uvm_object_utils(data_subsystem_base_vseq)

    // 声明一个 data_subsystem_virtual_sequencer 句柄 "p_sequencer"
    `uvm_declare_p_sequencer(data_subsystem_virtual_sequencer)

    function new(string name = "data_subsystem_base_vseq");
        super.new(name);
    endfunction

    task body();
        // 基类检查 vseq 是否正确连接了 vseqr 和子 seqr
        if (p_sequencer == null) begin
            `uvm_fatal(get_type_name(), "virtual sequencer handle is null")
        end
        if (p_sequencer.bus_sequencer == null || p_sequencer.wrp_sequencer == null) begin
            `uvm_fatal(get_type_name(), "sub-sequencer handle is null")
        end
    endtask

endclass
