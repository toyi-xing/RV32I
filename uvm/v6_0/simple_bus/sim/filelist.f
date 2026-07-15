// v6.0 simple data bus UVM 最小工程编译清单。
// 本文件中的相对路径以 sim/ 目录为基准，由 run_test.sh 在该目录调用 VCS。

// simple_bus_pkg.sv 通过 `include 引入 tests/ 下的 class 文件。
+incdir+../tb/agent
+incdir+../tb/env
+incdir+../tb/seq
+incdir+../tb/tests

// DUT 公共 package 必须先于使用它们的 UVM package 编译。
../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

// UVM package 先于导入它的静态 testbench top 编译。
../tb/interfaces/simple_bus_if.sv
../tb/pkg/simple_bus_pkg.sv
../tb/top/tb_simple_bus_uvm_top.sv
