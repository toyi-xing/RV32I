// v6.0 simple data bus UVM 最小工程编译清单。
// 本文件中的相对路径以 sim/ 目录为基准，由 run_test.sh 在该目录调用 VCS。

// data_subsystem_pkg.sv 通过 `include 引入 tests/ 下的 class 文件。
+incdir+../tb/agent
+incdir+../tb/checker
+incdir+../tb/env
+incdir+../tb/seq
+incdir+../tb/sva
+incdir+../tb/tests
+incdir+../tb/virtual

// DUT 公共 package 必须先于使用它们的 UVM package 编译。
../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

// DUT rtl
// -y ../dut/rtl/mem
// -y ../dut/rtl/periph
// -y ../dut/rtl/soc
// +libext+.sv
../../../../rtl/soc/data_subsystem.sv
../../../../rtl/periph/mmio_gpio.sv
../../../../rtl/periph/mmio_timer32.sv
../../../../rtl/periph/mmio_uart.sv
../../../../rtl/mem/simple_ram.sv

// UVM package 先于导入它的静态 testbench top 编译。
../tb/interfaces/simple_bus_if.sv
../tb/interfaces/wrapper_if.sv
../tb/pkg/data_subsystem_pkg.sv
../tb/top/tb_data_subsystem_uvm_top.sv
