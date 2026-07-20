//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/seq/wrapper_item.svh
// 用途      : response-delay wrapper 配置 agent 使用的配置 transaction。
//
// 说明：
//   - 一笔 item 只配置一个 target 的 response delay，不属于 simple data bus 协议。
//   - cfg driver 应用配置后发布 clone，供后续 wrapper checker 与实际 transfer 的
//     response delay 对比。
//   - `delay_cycles` 使用 int，以 -1 作为未初始化哨兵；随机生成时仍限制在 RTL
//     支持的 0～127 范围。
//------------------------------------------------------------------------------

class wrapper_item extends uvm_sequence_item;

    rand soc_pkg::target_e  target;
    rand int                delay_cycles;

    `uvm_object_utils_begin(wrapper_item)
        `uvm_field_enum(soc_pkg::target_e, target,       UVM_ALL_ON)
        `uvm_field_int (                   delay_cycles, UVM_ALL_ON)
    `uvm_object_utils_end

    constraint c_target_range {
        target inside {
            TARGET_DMEM,
            TARGET_GPIO0,
            TARGET_UART0,
            TARGET_TIMER0
        };
    }

    constraint c_delay_cycles_range {
        delay_cycles inside {[0:127]};
    }
    constraint c_delay_cycles_distribution {
        delay_cycles dist {
            0:=        30,
            [1:7]:/    50,
            [8:15]:/   10,
            [16:63]:/  5,
            [64:127]:/ 5
        };
    }

    function new(string name = "wrapper_item");
        super.new(name);
        target       = TARGET_UNDEFINED;
        delay_cycles = -1;
    endfunction

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    function string target_name();
        case (target)
            soc_pkg::TARGET_DMEM:      return "DMEM";
            soc_pkg::TARGET_GPIO0:     return "GPIO0";
            soc_pkg::TARGET_UART0:     return "UART0";
            soc_pkg::TARGET_TIMER0:    return "TIMER0";
            default:                   return "UNDEFINED";
        endcase
    endfunction

    function string item2string(string object_kind = "wrapper_item");
    return $sformatf("\n[%s] wrapper: %s delay_cycles=%0d",
                    object_kind, target_name(), delay_cycles);
    endfunction

endclass
