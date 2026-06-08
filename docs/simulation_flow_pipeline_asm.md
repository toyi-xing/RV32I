# 五级流水线汇编仿真流程

> 本文档只写与单周期仿真流程的差异。六步总览、文件角色、工具链等通用内容参见 `simulation_flow_singlecycle_asm.md`。

---

## 1. 仿真命令

将单周期脚本路径替换为流水线版本：

```bash
# 编译汇编 → .mem（与单周期共用 build/ 目录）
sim/pipeline5_asm/05_build_mem.sh <test>

# 构建 Verilator 仿真 + 运行
sim/pipeline5_asm/06_run_sim.sh <test>

# 两步合一
sim/pipeline5_asm/run_test.sh <test>

# 回归全部汇编测试（10 个：分指令类型 7 个 + 流水线 3 个）
sim/pipeline5_asm/run_all.sh
```

`<test>` 可以是四位编号或完整 basename，例如：

```bash
sim/pipeline5_asm/run_test.sh 0303
sim/pipeline5_asm/run_test.sh 0303_pipeline5_fwd_redirect
```

## 2. 仿真脚本中的 RTL 文件列表

流水线的 Verilator 编译命令比单周期多了以下文件：

```
rtl/common/pipeline_pkg.sv     # 流水线专用类型（struct、fwd_sel 枚举）
rtl/core/pipe_reg.sv           # 四组流水线寄存器（IF/ID、ID/EX、EX/MEM、MEM/WB）
rtl/core/forwarding_unit.sv    # RAW 数据前递检测
rtl/core/hazard_unit.sv        # load-use stall + redirect flush/kill 控制
rtl/core/core_pipeline5.sv     # 五级流水顶层（代替 core_single_cycle）
```

注意 `core_single_cycle.sv` 不在流水线仿真列表中，改用 `core_pipeline5.sv`。

## 3. 与单周期汇编测试的差异

### 3.1 测试关注点不同

| | 单周期测试 | 流水线测试 |
|--|----------|-----------|
| 测什么 | 指令语义是否正确 | 数据依赖是否正确处理 |
| RAW 怎么处理 | 不涉及（一拍完成） | forwarding + stall 硬件解决 |
| 怎么验证 | 自检：`bne x5, x6, fail` | 累加链：所有场景结果→同一个 reg→减常数→1 |
| nop 的用途 | 收尾填充 | 收尾填充 + 早期测试手工隔离 RAW |

### 3.2 branch/JAL/JALR 已支持

control hazard flush（redirect 时清空 IF/ID、ID/EX）已在 v2.0 实现。branch/JAL/JALR 可在流水线测试中正常使用。

### 3.3 可用的测试文件

| 文件 | 前置条件 | 描述 |
|------|---------|------|
| `0301_pipeline5_nofwd_noredirect.S` | 空壳数据通路 | 手工 3 NOP 隔离 RAW，验证 pipeline 基础通路 |
| `0302_pipeline5_fwd_noredirect.S` | forwarding + load-use stall | 所有 data hazard 由硬件解决，无需 RAW 隔离 NOP |
| `0303_pipeline5_fwd_redirect.S` | forwarding + control hazard | forwarding + redirect 混合：分支操作数前递、load-use 后紧跟分支、JAL/JALR wrong-path kill、JALR bit0 清零 |

## 4. 调试注意事项

- 加新 .sv 文件时，同步加到 `06_run_sim.sh` 的 verilator 命令中。
- 流水线的 commit trace 比单周期晚 4 拍（指令从 IF 走到 WB 需要 5 个周期）。第一条指令在 cycle 5 左右提交，而非单周期的 cycle 1。
- 如果看到非法指令提交，先检查 redirect flush 是否没有正确清掉错误路径指令，或测试程序是否跳到了未初始化 ROM 区域。
- 仿真结束时会打印 `DMEM access range` 和 `Stack max used`。汇编测试通常不初始化 `sp`，所以栈统计可能显示 `SP not initialized to stack top`；DMEM 范围已排除 `TEST_STATUS_ADDR` 的 PASS/FAIL 写入。
