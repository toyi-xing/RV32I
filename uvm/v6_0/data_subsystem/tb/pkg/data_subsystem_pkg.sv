//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/pkg/data_subsystem_pkg.sv
// 用途      : v6.0 data_subsystem UVM 环境的公共 package 入口。
//
// 规范：
//   - UVM package 和宏文件必须先于各 UVM class include。
//   - DUT 公共类型从归档的 core_pkg/soc_pkg/data_bus_pkg 导入。
//   - class 文件通过本 package 按依赖顺序 include，不在 filelist 中重复编译。
//   - package 使用 data_subsystem_* 口径；simple_bus_* 与 wrapper_* class 保持各自子系统边界。
//
// 功能：
//   - 汇总 data_subsystem UVM 环境所需的公共 package 和宏依赖。
//   - 当前已接入 bus/wrapper transaction、sequence、agent、virtual sequencer、DMEM
//     scoreboard、env、base test 和 smoke test；后续继续加入 wrapper checker、coverage
//     与更多派生 test。
//------------------------------------------------------------------------------

package data_subsystem_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import core_pkg::*;
    import soc_pkg::*;
    import data_bus_pkg::*;

    // item/tr
    `include "simple_bus_item.svh"
    `include "simple_bus_transfer.svh"
    `include "wrapper_item.svh"

    // seq
    `include "simple_bus_base_sequence.svh"
    `include "simple_bus_sequences.svh"
    `include "wrapper_base_sequence.svh"
    `include "wrapper_sequences.svh"

    // agent
    `include "simple_bus_sequencer.svh"
    `include "wrapper_sequencer.svh"
    `include "simple_bus_driver.svh"
    `include "wrapper_driver.svh"
    `include "simple_bus_monitor.svh"
    `include "simple_bus_agent.svh"
    `include "wrapper_agent.svh"

    // checker
    `include "simple_bus_scoreboard.svh"

    // virtual
    `include "data_subsystem_virtual_sequencer.svh"
    `include "data_subsystem_base_virtual_sequence.svh"
    `include "data_subsystem_virtual_sequences.svh"

    // env
    `include "data_subsystem_env.svh"

    // test
    `include "data_subsystem_base_test.svh"
    `include "data_subsystem_tests.svh"
endpackage
