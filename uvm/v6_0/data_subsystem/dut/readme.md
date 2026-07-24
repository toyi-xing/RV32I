# v6.0 Simple Bus DUT RTL 快照

本目录保存 `v6_0/data_subsystem` UVM 环境使用的最小 DUT RTL 编译闭包。保存快照的目的是让本环境在主线后续切换到 AXI-Lite、修改 package 或删除 `data_subsystem` 后，仍能从当前仓库独立编译和复现。

## 来源基线

| 项目 | 值 |
|---|---|
| 源仓库 commit | `8930f3a` |
| 源仓库 release | v6.17，0835 最终收口 tag 待创建 |
| 快照建立日期 | `2026-07-24` |
| 验证对象 | `data_subsystem + simple_ram + GPIO0/UART0/TIMER0` |
| data bus 版本 | v6.0 single-outstanding simple request/response bus |

快照建立时，下列 RTL/ABI 文件与根目录对应文件逐字节一致。`sim/filelist.f` 只引用本目录的镜像文件。

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

相对 v6.0 `v6.0-data-side-variable-delay` 基线，本快照包含后续 VCS 兼容性整理和 RTL-001 修复。RTL-001 将 GPIO0、UART0、TIMER0 的寄存器 decode 从原始 byte offset 改为 word-aligned offset `{full_offset[11:2], 2'b00}`；原始 byte address 继续透传，`be` 继续决定有效 byte lane。修复前后 UVM 证据记录在根目录 `docs/known_issues.md`。

本快照中的 RTL 不包含 UVM 专用改动；任何未来主线变更若需要同步，必须重新完成主线回归、更新本说明并重新运行本工作区回归。
