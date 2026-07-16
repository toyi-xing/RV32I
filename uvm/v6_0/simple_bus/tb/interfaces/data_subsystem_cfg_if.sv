//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/interfaces/data_subsystem_cfg_if.sv
// 用途      : v6.0 data_subsystem response delay 的 UVM 专用配置接口。
//
// 规范：
//   - 不属于 simple data bus 协议，不进入通用 agent 的 transaction payload。
//   - 仅在没有 outstanding request 时更新配置，并在下一笔 request accepted 前保持稳定。
//   - 配置 task 立即生效且不等待时钟，避免引入额外 request idle 拍。
//
// 功能：
//   - 保存 DMEM、GPIO0、UART0、TIMER0 的 response delay 配置。
//   - 提供全 target 清零和按 target 更新 delay 的 task，供 top/test/sequence 使用。
//------------------------------------------------------------------------------

`default_nettype none

interface resp_delay_cfg_if(
    input clk_i,
    input rst_n_i
);

    import  soc_pkg::*;

    logic [6:0] dmem_resp_delay_cycles;
    logic [6:0] gpio0_resp_delay_cycles;
    logic [6:0] uart0_resp_delay_cycles;
    logic [6:0] timer0_resp_delay_cycles;

    task automatic rst_resp_delay();
        dmem_resp_delay_cycles   = '0;
        gpio0_resp_delay_cycles  = '0;
        uart0_resp_delay_cycles  = '0;
        timer0_resp_delay_cycles = '0;
    endtask

    task automatic set_target_resp_delay(
        soc_pkg::target_e  target_i,
        logic [6:0]        delay_cycles_i
    );
        unique case (target_i)
            TARGET_DMEM:   dmem_resp_delay_cycles   = delay_cycles_i;
            TARGET_GPIO0:  gpio0_resp_delay_cycles  = delay_cycles_i;
            TARGET_UART0:  uart0_resp_delay_cycles  = delay_cycles_i;
            TARGET_TIMER0: timer0_resp_delay_cycles = delay_cycles_i;
            default: ;
        endcase
    endtask

endinterface

`default_nettype wire
