//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/wrapper_base_sequence.svh
// 用途      : response-delay wrapper physical sequence 的公共基类。
//
// 说明：
//   - 只构造和发送 `wrapper_item`，不直接访问 wrapper interface，也不产生 simple bus
//     transaction。
//   - `target` 和 `delay_cycles` 保存单笔默认配置，供 `apply_wrapper_cfg_seq` 生成一笔
//     wrapper item；未初始化值由 wrapper driver 作最终合法性检查。
//   - `send_wrapper_cfg()` 支持派生 sequence 以显式参数连续发送多笔不同配置；
//     `apply_wrapper_cfg()` 则发送当前 sequence 保存的一笔默认配置。
//   - `num_items` 为后续 multi-config/random sequence 预留；当前 `apply_wrapper_cfg_seq`
//     固定只发送一笔 item。
//------------------------------------------------------------------------------

class wrapper_base_seq extends uvm_sequence #(wrapper_item);

    `uvm_object_utils(wrapper_base_seq)

    soc_pkg::target_e  target;
    int                delay_cycles;

    rand int unsigned num_items;
    constraint c_mum_items{
        num_items inside {[1:100]};
    }

    function new(string name = "wrapper_base_seq");
        super.new(name);
        target       = TARGET_UNDEFINED;
        delay_cycles = -1;
        num_items    = 1;
    endfunction

    //-----------------------------------------------------------------------
    // helper 基类提供的方法，供子类拓展方便调用
    //-----------------------------------------------------------------------

    // 直接建立一个 cfg item，无需配置内部变量
    protected task automatic send_wrapper_cfg(
        soc_pkg::target_e target,
        int               delay_cycles
    );
        req = wrapper_item::type_id::create("req_wrapper");
        start_item(req);
        req.target       = target;
        req.delay_cycles = delay_cycles;
        finish_item(req);
    endtask

    // 应用当前配置的内部 target、delay_cycles
    protected task automatic apply_wrapper_cfg();
        req = wrapper_item::type_id::create("req_wrapper");
        start_item(req);
        req.target       = this.target;
        req.delay_cycles = this.delay_cycles;
        finish_item(req);
    endtask

endclass
