# v6.0 Data Subsystem UVM Verification Report

本文记录 0835 收口时 `uvm/v6_0/data_subsystem` 的实际验证证据。验证要求和协议边界见 `spec.md`，仿真命令及脚本行为见 `dut/docs/uvm_simulation_flow.md`。

## 1. 基线

| 项目 | 值 |
|---|---|
| 报告日期 | 2026-07-24 |
| 主工程 RTL commit | `v7.0` |
| DUT 快照 | `dut/rtl`，与上述主工程 RTL 逐文件一致 |
| DUT | `data_subsystem + simple_ram + GPIO0/UART0/TIMER0` |
| 协议 | v6.0 single-outstanding simple request/response bus |
| 仿真器 | Synopsys VCS `W-2024.09-SP1_Full64` |
| UVM | VCS 自带 UVM 1.1d |
| UVM 固定 seed | `1` |

`sim/filelist.f` 已切换为只编译本工作区 `dut/rtl` 快照，不引用根目录主线 RTL。快照来源和文件映射见 `dut/readme.md`。

## 2. UVM 回归结果

下表来自收口时本地 `sim/logs/` 中 seed 1 的运行日志。`partial` 表示只检查了当前已定义的 error/data 子集，`skip` 表示 target-specific 功能模型尚未接入；两者不等于 mismatch，剩余边界见第 6 章。日志属于可重新生成的本地产物，本报告保存版本化结论。

| Test | Transaction | Simple bus scoreboard | Wrapper scoreboard | Data coverage | Behavior coverage | UVM error/fatal | 结果 |
|---|---:|---|---|---:|---:|---|---|
| `data_subsystem_base_test` | 0 | 0 correct / 0 error / 0 partial / 0 skip | 0 correct / 0 error | 0.00% | 0.00% | 0 / 0 | PASS |
| `simple_bus_smoke_test` | 4 | 2 correct / 0 error / 2 partial / 0 skip | 4 correct / 0 error | 60.00% | 27.86% | 0 / 0 | PASS |
| `data_subsystem_smoke_test` | 10 | 5 correct / 0 error / 5 partial / 0 skip | 10 correct / 0 error | 60.00% | 40.57% | 0 / 0 | PASS |
| `DS_dmem_random_test` | 2000 | 826 correct / 0 error / 1174 partial / 0 skip | 2000 correct / 0 error | 100.00% | 71.15% | 0 / 0 | PASS |
| `DS_map_random_test` | 2100 | 819 correct / 0 error / 703 partial / 578 skip | 2100 correct / 0 error | 96.67% | 100.00% | 0 / 0 | PASS |

`data_subsystem_base_test` 是结构性空场景，只证明 env 构建、连接和 phase 收尾正常，不提供功能 coverage。其余 test 均由 monitor 产生完整 transaction，并由 wrapper scoreboard 覆盖全部 transaction。

## 3. Coverage 结论

`DS_map_random_test` 在每个 delay 档位为 DMEM、GPIO0、UART0、TIMER0 配置相同 delay，并依次运行 `0/1/3/8/32/64/127` 七档，共完成 2100 笔 transaction。该固定 seed 命中当前 `bus_behavior_cg` 的全部 bins/crosses，behavior coverage 为 100.00%；成功 transaction 的 data 分布 coverage 为 96.67%。

该百分比只说明当前 covergroup 定义的 op、target、地址低位、BE 分类、idle gap、response delay、error 及相应 crosses 已被命中，不代表 UART0/TIMER0 reference model、全部 GPIO0 寄存器、外设 side effect 或 full CPU/SoC 已覆盖。

当前 VCS/URG 工具环境生成 HTML 报告时发生工具自身异常，因此 0835 使用 UVM `report_phase` 的 console coverage、checker 统计和固定 seed 日志作为归档证据。HTML coverage 不是本次收口的 PASS 条件。

## 4. RTL-001 前后对比

`DS_map_random_test 1` 在 RTL-001 修复前得到 `UVM_ERROR=52`：其中 48 条是 GPIO0 已定义 word offset 上的非零 byte address 被误判为 unknown offset，另有 4 条是被拒绝写入后产生的 OUT/OE readback mismatch。相同运行中 wrapper scoreboard 为 2100/2100 匹配，说明失败集中在 MMIO register decode，而不是 response-delay wrapper。

RTL 修复将 GPIO0、UART0、TIMER0 的寄存器 offset decode 统一改为 `{full_offset[11:2], 2'b00}`，保留原始 byte address 和 `be` 的 byte-lane 语义。修复后使用相同 test 和 seed，`UVM_ERROR=0`、`UVM_FATAL=0`，GPIO0 known/unknown word-offset 检查通过，wrapper scoreboard 仍为 2100/2100 匹配。

完整问题分析、定向测试未暴露原因和修复记录见根目录 `docs/known_issues.md` 的 RTL-001。

## 5. Directed Regression

RTL-001 修复后，现有 Verilator C 与 ASM self-check regression 已由项目维护者运行并通过。该结果证明修复未破坏现有 CPU/SoC 软件可见场景；UVM 与 directed regression 的验证职责仍保持并行。

本报告不把 C/ASM 日志复制进 UVM 工作区。对应 testcase、脚本和原始日志继续由根目录 Verilator 回归目录维护。

## 6. 剩余风险

- `simple_bus_scoreboard` 完整建模 DMEM，并只建模 GPIO0 OUT/OE；UART0/TIMER0 功能 transfer 当前计入 `skip_count`。
- GPIO0 其它已定义寄存器和 write response 只完成部分检查，计入 `partial_count`；没有 UVM error 不代表这些未建模结果已经验证。
- GPIO input、UART RX、外设输出事件和 IRQ 没有独立 sideband agent/checker。
- bus driver `planned_item_ap` 尚未接入 execution checker，planned/observed idle gap 未作为 PASS/FAIL 条件。
- 当前只归档 seed 1 的 closure 结果，没有定义多 seed coverage closure 或 CI 阈值。
- SVA 可通过 `ASSERT_ON=1` 启用并由脚本统计 `SIM_ERROR`，但本表不单列一次 assertion-enabled 全回归证据。
- VDB/URG HTML 报告受当前工具环境限制，未作为归档证据。

这些项目不阻塞 v7.0 教学型 UVM 基础设施收口；若继续扩展本工作区，应按 `spec.md` 第 16 章逐项增加明确 testcase、checker 和 coverage。
