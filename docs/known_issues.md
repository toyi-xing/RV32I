# Known Issues

本文档用于记录已经确认、但暂未修复的问题，避免问题因阶段切换或 `plan.md` 更新而丢失。这里记录问题现象、影响范围、暂缓原因、验证方法和关闭条件；具体阶段的执行步骤仍放在 `plan.md` 中。

问题状态使用以下口径：

- `Open`：问题已经确认，正在但尚未修复。
- `Fixed`：根因已经修复，并完成相应回归验证。
- `Deferred`：问题确认存在，但明确推迟到后续阶段或版本处理。

## RTL-001：MMIO 子字节访问的寄存器偏移解码不一致

| 项目 | 内容 |
| --- | --- |
| 状态 | `Deferred` |
| 发现日期 | 2026-07-13 |
| 影响范围 | 当前主线 RTL、v6.0 UVM DUT 快照 |
| 相关模块 | `rtl/core/mem_stage.sv`、`rtl/soc/data_subsystem.sv`、各 MMIO 外设 |
| 暂缓原因 | 当前先完成 simple bus UVM 基础环境和 word access/wait-state MVP，避免在复现用例建立前直接修改 RTL |
| 预计处理时点 | 0835 `plan.md` 第 13 章 byte enable 和 error 阶段：先补充失败用例稳定复现，再修复主线 RTL并完成回归 |
| 预计修复版本 | 主线修复归属的 release 待定；v6.0 DUT 快照是否同步修复，在问题复现后按快照策略确定 |

### 问题说明

CPU 当前向 simple data bus 输出未经对齐的字节地址，同时根据地址低两位生成 `be`，并将写数据移动到对应 byte lane。例如：

- `SB reg+1`：总线地址为 `reg+1`，`be = 4'b0010`。
- `SH reg+2`：总线地址为 `reg+2`，`be = 4'b1100`。

该语义在 data memory 中可以正常工作：RAM 使用地址的 word index 选择存储字，再使用 `be` 更新对应 byte lane。

当前 GPIO、UART、timer 等 MMIO 外设则直接使用完整的低 12 位地址偏移匹配word-aligned 寄存器地址。因此，访问已定义寄存器内部的非零 byte offset 时，地址无法命中寄存器：

| 访问形式 | 当前结果 |
| --- | --- |
| 对齐的 `LW/SW reg+0` | 正常命中 |
| `LB/SB reg+0` | 可以命中 |
| `LB/SB reg+1`、`reg+2` 或 `reg+3` | 被识别为未知偏移并返回 access fault |
| `LH/SH reg+0` | 可以命中 |
| 对齐的 `LH/SH reg+2` | 被识别为未知偏移并返回 access fault |

这不是一套完整一致的“MMIO 仅支持 word 访问”规则。外设内部已经使用 `be` 控制 byte lane；若请求使用 word-aligned 地址并携带非零 lane 的 `be`，外设可以处理，但 CPU 生成的等价子字节请求却会因地址偏移不匹配而失败。因此，按当前simple data bus 的“字节地址 + byte enable”口径，应将其视为 RTL 问题。

### 当前定向测试未暴露问题的原因

现有定向测试分别覆盖了 data memory 的子字节访问和 MMIO 的 word 访问，但尚未覆盖“已映射 MMIO 寄存器的合法子字节访问”这一交叉场景：

- `sw/asm/0801_dmem_wait_basic.S` 包含 `SB/LB/LBU` 和 `SH/LH/LHU`，但访问对象是 data memory。RAM 会忽略地址低两位进行 word 选择，再由 `be` 选择 byte lane，因此这些测试能够通过。
- 现有 MMIO 汇编测试主要使用 word-aligned 的 `LW/SW` 访问寄存器，没有产生 `reg+1` 或 `reg+2` 形式的合法子字节请求。
- C 测试通过 `mmio_read32`、`mmio_write32` 等 32-bit 接口访问 MMIO，编译后同样是 word-aligned 的 word load/store。
- `sw/asm/0605_mmio_misaligned_priority.S` 验证的是未对齐 `LW/SW` 的异常优先级。这类请求会在 core 内被判定为 misaligned，并在到达 data subsystem 前被抑制，因而不能覆盖已映射 MMIO 寄存器上的合法 byte/halfword 访问。

所以，当前回归通过只能说明 DMEM 子字节语义和 MMIO word 访问语义分别正确，不能说明 MMIO 子字节访问已经正确实现。

### 预期修复方向

优先保留 simple data bus 当前的原始字节地址语义，不在 `mem_stage` 中强制清除地址低两位。建议在 MMIO 寄存器解码处使用 word-aligned 的寄存器偏移进行匹配，再由 `be` 选择有效 byte lane，例如按 `full_offset[11:2]` 识别寄存器。

不建议在 core 侧直接对所有 data address 做 word 对齐，因为这会改变总线地址契约、隐藏原始 byte offset，并限制后续总线或外设扩展。最终修复前仍需结合MMIO 寄存器的只读、只写和 side effect 语义，确认各 byte lane 的合法行为。

### 计划验证方法

本问题暂不打断当前从 `plan.md` 第 3 章开始的 UVM 基础环境搭建。完成基础
agent/env/scoreboard、word access smoke 和 wait-state smoke 后，在第 13 章
byte enable 和 error 阶段重新处理本问题。

届时先补充定向用例，至少覆盖：

- 对可读写 MMIO 寄存器执行 `SB reg+1`，检查对应 byte lane 更新且不报错。
- 对可读写 MMIO 寄存器执行 `SH reg+2`，检查高两个 byte lane 更新且不报错。
- 用 CPU-shaped byte/halfword bus request 读取非零 byte offset，检查 response 的
  `rdata/error`。load 数据选择和符号扩展属于 core `mem_stage`，继续由 SoC directed
  regression 覆盖，不属于本 data_subsystem 级 UVM harness 的职责。
- 检查真正未定义的寄存器 word offset 仍然返回 access fault。
- 在固定延迟和可变延迟配置下重复关键场景，确保修复不破坏 request/response 和 backpressure 语义。

测试应先在当前 DUT 上稳定复现失败，再修复根因，避免仅根据代码推断问题已经被覆盖。

### 关闭条件

满足以下条件后可将状态更新为 `Fixed`：

- 新增测试能够在修复前暴露该问题，并在修复后通过。
- 已映射 MMIO 寄存器的合法 byte/halfword 访问符合约定。
- 未定义 MMIO 寄存器偏移仍能正确返回错误。
- 现有 Verilator C/ASM 定向自检回归全部通过。
- 相关 UVM 定向测试在固定延迟和可变延迟下通过。
- 明确 v6.0 DUT 快照的处理方式：同步修复并记录快照差异，或保留 v6.0 行为并将修复归入后续 release。
