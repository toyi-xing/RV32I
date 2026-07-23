//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/env/data_subsystem_coverage.svh
// 用途      : data_subsystem UVM 环境的基础 functional coverage collector。
//
// 规范：
//   - 作为 `simple_bus_transfer` 的 subscriber，只采样 simple bus monitor 重建的
//     实际完成 transaction，不读取 sequence、driver 或 wrapper 配置 item。
//   - 正常访问采样实际 read/write 数据分布；所有完成 transaction 均采样实际 idle
//     gap、response delay、response error 及其 timing cross。
//   - functional coverage 只证明已观测场景发生过，不替代 DMEM scoreboard、wrapper
//     scoreboard 或 SVA 的功能正确性检查。
//
// 功能：
//   - 覆盖实际 read/write 数据分布及其 access-kind cross。
//   - 覆盖实际 idle gap、response delay、response error，以及 op/delay、
//     idle-gap/delay cross。
//------------------------------------------------------------------------------

class data_subsystem_coverage extends uvm_subscriber #(simple_bus_transfer);

    `uvm_component_utils(data_subsystem_coverage)

    covergroup rw_data_cg with function sample(
        bit          rw_kind,
        logic [31:0] rw_data
    );

        option.per_instance = 1;
        option.name = "rw_data_cg";

        // 访问类型
        cp_rw_kind: coverpoint rw_kind{
            bins read  = {1'b0};
            bins write = {1'b1};
        }

        // 访问数据
        cp_data: coverpoint rw_data{
            bins zero = { 32'h0000_0000};
            bins low  = {[32'h0000_0001 : 32'h3fff_ffff]};
            bins mid  = {[32'h4000_0000 : 32'hbfff_ffff]};
            bins high = {[32'hc000_0000 : 32'hffff_fffe]};
            bins ones = { 32'hffff_ffff};
        }

        // 访问类型 x 数据
        cross_rw_data: cross cp_rw_kind, cp_data;
    endgroup

    covergroup bus_behavior_cg with function sample(
        simple_bus_transfer tr
    );
        option.per_instance = 1;
        option.name = "bus_behavior_cg";

        // 读访问 or 写访问
        cp_op_kind: coverpoint tr.observed_item.write{
            bins read  = {1'b0};
            bins write = {1'b1};
        }

        // 访问间隔，0 表示连续访问
        cp_idle_gap: coverpoint tr.observed_item.idle_cycles{
            bins zero  = {0};
            bins short = {[1:3]};
            bins med   = {[4:7]};
            bins long  = {[8:$]};   // 非 dut 硬件边界，有 uvm_drv 决定
        }

        // 访问地址对应设备
        cp_addr_dev: coverpoint tr.observed_item.addr{
            bins dmem   = {[core_pkg::DMEM_BASE  : core_pkg::DMEM_BASE  + core_pkg::DMEM_SIZE_BYTES  - 1]};
            bins gpio0  = {[soc_pkg::GPIO0_BASE  : soc_pkg::GPIO0_BASE  + soc_pkg::GPIO0_SIZE_BYTES  - 1]};
            bins timer0 = {[soc_pkg::TIMER0_BASE : soc_pkg::TIMER0_BASE + soc_pkg::TIMER0_SIZE_BYTES - 1]};
            bins uart0  = {[soc_pkg::UART0_BASE  : soc_pkg::UART0_BASE  + soc_pkg::UART0_SIZE_BYTES  - 1]};
            bins undef  = default;
        }

        // 访问宽度，根据实际应用场景分类
        cp_accses_width: coverpoint tr.observed_item.be{
            bins word32 = {4'b1111};
            bins half16 = {4'b0011, 4'b1100};
            bins byte8  = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
        }

        // resp 延迟
        cp_resp_delay: coverpoint tr.resp_delay{
            bins zero  = {0};
            bins next  = {1};
            bins short = {[2:7]};
            bins med   = {[8:15]};
            bins long  = {[16:63]};
            bins slong = {[64:126]};
            bins max   = {127};     // wrapper 支持的最大边界
        }

        // 访问成功 or 失败
        cp_resp_error: coverpoint tr.error{
            bins access_correct = {1'b0};
            bins access_error   = {1'b1};
        }

        // 读写访问 x 不同访问宽度
        cross_op_width: cross cp_op_kind, cp_accses_width;
        // 读写访问 x 不同 resp 延迟
        cross_op_delay: cross cp_op_kind, cp_resp_delay;
        // 访问不同设备 x 不同 resp 延迟。访问为定义时不经过 wrapper，延迟也是固定当拍响应
        cross_dev_delay: cross cp_addr_dev, cp_resp_delay {
            ignore_bins ignore_undef =
                binsof(cp_addr_dev.undef);
        }
        // 不同访问间隔 x 不同 resp 延迟
        cross_idle_delay: cross cp_idle_gap, cp_resp_delay;

    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        rw_data_cg    = new();
        bus_behavior_cg = new();
    endfunction

    function void write(simple_bus_transfer tr);
        if (!tr.error) begin
            if (tr.observed_item.write) begin
                rw_data_cg.sample(tr.observed_item.write, tr.observed_item.wdata);
            end
            else begin
                rw_data_cg.sample(tr.observed_item.write, tr.rdata);
            end
        end
        bus_behavior_cg.sample(tr);
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
                  $sformatf({"[Functional coverage]",
                             "\naccess bus with data coverage: %0.2f%%",
                             "\naccess bus with behavior coverage: %0.2f%%"},
                            rw_data_cg.get_coverage(), bus_behavior_cg.get_coverage()), UVM_MEDIUM)
    endfunction

endclass
