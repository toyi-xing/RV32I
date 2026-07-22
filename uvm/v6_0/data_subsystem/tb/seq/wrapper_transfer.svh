//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/wrapper_transfer.svh
// 用途      : response-delay wrapper monitor 重建的配置状态快照。
//
// 规范：
//   - 只保存 wrapper interface 上实际观察到的四路 delay 配置，不读取 sequence 或
//     driver 持有的计划 item。
//   - 一笔 transfer 表示某个采样时刻的完整 wrapper 配置状态，而非只配置一个 target
//     的 command；单 target 配置命令仍使用 `wrapper_item` 表示。
//   - wrapper checker 根据 bus address 译码 target，并从该状态快照取得对应的 expected
//     delay，与 simple bus monitor 观察到的 response delay 比较。
//
// 功能：
//   - 保存 DMEM、GPIO0、UART0、TIMER0 的实际 response delay 配置和采样周期。
//   - 由 checker 按 target 和 accept_cycle 选择对应 tr 的 delay。
//------------------------------------------------------------------------------

class wrapper_transfer extends uvm_sequence_item;

    logic  [6:0] dmem_resp_delay_cycles;
    logic  [6:0] gpio0_resp_delay_cycles;
    logic  [6:0] uart0_resp_delay_cycles;
    logic  [6:0] timer0_resp_delay_cycles;
    int unsigned sample_cycle;

    `uvm_object_utils_begin(wrapper_transfer)
        `uvm_field_int(dmem_resp_delay_cycles,   UVM_ALL_ON)
        `uvm_field_int(gpio0_resp_delay_cycles,  UVM_ALL_ON)
        `uvm_field_int(uart0_resp_delay_cycles,  UVM_ALL_ON)
        `uvm_field_int(timer0_resp_delay_cycles, UVM_ALL_ON)
        `uvm_field_int(sample_cycle,             UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "wrapper_transfer");
        super.new(name);
        dmem_resp_delay_cycles   = 'x;
        gpio0_resp_delay_cycles  = 'x;
        uart0_resp_delay_cycles  = 'x;
        timer0_resp_delay_cycles = 'x;
        sample_cycle             =  0;
    endfunction

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    function string transfer2string(string object_kind = "wrapper_transfer");
        return $sformatf("\n[%s] wrapper resp delay cfg: dmem=%0d gpio0=%0d uart0=%0d timer0=%0d, sample_cycle=%0d",
                         object_kind, dmem_resp_delay_cycles, gpio0_resp_delay_cycles,
                         uart0_resp_delay_cycles, timer0_resp_delay_cycles, sample_cycle);
    endfunction

endclass
