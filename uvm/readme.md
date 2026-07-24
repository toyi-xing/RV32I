# RV32I UVM 验证工作区

本目录保存按 RTL release 和验证对象划分的 UVM 验证环境。它与 `fpga/` 工作区采用相似的版本归档原则：每套环境保存与目标版本匹配的 RTL 快照、专用验证代码、工具入口和结果文档，使主线后续修改协议或删除旧模块后，历史环境仍能独立理解和复现。

UVM、根目录 directed regression 和 FPGA 工作区是并行验证资产。UVM 环境侧重模块、接口协议和受控随机场景；根目录 Verilator ASM/C self-check regression 侧重软件驱动的 CPU/SoC 端到端行为；FPGA 工作区侧重综合实现和真实板级 IO。具体 UVM 环境可以使用不同仿真器、UVM 版本、操作系统和运行脚本，其工具依赖、命令、结果口径及已知边界由各环境自己的 `readme.md` 和 spec 定义。

## 目录组织

每套环境使用版本目录和验证对象目录形成独立边界：

```text
uvm/
  readme.md
  <rtl_release>/
    <verification_target>/
      readme.md
      spec.md
      verification_report.md
      dut/
      tb/
      sim/
```

同一 RTL release 可以按验证对象建立多个并列环境；不同 release 即使验证相同对象，也应使用新的版本目录。

## 工具依赖

本工作区在 Linux 下开发和运行，依赖：

- Synopsys VCS `W-2024.09-SP1_Full64`，用于 SystemVerilog 编译、elaboration 和仿真。
- VCS 自带 UVM 1.1d，由脚本通过 `-ntb_opts uvm` 启用，不需要在仓库内单独保存 UVM library。
- 可用的 Synopsys license 环境。
- Bash、AWK 及常见 GNU/Linux 命令行工具，用于运行和统计回归。
- 可选 URG，用于生成 VCS coverage database 报告。

## 使用原则

进入具体环境前先阅读其 `readme.md`，再根据需要查看 verification spec、仿真流程和 verification report。命令应从具体环境声明的工作目录执行；build、log、coverage database 等生成物是否归档，也由该环境的文档和忽略规则确定。

## 版本原则

- 每套环境绑定明确的 RTL release 和验证对象。
- DUT 快照、UVM 源码和仿真脚本放在同一版本目录下，避免主线 RTL 演进后历史环境无法运行。
- 不同版本可以保留同名 package、class 和 module，但不得放入同一个 filelist 编译。
- 根目录 `rtl/` 是当前产品主线；版本目录下的 `dut/rtl/` 是对应 UVM 环境的受控快照。
- UVM 发现 RTL bug 时，先修复根目录主线并运行现有 directed regression，再同步到仍处于开发期的 DUT 快照并记录差异。
- 环境完成并冻结后，不再静默同步主线变化；后续协议或 RTL 版本使用新目录。
