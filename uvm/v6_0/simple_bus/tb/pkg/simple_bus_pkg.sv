//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/simple_bus/tb/pkg/simple_bus_pkg.sv
// 用途      : v6.0 simple data bus UVM 环境的公共 package 入口。
//
// 规范：
//   - UVM package 和宏文件必须先于各 UVM class include。
//   - DUT 公共类型从归档的 core_pkg/soc_pkg/data_bus_pkg 导入。
//   - class 文件通过本 package 按依赖顺序 include，不在 filelist 中重复编译。
//   - package/class 名保持 simple_bus_* 口径，release 边界由目录和 filelist 隔离。
//
// 功能：
//   - 汇总 simple bus UVM 环境所需的公共 package 和宏依赖。
//   - 当前已接入 transaction、sequence、agent、DMEM scoreboard、env、base test 和
//     DMEM smoke test；后续继续加入 coverage 与更多派生 test。
//------------------------------------------------------------------------------

package simple_bus_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import core_pkg::*;
    import soc_pkg::*;
    import data_bus_pkg::*;

    `include "simple_bus_item.svh"
    `include "simple_bus_base_sequence.svh"
    `include "simple_bus_sequences.svh"
    `include "simple_bus_sequencer.svh"
    `include "simple_bus_driver.svh"
    `include "simple_bus_monitor.svh"
    `include "simple_bus_agent.svh"
    `include "simple_bus_scoreboard.svh"
    `include "simple_bus_env.svh"
    `include "simple_bus_base_test.svh"
    `include "simple_bus_tests.svh"
endpackage
