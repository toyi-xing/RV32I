//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/simple_bus_transfer.svh
// 用途      : v6.0 simple data bus UVM monitor 重建的 observed transfer。
//
// 规范：
//   - 只保存 interface 上实际观察到的 master-side item 和 DUT response，不读取
//     sequence/driver 持有的计划 item。
//   - 内嵌 item 是由 monitor 独立填写的对象实例，与计划 item 仅复用字段结构；
//     两者是否一致由后续 driver execution checker 检查。
//   - response delay 来自 monitor 采样结果，供 wrapper checker 和 coverage 使用。
//
// 功能：
//   - 组合实际 request、request 前 idle_cycles、response 数据/错误和 response delay。
//   - 作为 scoreboard、checker 和 coverage 的统一 observed transaction 输入。
//   - 提供完整 transfer 的格式化日志 helper。
//------------------------------------------------------------------------------

class simple_bus_transfer extends uvm_sequence_item;

    // mon 观测的 DUT 实际输入与计划驱动变量类型一致，直接用 item（但不使用 randomize）
    simple_bus_item            observed_item;
    // 再扩展 mon 挂测的 DUT 输出
    logic [core_pkg::XLEN-1:0] rdata;
    logic                      error;
    int                        resp_delay;  // UVM 统计的 accept req 请求到 resp 响应的实际延迟时间，应与配置匹配，验证总线 wrapper

    int unsigned               req_cycle, accept_cycle, resp_cycle;

    `uvm_object_utils_begin(simple_bus_transfer)
        `uvm_field_object(observed_item,UVM_ALL_ON)
        `uvm_field_int   (rdata,        UVM_ALL_ON)
        `uvm_field_int   (error,        UVM_ALL_ON)
        `uvm_field_int   (resp_delay,   UVM_ALL_ON)
        `uvm_field_int   (req_cycle,    UVM_ALL_ON)
        `uvm_field_int   (accept_cycle, UVM_ALL_ON)
        `uvm_field_int   (resp_cycle,   UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "simple_bus_transfer");
        super.new(name);
        observed_item = simple_bus_item::type_id::create({name, "_observed_item"});
        // 默认 sentinel 赋值，防止未发送时以为已回填
        rdata        = 'x;
        error        = 1'bx;
        resp_delay   = -1;
        req_cycle    = 0;
        accept_cycle = 0;
        resp_cycle   = 0;
    endfunction

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    function string transfer2string(string object_kind = "simple_bus_transfer");
    return $sformatf({observed_item.item2string(object_kind)," req_cycle=%0d, accept_cycle=%0d",
                      "\n[%s]  slave: rdata=0x%08x error=%0d resp_delay=%0d resp_cycle=%0d"},
                      req_cycle, accept_cycle,
                      object_kind, rdata, error, resp_delay, resp_cycle);
    endfunction

endclass
