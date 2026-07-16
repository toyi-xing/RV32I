# v6.0 Simple Bus UVM 仿真流程

本文定义 `uvm/v6_0/simple_bus` 的 VCS/UVM 仿真入口、产物和结果判定。该环境绑定 v6.0 single-outstanding simple data bus DUT 快照；主线 RTL 后续演进不改变本环境的 DUT 语义。

## 1. 入口脚本

`sim/run_test.sh` 运行一个指定 UVM test：

```bash
uvm/v6_0/simple_bus/sim/run_test.sh <test_name> <seed> [extra_plusargs...]
```

示例：

```bash
uvm/v6_0/simple_bus/sim/run_test.sh simple_bus_smoke_test 1
ASSERT_ON=1 uvm/v6_0/simple_bus/sim/run_test.sh simple_bus_wait_test 17
```

`ASSERT_ON=1` 在 VCS 编译期加入 `+define+ASSERT_ON`，启用 `simple_bus_if` 及后续 bind SVA。开启和关闭断言使用不同 build 目录，不会复用彼此的增量编译产物。

`sim/run_all.sh` 是受控回归入口。正式加入回归的 test class 放入其 `TESTS` 列表；脚本逐项调用 `run_test.sh`，即使某一项失败也继续运行其余项，并在末尾打印汇总表。

## 2. 编译与运行

每个 test 的 VCS 编译顺序由 `sim/filelist.f` 固定：

1. DUT 公共 package。
2. v6.0 DUT RTL 闭包。
3. static interface、UVM package/class 和 harness top。

UVM top 实例化 DUT、simple bus interface、delay configuration interface 和外部 DMEM model。`run_test.sh` 通过 `+UVM_TESTNAME=<test_name>` 让 `run_test()` 从 factory 创建派生 test；test 创建 env，sequence 经 sequencer 交给 driver，monitor 将观察到的 transaction 广播给 scoreboard、coverage 和 DUT 专用 checker。

## 3. 产物与日志

以 `<test>` 和 `<seed>` 为键保存产物：

| 路径 | 内容 |
|---|---|
| `sim/build/<test>_<seed>/` | 不启用 SVA 时的 VCS 增量编译目录和 `simv`。 |
| `sim/build/<test>_<seed>_assert_on/` | 启用 `ASSERT_ON=1` 时的独立 VCS 编译目录和 `simv`。 |
| `sim/logs/<test>_<seed>_compile.log` | VCS 编译/elaboration log。 |
| `sim/logs/<test>_<seed>.log` | runtime log，包含 UVM Report Summary 和 simulator diagnostics。 |

build/log 产物属于本地仿真输出，不纳入版本控制。排查失败时先看 runtime log；若没有该文件，则查看 compile log。

## 4. PASS/FAIL 口径

`run_test.sh` 在仿真结束后打印：

```text
>>> RESULT: PASS|FAIL (run_rc=<n> uvm_error=<n> uvm_fatal=<n> sim_error=<n>)
```

以下任一条件成立即为 `FAIL`：

- VCS 编译失败，或预期 `simv` 未生成。
- `simv` runtime 返回码 `run_rc` 非零。
- UVM Report Summary 中 `UVM_ERROR` 非零。
- UVM Report Summary 中 `UVM_FATAL` 非零。
- runtime log 中 VCS `Error:` 或 `%Error` diagnostics 非零；这包括当前 SVA fail action 的 `$error`。

因此 `PASS` 表示仿真基础设施正常完成，且已接入的 UVM checker、scoreboard、coverage threshold check、SVA 和 SystemVerilog runtime checks 均未报告失败。它不是“DUT 未经检查即天然正确”的含义；DUT 功能正确性由各 test 的 checker/scoreboard/SVA 覆盖范围共同定义。

## 5. 回归汇总

`run_all.sh` 汇总每个 test 的 `RUN_RC`、`UVM_INFO`、`UVM_WARN`、`UVM_ERROR`、`UVM_FATAL` 和 `SIM_ERROR`。其中：

- `RUN_RC` 表示单 test 脚本及其 VCS/simv 进程的退出状态，用于识别 license、编译、可执行文件和仿真启动问题。
- `UVM_*` 来自 UVM Report Summary。
- `SIM_ERROR` 是 UVM 之外的 simulator runtime error 计数，主要用于 SVA `$error`。

回归中任一 test 为 `FAIL` 时，`run_all.sh` 最终返回非零退出码，适合后续 CI 或批量 nightly regression 使用。
