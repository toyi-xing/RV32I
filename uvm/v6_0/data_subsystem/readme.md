# v6.0 Data Subsystem UVM 工作区

本工作区是 0835 为 v6.0 simple data bus 建立的独立 VCS/UVM/SVA 验证环境。DUT 是 `data_subsystem + simple_ram + GPIO0/UART0/TIMER0`，不包含 CPU、IMEM、软件程序或 SoC 级 testbench。它与根目录 Verilator ASM/C self-check regression 并行存在，不替代后者。

## 当前范围

- simple bus active master agent 驱动 single-outstanding request/response 协议。
- wrapper agent 为 DMEM、GPIO0、UART0、TIMER0 配置 response delay；wrapper scoreboard 检查实际 delay。
- simple bus monitor 产生 observed transfer；simple bus scoreboard 当前检查 DMEM 与 GPIO0 可建模行为，UART0/TIMER0 保持明确 skip。
- `simple_bus_sva.svh` 提供基础协议断言；`data_subsystem_coverage` 采样实际 transfer 的读写、target、地址低位、idle gap、delay 和 error。
- `DS_map_random_test` 在固定 seed 下覆盖全部现有 wrapper delay bin，并作为 RTL-001 修复前 FAIL、修复后 PASS 的回归证据。

完整协议、对象所有权、reference model 边界和 out-of-scope 见 `spec.md`；固定 seed 回归、coverage、RTL-001 前后对比和剩余风险见 `verification_report.md`；DUT 快照来源见 `dut/readme.md`。

## 文档入口

| 文档 | 内容 |
|---|---|
| [`spec.md`](spec.md) | DUT 协议、对象所有权、checker/reference model、coverage 和 out-of-scope。 |
| [`verification_report.md`](verification_report.md) | 固定 seed 回归、coverage、RTL-001 修复证据和剩余风险。 |
| [`dut/readme.md`](dut/readme.md) | DUT 快照来源、文件映射、同步和冻结规则。 |
| [`dut/docs/uvm_simulation_flow.md`](dut/docs/uvm_simulation_flow.md) | VCS 编译运行流程、产物和 PASS/FAIL 统计口径。 |

## 常用命令

运行单个 test：

```bash
uvm/v6_0/data_subsystem/sim/run_test.sh <test_name> <seed> [extra_plusargs...]
```

常用示例：

```bash
uvm/v6_0/data_subsystem/sim/run_test.sh simple_bus_smoke_test 1
uvm/v6_0/data_subsystem/sim/run_test.sh data_subsystem_smoke_test 1
uvm/v6_0/data_subsystem/sim/run_test.sh DS_dmem_random_test 1
uvm/v6_0/data_subsystem/sim/run_test.sh DS_map_random_test 1
ASSERT_ON=1 uvm/v6_0/data_subsystem/sim/run_test.sh simple_bus_smoke_test 1
```

运行当前受控回归：

```bash
uvm/v6_0/data_subsystem/sim/run_all.sh
```

`ASSERT_ON=1` 是单条命令的环境变量赋值，只对该次脚本调用生效。传给 `run_test.sh` 的名称必须是已经被 `data_subsystem_pkg.sv` 包含并完成 factory 注册的 test class，不能直接传 sequence class 名。

## 结果与本地产物

`run_test.sh` 的 PASS 条件是 VCS 编译和 runtime 正常完成，且 UVM error/fatal、SVA/SystemVerilog runtime error 均为零。`run_all.sh` 会继续执行完整测试列表，并在末尾汇总每项 test 的进程返回码、UVM severity、simulator error 和最终结果。

本地仿真主要生成：

| 路径 | 内容 |
|---|---|
| `sim/build/` | 按 test、seed 和 SVA 开关隔离的 VCS 编译产物与 `simv`。 |
| `sim/logs/` | compile/runtime log。 |
| `sim/ucli.key` | VCS/UCLI 运行辅助文件。 |

build 和 log 属于可重新生成的本地产物，不作为版本化验证结论。收口时的 test、seed、scoreboard 统计、coverage 和已知问题前后对比统一写入 `verification_report.md`。functional coverage 在 UVM `report_phase` 输出 console summary；当前 VCS/URG 工具环境无法稳定生成 HTML，因此 HTML 不作为 0835 收口条件。

## DUT 快照

`sim/filelist.f` 只编译本目录 `dut/rtl` 下的冻结 RTL，不引用根目录主线。当前镜像来源为 v6.17 修复 RTL-001 后的主线 commit `8930f3a`。0835 收口完成后，该快照不再随主线 AXI-Lite 等后续演进自动同步。

## 已知边界

- 不验证 full CPU/SoC UVM、trap/CSR/interrupt 精确提交或 multi-outstanding 协议。
- 不建立 UART0/TIMER0 完整 reference model，也不覆盖 GPIO/UART/TIMER 的全部 side effect。
- `idle_cycles` 的计划值与 observed gap 可能受 UVM item 交付相位影响；DUT 功能检查以 monitor observed transfer 为准。
- VDB/URG HTML 报告属于工具环境后续事项，当前以固定 seed、checker 统计和 console coverage 作为证据。
