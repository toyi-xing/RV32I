# 0829 综合、FPGA上板与SoC扩展方向

> 文档编号：0829  
> 所属系列：082x RISC-V 最小教学核项目实践  
> 文档定位：说明第一版 RV32I 教学核通过仿真后，如何做可综合性检查、Yosys 综合、FPGA 上板准备，以及向 MCU/SoC 扩展的路线  
> 前置文档：`0820 RISC-V最小教学核设计流程与方案.md`、`0822 最小教学核工程目录、顶层接口与命名约定.md`、`0827 Testbench、commit trace与测试集组织.md`

本文不是要求第一版教学核必须立刻上板或做成 SoC。它的作用是给后续方向一个边界：哪些检查现在就该做，哪些扩展等 core 稳定后再做。

本文默认项目状态：

| 项目 | 状态 |
|---|---|
| RV32I 主线 directed test | 已通过或基本通过 |
| forwarding/load-use/flush | 有专门测试 |
| commit trace | 可用 |
| memory | simple_rom/simple_ram，固定响应 |
| CSR/MMIO/cache/MMU | 第一版未实现 |

## 第1章 仿真通过不等于可综合

### 1.1 需要区分的三件事

| 层次 | 目标 | 常用工具 |
|---|---|---|
| 功能仿真 | 程序跑得对 | Verilator、Icarus |
| 可综合性检查 | RTL 能被综合工具接受 | Yosys |
| FPGA/ASIC 实现 | 映射到真实硬件资源并满足时序 | FPGA toolchain、商业 EDA |

仿真通过只能说明在当前 testbench 和 memory model 下行为正确。综合还会暴露：

- latch。
- 多驱动。
- 不可综合 system task。
- 未约束初值。
- memory 推断问题。
- 组合环。
- 宽度截断。

### 1.2 哪些代码不能进综合主路径

| 内容 | 是否可综合 | 处理建议 |
|---|---|---|
| `core_top`、stage、decoder、ALU、regfile | 应可综合 | 主 RTL |
| simple synchronous RAM | 视写法和目标而定 | FPGA 可推 BRAM，ASIC 需 wrapper |
| `$readmemh` | 仿真可用，FPGA 部分支持初始化 | 用 `ifdef` 或 wrapper 管理 |
| `$display/$finish/$fopen` | 不可综合 | 只放 testbench 或 `ifndef SYNTHESIS` |
| commit trace monitor | 不可综合 | testbench 或 debug-only |
| assertion | 部分工具忽略，部分支持形式 | 用宏控制 |

建议把 testbench 和 debug 输出从 core RTL 中隔离出来。

## 第2章 Yosys 可综合性检查

### 2.1 最小检查脚本

可以写 `sim/yosys/check.ys`：

```tcl
read_verilog -sv rtl/common/core_pkg.sv
read_verilog -sv rtl/core/alu.sv
read_verilog -sv rtl/core/imm_gen.sv
read_verilog -sv rtl/core/decoder.sv
read_verilog -sv rtl/core/regfile.sv
read_verilog -sv rtl/core/if_stage.sv
read_verilog -sv rtl/core/id_stage.sv
read_verilog -sv rtl/core/ex_stage.sv
read_verilog -sv rtl/core/mem_stage.sv
read_verilog -sv rtl/core/wb_stage.sv
read_verilog -sv rtl/core/forwarding_unit.sv
read_verilog -sv rtl/core/hazard_unit.sv
read_verilog -sv rtl/core/core_top.sv

hierarchy -top core_top
proc
check
stat
```

运行：

```bash
yosys -s sim/yosys/check.ys
```

这个脚本只做基本读取、过程转换、结构检查和统计，不代表最终时序收敛。

### 2.2 常见 Yosys 报告怎么看

| 报告/告警 | 常见原因 | 处理 |
|---|---|---|
| latch inferred | `always_comb` 分支没赋默认值 | 补默认赋值 |
| multiple drivers | 同一信号多个 always/assign 驱动 | 统一驱动点 |
| wire has no driver | 忘记连接或拼写错误 | 检查端口和中间信号 |
| width mismatch | 位宽截断/扩展不明确 | 显式 cast 或补位宽 |
| combinational loop | 组合逻辑互相依赖 | 打断反馈，重新整理寄存器边界 |
| memory not mapped | memory 写法不适合目标 | 改成目标工具支持的 RAM 模板 |

早期目标是让 core RTL 至少能被综合工具读懂，并且 `check` 没有严重问题。

## 第3章 FPGA 上板前要改什么

### 3.1 testbench 会被真实硬件替代

仿真阶段：

```text
testbench -> clock/reset
testbench -> $readmemh 初始化 imem
testbench -> 观察 dmem/tohost
```

FPGA 阶段：

```text
板上时钟/PLL -> clock
按键/复位电路 -> reset
block RAM -> imem/dmem
LED/UART/JTAG -> 可观察输出
```

因此上板不是把 testbench 烧进去，而是写一个 FPGA top wrapper。

### 3.2 FPGA top wrapper 需要什么

| 模块 | 作用 |
|---|---|
| clock/reset wrapper | 处理板上时钟、复位同步 |
| imem block RAM | 存程序，可能由 bitstream 初始化 |
| dmem block RAM | 存数据 |
| core_top | CPU 核 |
| 简单输出 | LED、UART 或调试寄存器 |

第一版最简单上板目标可以是：程序运行后把结果写到某个 memory-mapped LED 寄存器，或通过 UART 打印一个字节。但这需要 MMIO，所以通常要先做一个很小的地址译码。

### 3.3 memory 初始化

仿真中 `$readmemh` 很方便。FPGA 中有几种方式：

| 方式 | 说明 |
|---|---|
| bitstream 初始化 BRAM | 程序随 bitstream 固化，适合最早期 |
| UART/JTAG 加载 SRAM | bitstream 固定，程序可运行时加载 |
| bootloader | 先运行小程序，再加载大程序 |
| 外部 flash | FPGA/SoC 启动后从 flash 取程序或搬运程序 |

教学阶段优先用 BRAM 初始化，路径最短。

## 第4章 从教学核到最小 MCU

### 4.1 加 MMIO

要让 CPU 控制 LED、UART、timer，就需要 MMIO。基本思路：

```text
CPU dmem access
    ├── 地址落在 SRAM 区域 -> 访问 data RAM
    └── 地址落在 MMIO 区域 -> 访问外设寄存器
```

推荐 memory map：

| 区域 | 起始地址 | 用途 |
|---|---:|---|
| IMEM | `0x0000_0000` | 程序 |
| SRAM/DMEM | `0x0001_0000` | 数据 |
| MMIO | `0x1000_0000` | timer、UART、GPIO |

MMIO 会让 load/store 不再只是访问 RAM。软件写某个地址，硬件外设状态就改变。

### 4.2 最小外设优先级

| 外设 | 为什么适合先做 |
|---|---|
| GPIO/LED | 最简单，可观察 |
| UART TX | 能打印字符，debug 价值高 |
| timer | 后续中断和 RTOS 需要 |
| UART RX | 需要输入同步和接收状态 |
| SPI/I2C | 协议更多，不适合作为第一个外设 |

第一版 SoC 扩展可以先做 GPIO 或 UART TX。

### 4.3 总线是否一开始就要 AXI/APB

不需要。最小 MCU 阶段可以先做非常简单的内部地址译码：

```text
if addr in DMEM:
    access SRAM
else if addr in UART:
    access UART registers
else:
    return error/default
```

等外设数量增多，再引入 APB/AHB/AXI。总线协议是系统化扩展，不是第一版 core 的启动条件。

## 第5章 CSR、异常和中断扩展

### 5.1 什么时候加 CSR/trap

建议满足这些条件后再加：

| 条件 | 原因 |
|---|---|
| 基础 RV32I directed test 稳定 | 不想把 ISA bug 和 trap bug 混在一起 |
| flush/kill 正确 | 异常也需要 kill younger 指令 |
| commit trace 可用 | precise exception 需要知道哪条指令提交/异常 |
| MMIO 初步可用 | timer interrupt 往往依赖 MMIO timer |

### 5.2 最小 machine mode CSR

后续最小集合可能包括：

| CSR | 作用 |
|---|---|
| `mstatus` | 全局中断使能等状态 |
| `mtvec` | trap handler 入口 |
| `mepc` | 异常/中断返回 PC |
| `mcause` | trap 原因 |
| `mtval` | 附加错误信息 |
| `mie/mip` | 中断使能/挂起 |

这部分对应 `0803`，不是 `0829` 展开的重点。

### 5.3 trap 会影响流水线

trap 不是简单跳转。它要求：

- 记录异常指令 PC。
- 记录原因。
- kill younger 指令。
- 跳到 `mtvec`。
- handler 结束后通过 `mret` 返回。

因此 trap 扩展会复用并强化 `0825` 的 flush/kill 机制。

## 第6章 cache、TLB、MMU 与分支预测

### 6.1 cache 不是第一阶段功能

加 cache 后，memory 不再固定一拍返回：

| 情况 | 流水线影响 |
|---|---|
| I-cache hit | 类似固定取指 |
| I-cache miss | IF 要 stall，等待 refill |
| D-cache hit | load/store 类似固定响应 |
| D-cache miss | MEM 要 stall，向前级 backpressure |

这会引入比第一版复杂得多的 stall 网络。

### 6.2 TLB/MMU 更依赖 OS

MMU 涉及虚拟地址、物理地址、页表、权限和异常。没有 OS 时，MMU 的学习价值有限。建议在理解 `0805` 后再作为独立扩展。

### 6.3 分支预测

第一版假设不预测或默认顺序取指，EX 决策后 flush。后续可以加：

| 预测方式 | 说明 |
|---|---|
| static not-taken | 默认不跳，taken 才 flush |
| static backward taken | 向后跳多半是循环 |
| BTB | 预测 target |
| BHT | 预测 taken/not-taken |

分支预测的难点不是“猜”，而是猜错后的恢复和正确性证明。

## 第7章 后端和时序角度的注意点

### 7.1 教学核常见关键路径

| 路径 | 可能成为关键路径 |
|---|---|
| ID decode | instruction -> 控制信号 |
| GPR read -> forwarding -> ALU | EX 操作数选择和运算 |
| branch compare -> redirect PC | 控制流反馈到 IF |
| load data -> WB mux -> GPR write | 如果 memory 读延迟长 |
| store byte enable | 地址低位、size 到 be/wdata |

第一版不要过早优化频率，但要知道这些路径后续可能影响 Fmax。

### 7.2 综合前 RTL 风格自查

| 检查 | 说明 |
|---|---|
| `always_comb` 有默认值 | 防 latch |
| `always_ff` 只描述寄存器 | 避免混乱 |
| 一个信号一个驱动源 | 防多驱动 |
| reset 策略一致 | 不要有些同步有些异步除非明确 |
| valid gating 完整 | 防 wrong-path 副作用 |
| 参数位宽明确 | 防截断 |
| testbench 代码不进综合 | 防不可综合任务 |

## 第8章 阶段路线建议

| 阶段 | 目标 | 说明 |
|---|---|---|
| S0 | 仿真通过 directed test | `0827` 的基础回归 |
| S1 | Yosys 能读入并 `check` 通过 | 消除明显不可综合问题 |
| S2 | 简单综合统计 | 看 cell 数、寄存器数、memory 推断 |
| S3 | FPGA wrapper | 替换 testbench，接 BRAM/LED/UART |
| S4 | 最小 MMIO | CPU 能写外设寄存器 |
| S5 | 最小 CSR/trap | 支持异常/中断入口 |
| S6 | timer interrupt | 为裸机 runtime/RTOS 做准备 |
| S7 | cache/总线扩展 | 进入更完整 SoC 学习 |

不要在 S0 不稳定时跳 S4/S5。core 主干错时，外设和中断只会放大 debug 难度。

## 第9章 相关文档

| 文档 | 关系 |
|---|---|
| `0803 CSR、异常中断与特权级.md` | CSR/trap/interrupt 扩展前置 |
| `0804 RISC-V SoC、MMIO与外设互联.md` | MMIO、外设、总线扩展前置 |
| `0805 Cache、TLB、MMU、分支预测与内存模型.md` | cache/MMU/分支预测扩展前置 |
| `0822 最小教学核工程目录、顶层接口与命名约定.md` | 上板/SoC wrapper 沿用的接口边界 |
| `0827 Testbench、commit trace与测试集组织.md` | 综合和上板前应先通过的仿真基础 |
| `0828 波形debug、常见bug与定位清单.md` | 综合/上板前定位 core bug |

