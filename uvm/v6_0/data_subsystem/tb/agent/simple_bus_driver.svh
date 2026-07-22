//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/agent/simple_bus_driver.svh
// 用途      : v6.0 simple data bus UVM agent 的 active driver。
//
// 规范：
//   - 通过 `drv_cb` 驱动 request 并采样 ready/response，避免与 DUT 产生时钟沿竞争。
//   - 当前总线只允许 single outstanding；一笔 request 收到 response 后才获取下一笔 item。
//   - `idle_cycles` 由 sequence 决定，driver 只负责执行；response 仅用于完成和超时判断，
//     实际 response 结果由 monitor 记录到 observed transfer。
//   - driver 在执行前发布 planned item 的 clone，供后续 execution checker 与 monitor
//     观测值进行独立配对。
//   - 正常 sequence 不在相邻 item 间插入额外时间控制，计划 idle 与 monitor 观测值应一致；
//     若 item 在 clocking event 之间交付，实际 gap 可能包含额外对齐拍，属于平台调度偏差。
//
// 功能：
//   - 等待 reset 释放，按 item 产生 request，并在 backpressure 期间保持 payload。
//   - 支持 accepted 同拍 response 和延迟 response，并用本地 watchdog 防止验证平台无限等待。
//------------------------------------------------------------------------------

class simple_bus_driver extends uvm_driver #(simple_bus_item);

    `uvm_component_utils(simple_bus_driver)

    virtual simple_bus_if.drv_mp vif;
    simple_bus_item planned_item;
    uvm_analysis_port #(simple_bus_item) planned_item_ap;   // 计划 item 可以广播出去待后续使用
    localparam int MAX_REQ_WAIT_CYCLES   = 256; // master req 等待 slave ready 的最大时长
    localparam int MAX_RESP_DELAY_CYCLES = 127; // req 被接受后 slave resp 的最大时长，应与 bus wrapper 最大延迟一致

    function new(string name = "simple_bus_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db #(virtual simple_bus_if.drv_mp)::get(this,"","simple_bus_vif",vif)) begin
            `uvm_fatal(get_type_name(), "failed to get bus driver vif")
        end
        planned_item_ap = new("planned_item_ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        // rst 行为
        drive_idle();
        wait_reset_release();
        // 不断发送 seq 例化的 item
        forever begin
            seq_item_port.get_next_item(req);   // 直接使用 drv 自带的 req 语柄
            $cast(planned_item, req.clone());   // 方法 clone 在基类 uvm_object 中定义，因此 req.clone 返回类型是 uvm_object，使用 cast 进行句柄转换
            planned_item_ap.write(planned_item);
            drive_item(req);
            seq_item_port.item_done();
        end
    endtask

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    protected task wait_reset_release();
        // rst_n 不是 1 时一直等待，包含 X/0 两种情况。
        while (vif.rst_n_i !== 1'b1) begin
            @(posedge vif.clk_i);
        end
        // 再对齐到 driver clocking block，后续驱动都通过 drv_cb 进行。
        @(vif.drv_cb);
    endtask

    // 驱动 req.valid = 0
    protected task automatic drive_idle();
        vif.drv_cb.req_i.valid <= 1'b0;
    endtask

    // 驱动 req
    protected task automatic drive_one(simple_bus_item item);
        vif.drv_cb.req_i.valid <= 1'b1;
        vif.drv_cb.req_i.write <= item.write;
        vif.drv_cb.req_i.be    <= item.be;
        vif.drv_cb.req_i.addr  <= item.addr;
        vif.drv_cb.req_i.wdata <= item.wdata;
    endtask

    // 驱动 driver 发一个 item 给 dut
    protected task automatic drive_item(simple_bus_item item);
        int unsigned wait_cycles, resp_delay_cycles;
        bit accepted, got_resp;  // 根据实际握手而不单纯看 ready 或 resp valid,因为可能存在 item 在非 posedge 交付时导致误判
        // 上一笔 response 完成后的空拍
        repeat (item.idle_cycles) begin
            @(vif.drv_cb);
        end
        // 发送本拍 req，等待接受
        drive_one(item);
        accepted = 1'b0;         // 当前肯定还没握手，因为驱动的 item 还没经历 posedge
        wait_cycles = 0;
        while (!accepted) begin  // 同时覆盖 item 在 posedge 或 clk 间到达
            @(vif.drv_cb);
            accepted = (vif.drv_cb.req_valid_observed === 1'b1 ) && (vif.drv_cb.req_ready_o === 1'b1);
            if (!accepted) begin // 防止首拍握手导致多记 1
                wait_cycles++;
                if (wait_cycles > MAX_REQ_WAIT_CYCLES) begin        // 仅负责超时保护，不负责协议检查
                    `uvm_fatal(get_type_name(),
                               $sformatf("req wait timeout after %0d cycles, item: %s",
                               wait_cycles, item.item2string()));
                end
            end
        end
        // req 发送完毕，等待 resp
        drive_idle();
        resp_delay_cycles = 0;
        got_resp = accepted && (vif.drv_cb.resp_o.valid === 1'b1);   // 可能握手当拍 resp
        while (!got_resp) begin
            @(vif.drv_cb);
            got_resp = accepted && (vif.drv_cb.resp_o.valid === 1'b1);
            resp_delay_cycles++;   // 与 wait_cycles 不同，got_resp 初始化策略不同，这里不会多记 1
            if (resp_delay_cycles > MAX_RESP_DELAY_CYCLES) begin  // 仅负责超时保护，不负责协议检查
                `uvm_fatal(get_type_name(),
                           $sformatf("resp delay timeout after %0d cycles, item: %s",
                           resp_delay_cycles, item.item2string()));
            end
        end
        `uvm_info(get_type_name(), {"bus driver completed a item:", item.item2string()}, UVM_MEDIUM);
    endtask
endclass
