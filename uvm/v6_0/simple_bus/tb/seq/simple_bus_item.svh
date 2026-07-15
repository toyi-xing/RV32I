//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/seq/simple_bus_item.svh
// 用途      : v6.0 simple data bus UVM 环境的一笔总线 transaction。
//
// 规范：
//   - item 只保存 simple bus 协议字段和 monitor 观察到的 response，不包含 driver
//     或 scoreboard 行为。
//   - 通用约束只限制 byte enable 非零；CPU access profile、target 和 MMIO offset
//     的专属约束由后续 sequence 施加。
//
// 功能：
//   - 为 sequence、driver、monitor 和 scoreboard 提供统一的请求/响应数据对象。
//   - 提供 target 译码和格式化 helper，统一日志和后续检查的地址图口径。
//------------------------------------------------------------------------------

class simple_bus_item extends uvm_sequence_item;

    // driver/sequence 使用
    rand bit                        write;
    rand logic [3:0]                be;
    rand logic [core_pkg::XLEN-1:0] addr;
    rand logic [core_pkg::XLEN-1:0] wdata;
    rand int                        idle_cycles;    // 上一笔 response 完成后，到本笔 request 之前的空拍，模拟 cpu 并不每拍指令都访存；首笔表示 initial idle

    // 从 DUT response 填写（简化 UVM 平台，放在同一个 item 中）
    logic [core_pkg::XLEN-1:0] rdata;
    logic                      error;
    int                        resp_delay;          // UVM 统计的 accept rsq 请求到 resp 响应的实际延迟时间，应与配置匹配，验证总线 wrapper

    `uvm_object_utils_begin(simple_bus_item)
        `uvm_field_int(write,       UVM_ALL_ON)
        `uvm_field_int(be,          UVM_ALL_ON)
        `uvm_field_int(addr,        UVM_ALL_ON)
        `uvm_field_int(wdata,       UVM_ALL_ON)
        `uvm_field_int(idle_cycles, UVM_ALL_ON)

        `uvm_field_int(rdata,       UVM_ALL_ON)
        `uvm_field_int(error,       UVM_ALL_ON)
        `uvm_field_int(resp_delay,  UVM_ALL_ON)
    `uvm_object_utils_end

    // be 非零（当前只做基础约束，后续联合约束由专属 sequence 施加）
    constraint c_non0_be {
        be != 4'b0000;
    }

    // idle_cycles 范围及分布
    constraint c_idle_cycles_range {
        idle_cycles inside {[0:15]};
    }
    constraint c_idle_cycles_distribution{
        idle_cycles dist {
            0:=      20,
            [1:8]:/  30,
            [9:15]:/ 50
        };
    }

    function new(string name = "simple_bus_item");
        super.new(name);
        // 默认 sentinel 赋值，在 seq 忘记赋值或 randomize() 情况下也保证安全行为
        write       = 1'b0;
        be          = 4'b1111;
        addr        = core_pkg::DMEM_BASE;
        wdata       = '0;
        idle_cycles = -1;
        // 默认 sentinel 赋值，防止未发送时以为已回填
        rdata       = 'x;
        error       = 1'bx;
        resp_delay  = -1;
    endfunction

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    function string rw2string();
        return (write ? "write" : "read");
    endfunction

    function soc_pkg::target_e decode_target();
        if ((addr >= core_pkg::DMEM_BASE) &&
            (addr <  core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES)) begin
            return soc_pkg::TARGET_DMEM;
        end
        if ((addr >= soc_pkg::GPIO0_BASE) &&
            (addr <  soc_pkg::GPIO0_BASE + soc_pkg::GPIO0_SIZE_BYTES)) begin
            return soc_pkg::TARGET_GPIO0;
        end
        if ((addr >= soc_pkg::UART0_BASE) &&
            (addr <  soc_pkg::UART0_BASE + soc_pkg::UART0_SIZE_BYTES)) begin
            return soc_pkg::TARGET_UART0;
        end
        if ((addr >= soc_pkg::TIMER0_BASE) &&
            (addr <  soc_pkg::TIMER0_BASE + soc_pkg::TIMER0_SIZE_BYTES)) begin
            return soc_pkg::TARGET_TIMER0;
        end
        return soc_pkg::TARGET_UNDEFINED;
    endfunction

    function string target_name();
        case (decode_target())
            soc_pkg::TARGET_DMEM:      return "DMEM";
            soc_pkg::TARGET_GPIO0:     return "GPIO0";
            soc_pkg::TARGET_UART0:     return "UART0";
            soc_pkg::TARGET_TIMER0:    return "TIMER0";
            default:                   return "UNDEFINED";
        endcase
    endfunction

    function string item2string();
        return $sformatf({"\n[item] master: %s be=%04bb addr=0x%08x target=%s wdata=0x%08x idle_cycles=%0d",
                          "\n[item]  slave: rdata=0x%08x error=%0d resp_delay=%0d"},
                         rw2string(), be, addr, target_name(), wdata, idle_cycles,
                         rdata, error, resp_delay);
    endfunction

endclass
