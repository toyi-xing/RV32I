
//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/checker/wrapper_scoreboard.svh
// 用途      : response-delay wrapper 的时序行为 scoreboard。
//
// 规范：
//   - 接收 wrapper monitor 的逐拍配置快照和 simple bus monitor 的完整 transfer，
//     不读取 sequence 或 wrapper driver 的计划/applied item。
//   - 两路 monitor 的 analysis port 分别接入 FIFO；run_phase 按总线 transaction
//     顺序消费 bus FIFO，并从时间顺序的 wrapper FIFO 中取得 sample_cycle 等于
//     accept_cycle 的配置快照，消除同拍 analysis port 回调顺序的影响。
//   - 当前总线为 single outstanding、in-order；wrapper monitor 每拍发布一笔快照，
//     checker 丢弃早于当前 accept_cycle 的快照。
//   - 只检查 wrapper delay 行为，不检查读写数据和 error，后者仍由 simple bus
//     scoreboard 负责。
//   - check_phase 检查 bus FIFO 没有遗留未比较 transaction；wrapper FIFO 中剩余
//     的后续周期快照不视为错误。
//------------------------------------------------------------------------------
class wrapper_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(wrapper_scoreboard)

    // 本 checker 需要配对两路 monitor 的 transaction；FIFO 将两路 analysis port
    // 的到达顺序与实际比较流程解耦。
    uvm_tlm_analysis_fifo #(simple_bus_transfer) bus_tr_fifo;
    uvm_tlm_analysis_fifo #(wrapper_transfer   ) wrp_tr_fifo;
    // 统计信息，用于 check/report 阶段判断测试是否真正完成。
    int unsigned compare_count;
    int unsigned error_count;

    function new(string name = "wrapper_scoreboard", uvm_component parent = null);
        super.new(name, parent);
        compare_count = 0;
        error_count   = 0;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        bus_tr_fifo = new("bus_tr_fifo", this);
        wrp_tr_fifo = new("wrp_tr_fifo", this);
    endfunction

    task run_phase(uvm_phase phase);
        simple_bus_transfer bus_tr;
        wrapper_transfer    wrp_tr;
        int resp_delay_got;
        int resp_delay_exp;
        forever begin
            bus_tr_fifo.get(bus_tr);
            resp_delay_got = bus_tr.resp_delay;
            wrp_tr_fifo.get(wrp_tr);
            while (wrp_tr.sample_cycle < bus_tr.accept_cycle) begin
                wrp_tr_fifo.get(wrp_tr);
            end
            resp_delay_exp = int'(get_expected_resp_delay(bus_tr, wrp_tr));
            compare_count ++;
            if (resp_delay_got != resp_delay_exp) begin
                error_count ++;
                `uvm_error(get_type_name(),
                    $sformatf({"resp delay mismatch: target=%s accept_cycle=%0d resp_cycle=%0d ",
                               "actual resp_delay=%0d expected=%0d",
                               "\nselected wrapper cfg:%s"},
                              bus_tr.observed_item.target_name(), bus_tr.accept_cycle, bus_tr.resp_cycle,
                              resp_delay_got, resp_delay_exp,
                              wrp_tr.transfer2string("wrapper cfg")))
            end
        end
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (bus_tr_fifo.used() != 0) begin
            `uvm_fatal(get_type_name(),
                $sformatf("unprocessed bus transfer remains at end of test: bus_fifo_used=%0d compare_count=%0d wrapper_fifo_used=%0d",
                          bus_tr_fifo.used(), compare_count, wrp_tr_fifo.used()))
        end
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("wrapper check finish, result: check_num=%0d, error_num=%0d",
                compare_count, error_count), UVM_MEDIUM)
    endfunction

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    function logic [6:0] get_expected_resp_delay(simple_bus_transfer bus_tr, wrapper_transfer wrp_tr);
        if (bus_tr.accept_cycle != wrp_tr.sample_cycle) begin
            `uvm_error(get_type_name(),
                $sformatf("wrp_tr sample cycle mismatch bus_tr accept cycle: bus_accept_cycle=%0d wrapper_sample_cycle=%0d",
                          bus_tr.accept_cycle, wrp_tr.sample_cycle))
        end
        unique case (bus_tr.observed_item.decode_target())
            soc_pkg::TARGET_DMEM:      return wrp_tr.dmem_resp_delay_cycles;
            soc_pkg::TARGET_GPIO0:     return wrp_tr.gpio0_resp_delay_cycles;
            soc_pkg::TARGET_UART0:     return wrp_tr.uart0_resp_delay_cycles;
            soc_pkg::TARGET_TIMER0:    return wrp_tr.timer0_resp_delay_cycles;
            default: return '0;  // undefined target 不经过 response-delay wrapper，expected delay 固定为 0
        endcase
    endfunction

endclass
