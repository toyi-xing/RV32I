//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/agent/resp_delay_cfg_driver.svh
// 用途      : response-delay wrapper cfg agent 的 active driver。
//
// 规范：
//   - reset 期间将所有 response delay 初始化为 0；reset 释放后才执行普通 cfg item。
//   - 对 sequence 提交的 delay 进行最终范围检查，并将超过 RTL 范围的值饱和为 127。
//   - 发布实际应用配置的独立 clone，供后续 wrapper checker 与 observed transfer 配对。
//
// 功能：
//   - 通过 `resp_delay_cfg_if` 配置 DMEM、GPIO0、UART0、TIMER0 的 response delay。
//   - 不驱动 simple bus request，也不等待或观测 bus response。
//------------------------------------------------------------------------------

class resp_delay_cfg_driver extends uvm_driver #(resp_delay_cfg_item);

    `uvm_component_utils(resp_delay_cfg_driver)

    virtual resp_delay_cfg_if vif;
    resp_delay_cfg_item applied_item;
    uvm_analysis_port #(resp_delay_cfg_item) applied_item_ap;

    function new(string name = "resp_delay_cfg_driver", uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual resp_delay_cfg_if)::get(this,"","resp_delay_cfg_vif",vif)) begin
            `uvm_fatal(get_type_name(), "failed to get resp_delay_cfg vif")
        end
        applied_item_ap = new("applied_item_ap", this);
    endfunction

    task run_phase (uvm_phase phase);
        vif.rst_resp_delay();
        wait_reset_release();
        forever begin
            seq_item_port.get_next_item(req);
            $cast(applied_item, req.clone());
            applied_item.delay_cycles = item_check(applied_item);    
            drive_item(applied_item);
            applied_item_ap.write(applied_item);
            seq_item_port.item_done();
        end
    endtask

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    protected task wait_reset_release();
        while (vif.rst_n_i !== 1'b1) begin
            @(posedge vif.clk_i);
        end
    endtask

    // 检查 item 是否合法，包含：检查 target 是否是已经实现的部分；delay_cycles 是否在 [0:127] 范围之间
    protected function int item_check(resp_delay_cfg_item item);
        case (item.target)
            TARGET_DMEM, TARGET_GPIO0, TARGET_UART0, TARGET_TIMER0: ; 
            default: begin
                `uvm_fatal(get_type_name(),
                       $sformatf("target=%s must be configured, item: %s",
                                 item.target_name(), item.item2string("applied cfg item")))
            end
        endcase
        if (item.delay_cycles < 0) begin
            `uvm_fatal(get_type_name(),
                       $sformatf("delay_cycles=%0d must be non-negative, item: %s",
                                 item.delay_cycles, item.item2string("applied cfg item")))
        end
        else if (item.delay_cycles > 127) begin
            `uvm_warning(get_type_name(),
                       $sformatf("delay_cycles=%0d for target=%s exceeds RTL range [0:127]; clamp to 127",
                                 item.delay_cycles, item.target_name()))
            return 127;
        end
        else begin
            return item.delay_cycles;
        end
    endfunction

    protected task automatic drive_item(resp_delay_cfg_item item);
        vif.set_target_resp_delay(item.target, item.delay_cycles);
        `uvm_info(get_type_name(), {"cfg driver applied configuration:", item.item2string("applied cfg item")}, UVM_MEDIUM)
    endtask

endclass
