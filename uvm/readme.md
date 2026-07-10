# RV32I UVM 验证工作区

本目录保存按 RTL release 和验证对象划分的 UVM 验证环境。这里的环境用于长期保留可独立编译的 DUT RTL 快照、verification spec、UVM testbench 和 VCS 运行入口，不替代根目录下的 Verilator ASM/C directed regression。

## 目录组织

```text
uvm/
  v6_0/
    simple_bus/
      spec.md
      dut/
        README.md
        rtl/
        docs/
      tb/
      sim/
```

当前环境：

| 路径 | 状态 | 说明 |
|---|---|---|
| `v6_0/simple_bus` | 0835 开发中 | 验证 v6.0 `data_subsystem` simple request/response bus、DMEM/MMIO、response delay 和 error/side-effect 边界。 |

## 版本原则

- 每套环境绑定明确的 RTL release 和验证对象。
- DUT 快照、UVM 源码和仿真脚本放在同一版本目录下，避免主线 RTL 演进后历史环境无法运行。
- 不同版本可以保留同名 package、class 和 module，但不得放入同一个 filelist 编译。
- 根目录 `rtl/` 是当前产品主线；版本目录下的 `dut/rtl/` 是对应 UVM 环境的受控快照。
- UVM 发现 RTL bug 时，先修复根目录主线并运行现有 directed regression，再同步到仍处于开发期的 DUT 快照并记录差异。
- 环境完成并冻结后，不再静默同步主线变化；后续协议或 RTL 版本使用新目录。

具体协议、检查边界和完成标准见各环境的 `spec.md`。DUT RTL 来源和快照维护规则见各环境的 `dut/README.md`。
