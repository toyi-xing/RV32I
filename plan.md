# 五级流水 RTL 实现计划

当前五级流水线 v2.0 已完成。

当前版本：v2.0 — 完整 data hazard + control hazard。

## v2.0 已完成范围

- 37 条 RV32I 基础指令主路径。
- 五级流水 IF/ID/EX/MEM/WB。
- pipeline register + valid bit。
- 完整数据通路和控制信号随指令流动。
- data hazard：forwarding + load-use stall。
- control hazard：branch/JAL/JALR redirect + wrong-path flush/kill。
- 单周期和五级流水 testbench 均支持 PASS/FAIL、commit trace、DMEM access range 和 stack max used 统计。

当前阶段默认前提仍是：程序只使用已支持的合法指令，访存地址满足访问宽度对齐，不测试非法指令异常、mem 不对齐异常、CSR/trap/interrupt。

## 后续可选方向

以下方向都可以作为下一阶段选择，但当前尚未进入具体规划，也没有排定实现顺序：

- 更系统的验证收口：补更多 C 程序、随机/参考模型、trace 对比、覆盖率或断言。
- 最小 CSR/trap：加入 `mstatus/mtvec/mepc/mcause` 等基础 CSR，支持 `ECALL/EBREAK/MRET`、非法指令和访存不对齐 trap。`优先级最高`
- interrupt：在最小 CSR/trap 基础上加入 timer/software/external interrupt 的入口、屏蔽和返回。`高优先级`
- MMIO/最小 MCU：增加地址译码，把部分 DMEM 地址映射到 GPIO、UART TX、timer 等外设。
- 简单总线或 wait state：从固定 1-cycle imem/dmem 扩展到带 ready/valid 的 memory 或外设访问。
- FPGA 上板：加入 FPGA top wrapper、BRAM 初始化、时钟复位同步和 LED/UART 可观察输出。
- cache/分支预测：加入 I-cache/D-cache 或简单 branch predictor，降低访存和 control hazard 代价。
- M 扩展：加入乘除法和多周期执行单元，并处理对应 structural/data hazard。`中低优先级`

进入任何一个方向前，应先新建对应计划文档或更新本文件，明确目标范围、接口变化、测试方式和不支持项。
