# v5.1 从仿真工程到 FPGA 上板工程

本目录归档 RV32I SoC v5.1 从仿真器验证工程迁移到 FPGA 上板工程的完整材料。这里保留两个并列工程：一个是迁移前的 original 版本，一个是面向 E10 `EP4CE10F17C8` 系统板的 FPGA 版本。

## 目录结构

```text
project_v5.1_original_to_fpga/
+-- readme.md
+-- docs/
+-- project_v5.1_original/
`-- project_v5.1_fpga/
```

| 路径 | 内容 |
| --- | --- |
| [project_v5.1_original](project_v5.1_original/) | v5.1 原始工程，面向 Verilator/仿真器验证，保留原始 RTL、仿真脚本和测试程序。 |
| [project_v5.1_fpga](project_v5.1_fpga/) | v5.1 FPGA 上板工程，包含 E10 顶层、FPGA memory wrapper、Quartus 工程、C 镜像脚本和上板 demo。 |
| [docs](docs/) | v5.1 专项说明文档目录。除本入口 `readme.md` 外，较细的迁移、软件、编译和边界说明统一放在这里。 |

## 阶段结论

v5.1 FPGA 版本已经完成最小上板闭环：

- CPU core RTL 保持不改。
- SoC MMIO 地址图保持不改。
- IMEM/DMEM 缩小到各 16 KiB（方便适配当前工程和FPGA资源的最小改动）。
- 新增 E10 FPGA top、IMEM/DMEM FPGA wrapper、UART TX/RX PHY 和 Quartus 工程。
- C 程序镜像可生成 `current_imem.mem` 与 `current_dmem.mif`，并随 Quartus 编译打包进 `.sof`。
- 已完成 GPIO、KEY、TIMER polling、interrupt 等板级验证。
- FPGA block RAM 同步读与仿真 RAM 组合读时序行为不一致，会导致的中断栈恢复问题。

## 综合与时序结果

当前 Quartus 编译报告来自 `project_v5.1_fpga/fpga/quartus/output_files/`。

| 项目 | 结果 |
| --- | --- |
| Quartus 版本 | Quartus Prime Lite 25.1std.0 Build 1129 |
| 编译状态 | Successful |
| 顶层模块 | `e10_rv32i_top` |
| 目标器件 | `EP4CE10F17C8` |
| Logic elements | 5,184 / 10,320，约 50% |
| Registers | 2,488 |
| Pins | 8 / 180，约 4% |
| Memory bits | 262,144 / 423,936，约 62% |
| Embedded multiplier | 0 / 46 |
| PLL | 0 / 2 |
| 50 MHz setup slack | +1.008 ns，Slow 1200 mV 85 C model |
| 50 MHz hold slack | +0.452 ns，Slow 1200 mV 85 C model |
| 理论最高频率粗算 | 约 52.65 MHz |

该结果说明当前工程可以 fit 到 EP4CE10F17C8，并满足 50 MHz 板载时钟约束。按最差 setup slack 粗略估算，当前关键路径延迟约为 `20.000 ns - 1.008 ns = 18.992 ns`，对应理论最高频率约 `1 / 18.992 ns = 52.65 MHz`。这个数字只用于理解当前 50 MHz 约束下的余量，不等价于重新约束后的正式 Fmax；后续若继续增加外设或扩展 RAM/总线，应重新查看完整 STA report，而不是沿用本次余量。

## 板级验证结果

已在 FPGA 上完成的最小验证：

| 程序/场景 | 验证内容 | 结论 |
| --- | --- | --- |
| `0500` GPIO LED | 软件延时驱动 LED 交替闪烁 | 通过 |
| `0501` smoke | C 裸机程序、GPIO、UART MMIO 写路径 | 通过 |
| `0502` key/LED | GPIO input/output 与按键电平读取 | 通过 |
| `0503` timer polling | TIMER0 计数器轮询 | 通过 |
| `0504` timer interrupt | TIMER0 中断、trap entry、C handler、mret 返回 | 通过 |
| `0505` 综合 | GPIO、KEY、TIMER、UART MMIO 和中断组合使用 | 通过 |

本阶段最关键的问题闭环是 DMEM FPGA wrapper。原仿真 RAM 近似组合读，而 FPGA M9K 是同步读；简单轮询程序可能不暴露问题，但中断入口会大量使用栈保存/恢复寄存器。将 FPGA DMEM 访问时序改为与 CPU 固定访存假设匹配后，中断程序恢复正常。

## 配套文档

`readme.md` 作为阶段入口，汇总目标、目录、结论、资源占用和板级验证结果，不再单独规划 bring-up summary 或 verification report。下面四篇配套文档补齐：

| 文档 | 内容 |
| --- | --- |
| [docs/01_v5.1_rtl_migration_notes.md](docs/01_v5.1_rtl_migration_notes.md) | 说明 RTL 迁移目标、不变边界、逐文件变更表、FPGA memory wrapper、UART ready 握手和 DMEM 同步读时序问题。 |
| [docs/02_v5.1_software_memory_map_and_c_flow.md](docs/02_v5.1_software_memory_map_and_c_flow.md) | 说明 v5.1 软件侧地址图、`platform.h` 同步项、C 裸机规则、`mem/mif` 镜像生成流程。 |
| [docs/03_v5.1_quartus_compile_and_download.md](docs/03_v5.1_quartus_compile_and_download.md) | 说明 v5.1 Quartus 工程编译、SOF 生成、Programmer 下载、更新 C 镜像后重新编译的操作流程。 |
| [docs/04_v5.1_known_limits_and_next_steps.md](docs/04_v5.1_known_limits_and_next_steps.md) | 记录 v5.1 当前边界、未验证项、非通用假设和后续可扩展方向。 |

## 阅读顺序

建议先看根目录 [readme.md](../readme.md) 了解通用上板方法和工具依赖，再回到本目录阅读 v5.1 专项材料。理解 RTL 迁移时优先阅读 `docs/01_v5.1_rtl_migration_notes.md`；实际重新构建和下载时阅读 `docs/02` 到 `docs/03`；评估后续扩展时阅读 `docs/04`。
