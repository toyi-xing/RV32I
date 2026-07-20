# v6.0 Simple Bus DUT RTL 快照

本目录保存 `v6_0/simple_bus` UVM 环境使用的最小 DUT RTL 编译闭包。保存快照的目的是让本环境在主线后续切换到 AXI-Lite、修改 package 或删除 `data_subsystem` 后，仍能从当前仓库独立编译和复现。

## 来源基线

| 项目 | 值 |
|---|---|
| 源仓库 commit | `c2f7d82` |
| 源仓库 tag | `v6.0-data-side-variable-delay` |
| 快照建立日期 | `2026-07-10` |
| 验证对象 | `data_subsystem + simple_ram + GPIO0/UART0/TIMER0` |
| data bus 版本 | v6.0 single-outstanding simple request/response bus |

快照建立时，下列 RTL 文件与根目录对应文件逐字节一致。

## 文件映射

| 快照文件 | 来源文件 | 用途 |
|---|---|---|
| `rtl/common/core_pkg.sv` | `rtl/common/core_pkg.sv` | XLEN、DMEM 地址和基础公共类型。 |
| `rtl/common/soc_pkg.sv` | `rtl/common/soc_pkg.sv` | MMIO 地址图、寄存器 offset 和 target 类型。 |
| `rtl/common/data_bus_pkg.sv` | `rtl/common/data_bus_pkg.sv` | `data_req_t`、`data_resp_t`。 |
| `rtl/mem/simple_ram.sv` | `rtl/mem/simple_ram.sv` | 外置固定响应 DMEM model。 |
| `rtl/periph/mmio_gpio.sv` | `rtl/periph/mmio_gpio.sv` | GPIO0 register block。 |
| `rtl/periph/mmio_uart.sv` | `rtl/periph/mmio_uart.sv` | UART0 register block。 |
| `rtl/periph/mmio_timer32.sv` | `rtl/periph/mmio_timer32.sv` | TIMER0 register block。 |
| `rtl/soc/data_subsystem.sv` | `rtl/soc/data_subsystem.sv` | simple bus decoder、target wrapper 和 response mux。 |
| `docs/periph_register_abi.md` | `rtl/periph/readme.md` | 与快照匹配的外设寄存器 ABI。 |

本快照不包含 CPU core、`rv32i_soc`、IMEM、软件程序或 SoC directed testbench，因为它们不属于本 UVM harness 的 DUT 编译闭包。

## 开发期同步规则

0835 环境尚未冻结时，如果 UVM 发现真实 RTL bug：

1. 先在根目录主线 RTL 修复问题。
2. 运行相关 Verilator directed test，确认 CPU/SoC 端到端行为不退化。
3. 将同一修复同步到本快照。
4. 在下方“快照差异”记录原因、文件和对应 commit。

不得只修改本快照来隐藏 DUT bug，也不得为了方便 UVM 驱动而改变协议。验证适配应放在 `../tb/` 的 interface、harness 或 bind/assertion 中。

## 冻结规则

0835 完成后，本目录作为 v6.0 simple bus DUT 归档冻结。主线进入 AXI-Lite 或其它协议后，不再把无关变化同步到这里。未来环境应建立新的版本目录和独立 filelist，不能同时编译多个版本的同名 package/module。

## 快照差异

当前没有相对 `c2f7d82` / `v6.0-data-side-variable-delay` 的 RTL 差异。
