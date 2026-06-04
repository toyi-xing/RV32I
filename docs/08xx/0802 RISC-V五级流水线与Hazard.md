# 0802 RISC-V 五级流水线与 Hazard(冒险)

> 文档编号：0802  
> 所属部分：08 处理器架构、RISC-V(第五代精简指令集架构) 与 CPU(中央处理器) 微架构  
> 对应总纲小节：8.2 RISC-V 经典五级流水线、8.3 hazard  
> 主题定位：系统讲解经典 RISC-V 五级流水线的 IF(取指)、ID(译码)、EX(执行)、MEM(访存)、WB(写回) 分工，重点理解 structural hazard(结构冒险)、data hazard(数据冒险)、control hazard(控制冒险)、forwarding(前递/旁路)、stall(停顿)、bubble(气泡)、flush(冲刷) 与 load-use hazard(加载-使用冒险)。  
> 目标岗位：数字 IC(集成电路) 设计、数字 IC 验证、SoC(片上系统) 前端、FPGA(现场可编程门阵列)/ASIC(专用集成电路) RTL(寄存器传输级)、CPU 前端设计、处理器验证、嵌入式处理器相关岗位。  
> 前置知识：建议先阅读 `0801 RISC-V ISA基础.md`；需要理解 register file(寄存器堆)、ALU(算术逻辑单元)、PC(程序计数器)、基础 RV32I/RV64I(32 位/64 位基础整数指令集) 指令语义、组合逻辑和时序逻辑。

---

## 术语首次出现说明

本文档遵循“英文名词或缩写首次出现时给出中文名称”的规则。以下术语在后文会高频出现，后续再次出现时可直接使用英文或缩写。

| 英文术语 | 中文名称 | 英文术语 | 中文名称 | 英文术语 | 中文名称 |
|---|---|---|---|---|---|
| RISC-V | 第五代精简指令集架构 | Hazard | 冒险/相关冲突 | CPU | 中央处理器 |
| IC | 集成电路 | SoC | 片上系统 | FPGA | 现场可编程门阵列 |
| ASIC | 专用集成电路 | RTL | 寄存器传输级 | SystemVerilog | 系统 Verilog |
| ISA | 指令集架构 | RV32I/RV64I | 32 位/64 位基础整数指令集 | RISC | 精简指令集计算机 |
| IF/ID/EX/MEM/WB | 取指/译码/执行/访存/写回 | pipeline | 流水线 | stage | 流水级 |
| pipeline register | 流水线寄存器 | cycle | 时钟周期 | clock period | 时钟周期时间 |
| frequency | 频率 | Fmax | 最高工作频率 | CPI | 每条指令平均周期数 |
| IPC | 每周期执行指令数 | latency | 延迟 | throughput | 吞吐率 |
| critical path | 关键路径 | PPA | 性能、功耗、面积 | STA | 静态时序分析 |
| PC | 程序计数器 | instruction | 指令 | instruction memory | 指令存储器 |
| data memory | 数据存储器 | memory | 存储器/内存 | Harvard architecture | 哈佛结构 |
| von Neumann architecture | 冯诺依曼结构 | register file | 寄存器堆 | GPR | 通用寄存器 |
| x0 | 恒零寄存器 | ALU | 算术逻辑单元 | LSU | 加载存储单元 |
| CSR | 控制状态寄存器 | decoder | 译码器 | immediate generator | 立即数生成器 |
| branch comparator | 分支比较器 | control signal | 控制信号 | datapath | 数据通路 |
| valid bit | 有效位 | valid-ready | 有效-就绪握手 | backpressure | 反压 |
| stall | 停顿 | bubble | 气泡 | flush | 冲刷 |
| kill/squash | 杀除/压掉无效指令 | interlock | 流水线互锁 | replay | 重放 |
| forwarding | 前递/旁路 | bypass | 旁路 | MUX | 多路选择器 |
| structural hazard | 结构冒险 | data hazard | 数据冒险 | control hazard | 控制冒险 |
| RAW/WAR/WAW | 读后写/写后读/写后写相关 | load-use hazard | 加载-使用冒险 | branch hazard | 分支冒险 |
| branch prediction | 分支预测 | branch target | 分支目标地址 | branch resolution | 分支决策完成 |
| BTB | 分支目标缓冲器 | BHT | 分支历史表 | RAS | 返回地址栈 |
| PC redirect | 程序计数器重定向 | wrong-path instruction | 错误路径指令 | mispredict | 预测错误 |
| speculative work | 推测性工作 | side-effect gating | 副作用门控 | target PC | 目标程序计数器 |
| always not taken | 总是不跳转预测 | always taken | 总是跳转预测 | static prediction | 静态预测 |
| dynamic prediction | 动态预测 | write-first/read-first | 先写后读/先读后写寄存器堆语义 | single-port RAM | 单端口随机存储器 |
| dual-port RAM | 双端口随机存储器 | cache | 缓存 | instruction cache | 指令缓存 |
| data cache | 数据缓存 | load/store | 加载/存储 | store data forwarding | 存储数据前递 |
| writeback forwarding | 写回前递 | EX-to-EX forwarding | 执行级到执行级前递 | MEM-to-EX forwarding | 访存级到执行级前递 |
| comparator | 比较器 | priority | 优先级 | opcode | 操作码 |
| rd/rs1/rs2 | 目的/源 1/源 2 寄存器字段 | funct3/funct7 | 3 位/7 位功能码 | immediate | 立即数 |
| hazard detection | 冒险检测 | effective address | 有效地址 | write mask | 写掩码 |
| sign extension/zero extension | 符号扩展/零扩展 | source operand | 源操作数 | destination register | 目的寄存器 |
| branch taken | 分支成立 | branch not taken | 分支不成立 | next PC | 下一条程序计数器 |
| exception | 异常 | interrupt | 中断 | trap | 陷入 |
| precise exception | 精确异常 | commit/retire | 提交/退休 | illegal instruction | 非法指令异常 |
| reset | 复位 | setup/hold | 建立时间/保持时间 | clock gating | 时钟门控 |
| CDC | 跨时钟域 | SVA | SystemVerilog 断言 | UVM | 通用验证方法学 |
| directed test | 定向测试 | random test | 随机测试 | coverage | 覆盖率 |
| scoreboard | 记分板 | reference model | 参考模型 | ISS | 指令集模拟器 |
| DUT | 待测设计 | testbench | 测试平台 | waveform | 波形 |
| trace | 跟踪记录 | bug | 缺陷 | debug | 调试 |
| trade-off | 权衡 | one-hot | 独热编码 | FSM | 有限状态机 |
| parameter | 参数 | logic | SystemVerilog 四态逻辑类型 | always_ff/always_comb | 时序/组合过程块 |
| MDU | 乘除法单元 | cache miss | 缓存未命中 | bus | 总线 |
| data valid | 数据有效 | memory response | 存储响应 | byte enable | 字节使能 |
| byte lane | 字节通道 | store data | 存储写数据 | load value | 加载结果值 |
| ALU result | ALU 结果 | CSR read data | CSR 读取数据 | commit valid | 提交有效信号 |
| instruction address misaligned | 指令地址非对齐异常 | instruction access fault | 指令访问错误异常 | load/store address misaligned | 加载/存储地址非对齐异常 |
| access fault | 访问错误异常 | side effect | 副作用 | debug halt | 调试暂停 |
| trap vector | 陷入入口地址 | reset vector | 复位入口地址 | commit mismatch | 提交不匹配 |
| OS | 操作系统 | bare-metal | 裸机软件 | runtime | 运行时 |
| kernel | 内核 | driver | 驱动程序 | software stack | 软件栈 |
| MMIO | 内存映射输入输出 | memory map | 地址映射 | linker script | 链接脚本 |
| virtual memory | 虚拟内存 | page table | 页表 | page fault | 页故障 |
| RTOS | 实时操作系统 | Unix-like OS | 类 Unix 操作系统 | boot code | 启动代码 |
| FENCE | 存储屏障指令 | store buffer | 存储缓冲 | device memory | 设备内存 |
| ROM | 只读存储器 | SRAM | 静态随机存取存储器 | DRAM | 动态随机存取存储器 |
| flash | 闪存 | I-cache | 指令缓存 | D-cache | 数据缓存 |
| storage controller | 存储控制器 | block device | 块设备 | DMA | 直接存储器访问 |
| PC+4 adder | 程序计数器加 4 加法器 | branch target adder | 分支目标地址加法器 | memory controller | 存储器控制器 |
| JAL/JALR | 跳转并链接/寄存器间接跳转并链接 | link register | 链接寄存器 | unconditional jump | 无条件跳转 |
| M extension | 乘除法扩展 | unified memory | 统一存储器 | memory arbiter | 存储端口仲裁器 |
| privilege level | 特权级 | M/S/U mode | 机器/监管/用户模式 | ECALL | 环境调用指令 |
| MRET/SRET | 机器/监管陷入返回指令 | MMU | 内存管理单元 | TLB | 地址转换后备缓冲 |
| CLINT | 核局部中断控制器 | PLIC | 平台级中断控制器 | atomic instruction | 原子指令 |
| EPC | 异常程序计数器 | cause | 陷入原因 | tval | 陷入附加值 |

---

## 第0章 本专题学习地图

### 0.0 为什么五级流水线是 CPU 面试核心

RISC-V ISA 告诉我们每条指令“最终应该做什么”，五级流水线讨论的是“硬件如何让多条指令重叠执行，并仍然保持 ISA 可见行为正确”。

五级流水线之所以高频，是因为它把数字 IC 的很多基础能力集中在一起：

- 时序切分：如何把长组合路径切成多个 stage。
- 控制优先级：stall、flush、exception、interrupt 谁优先。
- 数据相关：后一条指令需要前一条结果时怎么办。
- 资源冲突：取指和访存是否抢同一个 memory。
- 分支控制：走错路径的指令如何清掉。
- 验证闭环：如何证明流水线内部乱动后，commit 的架构状态仍符合 ISA。

很多候选人会背“五级是 IF、ID、EX、MEM、WB”，但面试官真正想看的是：

```text
你能不能画出相邻指令在不同周期的位置；
能不能说明哪一拍数据可用；
能不能解释 forwarding 为什么有时够、有时不够；
能不能写出 load-use hazard 的检测条件；
能不能说明 branch flush 和 stall 同时发生时怎么定优先级。
```

### 0.1 小节划分与关系

本篇按以下顺序展开：

1. 第1章讲为什么需要 pipeline，以及 latency、throughput、CPI、Fmax 的关系。
2. 第2章讲经典 RISC-V 五级流水线每一级做什么。
3. 第3章讲 pipeline register、valid bit、stall、bubble、flush 的通用控制模型。
4. 第4章总览三类 hazard。
5. 第5章深入 data hazard，重点是 RAW 与 forwarding。
6. 第6章深入 load-use hazard，解释为什么 forwarding 仍然不够。
7. 第7章讲 structural hazard，包括单端口 memory、register file 端口、计算资源复用和多周期执行单元。
8. 第8章讲 control hazard，包括分支决策位置、flush、静态预测和简单动态预测。
9. 第9章讲异常、中断与流水线精确提交的基础。
10. 第10章集中概述系统 OS、裸机运行时和 CPU 流水线的关系，并说明后续 `0803-0805` 会分别展开哪些软件视角。
11. 第11章给出 RTL 控制骨架。
12. 第12章讲验证、断言、coverage 和 reference model。
13. 第13章整理常见 bug、面试问法和练习题。
14. 第14章讲与其他章节的关联。
15. 第15章做本篇总结。

### 0.2 与其他文档的关系

- `0801 RISC-V ISA基础.md` 是本篇前置，所有流水线控制都必须服务于 ISA 语义。
- `030x` 流水线和握手类文档可支撑通用 pipeline 控制。
- `040x` 运算单元文档可支撑 EX 阶段 ALU、乘除法、多周期执行单元。
- `060x` 存储器和 cache 文档可支撑 MEM 阶段和 cache miss。
- `0803 CSR、异常中断与特权级.md` 应继续展开 trap、CSR 和 precise exception。
- `100x` 验证文档可支撑指令随机验证、scoreboard、SVA 和 coverage。
- `130x` STA 文档可支撑 pipeline stage 切分、critical path 和 Fmax 分析。

---

## 第1章 为什么需要流水线

### 1.0 本章概述

流水线的核心目标是提高 throughput，而不一定降低单条指令 latency。它通过在不同 stage 同时处理不同指令，让硬件资源在每个 cycle 尽量忙起来。

### 1.1 单周期、多周期和流水线

假设一条指令需要完成：

```text
取指 -> 译码/读寄存器 -> 执行 -> 访存 -> 写回
```

有三种典型实现：

| 实现 | 特点 | 优点 | 缺点 |
|---|---|---|---|
| 单周期 CPU | 一条指令一个长 cycle 完成所有工作 | 控制简单 | clock period 被最慢指令决定，Fmax 低 |
| 多周期 CPU | 一条指令分多个 cycle 完成，不同指令不重叠 | 复用硬件，面积小 | CPI 高，throughput 低 |
| pipeline CPU | 多条指令重叠执行 | throughput 高，Fmax 可提高 | 控制复杂，有 hazard |

单周期核的关键路径可能是：

```text
PC寄存器 -> instruction memory -> decode -> register file -> ALU -> data memory -> writeback MUX -> register file
```

这个路径太长。五级流水线用 pipeline register 把它切成：

```text
IF | ID | EX | MEM | WB
```

每一级只做一部分工作。

从时序角度看，流水线的收益来自把一个长组合路径拆成若干较短路径。拆分后时钟周期不再由整条指令路径决定，而由最慢的流水级决定：

$$
T_{clk} \ge \max_i(T_{stage,i}) + T_{reg} + T_{skew} + T_{margin}
$$

其中 $T_{stage,i}$ 是第 $i$ 个 stage 的组合延迟，$T_{reg}$ 是 pipeline register 的 clk-to-q、setup 等寄存器开销，$T_{skew}$ 是时钟偏斜，$T_{margin}$ 是工程余量。面试中要注意：pipeline 不是免费加速，切得越细，寄存器开销、flush penalty、控制复杂度和功耗都会增加。

### 1.2 latency 和 throughput

不要把 latency 和 throughput 混淆。

| 概念 | 含义 | 五级流水线中的表现 |
|---|---|---|
| latency | 一条指令从进入到完成经历多久 | 理想情况下约 5 个 cycle |
| throughput | 单位时间完成多少指令 | 理想情况下每 cycle 完成 1 条 |
| CPI | 平均每条指令消耗多少 cycle | 理想流水线接近 1 |
| IPC | 每 cycle 完成多少条指令 | 单发射理想情况下接近 1 |

流水线主要提升 throughput。单条指令从 IF 到 WB 仍然需要多个 cycle。

对理想单发射五级流水线：

$$
\begin{aligned}
latency_{inst} &\approx 5 \times T_{clk} \\
throughput_{ideal} &\approx \frac{1}{T_{clk}} \\
CPI_{ideal} &\approx 1 \\
IPC_{ideal} &\approx 1
\end{aligned}
$$

这和 `0405` 中 MAC pipeline 的 II 思想类似：单个操作的 latency 可能变长，但只要每拍能接收一条新指令，填满后吞吐就高。CPU pipeline 的难点在于指令之间有数据相关、控制流和共享资源，所以真实 II 经常被 stall 和 flush 打断。

### 1.3 理想五级流水线时序

假设没有 hazard，连续指令 `I1` 到 `I5` 的执行可表示为：

```text
cycle:  1   2   3   4   5   6   7   8   9
I1:     IF  ID  EX  MEM WB
I2:         IF  ID  EX  MEM WB
I3:             IF  ID  EX  MEM WB
I4:                 IF  ID  EX  MEM WB
I5:                     IF  ID  EX  MEM WB
```

填满 pipeline 后，每个 cycle 都有一条指令进入 WB。

这张图是理解 throughput 的理想模型：IF 每拍都按顺序 PC 取一条指令，`I1` 这拍在 IF，下一拍进 ID，同时 `I2` 进入 IF。它默认了一个非常强的前提：下一拍要取的 PC 已经确定，而且前面进入流水线的指令都不会改变控制流。

真实 CPU 里这个前提经常不成立。`BEQ`、`BNE`、`JAL`、`JALR`、exception、interrupt 都可能改变 PC。问题在于：IF 为了保持吞吐，不能总是等到所有老指令都完全执行完再取下一条；它通常会先按某种策略取一个“猜测的下一条”。

最简单策略是 always not taken：默认下一条是 `pc + 4`。若一条 `BEQ` 到 EX 阶段才算出 taken 和 branch target，那么在它到 EX 之前，后面的顺序指令已经进入 IF/ID，甚至 ID/EX：

```text
cycle:       1   2   3   4   5
BEQ I0:      IF  ID  EX  MEM WB
I1=pc+4:         IF  ID  EX
I2=pc+8:             IF  ID
target T:                 IF  ID  EX ...
```

如果 `BEQ` 在 cycle 3 的 EX 阶段发现 taken，那么 `I1` 和 `I2` 不是 ISA 语义上应该执行的指令，它们只是为了保持前端不断流而提前取入的 wrong-path instruction(错误路径指令)。正确处理不是让它们继续产生结果，而是在 branch resolution(分支决策完成) 的那一拍做三件事：

1. 产生 PC redirect(程序计数器重定向)，把 PC 改成 branch target。
2. flush 或 kill 比该 branch 更年轻的 wrong-path instruction，例如 IF/ID、ID/EX 中的 `I1`、`I2`。
3. 用 valid/kill 门控所有副作用，保证被 flush 的指令不能写 GPR、写 memory、写 CSR，也不能作为 commit 指令被 scoreboard 看见。

时序上可以理解成：

```text
cycle:       1    2    3             4    5    6
BEQ I0:      IF   ID   EX(taken)     MEM  WB
I1=pc+4:          IF   ID(killed)    --   --
I2=pc+8:               IF(killed)    --   --
target T:                              IF   ID   EX
```

所以“下一条指令已经 IF 了”并不等于“下一条指令已经被 ISA 接受执行了”。在流水线 CPU 中，IF/ID/EX 里的年轻指令有时只是 speculative work(推测性工作)。只有当一条指令有效、没有被 kill，并走到设计定义的 commit/retire 边界，它的寄存器写回、内存写、CSR 更新等副作用才算真正改变架构状态。

这点和 `0405` 中流水 MAC 的反馈问题有相似之处：一旦后级结果会反过来影响前级输入选择，控制逻辑就必须定义“旧路径上已经进入流水线的数据怎么办”。区别是 MAC 数据通路通常处理的是数值反馈和 valid 对齐，而 CPU 控制流处理的是 PC 反馈和错路径副作用取消。CPU 不能只把 target PC 接回 IF，还必须同时 flush 已经按旧 PC 取入的年轻指令。

一个常见面试级回答可以这样说：

```text
五级流水线不是等 branch 完成后才继续取指，而是先按 pc+4 或预测方向取指。
如果后级发现真实 next PC 与前面取指假设不同，就 redirect PC，并 flush younger wrong-path instructions。
所有架构副作用必须由 valid 且未被 kill 的指令产生，因此错路径指令可以进过前几级，但不能 commit。
```

后文第8章会专门展开 control hazard、branch penalty、提前分支决策和 branch prediction。本节先建立关键直觉：理想流水线图说明吞吐，真实流水线还必须有 redirect、flush 和 side-effect gating 才能保持 ISA 正确。

### 1.4 理想 CPI 和实际 CPI

实际 CPI 可粗略理解为：

$$
CPI = 1 + penalty_{stall} + penalty_{branch} + penalty_{memory} + penalty_{exception}
$$

五级流水线性能优化常围绕：

- 减少 data hazard stall。
- 提前 branch resolution。
- 提高 branch prediction 准确率。
- 降低 memory miss 代价。
- 平衡各 stage critical path。

更具体地说，性能不是只看 CPI，也不是只看 Fmax，而是看单位时间提交多少指令。对单发射顺序核可以粗略写成：

$$
Perf \propto \frac{IPC}{T_{clk}} = \frac{1}{CPI \times T_{clk}}
$$

所以一个优化是否值得，要同时看两边：提前 branch resolution 可能降低 $penalty_{branch}$，但如果把比较器、target adder 和 forwarding 都塞进 ID，导致 $T_{clk}$ 变大，最终性能未必提升。这个 trade-off 是五级流水线面试中最常见的深入追问。

### 1.5 三类 Hazard 的先导认识

前面已经看到，理想五级流水线默认每拍都能让一条新指令进入 IF，并让流水线中所有指令自然前进一级。hazard 可以先粗略理解成：**如果还按这个理想节奏推进，结果就可能出错或资源就不够用**。

这里先只建立直觉，不展开检测条件和 RTL 控制。后面第4章会做总览，第5到第8章再分别深入。

| Hazard 类别 | 中文直觉 | 破坏了理想流水线的哪个假设 | 一个最小例子 | 典型处理动作 | 后文位置 |
|---|---|---|---|---|---|
| structural hazard | 硬件资源冲突 | 默认不同 stage 可以同时使用自己需要的硬件 | IF 要取指，同时 MEM 要访存，但只有一个 single-port RAM | 增加资源、仲裁、stall | 第7章 |
| data hazard | 前后指令有数据依赖 | 默认后一条指令读寄存器时，前一条结果已经可用 | `ADD x3, x1, x2` 后紧跟 `SUB x4, x3, x5`，`SUB` 需要新的 `x3` | forwarding、stall、bubble | 第5章、第6章 |
| control hazard | 下一条 PC 不确定 | 默认 IF 每拍取的 `pc + 4` 就是正确路径 | `BEQ` 到 EX 才知道 taken，但后面的顺序指令已经被取入 | predict、redirect、flush/kill | 第8章 |

这三类问题的共同点是：它们都不是 ISA 语义本身，而是“重叠执行”带来的微架构问题。单周期 CPU 通常不会暴露这些流水线 hazard，因为一条指令做完才开始下一条；五级流水线为了提高 throughput，让多条指令同时处在不同 stage，于是必须额外处理资源、数据和 PC 流向之间的冲突。

从控制动作上也可以先有一个分工印象：`stall` (阻塞)多用于“还不能前进，但这条路径仍然是对的”；`flush/kill` 多用于“已经取进来的某些年轻指令不该继续产生副作用”；`forwarding`  (旁路转发)则是“结果还没写回 register file，但可以从后级直接送到前级使用”。这些动作的精确定义会在第3章展开。

---

## 第2章 RISC-V 五级流水线分工

### 2.0 本章概述

经典五级流水线把指令执行分成 IF、ID、EX、MEM、WB。每一级边界不是唯一标准，但下面的划分最常见，也最适合面试讨论。

### 2.1 IF：取指

IF 主要做：

- 使用当前 PC 访问 instruction memory 或 instruction cache。
- 取出 instruction。
- 计算默认 next PC，通常是 `pc + 4`。
- 根据分支预测或重定向选择下一拍 PC。
- 把 `pc`、`inst`、预测信息写入 IF/ID pipeline register。

简化结构：

```text
          +---------+
next_pc ->| PC reg  |---- pc ----+
          +---------+            |
                ^                v
                |        +---------------+
                +--------| next PC MUX   |
                         +---------------+
                                 ^
                                 |
      branch/jump/trap redirect -+
```

### 2.2 ID：译码和读寄存器

ID 可以理解为“把一条 instruction 变成后级能执行的控制包和数据包”。IF 只负责把 `pc` 和 `inst` 取进来；到了 ID，硬件才真正开始回答：这是什么指令、要读哪些寄存器、要不要写回、是否访问 memory、后面能不能继续流动。

| ID 做的事情 | 通常怎么做 | 作用 | 需要注意的点 |
|---|---|---|---|
| 字段解析 | 从 `inst` 中切出 opcode、rd、rs1、rs2、funct3、funct7 | 给 decoder、register file、hazard detection 提供基础输入 | 不同 type 对同一 bit 段的含义不同，例如 I-type 没有 rs2 |
| 主译码 | 用 opcode/funct3/funct7 查 decode table 或进入 `case` 译码 | 生成 `alu_op`、`operand_sel`、`mem_read`、`mem_write`、`wb_sel`、`reg_we`、`branch/jump` 等 control signal | control signal 必须和这条指令一起写入 ID/EX，不能后级重新猜 |
| 读 register file | 用 rs1、rs2 作为读地址读出源操作数，`x0` 读出全 0 | 为 EX 的 ALU、branch comparator、load/store 地址计算准备操作数 | 读出的值不一定就是最终值，后面可能被 forwarding 覆盖 |
| 生成 immediate | immediate generator 按 I/S/B/U/J type 拼接并符号扩展 | 为 ALU 立即数、load/store offset、branch/JAL target 提供操作数 | B/J type 的低位隐含 0，JALR 是 `rs1 + imm_I` 后清 bit 0 |
| 冒险检测 | 比较当前指令源寄存器和流水线中更老指令的目的寄存器，并结合结果是否已经可用 | 决定本拍能不能让 ID 指令进入 EX，或是否需要 stall/bubble | 要区分“可以靠 forwarding 解决”和“必须 stall”等情况 |
| 可选的早期分支判断 | 简单核可把 branch comparator 和 target adder 放在 ID | 提前知道 branch 方向，减少 flush 代价 | 会拉长 ID 关键路径，并让 branch operand forwarding 更复杂 |
| 写入 ID/EX | 把 `pc`、寄存器读值、immediate、rd/rs1/rs2、control signal、valid bit 写入 ID/EX pipeline register | 让下一拍 EX 能处理同一条指令的数据和控制 | stall/flush 时必须按统一控制更新 valid 和控制信号 |

其中 hazard detection 最容易让初学者困惑。它不是“看到寄存器编号相同就停”，而是要判断当前 ID 指令真正需要的源操作数，在下一拍进入 EX 时能不能拿到正确值。

| 检测场景 | 典型判断 | 常见动作 | 为什么 |
|---|---|---|---|
| 当前指令不使用某个源寄存器 | 例如 I-type 算术只使用 rs1，不使用 rs2 | 不因为 `inst[24:20]` 碰巧相等而 stall | 指令格式里的 bit 段不一定都是有效源寄存器 |
| 源寄存器是 `x0` | `rs1 == 0` 或 `rs2 == 0` | 通常不需要 forwarding 或 stall | `x0` 永远读 0，写 `x0` 也不会改变架构状态 |
| 前一条 ALU 指令写当前源寄存器 | ID 源寄存器等于 ID/EX 或 EX/MEM 中老指令的 rd，且老指令会写 GPR | 多数五级流水线允许继续前进，后续在 EX 用 forwarding MUX 选新值 | ALU 结果通常在 EX 末尾已经产生，下一拍可从后级旁路给消费者 |
| 前一条 load 写当前源寄存器 | ID/EX 是 load，rd 等于当前指令实际使用的 rs1/rs2 | 典型处理是 PC 和 IF/ID stall 一拍，同时 ID/EX 插入 bubble | load 数据通常要到 MEM 末尾才回来，下一拍 EX 还拿不到 |
| branch/JALR 的源操作数依赖老指令 | 分支比较或 JALR target 需要的 rs1/rs2 尚未可用 | 根据 branch 在 ID 还是 EX 决策，选择 forwarding 或 stall | 控制流目标不能用旧操作数，否则会跳到错误 PC |
| 后级资源不能接收新指令 | 例如 MEM 因 cache miss 反压，或多周期执行单元 busy | 保持相关 pipeline register，不让 ID 覆盖还没前进的指令 | 防止丢指令、重复执行或控制信号和数据错位 |

ID 阶段的关键风险是组合逻辑容易变长：decode、register file 读、immediate 生成、hazard detection、甚至早期 branch 比较都可能挤在同一拍里。真实项目里常把“功能正确”和“时序可收敛”一起考虑，不是把所有能提前做的事都无条件塞进 ID。

### 2.3 EX：执行和地址计算

EX 主要做：

- ALU 运算。
- branch comparator 或 branch target 计算。
- JAL/JALR target 计算。
- load/store 地址计算。
- forwarding MUX 选择真实操作数。
- 对多周期乘除法，可能启动 M extension 执行单元。

EX 是五级流水线中 data hazard 最集中的 stage，因为多数消费者指令在 EX 需要源操作数。

这里有两个容易忽略的点。第一，EX 使用的操作数通常不是直接来自 ID 读出的 register file 值，而是先经过 forwarding MUX；否则前一两条指令刚算出的结果还没写回，消费者就会读到旧值。第二，branch、JALR、load/store 也都依赖 EX 操作数：branch comparator 要比较真实 rs1/rs2，JALR 要用真实 rs1 算 target，store 既要用 rs1 算地址，也可能需要对 rs2 的 store data 做 forwarding。

### 2.4 MEM：访存

MEM 是 load/store 真正接触数据存储系统的阶段。对不访存的 ALU/JAL/JALR 指令，MEM 通常只是把 EX/MEM pipeline register 中的结果继续传给 MEM/WB；对 load/store，MEM 是 LSU、cache、总线和异常信息交汇的地方。

| MEM 做的事情 | 通常怎么做 | 作用 | 需要注意的点 |
|---|---|---|---|
| 接收 EX 的访存信息 | 从 EX/MEM 取得 effective address、store data、访问大小、load/store 控制、rd、valid bit | 确保访存请求和原指令绑定 | 地址、数据、控制信号必须来自同一条有效指令 |
| 对齐与异常检查 | 根据访问大小检查地址低位，并接收 cache/bus 返回的 access fault | 决定本次 load/store 是否可以正常完成，或是否要进入 trap | misaligned/access fault 不能被后续普通写回覆盖 |
| load 读数据 | 向 data memory/data cache 发出读请求，等待 memory response | 取得原始读数据，供 WB 写回 GPR | 若 cache miss 或总线等待，需要让 pipeline stall 或 backpressure |
| store 写数据 | 根据地址低位、访问大小生成 byte enable/write mask，并把 store data 放到正确 byte lane | 只改写目标 byte/halfword/word，完成 memory 或 MMIO 写副作用 | store 是外部副作用，必须受 valid/kill 门控，不能被 flush 后仍然发出 |
| load 数据整理 | 从返回的数据中选出目标 byte/halfword/word，并按 LB/LBU/LH/LHU/LW 做 sign extension 或 zero extension | 形成最终要写回 rd 的 load value | signed/unsigned load 的区别在这里体现，错了会像 ALU 比较错误 |
| memory stall 控制 | 当 data cache miss、总线未 ready 或外设未响应时，保持 MEM 及其前级状态 | 防止前级覆盖尚未完成的访存指令 | 可变延迟 memory 会把简单五级流水线推向 valid-ready/backpressure 控制 |

如果没有 data cache，而 instruction memory 和 data memory 是同一个单端口 RAM，则 IF 和 MEM 可能出现 structural hazard。

### 2.5 WB：写回

WB 是很多简单顺序五级流水线的寄存器写回和 commit/retire 边界。它的工作看起来比 ID/EX/MEM 简单，但它直接决定软件可见的 GPR 状态，因此 valid、kill、rd 和写使能的门控不能含糊。

| WB 做的事情 | 通常怎么做 | 作用 | 需要注意的点 |
|---|---|---|---|
| 选择写回数据 | 根据 `wb_sel` 从 ALU result、load value、`pc + 4`、CSR read data 中选一路 | 把不同指令类型统一成“写 rd 的值” | `wb_sel` 必须跟随同一条指令从 ID 一路传到 WB |
| 写 register file | 当 `wb_valid && !wb_kill && reg_we && rd != x0` 时写 rd | 更新 GPR，这是最常见的 ISA 可见状态更新 | `rd == x0` 必须抑制写入；被 flush 的指令不能写回 |
| 产生 commit/retire 信息 | 输出 commit valid、pc、inst、rd、写回值、异常信息等 | 供 trace、scoreboard、debug 和性能计数使用 | commit 口看到的必须是有效且未被 kill 的指令 |
| 配合寄存器堆时序 | 设计可能规定同拍 WB 写、ID 读时是 write-first 或 read-first | 影响是否需要额外 writeback forwarding | 这个语义要在 RTL 和验证环境中统一 |
| 处理不写 rd 的指令 | store、branch、部分 system 指令即使到 WB，也可能 `reg_we = 0` | 保持流水线统一推进，同时不改变 GPR | store 的 memory 副作用通常已在 MEM 发生，不能误以为所有副作用都在 WB |

因此，“WB commit”是一个简化但很有用的模型：对大多数写 GPR 的普通指令，WB 是结果变成架构状态的位置；但对 store、trap、CSR 这类有特殊副作用的指令，设计还要明确副作用发生在哪一级，以及它们如何被 valid/kill 和异常优先级约束。

### 2.6 五级流水线寄存器

这里的“寄存器”容易和 `0801` 第 3.4 节的 ABI 寄存器别名混在一起。`IF/ID`、`ID/EX`、`EX/MEM`、`MEM/WB` 不是 `x0-x31`，也不是 `ra/sp/a0` 这类软件能在汇编里直接读写的寄存器；它们是 CPU 内部相邻 stage 之间的时序暂存。

可以把 pipeline register 理解成“每条指令随身带着的一张草稿纸”：上一拍某一级得到的中间信息，在时钟沿被记下来，下一拍交给后一级继续使用。普通组合中间信号只在当前 cycle 内传播，而 pipeline register 会把这些信息跨 cycle 保存下来。

| 对象 | 软件是否可见 | 例子 | 主要作用 |
|---|---|---|---|
| GPR/ABI 寄存器 | 可见 | `x10/a0`、`x1/ra`、`x2/sp` | 指令语义真正读写的架构寄存器，属于 ISA 可见状态 |
| pipeline register | 不可见 | `IF/ID.inst`、`ID/EX.rs1_value`、`EX/MEM.alu_result`、`MEM/WB.rd` | 保存某条指令在流水线中间阶段携带的数据、控制信号和 valid bit |

`IF/ID` 这种名字表示“位于 IF stage 和 ID stage 之间的 pipeline register”。更具体地说，当前 cycle 在 IF 阶段取到的 `PC`、`instruction` 等中间信息，会在时钟沿写入 `IF/ID`；下一 cycle，ID 阶段再从 `IF/ID` 里读取这些信息继续译码。因此，`IF/ID` 不是 IF 里一个寄存器加 ID 里一个寄存器，而是 IF 输出到 ID 输入之间的一组时序暂存寄存器。

同理，`ID/EX` 保存 ID 交给 EX 的信息，`EX/MEM` 保存 EX 交给 MEM 的信息，`MEM/WB` 保存 MEM 交给 WB 的信息。斜杠前后两个名字描述的是它所在的 stage 边界。
因此，`ID/EX.rd = x10` 的意思不是硬件里又多了一个 ABI 寄存器，而是“当前进入 EX 的这条指令，将来如果有效提交，需要把结果写回 `x10`”。同理，`ID/EX.rs1_value` 是 ID 阶段从 register file 读出的源操作数值的暂存副本，不等于 `x11` 这个寄存器本身。

典型 pipeline register：

| 寄存器 | 保存内容 |
|---|---|
| IF/ID | PC、instruction、预测信息、valid bit |
| ID/EX | PC、rs1/rs2 值、rd/rs1/rs2 编号、immediate、控制信号、valid bit |
| EX/MEM | ALU 结果、store 数据、rd、memory 控制、写回控制、valid bit |
| MEM/WB | load 数据、ALU 结果、rd、写回控制、valid bit |

关键思想：

```text
指令往后流动，控制信号也必须跟着同一条指令往后流动。
```

如果控制信号没有和数据对齐，就会出现“上一条指令的数据配上下一条指令的写使能”这类严重 bug。

---

## 第3章 流水线控制基础：valid、stall、bubble、flush

### 3.0 本章概述

五级流水线不是每拍都简单整体前进。遇到 hazard，需要让某些 stage 停住、插入 bubble 或清掉错误路径指令。清楚区分这些动作，是写对控制逻辑的基础。

### 3.1 valid bit

valid bit 表示 pipeline register 中是否有一条有效指令。

为什么需要 valid bit：

- reset 后 pipeline 为空。
- flush 后某些 stage 应变为空。
- stall 时某些 stage 保持原指令。
- exception 或 branch 可能 kill younger instruction。

没有 valid bit 的设计容易把空槽当成真实指令写寄存器或访问 memory。

### 3.2 stall

stall 表示某一级或某段 pipeline 暂停前进，pipeline register 保持原值。

典型原因：

- load-use hazard。
- data cache miss。
- instruction memory 未 ready。
- 多周期乘除法未完成。
- 下游总线 backpressure。

stall 的本质是：

```text
当前 stage 不能接收新输入，前面的 stage 也不能覆盖它保存的旧指令。
```

### 3.3 bubble

bubble 是插入一条“无效指令”或空槽。它向后流动，但不会改变架构状态。

load-use hazard 的典型处理：

- IF/ID 保持不动。
- ID/EX 写入 bubble。
- EX/MEM、MEM/WB 正常前进。

这样消费者指令延后一拍进入 EX，load 数据有机会从 MEM/WB forwarding 到 EX。

### 3.4 flush

flush 表示清掉错误路径或不该继续执行的指令。

典型原因：

- branch prediction 错误。
- JAL/JALR 在 EX 才确认目标。
- exception/trap 发生。
- interrupt 被接收。

flush 和 bubble 的区别：

| 动作 | 目的 | 来源 |
|---|---|---|
| bubble | 为等待数据或资源主动插入空槽 | hazard stall |
| flush | 清除已经进入 pipeline 的错误指令 | 控制流改变或异常 |

### 3.5 valid bit 是流水线安全边界

valid bit 不只是“这个 stage 里有没有指令”的标志，而是副作用是否允许发生的安全边界。流水线中很多信号即使在 bubble 或 flush 后仍然会有某个编码值：`rd` 可能不是 0，`mem_we` 可能因为旧控制信号还保持为 1，`wb_data` 也可能是上一拍的结果。如果没有 valid 统一门控，这些残留值就可能错误写寄存器或 memory。

工程上可以把每一级动作分成三类：

| 动作 | 例子 | 是否必须受 valid/kill 门控 |
|---|---|---|
| 纯组合计算 | ALU 输出、branch compare、next PC 候选 | 可以计算，但不能直接产生架构副作用 |
| pipeline 状态更新 | IF/ID、ID/EX、EX/MEM、MEM/WB 写入 | 必须按 stall/flush 规则更新 valid |
| 架构或外部副作用 | GPR 写回、data memory 写、CSR 更新、trap 接受 | 必须由 valid 且未 kill 的指令触发 |

典型原则是：

$$
side\_effect\_en = stage\_valid \land \lnot stage\_kill \land op\_en
$$

这条公式在 RTL 中会落成类似：

```systemverilog
assign rf_we_o   = wb_valid_q  && !wb_kill_q  && wb_reg_we_q && (wb_rd_q != 5'd0);
assign dmem_we_o = mem_valid_q && !mem_kill_q && mem_mem_we_q;
```

面试回答 stall/flush 时，如果只说“清一下流水线寄存器”还不够。更完整的回答要说明：flush 后 wrong-path instruction 即使控制信号残留，也不能 commit；exception redirect 后 younger instruction 不能写 GPR、写 memory 或更新 CSR。

### 3.6 stall 与 flush 的优先级

常见原则：

```text
更年轻的错误路径指令必须被 flush；
持有正确老指令的 stage 不能被错误覆盖；
exception/trap redirect 通常优先级高于普通 branch redirect；
reset 优先级最高。
```

一种常见优先级：

```text
reset > exception/trap flush > branch/jump flush > load-use stall > normal advance
```

但实际设计要结合 stage 位置决定。例如 EX 阶段 branch flush 和 ID 阶段 load-use stall 同时出现时，通常要优先处理 branch redirect，并 kill 错路径 younger instruction。

### 3.7 pipeline register 更新模型

一个带 valid/stall/flush 的 pipeline register 可抽象为：

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    id_ex_valid_q <= 1'b0;
    id_ex_q       <= '0;
  end else if (flush_id_ex) begin
    id_ex_valid_q <= 1'b0;
    id_ex_q       <= '0;
  end else if (stall_id_ex) begin
    id_ex_valid_q <= id_ex_valid_q;
    id_ex_q       <= id_ex_q;
  end else begin
    id_ex_valid_q <= if_id_valid_q;
    id_ex_q       <= id_ex_d;
  end
end
```

真实设计中如果 `stall_id_ex` 为真，通常没有必要写自赋值；这里写出来是为了说明行为。

---

## 第4章 Hazard 总览

### 4.0 本章概述

hazard 是 pipeline 中“下一拍按理想方式推进会出错”的情况。经典分类为 structural、data、control。

### 4.1 structural hazard (结构冒险)

structural hazard 来自硬件资源冲突。

例子：

- IF 和 MEM 同时访问同一个 single-port RAM。
- register file 读写端口数量不足。
- ALU 被普通指令和地址计算同时需要。
- 乘除法单元正在忙，下一条 M extension 指令无法进入。

解决方法：

- 增加资源，例如分离 instruction memory 和 data memory。
- 增加端口，例如 2 读 1 写 register file。
- 仲裁和 stall。
- pipeline 化共享资源。

### 4.2 data hazard (数据冒险)

data hazard 来自指令之间的数据依赖。

最重要的是 RAW：

```text
I1: ADD x3, x1, x2
I2: SUB x4, x3, x5
```

I2 读 x3，I1 写 x3。如果 I2 在 I1 写回前就读取旧 x3，就会错。

data hazard 里最常见的是“前一条指令产生结果，后一条指令马上使用结果”。但不同 producer 的结果产生时间不同，所以处理方式也不同：

| 典型相关 | 示例 | 为什么会有 hazard | 总览层面的处理 |
|---|---|---|---|
| ALU-ALU 相关 | `ADD x3, x1, x2` 后接 `SUB x4, x3, x5` | `ADD` 的 ALU 结果在 EX 末尾已经产生，但还没写回 register file | 通常用 forwarding 从后级直接送到下一条指令的 EX 输入 |
| Load-Use 相关 | `LW x3, 0(x1)` 后接 `ADD x4, x3, x5` | load 的数据要等 MEM 访存后才返回，紧邻指令到 EX 时数据通常还没准备好 | forwarding 还不够，通常要 stall 一拍并插入 bubble |

因此，Load-Use Hazard 不是独立于 data hazard 的第四类 hazard，而是 RAW data hazard 中最典型、也最容易考察的特殊情况。第5章先讲数据已经产生时如何 forwarding；第6章再专门讲 load 数据尚未产生时为什么必须 interlock。

解决方法：

- forwarding/bypass。
- stall 插入 bubble。
- 编译器插入独立指令。
- 乱序核用 register renaming 和调度解决更多相关。

### 4.3 control hazard (控制冒险)

control hazard 来自下一条 PC 不确定。

例子：

```text
BEQ x1, x2, target
```

在 branch 条件计算完成前，IF 不知道下一条应取：

- 顺序地址 `pc + 4`。
- branch target。

解决方法：

- stall 等待 branch resolution。
- 默认预测 not taken。
- branch prediction。
- 提前在 ID 阶段比较。
- flush 错路径指令。

### 4.4 hazard 与 ISA 的关系

hazard 是微架构问题，不是 ISA 语义本身。

ISA 只要求：

```text
程序按指令语义执行，最终架构状态正确。
```

pipeline 必须通过 stall、forwarding、flush 等机制，让重叠执行不改变这个结果。

---

## 第5章 Data Hazard 与 Forwarding (旁路转发)

### 5.0 本章概述

简单顺序五级流水线中，最常见 data hazard 是 RAW (Read After Write)。WAR 和 WAW 在严格按序读寄存器、按序写回的五级流水线中通常不会发生，但在乱序或多写回端口设计中会出现。

### 5.1 RAW、WAR、WAW

| 类型 | 含义 | 简单五级顺序流水线是否常见 |
|---|---|---|
| RAW | 后一条读前一条将要写的数据 | 常见，必须处理 |
| WAR | 后一条写前一条还没读的数据 | 通常不出现，因为读在 ID，写在 WB，顺序流动 |
| WAW | 后一条写前一条还没写的数据 | 通常不出现，因为写回顺序和指令顺序一致 |

例子：

```text
ADD x5, x1, x2
SUB x6, x5, x3
```

SUB 在 EX 阶段需要 x5，但 ADD 的结果还没有写回 register file。

### 5.2 为什么 register file 写回太晚

无 forwarding 时，时序如下：

```text
cycle:  1   2   3   4   5   6
ADD:    IF  ID  EX  MEM WB
SUB:        IF  ID  EX  MEM WB
```

SUB 在 cycle 3 的 ID 读 register file，此时 ADD 要到 cycle 5 才 WB，SUB 读到旧 x5。

如果只靠 stall，要等 ADD 写回后 SUB 再读：

```text
cycle:  1   2   3   4   5   6   7   8
ADD:    IF  ID  EX  MEM WB
SUB:        IF  ID  ID  ID  EX  MEM WB
```

这会浪费多个 cycle。forwarding 的目的就是减少 stall。

### 5.3 forwarding 的基本思想

forwarding 不等结果写回 register file，而是从后面 stage 直接把结果送到前面需要它的 EX 输入。

更准确地说，forwarding 解决的是“数据已经在某个流水级产生，但还没有写回架构寄存器”的时序窗口。它不是按指令名字前递，而是按 producer 的结果可用时间和 consumer 的操作数需要时间来决定。

典型路径：

```text
EX/MEM.alu_result  ----+
                       |
MEM/WB.wb_data     ----+--> operand MUX --> ALU input
                       |
ID/EX.rs_value     ----+
```

常见 forwarding 来源：

| 来源 | 目标 | 用途 |
|---|---|---|
| EX/MEM -> EX | 下一条指令需要上一条 ALU 结果 | ALU-ALU 相关 |
| MEM/WB -> EX | 隔一条指令需要结果，或 load 数据已到 WB | ALU/load 结果前递 |
| MEM/WB -> ID | 某些 register file 读写语义下辅助读新值 | 依设计而定 |
| EX/MEM 或 MEM/WB -> store data | store 的 rs2 数据来自前面指令 | store data forwarding |

| producer 类型 | 结果何时可用 | 紧邻 consumer 能否只靠 forwarding | 说明 |
|---|---|---|---|
| ALU 指令 | EX 末尾，进入 EX/MEM 后可用 | 通常可以 | 下一拍 consumer 在 EX，从 EX/MEM 取数 |
| LUI/AUIPC/JAL | 依实现，常在 EX 或更早形成写回值 | 通常可以 | 关键是 forward data 必须选对 `wb_sel` |
| load 命中一拍 memory | MEM 末尾，进入 MEM/WB 后可用 | 通常不可以 | 紧邻 consumer 同拍 EX 太早，需要 bubble |
| 多周期乘除法 | done 时才可用 | 取决于 interlock/scoreboard | 未 done 前不能前递 |
| CSR (控制状态寄存器)读写 | CSR read stage 结束后 | 取决于放在哪一级 | 还要处理异常和特权检查 |

因此，forwarding 单元不能只看 `rd == rs1/rs2`。它还要知道该 producer 的数据在当前 cycle 是否已经可用。把 load 的 EX/MEM 地址计算结果误当前递数据，是 load-use bug 的典型来源。

### 5.4 ALU-ALU forwarding 示例

```text
I1: ADD x5, x1, x2
I2: SUB x6, x5, x3
```

时序：

```text
cycle:  1   2   3   4   5   6
I1:     IF  ID  EX  MEM WB
I2:         IF  ID  EX  MEM WB
```

在 cycle 4：

- I1 位于 MEM，ALU 结果保存在 EX/MEM。
- I2 位于 EX，需要 x5。
- forwarding MUX 选择 EX/MEM.alu_result 给 I2 的 ALU 输入。

这样不需要 stall。

### 5.5 forwarding 检测条件

以 EX 阶段源操作数 A 为例：

```text
如果 EX/MEM 阶段指令有效，并且会写 rd，并且 rd != x0，并且 rd == ID/EX.rs1，
则 operand A 从 EX/MEM forwarding。

否则，如果 MEM/WB 阶段指令有效，并且会写 rd，并且 rd != x0，并且 rd == ID/EX.rs1，
则 operand A 从 MEM/WB forwarding。

否则 operand A 使用 ID/EX 中保存的 register file 读值。
```

EX/MEM 优先于 MEM/WB，因为它代表更年轻、更接近消费者的写入。

### 5.6 forwarding 控制示例

```systemverilog
typedef enum logic [1:0] {
  FWD_REG,                                                            // 使用 ID/EX 中已经保存的 register file 读值
  FWD_EX_MEM,                                                         // 从 EX/MEM 旁路，通常是上一条 ALU 指令刚算出的结果
  FWD_MEM_WB                                                          // 从 MEM/WB 旁路，通常是更老一拍的 ALU/load/writeback 数据
} fwd_sel_e;

always_comb begin
  fwd_a_sel_o = FWD_REG;                                              // 默认不前递，operand A 直接用 ID/EX.rs1_value
  fwd_b_sel_o = FWD_REG;                                              // 默认不前递，operand B 直接用 ID/EX.rs2_value

  if (ex_mem_valid_i && ex_mem_reg_we_i &&                            // EX/MEM 中有有效 producer，且它会写 GPR
      (ex_mem_rd_i != 5'd0) && (ex_mem_rd_i == id_ex_rs1_i)) begin    // producer.rd 命中当前 EX 消费者的 rs1，且 rd 不是 x0
    fwd_a_sel_o = FWD_EX_MEM;                                         // 选择最近的 EX/MEM 结果，优先级高于 MEM/WB
  end else if (mem_wb_valid_i && mem_wb_reg_we_i &&                   // 若 EX/MEM 未命中，再检查 MEM/WB 中更老的 producer
      (mem_wb_rd_i != 5'd0) && (mem_wb_rd_i == id_ex_rs1_i)) begin    // producer.rd 命中 rs1，且 rd 不是 x0
    fwd_a_sel_o = FWD_MEM_WB;                                         // 选择 MEM/WB 写回数据作为 operand A
  end

  if (ex_mem_valid_i && ex_mem_reg_we_i &&                            // operand B 的判断逻辑与 operand A 相同
      (ex_mem_rd_i != 5'd0) && (ex_mem_rd_i == id_ex_rs2_i)) begin    // producer.rd 命中当前 EX 消费者的 rs2
    fwd_b_sel_o = FWD_EX_MEM;                                         // store data 或 ALU operand B 都可能需要这一路
  end else if (mem_wb_valid_i && mem_wb_reg_we_i &&                   // EX/MEM 未命中时，继续检查 MEM/WB
      (mem_wb_rd_i != 5'd0) && (mem_wb_rd_i == id_ex_rs2_i)) begin    // producer.rd 命中 rs2，且 rd 不是 x0
    fwd_b_sel_o = FWD_MEM_WB;                                         // 选择 MEM/WB 写回数据作为 operand B
  end
end
```

注意：

- x0 不需要 forwarding。
- 对 load 指令，EX/MEM 阶段可能还没有真正 load data，不能把地址计算结果当成 load 结果前递给 ALU。
- forwarding 数据源必须根据写回选择产生，例如 ALU 结果、load 数据、PC+4、CSR 数据。

### 5.7 store data forwarding

store data forwarding 指的是：**store 指令要写入 memory 的数据来自前面某条还没写回 register file 的指令时，硬件要把这个新数据旁路给 store，而不能让 store 写入旧值**。

store 指令有两个源寄存器，但它们的用途不同：

| 源寄存器 | 在 store 中的作用 | 典型使用阶段 | 是否需要 forwarding |
|---|---|---|---|
| `rs1` | base address，用来和 immediate 相加形成 effective address | EX | 需要普通 ALU operand forwarding |
| `rs2` | store data，也就是要写进 memory 的数据 | 通常在 MEM 真正写出 | 需要 store data forwarding |

所以 store 的 forwarding 不能只看“ALU 两个输入”。`rs1` 影响写到哪里，`rs2` 影响写什么值；二者任何一个用旧值都会出错。

例子：

```text
ADD x5, x1, x2
SW  x5, 0(x10)
```

第二条 `SW` 的含义是：

```text
memory[x10 + 0] = x5
```

这里 `x10` 是地址基址，`x5` 是要写入 memory 的数据。`ADD` 刚产生新的 `x5`，但这个结果可能还没有写回 register file；如果 `SW` 直接使用 ID 阶段读出的旧 `x5`，memory 中就会被写入错误数据。

如果 x5 是 store data：

- 可以在 EX 阶段把前递后的 `rs2` 选好，写入 `EX/MEM.store_data`，再一路带到 MEM。
- 也可以让 `SW` 到 MEM 阶段时，再专门比较它的 `rs2` 和后级 producer 的 `rd`，命中后把最新数据送到 data memory 写端口。

两种做法都可以，关键是项目里要定义清楚 store data 在哪一级最终确定，并让 hazard/forwarding 单元和这个时序一致。

容易漏测的是：

```text
LW  x5, 0(x1)
SW  x5, 4(x2)
```

这组指令比 `ADD -> SW` 更容易出 bug。`LW` 的数据通常到 MEM 末尾或 MEM/WB 才有效，而紧跟的 `SW` 要把这个 load 出来的新 `x5` 写到另一个地址。如果设计只做了 EX/MEM 到 EX 的 ALU forwarding，却没有覆盖 store data 路径，`SW` 可能会把旧 `x5` 写进 memory。

验证时建议至少覆盖三类情况：

| 序列 | 检查点 |
|---|---|
| `ADD rd,...` 后紧跟 `SW rd, offset(base)` | ALU 结果能作为 store data 写出 |
| `LW rd,...` 后紧跟或隔一条 `SW rd, offset(base)` | load data 能作为 store data 写出，必要时插入 stall |
| `SW rs2, offset(rd)` 且前一条写 `rd` | store address 的 base forwarding 也正确 |

### 5.8 register file (寄存器堆)写读语义

有些 register file 支持同一 cycle 对同一地址先写后读，ID 阶段可以读到 WB 正在写的数据；有些则读到旧值。

两种语义：

| 语义 | 同 cycle 写 rd、读 rs 命中时读到 |
|---|---|
| write-first | 新写入数据 |
| read-first | 旧数据 |

如果设计依赖 write-first，必须确保：

- 目标工艺或 FPGA 原语支持该行为。
- 仿真模型和综合后行为一致。
- 验证中覆盖 WB 与 ID 同址读写。

更稳妥的做法是把 WB forwarding 显式建模，不隐含依赖不清楚的 memory macro 语义。

---

## 第6章 Load-Use Hazard

### 6.0 本章概述

第4章已经把 Load-Use Hazard 放在 data hazard 里做了总览：它本质上仍然是 RAW 相关，只是 producer 是 load 指令，结果要到 MEM 阶段访存后才真正可用。

load-use hazard 是五级流水线最经典的面试题。它说明 forwarding 不是万能的：如果数据本身还没从 memory 返回，就没有东西可以前递。

可以把 ALU 指令和 load 指令先粗略区分成两种 producer：

| producer | EX 阶段做什么 | 结果大约什么时候可用 | 紧邻下一条指令能否直接用 |
|---|---|---|---|
| `ADD/SUB/AND` 等 ALU 指令 | 用组合逻辑算出结果 | EX 末尾已经得到 ALU result，下一拍可从 EX/MEM 前递 | 通常可以 |
| `LW/LH/LB` 等 load 指令 | 先用 ALU 算出访存地址 | 真正要写回的 load data 要等 MEM 访问 memory 后才返回 | 通常不可以，需要 stall |

也就是说，`LW x5, 0(x1)` 的 EX 阶段只是在算地址 `x1 + 0`，这时还没有读到 memory 里的数据。紧跟着的 `ADD x6, x5, x2` 到 EX 阶段时，ALU 输入需要的是 `x5` 的 load data，而不是 load 的地址计算结果。由于这份 data 通常要到同一个 cycle 的 MEM 末尾才有效，已经晚于 `ADD` 在 EX 前半段选择操作数的时间，所以不能像普通 ALU-ALU 相关那样直接前递。

### 6.1 典型例子

```text
LW  x5, 0(x1)
ADD x6, x5, x2
```

时序：

```text
cycle:  1   2   3   4   5   6
LW:     IF  ID  EX  MEM WB
ADD:        IF  ID  EX  MEM WB
```

在 cycle 4：

- LW 在 MEM，load data 通常到 cycle 4 末尾才有效。
- ADD 在 EX，cycle 4 中就需要操作数 x5。

因此无法在同一个 cycle 早些时候把还没产生的 load data 送给 ADD 的 ALU。需要 stall 一拍。

### 6.2 插入 bubble 后的时序

```text
cycle:  1   2   3   4   5   6   7
LW:     IF  ID  EX  MEM WB
ADD:        IF  ID  ID  EX  MEM WB
bubble:             EX
```

控制动作：

- PC 保持不变。
- IF/ID 保持不变，让 ADD 停在 ID。
- ID/EX 写入 bubble。
- LW 继续从 EX 进入 MEM，再进入 WB。
- 下一拍 ADD 进入 EX，从 MEM/WB forwarding 获得 load data。

### 6.3 检测条件

典型 load-use 检测：

```text
ID/EX 阶段是 load，且会写 rd；
IF/ID 阶段指令有效；
IF/ID.rs1 或 IF/ID.rs2 需要读取该 rd；
rd != x0；
则 stall。
```

注意“需要读取”很重要。不是所有指令字段 `[24:20]` 都表示 rs2。例如 I-type 指令没有 rs2。误判会造成多余 stall，漏判会造成功能错误。

### 6.4 RTL 示例

```systemverilog
always_comb begin
  load_use_stall_o = 1'b0;                                             // 默认不 stall，只有确认 load-use 相关时才拉高

  if (id_ex_valid_i && id_ex_is_load_i && id_ex_reg_we_i &&            // ID/EX 中有有效 load producer，且它会写 GPR
      (id_ex_rd_i != 5'd0) && if_id_valid_i) begin                     // producer.rd 不是 x0，且 IF/ID 中有有效 consumer
    if ((if_id_uses_rs1_i && (if_id_rs1_i == id_ex_rd_i)) ||           // consumer 确实使用 rs1，且 rs1 命中 load 的 rd
        (if_id_uses_rs2_i && (if_id_rs2_i == id_ex_rd_i))) begin       // consumer 确实使用 rs2，且 rs2 命中 load 的 rd
      load_use_stall_o = 1'b1;                                         // load data 还没从 MEM 返回，必须插入 bubble 等一拍
    end
  end
end
```

配套控制：

```text
load_use_stall:
  pc_write      = 0
  if_id_write   = 0
  id_ex_flush   = 1   // 插入 bubble
  ex_mem_write  = 1   // 后级继续推进
  mem_wb_write  = 1   // 后级继续推进
```

这里要区分“检测信号”和“流水线动作”。`load_use_stall_o` 只是说明控制单元发现了 load-use hazard；真正改变流水线状态的是 `pc_write`、`if_id_write`、`id_ex_flush` 这些控制信号。

和 6.2 的控制动作对照如下：

| 控制信号 | 取值 | 对应 6.2 的动作 | 为什么这么做 |
|---|---:|---|---|
| `pc_write` | `0` | PC 保持不变 | 不让 IF 继续取走新的顺序指令，否则前端会越过当前等待的 consumer |
| `if_id_write` | `0` | IF/ID 保持不变，让 `ADD` 停在 ID | consumer 还不能进入 EX，因为它需要的 load data 尚未返回 |
| `id_ex_flush` | `1` | ID/EX 写入 bubble | 在 EX 阶段插入一个空槽，让前面的 `LW` 能继续进入 MEM，同时不让 `ADD` 错误进入 EX |
| `ex_mem_write` | `1` | `LW` 继续从 EX 进入 MEM | producer 必须继续前进到 MEM，才能真正访问 memory 并拿到 load data |
| `mem_wb_write` | `1` | MEM 结果继续进入 WB | load data 返回后要进入 MEM/WB，下一拍才能作为 forwarding 来源 |

所以 load-use stall 的动作不是“整条流水线全部冻结”。更准确地说，它是**冻结 PC 和 IF/ID，向 ID/EX 插入 bubble，同时让 EX/MEM 和 MEM/WB 正常推进**：load 指令继续向 MEM 前进，consumer 指令留在 ID 等一拍。

“下一拍 `ADD` 进入 EX，从 MEM/WB forwarding 获得 load data”对应的是 stall 解除后的正常推进和 forwarding 选择：

```text
next cycle after bubble:
  pc_write      = 1
  if_id_write   = 1
  id_ex_flush   = 0
  fwd_a_sel_o / fwd_b_sel_o = FWD_MEM_WB   // 如果 ADD 的 rs1/rs2 命中 MEM/WB.rd
```

也就是说，load-use interlock 只负责把 consumer 延后一拍；真正把 load data 送到 `ADD` ALU 输入的，是第5章讲过的 MEM/WB -> EX forwarding。

### 6.5 load-use 的变体

需要覆盖的序列：

```text
LW  x5, 0(x1)
ADD x6, x5, x2       // rs1 相关

LW  x5, 0(x1)
ADD x6, x2, x5       // rs2 相关

LW  x5, 0(x1)
SW  x5, 0(x2)        // store data 相关

LW  x5, 0(x1)
BEQ x5, x0, label    // branch compare 相关，取决于分支在哪一级比较

LW  x0, 0(x1)
ADD x6, x0, x2       // 不应 stall，因为 x0 恒为 0
```

### 6.6 如果 memory 延迟不固定

前面假设 data memory 一拍返回。如果 data cache miss 或总线等待导致 load 延迟不固定，则简单“一拍 bubble”不够。

需要：

- MEM 阶段保持 load 指令直到 data valid。
- 后续 stage 不能错误前进。
- 前面 stage 可能 backpressure。
- load data 到达后再允许依赖指令继续。

这时 pipeline 更接近 valid-ready 控制，而不是固定五级每拍推进。

固定一拍 memory 和可变延迟 memory 的控制差异可以这样看：

| memory 模型 | load 数据返回 | load-use 处理 | 控制核心 |
|---|---|---|---|
| 一拍同步 SRAM | MEM 末尾固定返回 | 固定插入 1 个 bubble | 简单 interlock |
| cache hit/miss | hit 一拍，miss 多拍 | hit 后可继续，miss 期间全局或局部 stall | data valid + backpressure |
| 总线外设/MMIO | 延迟不可预测 | load/store 请求保持到 response | valid-ready 或 request/response 状态机 |

如果 MEM stage 因 cache miss 停住，不能只停住 MEM 自己。后面的 WB 可能还能接收已有结果，前面的 EX/ID/IF 也必须按设计 backpressure，否则会出现三类严重问题：

- 同一条 load 被覆盖，response 回来后找不到对应指令。
- 年轻指令越过未完成 load 提交，破坏顺序核的精确异常模型。
- store 在 miss 或 flush 期间重复发起，造成外设副作用重复。

因此，真实项目常会把 `mem_stall` 纳入统一 pipeline enable/flush 逻辑，而不是把 load-use interlock 当成唯一 stall 来源。验证上要覆盖 miss 持续 0、1、多拍，并检查 PC、IF/ID、ID/EX 的保持关系。

---

## 第7章 Structural Hazard

### 7.0 本章概述

structural hazard 不是“后面的指令需要前面的结果”，而是“同一个 cycle 里，有多个流水级想用同一个硬件资源，但这个资源同一拍服务不了这么多请求”。可以用一个很朴素的判断式理解：

$$
\text{某资源在本 cycle 的需求次数} > \text{该资源本 cycle 能服务的次数}
$$

在理想五级流水线里，同一个 cycle 不是只有一条指令在动，而是可能同时有五条不同指令分别位于 IF、ID、EX、MEM、WB：

| 流水级 | 这一拍通常需要的硬件资源 | 如果资源不够会怎样 |
|---|---|---|
| IF | PC 寄存器、PC+4 加法器、取指访问路径 | 取不到下一条 instruction，前端 stall |
| ID | decoder、immediate generator、register file 读端口 | 源操作数读不全，ID 不能推进 |
| EX | ALU、branch comparator、地址/目标地址计算资源 | 当前指令不能完成执行计算 |
| MEM | data memory、D-cache、总线或 MMIO 访问路径 | load/store 不能完成访存 |
| WB | register file 写端口 | rd 不能在本拍写回 |

所以，structural hazard 的学习重点不是“背有哪些资源冲突”，而是看懂：**五级流水线之所以能每拍推进，是因为硬件资源被设计成足够并行**。入门模型经常直接假设这些资源已经分开，因此很多 structural hazard 平时看不到；但面试里常会追问“为什么 instruction memory 和 data memory 要分离”“为什么 GPR 要 2 读 1 写”“为什么 PC+4 不一定复用主 ALU”，问的就是这些假设背后的硬件原因。

### 7.1 instruction memory 与 data memory 冲突

这里的 `instruction memory` 和 `data memory` 沿用的是流水线视角，分别表示 IF 阶段的取指访问路径和 MEM 阶段的 load/store 访问路径。它们不一定对应真实 SoC 里两块独立的物理 RAM：instruction 可能来自 boot ROM、flash、SRAM、I-cache 或总线；data 可能来自 SRAM、D-cache、DRAM、MMIO 外设，甚至由 storage controller 把 block device 中的数据搬到 DRAM 后再被 CPU 读取。`0801` 第7章已经先建立了这张直觉地图，本节只关心这些访问路径在同一个 cycle 会不会抢同一个硬件端口。

这是初学五级流水线时最值得先理解的 structural hazard。假设 IF 和 MEM 共用一个 single-port RAM：

```text
cycle N:
  I4 位于 IF   ：需要取下一条 instruction
  I1 位于 MEM  ：需要执行 load/store
```

single-port RAM 同一拍只能做一次读或写。现在 IF 想读 instruction，MEM 也想访问 data，两者同时访问同一个端口，就冲突。

这不是 data hazard，因为两条指令不一定有数据依赖；也不是 control hazard，因为 PC 不一定跳错。它单纯是硬件端口不够。

| 解决方法 | 硬件含义 | 对初学五级流水线的意义 |
|---|---|---|
| 使用 Harvard architecture | 取指和访存走两套访问路径 | 教科书五级流水线最常用的假设 |
| 使用 dual-port RAM | 同一个存储体提供两个端口 | 面积、时序和存储宏选择会更复杂 |
| MEM 访问时让 IF stall | 资源只有一个，优先保证 load/store | 硬件简单，但 CPI 变差 |
| 引入 instruction cache 和 data cache | 前端访问 I-cache，访存访问 D-cache | 更接近真实处理器，但 cache miss 后仍可能产生 backpressure |

如果选择“MEM 访问时让 IF stall”，控制动作要说清楚是“只停前端取指”，不是把整条流水线都冻结。一个常见保守做法是：PC 保持不变，IF/ID 不接收新指令，并在前端插入一个空槽；后面的 ID/EX、EX/MEM、MEM/WB 继续正常推进。

```text
当 MEM stage 正在占用统一 memory 端口：
  pc_write       = 0   // PC 保持，下一拍仍从同一个 PC 重新尝试取指
  if_id_bubble   = 1   // IF 没有取到新 instruction，IF/ID 写入空槽
  downstream_en  = 1   // ID/EX、EX/MEM、MEM/WB 继续推进，让 MEM 尽快释放端口
```

这和第6章 load-use stall 不完全一样。load-use 是让 ID 里的 consumer 原地等一拍，所以 IF/ID 要保持；single-port memory 冲突则是 IF 本拍没有拿到新指令，ID 中已有的指令通常可以继续往后走，因此 IF/ID 更像写入 bubble。二者都属于 stall/backpressure，但保持哪个流水线寄存器、哪个位置插 bubble，要由具体资源冲突的位置决定。

### 7.2 single-port memory 冲突的 RTL 示例

下面只展示一种最典型的 structural hazard：IF 取指和 MEM load/store 共用一个 single-port memory 端口。这个示例假设：

- MEM 阶段的 load/store 优先级高于 IF 取指。
- 当 MEM 占用端口时，IF 本拍不能发起取指。
- ID 及更后面的 stage 仍可继续推进。
- IF/ID 写入 bubble，表示这一拍前端没有提供新 instruction。

```systemverilog
always_comb begin
  mem_port_used_by_mem_o = ex_mem_valid_i && ex_mem_mem_req_i;            // MEM 阶段有有效 load/store，需要占用统一 memory 端口
  if_req_valid_o         = if_valid_i && !mem_port_used_by_mem_o;         // 只有端口没被 MEM 占用时，IF 才能发起取指请求

  pc_write_o             = 1'b1;                                          // 默认 PC 正常更新到 next PC
  if_id_write_o          = 1'b1;                                          // 默认 IF/ID 接收本拍取到的新指令
  if_id_bubble_o         = 1'b0;                                          // 默认不插入前端 bubble

  if (mem_port_used_by_mem_o) begin                                       // IF 和 MEM 争用 single-port memory，MEM 优先
    pc_write_o           = 1'b0;                                          // PC 保持，下一拍重新尝试取同一个地址
    if_id_write_o        = 1'b1;                                          // IF/ID 仍更新，但写入的是 bubble，而不是重复旧指令
    if_id_bubble_o       = 1'b1;                                          // 本拍没有有效新 instruction 进入 ID
  end
end
```

对应的 IF/ID pipeline register 可以这样理解：

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    if_id_valid_q <= 1'b0;                                                // 复位后 IF/ID 为空
  end else if (if_id_flush_i) begin
    if_id_valid_q <= 1'b0;                                                // control hazard 或 trap 时清掉错误路径指令
  end else if (if_id_write_i) begin
    if_id_valid_q <= if_resp_valid_i && !if_id_bubble_i;                  // 插 bubble 时 valid=0，表示没有真实指令进入 ID
    if_id_pc_q    <= if_pc_i;                                             // PC 可保留调试值；valid=0 时不能被当成真实指令提交
    if_id_inst_q  <= if_resp_inst_i;                                      // valid=0 时 inst 内容无架构意义，后级必须用 valid 门控
  end
end
```

这个例子故意没有写完整 memory arbiter，因为本节只想说明 structural hazard 的控制核心：**资源被 MEM 占用时，IF 不能假装取到了指令；流水线要么保持等待的 stage，要么插入 bubble，但不能让无效取指结果当成真实 instruction 往后流。**

### 7.3 register file 端口冲突

第二个典型例子是 register file 端口。这里的 register file 就是 `0801` 第3.4节讲的 x0-x31 GPR 的物理寄存器堆，不是 ABI 别名本身；ABI 名字只是软件约定，硬件实际看到的是 rs1、rs2、rd 编号。

在同一个 cycle 中，流水线里可能同时发生：

```text
ID stage:  一条较年轻指令要读 rs1、rs2
WB stage:  一条较年老指令要写 rd
```

所以典型 RV32I 五级流水线的 GPR 做成：

```text
2 read ports + 1 write port
```

这里的“2 读 1 写”不是随便定的，而是由指令格式和流水线并行性共同决定的：

| 指令类别 | ID 阶段最多读几个 GPR | WB 阶段是否写 GPR | 为什么需要这些端口 |
|---|---:|---|---|
| R-type，例如 `ADD rd, rs1, rs2` | 2 | 写 rd | 同一条指令需要两个源操作数 |
| I-type，例如 `ADDI rd, rs1, imm` | 1 | 写 rd | 一个源操作数来自 GPR，另一个来自 immediate |
| load，例如 `LW rd, imm(rs1)` | 1 | 写 rd | rs1 用来算 effective address，load value 写回 rd |
| store，例如 `SW rs2, imm(rs1)` | 2 | 不写 rd | rs1 给地址基址，rs2 给 store data |
| branch，例如 `BEQ rs1, rs2, label` | 2 | 不写 rd | 需要比较两个源寄存器 |

如果 register file 只有 1 个读端口，`ADD`、`SW`、`BEQ` 这类需要两个源操作数的指令就不能在一个 ID cycle 读完，只能分两拍读，或者让 ID stall 一拍。如果没有独立写端口，WB 写回也会和 ID 读寄存器争用，流水线就无法保持理想的一拍推进。

还有一个容易混淆的点：同一拍 WB 写 `rd`，ID 又读同一个寄存器时，是否能读到新值，取决于 register file 的 write-first/read-first 语义，或者是否额外做 writeback forwarding。这个问题和 data hazard 有交叉，但端口数量本身仍然属于 structural hazard 的讨论范围。

### 7.4 计算资源复用：不是“两条 EX 指令抢 ALU”

这里需要把一个常见误解拆开：**经典单发射、顺序五级流水线里，同一个 cycle 通常只有一条指令处于 EX，所以一般不是“两条 EX 指令同时抢主 ALU”。**

真正容易发生的是另一类问题：同一个 cycle 中，不同流水级或者同一条复杂控制流指令，都可能需要“加法/比较/地址计算”这类计算资源。

先看不同流水级同拍的例子：

```text
cycle N:
  IF:  需要计算 PC + 4，用来顺序取下一条 instruction
  EX:  当前指令是 LW，需要计算 rs1 + imm，得到 load effective address
```

如果整个 CPU 只有一个加法器，而且 PC+4 和 load 地址都必须在这一拍得到结果，那么这两个计算就会抢同一个资源。实际设计通常不会这样做，而是给 IF 放一个很小的 PC+4 加法器，EX 再用主 ALU 算 load/store 地址。

再看同一条 branch 指令的例子：

```asm
BEQ x1, x2, label
```

这条指令在决定 next PC 时至少需要两类信息：

| 需要的信息 | 硬件计算 | 用途 |
|---|---|---|
| branch 是否成立 | 比较 `x1 == x2` | 决定走顺序路径还是跳转路径 |
| branch target | 计算 `PC + immB` | branch 成立时作为 next PC |

如果比较复用主 ALU，target 也复用主 ALU，就要么把计算拆到不同拍，造成 stall；要么在一个 cycle 内串起很长的组合路径，影响 Fmax。更常见的做法是：主 ALU 负责普通算术/地址计算，branch comparator 负责比较，branch target adder 负责目标地址计算。

类似地，`JALR rd, imm(rs1)` 也需要：

$$
\text{target PC} = (\text{rs1} + \text{imm}) \mathbin{\&} \sim 1
$$

同时还要把返回地址 `PC+4` 写入 `rd`。因此很多实现会把 `PC+4` 很早就算好并一路带到 WB，而不是到 JALR 执行时再临时抢主 ALU。

几种实现选择可以这样对比：

| 实现选择 | 做法 | 优点 | 代价 |
|---|---|---|---|
| 主 ALU 大量复用 | PC+4、地址、target、比较都尽量走主 ALU 或同一套组合路径 | 面积小，早期教学设计容易画 | MUX 多，控制绕，critical path 可能变长；必要时还要 stall |
| 增加 PC+4 adder | IF stage 专门计算顺序 next PC | 取指路径清楚，几乎是经典五级流水线标配 | 多一个小加法器 |
| 增加 branch target adder | EX 或 ID 单独计算 `PC + immB` | 分支处理更清楚，减少和主 ALU 抢资源 | 面积略增；若放 ID，会拉长 ID stage |
| 增加 branch comparator | 比较逻辑不复用主 ALU | branch taken 判断更直接 | 需要额外比较器和 forwarding 配合 |
| 把部分计算提前到 ID | 提前算 target 或提前比较 | 可能减少 branch penalty | ID stage 更复杂，ID 阶段也可能需要 forwarding |

所以本节的核心不是“一个硬件线程单发射时会有多条 EX 指令”，而是：**一个看起来简单的五级流水线，其实每拍同时需要多个计算结果。到底复制小硬件，还是复用大硬件，是 PPA trade-off。**

### 7.5 多周期执行单元冲突

MDU 是 multiply/divide unit，也就是乘除法单元。RISC-V 基础整数指令集 RV32I/RV64I 不包含整数乘除法；如果实现 M extension，才会有 `MUL`、`MULH`、`DIV`、`REM` 这类指令。当前阶段不需要深入 M extension 的算法，只要知道：乘法和除法通常比普通 `ADD/SUB/AND/OR` 更贵，简单核可能不愿意做成“一拍完成”。

先看最直接的结构冲突：两条乘除法指令连续到来，但硬件里只有一个迭代 MDU(乘除单元，独立于 ALU)。迭代 MDU 的意思是，它接收一条 `MUL` 或 `DIV` 后，需要连续工作多拍，busy 期间不能再接收下一条乘除法请求。

```text
cycle 3: MUL x5, x1, x2  进入 EX，MDU 开始工作
cycle 4: DIV x6, x3, x4  也想进入 EX，但 MDU 仍 busy
cycle 5: DIV             继续等待
cycle 6: MUL             完成，结果可以向后推进
cycle 7: DIV             才能启动 MDU
```

这里 `DIV` 等待的原因不是它要读 `MUL` 的结果，而是同一个 MDU 还没空出来。因此这是 structural hazard：执行单元资源被占用。

再看一个容易困惑的情况：为什么有些资料会说 `MUL` 后面的普通 `ADD` 也可能被堵住？`ADD` 本身不需要 MDU，它只需要普通 ALU。它被堵住通常不是因为“ADD 抢 MDU”，而是因为简单顺序核采用了更保守的控制：只要 EX stage 中的多周期指令没完成，就把整个 EX stage 冻住，ID/IF 也一起 backpressure。这样控制简单，但无关指令也会被挡住。

```text
cycle 3: MUL 进入 EX，MDU busy
cycle 4: ADD 想进入 EX；虽然 ADD 不用 MDU，但 EX stage 被 MUL 占住
cycle 5: ADD 继续等待
cycle 6: MUL 完成并离开 EX
cycle 7: ADD 进入 EX，使用普通 ALU
```

所以这里要分清两层：

| 情况 | 为什么等待 | 属于哪类理解 |
|---|---|---|
| `MUL` 后接 `DIV`，只有一个 MDU | 两条 M extension 指令抢同一个 MDU | 直接的 structural hazard |
| `MUL` 后接无关 `ADD`，简单核仍 stall | 整个 EX stage 被多周期指令占住 | 保守流水线控制带来的结构占用 |
| `MUL x5,...` 后接 `ADD x6,x5,x7` | `ADD` 还需要 `x5` 的结果 | data hazard 和结构占用可能同时存在 |

| 方案 | 控制方式 | 适用场景 |
|---|---|---|
| EX 整体 stall | MDU busy 时，EX 不接收新指令，ID/IF 被 backpressure | 简单顺序核，控制最容易 |
| 乘法器 pipeline 化 | 每拍可以接收一个新的乘法请求，若干拍后连续出结果 | 乘法频繁、追求 throughput 的设计 |
| 除法器独立握手 | DIV 发给独立 MDU，完成后再写回或提交 | 比固定 stall 更灵活，但控制复杂 |
| 配合 scoreboard | 记录哪些 rd 结果未完成，允许无关指令继续前进 | 已经接近更复杂的顺序非阻塞或乱序思想 |

对初学五级流水线来说，记住第一行就够用：**多周期执行单元会让执行资源长时间 busy，因此可能产生 structural hazard，并通过 stall/backpressure 解决。**

### 7.6 后续还会在哪里遇到 structural hazard

本章前面讲的是最适合五级流水线入门的结构冲突。随着模型更接近真实 SoC，还会遇到一些更系统级的资源冲突：

| 场景 | 为什么像 structural hazard | 后续在哪里继续看 |
|---|---|---|
| cache miss 后 MEM stage 等 memory response | MEM stage 的访存资源没有完成，前后级需要 backpressure | `0805` 第3.3/3.4 会从 cache refill、MSHR 和 miss 阻塞角度继续讲 |
| CPU、DMA、外设同时访问总线或 SRAM | 多个访问者争用同一条 bus、同一个 SRAM 端口或同一个 memory controller | `0804` 第2章和第5章会从 interconnect、仲裁和 outstanding 事务角度继续讲 |
| MMIO 访问慢外设 | load/store 发出后，外设若干拍后才返回 response | `0804` 第1章、第5章会从 MMIO 事务、bridge 和 timeout 角度继续讲 |
| store buffer 满 | 新 store 想进入队列，但队列没有空位 | `0805` 第6.2 会从 store buffer、FENCE 和 drain 角度继续讲 |
| CSR 或特权控制路径需要串行化 | 某些状态更新不能和普通指令随意并行 | `0803` 第7.3 会从 CSR/trap/xRET 同拍竞争和优先级角度继续讲 |

这些内容暂时不需要提前学深。现在先建立一个判断标准即可：只要问题的根因是“硬件资源、端口、队列、执行单元或访问路径服务不过来”，就优先从 structural hazard 的角度分析；如果根因是“值没准备好”，再去看 data hazard；如果根因是“PC 路径选错或尚未确定”，再去看 control hazard。

### 7.7 本章小结

面试中可以这样回答 structural hazard：

> structural hazard 是流水线同一拍多个动作争用同一硬件资源。经典五级流水线为了接近每拍完成一条指令，通常假设 instruction/data 访问路径分离、register file 有 2 读 1 写端口、IF 有 PC+4 加法器、EX 有主 ALU，必要时再给 branch 单独比较器和 target adder。如果资源不足，就要复制资源、增加端口、pipeline 化资源，或者通过 stall/backpressure 让流水线等待。

对当前阶段最重要的三个例子是：

1. IF 取指和 MEM load/store 抢 single-port RAM。
2. ID 读 rs1/rs2 和 WB 写 rd 需要 register file 端口支持。
3. PC+4、load/store 地址、branch target、branch compare 等计算资源是否复用，会影响面积、时序和 CPI。

---

## 第8章 Control Hazard 与分支处理

### 8.0 本章概述

control hazard 的根源是：IF 需要每拍取下一条 instruction，但 branch/jump/trap 可能改变 PC。在目标和方向确定前，取到的指令可能是错路径。

### 8.1 分支决策在 EX 的代价

若 branch 在 EX 阶段才知道 taken/not taken：

```text
cycle:  1   2   3   4   5
BEQ:    IF  ID  EX  MEM WB
I+1:        IF  ID  EX
I+2:            IF  ID
```

如果 BEQ taken，则 I+1 和 I+2 是错路径，需要 flush。

代价通常是 2 个 cycle 左右，取决于设计中 PC redirect 何时生效。

这类代价可以粗略并入 CPI：

$$
penalty_{branch} \approx f_{branch} \times P_{mispredict} \times N_{flush}
$$

其中 $f_{branch}$ 是分支指令比例，$P_{mispredict}$ 是预测错误概率，$N_{flush}$ 是一次错误需要清掉或损失的 cycle 数。对 always not taken 来说，taken 分支都可看作预测错误，所以循环尾部 branch 会特别影响性能。

分支决策放在哪一级，本质是在时序和 CPI 之间取舍：

| 决策位置 | flush 代价 | 时序/控制代价 | 适用场景 |
|---|---:|---|---|
| EX | 较高，常见约 2 拍 | ID 简单，forwarding 主要到 EX | 入门五级流水线 |
| ID | 较低，常见约 1 拍 | ID 路径变长，需要到 ID 的 forwarding | 小核优化 branch penalty |
| IF/预测阶段 | 依预测准确率决定 | 需要 BTB/BHT/RAS 和恢复机制 | 高性能前端 |

### 8.2 always not taken (默认不跳转)

最简单策略：

- IF 默认取 `pc + 4`。
- branch 在 EX 判断。
- 如果 not taken，前面取的指令正确。
- 如果 taken，flush IF/ID 和 ID/EX 中的错路径指令，并把 PC 改为 branch target。

优点：

- 控制简单。
- 不需要预测表。

缺点：

- taken branch 有固定惩罚。
- 循环末尾分支通常 taken，会损失性能。

### 8.3 提前分支决策

可以把 branch comparator 和 target adder 放到 ID 阶段，减少 flush 代价。

但会带来：

- ID critical path 增长。
- branch 操作数可能需要更多 forwarding 到 ID。
- load-use 到 branch 的相关更复杂。

这是一种典型 trade-off：减少 branch penalty，但增加时序和控制复杂度。

### 8.4 JAL/JALR：无条件跳转也是 control redirect (控制流重定向)

JAL/JALR 不是“减少 control hazard 代价的一种技巧”，而是 RISC-V ISA 中本来就存在的无条件控制转移指令。它们和 branch 的区别是：branch 要先判断 taken/not taken，而 JAL/JALR 从语义上一定会跳转。硬件仍然要处理 PC redirect 和 flush，只是少了“条件是否成立”的判断。

可以这样对比：

| 指令类别 | 是否需要判断跳不跳 | target 来源 | 是否写 rd | 典型用途 |
|---|---|---|---|---|
| branch，例如 `BEQ` | 需要比较 rs1/rs2 | `PC + immB` | 不写 rd | if/loop 这类条件控制流 |
| `JAL rd, immJ` | 不需要，一定跳 | `PC + immJ` | 写 `PC+4` 到 rd | 函数调用、长距离直接跳转 |
| `JALR rd, imm(rs1)` | 不需要，一定跳 | `(rs1 + imm) & ~1` | 写 `PC+4` 到 rd | 函数返回、函数指针、间接调用 |

所以 8.4 要讲的不是“jump 可以消灭 control hazard”，而是：**jump 也会改变 PC，也会让已经按旧 PC 取进来的年轻指令变成错路径；只是它的 redirect 可能比条件 branch 更早、更确定。**

`JAL` 的目标只依赖当前指令的 PC 和 immediate：

$$
\text{jal\_target} = \text{PC} + \text{immJ}
$$

因此只要 ID 阶段已经拿到 instruction 并生成 immediate，就能很早算出 target。有些设计甚至在 IF/ID 附近就准备好 `PC+immJ`，这样 `JAL` 的 penalty 可以比 EX 决策的 branch 更小。

但 `JAL` 仍然有 flush 问题。假设 IF 默认每拍取 `PC+4`，而 `JAL` 在 ID 才被识别：

```text
cycle:  1   2   3
JAL:    IF  ID
I+1:        IF   <- 已经按 PC+4 取入，但 JAL 一定跳走
target:         IF
```

这里 `I+1` 是错路径，需要 flush。区别只是：`JAL` 不需要等到 EX 比较寄存器，所以通常比 `BEQ` 更早 redirect。

JALR 的目标依赖 rs1：

$$
\text{jalr\_target} = (\text{rs1} + \text{imm}) \mathbin{\&} \sim 1
$$

这里的 `& ~1` 来自 RISC-V ISA 规定：JALR 目标地址最低位要清 0。这样可以保证跳转目标至少按 2 byte 对齐，也给函数指针等软件约定留出低位标记空间。

`JALR` 比 `JAL` 晚一点，因为它的 target 依赖 `rs1` 的真实值。如果 `rs1` 来自前面指令，JALR 也会有 data hazard，需要 forwarding 或 stall。

JALR 比 JAL 更容易出 bug，因为它同时跨了三条路径：register source、immediate generator 和 PC redirect。一个典型序列是：

```asm
ADDI x1, x0, target
JALR x0, 0(x1)
```

如果 JALR 在 EX 计算 target，`x1` 需要从上一条 ADDI 前递；如果 forwarding 漏掉 jump operand，JALR 会用旧 `x1` 跳走。验证时要覆盖 JALR 的 `rs1` 来自前一条、隔一条、load 返回、以及 `rd=x0` 的纯跳转场景。

还要注意 `rd` 的含义。`JAL/JALR` 写回的不是 target，而是返回地址：

$$
\text{rd\_wdata} = \text{PC} + 4
$$

当 `rd = x1/ra` 时，软件通常把它当函数返回地址；当 `rd = x0` 时，就表示只跳转、不保存返回地址。例如 `JALR x0, 0(x1)` 常见于“跳到 x1 指向的位置，但不需要回来”的场景；函数返回更常见的伪指令 `RET` 本质上是 `JALR x0, 0(x1)`。

### 8.5 branch prediction 基础

更高性能设计会预测分支：

| 预测方式 | 思想 |
|---|---|
| always not taken | 默认不跳 |
| always taken | 默认跳 |
| static prediction | 根据方向或编译提示预测 |
| dynamic prediction | 根据历史行为预测 |
| BHT | 记录分支历史状态 |
| BTB | 记录分支目标地址 |
| RAS | 预测函数返回地址 |

入门五级流水线通常只需要会讲 always not taken 和 flush。若项目涉及 branch prediction，要能说清预测信息如何随指令进入 pipeline，以及 mispredict 如何恢复。

预测信息必须跟着指令流动，而不能只存在 IF 阶段。至少要记录：

```text
predicted_taken
predicted_target
predicted_next_pc
branch_pc
```

当 branch 在 EX 或 ID 解析出真实方向和真实 target 后，硬件比较 predicted next PC 和 actual next PC。如果不同，就 redirect PC (重定向 PC)，并 flush younger wrong-path instruction。这个过程和 data forwarding 一样，本质上不是“分支指令特殊处理一下”，而是让每条分支携带足够的元数据，在解析时能判断是否需要恢复。

### 8.6 redirect/flush RTL 示例

下面给一个入门五级流水线常见的控制示例：branch 和 JALR 都在 EX 阶段给出真实 next PC，JAL 在 ID 阶段已经可以给出 redirect。为了突出 control hazard，本例暂时不展开 trap/interrupt/cache miss 的优先级。

先约定一下信号含义：这里的 `flush_if_id_o`、`flush_id_ex_o` 表示“下一拍对应 pipeline register 写入 bubble”，而不是把 redirect 指令本身从当前 stage 里抹掉。比如 JAL 在 ID 阶段产生 redirect 时，JAL 自己仍要进入后级写回 `rd = PC+4`；被清掉的是更年轻的顺序取指结果。

```systemverilog
always_comb begin
  redirect_valid_o = 1'b0;                                                // 默认没有 PC redirect，IF 继续取顺序 next PC
  redirect_pc_o    = pc_plus4_i;                                          // 默认 next PC = PC + 4
  flush_if_id_o    = 1'b0;                                                // 默认不清 IF/ID
  flush_id_ex_o    = 1'b0;                                                // 默认不清 ID/EX

  if (ex_valid_i && ex_is_branch_i && ex_branch_taken_i) begin            // EX 阶段解析出条件 branch 成立
    redirect_valid_o = 1'b1;                                              // 真实 next PC 不是前面假设的顺序 PC
    redirect_pc_o    = ex_branch_target_i;                                // 跳到 branch target
    flush_if_id_o    = 1'b1;                                              // 清掉比 branch 年轻、已进入 IF/ID 的错路径指令
    flush_id_ex_o    = 1'b1;                                              // 清掉比 branch 年轻、已进入 ID/EX 的错路径指令
  end else if (ex_valid_i && ex_is_jalr_i) begin                          // JALR 一定跳，但 target 要等 rs1+imm 算出
    redirect_valid_o = 1'b1;                                              // JALR 也是 control redirect
    redirect_pc_o    = ex_jalr_target_i;                                  // target = (rs1 + imm) & ~1
    flush_if_id_o    = 1'b1;                                              // 清掉按旧 PC 取入的年轻指令
    flush_id_ex_o    = 1'b1;                                              // 清掉按旧 PC 推进的年轻指令
  end else if (id_valid_i && id_is_jal_i) begin                           // JAL 不需要比较寄存器，ID 阶段可较早确定 target
    redirect_valid_o = 1'b1;                                              // 发现无条件直接跳转
    redirect_pc_o    = id_jal_target_i;                                   // target = PC + immJ
    flush_if_id_o    = 1'b1;                                              // 阻止 IF 本拍按 PC+4 取到的年轻指令进入 IF/ID
    flush_id_ex_o    = 1'b0;                                              // JAL 自己仍要进入后级写 rd=PC+4，不能把自己清掉
  end
end
```

这段代码有三个关键点：

| 信号 | 作用 | 容易错的地方 |
|---|---|---|
| `redirect_valid_o` | 告诉 IF：下一拍 PC 要改成 `redirect_pc_o` | 只改 PC、不 flush 错路径指令 |
| `flush_if_id_o` | 清掉已经取入但不该执行的年轻指令 | 忘记用 valid/kill 门控副作用 |
| `flush_id_ex_o` | 清掉已经译码并进入 EX 前的错路径指令 | 对 ID 阶段 JAL 不能误清 JAL 自己 |

如果 branch 在 EX 才成立，那么 ID 阶段和 IF 阶段的年轻指令通常都可能是错路径，所以需要让 IF/ID、ID/EX 在下一拍写入 bubble。如果 JAL 在 ID 就解析出来，只有 IF 本拍按顺序路径取来的年轻指令需要被挡掉；JAL 自己还要继续向后执行并在 WB 写 `rd = PC+4`。实际项目会把“哪一级产生 redirect”和“哪些 pipeline register 比它年轻”做成明确规则。

实际设计还要处理：

- JAL/JALR redirect。
- trap redirect。
- interrupt redirect。
- cache miss stall 同时发生。
- IF 取指响应回来时是否属于被 kill 的旧请求。

### 8.7 flush/kill 的 RTL 实现：清 valid 与屏蔽副作用

从 RTL 角度看，flush/kill 不是把某条 instruction 从硬件里“删除”。pipeline register 本质上只是一组触发器，里面的 `pc`、`inst`、`rd`、控制信号在物理上仍然有 0/1 值。真正让一条指令失效的做法通常是：

1. 在对应 pipeline register 更新时把 `valid` 清 0，让它变成 bubble。
2. 对所有写寄存器、写 memory、写 CSR、提交 trace 等副作用使用 `valid` 或 `kill` 门控。
3. 如果有取指请求、cache miss、总线请求这类可能延迟返回的操作，用 `kill`、请求编号或 epoch 判断返回结果是否还属于当前路径。

因此，最入门的五级流水线可以先把 `flush` 理解成“下一拍把某些年轻 stage 的 `valid` 清 0”。例如 EX 阶段 branch taken 后，IF/ID 和 ID/EX 里的年轻指令都是错路径：

```text
cycle N:
  EX     : BEQ 发现 taken，产生 redirect_pc 和 flush
  ID     : I+1 是错路径
  IF     : I+2 是错路径

posedge N+1:
  PC     : 更新为 branch target
  IF/ID  : valid 清 0，I+2 被杀掉
  ID/EX  : valid 清 0，I+1 被杀掉
  EX/MEM : BEQ 自己继续向后流动
```

对应的 IF/ID pipeline register 可以写成这样：

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    if_id_valid_q <= 1'b0;                            // reset 后前端没有有效指令
    if_id_pc_q    <= '0;                              // 调试字段清零，不代表真实 PC
    if_id_inst_q  <= 32'h0000_0013;                   // 可选写入 NOP，便于看波形
  end else if (flush_if_id_i) begin                   // branch/jump/trap 要清掉 IF/ID 年轻指令
    if_id_valid_q <= 1'b0;                            // 关键动作：valid=0，这条指令变成 bubble
    if_id_pc_q    <= if_id_pc_q;                      // PC/inst 可保持旧值，valid=0 时无架构意义
    if_id_inst_q  <= 32'h0000_0013;                   // 可选写 NOP，降低后级误用旧 opcode 的风险
  end else if (!stall_if_id_i) begin                  // 没有 stall 时，IF/ID 接收新取到的指令
    if_id_valid_q <= if_resp_valid_i;                 // 取指响应有效，才让 ID 看到真实指令
    if_id_pc_q    <= if_resp_pc_i;                    // PC 必须和 instruction 一起进入 IF/ID
    if_id_inst_q  <= if_resp_inst_i;                  // 后级 decode 的就是这条 instruction
  end                                                 // stall 时保持 IF/ID 不变
end
```

ID/EX 也类似，但它已经包含译码后的控制信号，所以 flush 时通常会同时把关键副作用控制信号清 0。严格来说，只要后面所有副作用都受 `valid` 门控，控制信号残留也不会改变架构状态；但工程上常把 `reg_we`、`mem_we`、`csr_we` 等一起清掉，波形更直观，也能降低误接线风险。

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    id_ex_valid_q  <= 1'b0;             // reset 后 EX 前没有有效指令
    id_ex_reg_we_q <= 1'b0;             // 默认不允许写 GPR
    id_ex_mem_we_q <= 1'b0;             // 默认不允许写 data memory/MMIO
    id_ex_csr_we_q <= 1'b0;             // 默认不允许写 CSR
  end else if (flush_id_ex_i) begin     // 清掉已经译码但不该进入 EX 的错路径指令
    id_ex_valid_q  <= 1'b0;             // 关键动作：让 EX 下一拍看到 bubble
    id_ex_reg_we_q <= 1'b0;             // 防止后级误把旧 rd/control 当成真实写回
    id_ex_mem_we_q <= 1'b0;             // store 是外部副作用，flush 时必须关闭
    id_ex_csr_we_q <= 1'b0;             // CSR 写也属于架构副作用，必须关闭
  end else if (!stall_id_ex_i) begin    // 没有 stall 时，ID 指令正常进入 EX
    id_ex_valid_q  <= if_id_valid_q;    // ID/EX 的有效性来自 IF/ID
    id_ex_pc_q     <= if_id_pc_q;       // PC 跟随同一条指令传递
    id_ex_rs1_q    <= id_rs1_value_i;   // 源操作数进入 EX，供 ALU/branch 使用
    id_ex_rs2_q    <= id_rs2_value_i;   // store data 或第二个 ALU operand
    id_ex_rd_q     <= id_rd_i;          // 目的寄存器编号继续向后流动
    id_ex_reg_we_q <= id_reg_we_i;      // 是否写 GPR，由 decode 产生
    id_ex_mem_we_q <= id_mem_we_i;      // 是否 store，由 decode 产生
    id_ex_csr_we_q <= id_csr_we_i;      // 是否写 CSR，由 decode 产生
  end                                   // stall 时保持 ID/EX 不变
end
```

最后，还要在真正发生副作用的位置再门控一次。这样即使某个控制信号残留为 1，只要这条 instruction 已经被 flush/kill，就不会写出软件可见状态：

```systemverilog
assign dmem_we_o     = ex_mem_valid_q && !ex_mem_kill_q &&
                       ex_mem_mem_we_q && dmem_req_ready_i;               // 只有有效且未 kill 的 store 才能写 memory/MMIO

assign rf_we_o       = mem_wb_valid_q && !mem_wb_kill_q &&
                       mem_wb_reg_we_q && (mem_wb_rd_q != 5'd0);          // 只有有效且未 kill 的指令才能写 GPR

assign csr_we_o      = mem_wb_valid_q && !mem_wb_kill_q &&
                       mem_wb_csr_we_q;                                   // CSR 写必须同样受 valid/kill 保护

assign commit_valid_o = mem_wb_valid_q && !mem_wb_kill_q;                 // trace/scoreboard 只看真正提交的指令
```

这里的 `kill_q` 可以按设计复杂度选择是否真的做成一个独立 bit。简单五级流水线里，很多时候 `valid=0` 就已经等价于“这条指令被 kill”。更复杂的设计中，`kill` 常用来处理“指令或请求已经发出，但后来发现它属于旧路径”的情况，例如：

| 场景 | 为什么只清当前 pipeline register 不够 | 常见做法 |
|---|---|---|
| IF 请求已经发给 I-cache，总线响应晚几拍回来 | redirect 后返回的旧 instruction 可能已经不属于当前 PC 路径 | 给请求带 epoch/tag，响应回来时不匹配就丢弃 |
| store 已进入带缓冲的 memory path | 错路径 store 如果已经对 MMIO 可见，就无法撤销 | store 必须到确认可提交后才发出，或用 valid/kill 严格门控 |
| exception/trap 发生在较后级 | 更年轻指令可能已经在 IF/ID/ID/EX/EX/MEM 中 | trap redirect 时 flush younger stage，副作用只允许 older/exception instruction 产生 |

所以可以把实现原则压缩成一句话：**flush 负责把错路径的 pipeline slot 变成 bubble，kill/valid 负责保证这个 slot 后面即使还有残留信号，也不能产生任何架构副作用。**

---

## 第9章 Exception、Interrupt 与精确提交基础

### 9.0 本章概述

虽然本篇重点是五级流水线和 hazard，但一旦做 RISC-V CPU，exception 和 interrupt 无法完全回避。面试常追问：“如果流水线里同时有异常和分支，怎么办？”

先从硬件直觉看：exception 和 interrupt 都会让 CPU 暂停当前普通取指路径，转去执行 trap handler (异常中断处理函数)。区别在于，exception 通常是“当前这条指令自己执行时发现问题”，interrupt 通常是“外部或定时器等异步事件希望 CPU 尽快处理”。

| 事件 | 典型来源 | 硬件在哪一级可能发现 | 流水线要做什么 |
|---|---|---|---|
| illegal instruction | ID 译码发现 opcode/funct 组合不合法，或当前核不支持该扩展指令 | ID | 记录异常原因和该指令 PC，后续不应把它当普通指令执行 |
| instruction access fault (取指访问异常) | IF 取指访问的地址或总线返回错误 | IF | 把取指错误跟这条 PC 绑定，不能被后面译码错误覆盖 |
| load/store address misaligned (未对齐) | MEM 访问的数据地址不满足对齐要求，例如 word load 地址不是 4 字节对齐 | EX/MEM | 记录 fault address，阻止错误的访存副作用 |
| load/store access fault | 数据存储、MMIO、总线或权限检查返回访问错误 | MEM | 记录访问地址和原因，不能让后续 younger store 写出 |
| timer/external interrupt | 定时器、外设中断控制器、软件中断等 | 通常在 commit 边界采样并接受 | 当前指令边界进入 trap，flush younger instruction |

当某一级发现 exception 时，简单做法不是立刻把所有 CSR 都写掉，而是先把“这条指令发生了什么”作为异常信息放进 pipeline register，让它跟着这条 instruction 一起向后流动。这里的异常信息通常包括：

| 字段 | 含义 |
|---|---|
| `exception_valid` | 这条指令是否已经带着待处理异常 |
| `exception_cause` | 异常原因，例如 illegal instruction、load address misaligned |
| `exception_tval` | 附加调试值，常见是 fault address 或非法指令编码 |
| `exception_pc` | 触发异常的指令 PC，很多设计直接复用随流水线流动的 `pc` 字段 |
| `exception_is_interrupt` | 是否是 interrupt；简单五级核也可以把 interrupt 单独在 commit 边界处理 |

commit/retire 可以先理解成“这条指令正式被 CPU 承认为已经执行到软件可见边界”。一条普通 `ADD` 到 commit 时，写回 GPR 才算真正生效；一条 `SW` 到允许提交的位置时，store 才能对 memory/MMIO 产生不可撤销副作用；一条带 exception 的指令到 commit 时，CPU 不再按普通写回处理，而是写 EPC/cause/tval 等 CSR、flush 更年轻指令，并把 PC redirect 到 trap vector。后续 `0803` 会系统讲这些 CSR 和 trap 入口，本章只关心它们如何和流水线的 valid/kill/flush 配合。

进入 trap handler 后，后续程序是否继续执行不是流水线自己决定的，而是 trap handler 软件决定的。硬件只负责把现场交代清楚：`mepc/sepc` 记录触发 trap 的指令 PC，也就是后续 `MRET/SRET` 可能返回的位置；`mcause/scause` 记录原因，`mtval/stval` 记录附加信息，然后跳到 `mtvec/stvec` 指向的处理入口。

| 情况 | 流水线中的后续指令 | trap handler 处理完后通常怎样 |
|---|---|---|
| interrupt | 已经进入 IF/ID/ID/EX 的 younger instruction 会被 flush，避免它们在中断边界前产生副作用 | 处理完定时器或外设事件后执行 `MRET/SRET` (异常返回指令，负责 “从哪儿来回哪儿去”)，通常回到被打断位置继续执行 |
| illegal instruction 这类同步 exception | 异常指令后面的 younger instruction 必须 flush；异常指令自己不能再当普通指令写回 | 若程序错误，OS 可能杀进程，裸机可能进入错误处理；若 handler 能软件模拟这条指令，可以模拟效果后把 `mepc/sepc` 改到下一条指令再返回 |
| load/store access fault 或 page fault | fault 指令后面的 younger instruction 必须 flush，尤其不能让 younger store 写出 | OS 可能修复映射后重试同一条指令，也可能报告错误；是否重试取决于 handler 是否修改 `mepc/sepc` |

所以要区分两个“后续”：已经进入流水线的后续指令会被 flush/kill；程序代码里位于异常指令之后的后续指令，只有在 handler 选择返回并把 `mepc/sepc` 指到合适位置后，才可能重新被 IF 取出来执行。如果 illegal instruction 的 handler 不修改 `mepc/sepc` 就直接 `MRET/SRET`，CPU 会回到同一条非法指令并再次 trap。

这里还有一个很关键的边界：硬件不认识“函数还没执行完”或“这个函数后面的代码”。函数边界、调用栈和错误处理策略是软件概念；流水线只认识 PC 和已经进入各级的动态指令。因此 flush/kill 只杀掉“当时已经在流水线里、并且比异常指令更年轻”的那些 instruction。程序文本里更后面的 instruction 并不是永久作废，它们是否会执行，取决于 trap handler 最后让 PC 去哪里。

| handler 最后的选择 | 返回后的取指位置 | 原程序后续代码是否可能执行 |
|---|---|---|
| 保持 `mepc/sepc` 指向异常指令 | 回来重试同一条 instruction | 若异常原因被修复，后续代码会重新取指执行；若没修复，会再次 trap |
| 把 `mepc/sepc` 改成下一条 instruction | 跳过或软件模拟异常指令后继续 | 下一条及更后面的代码可能继续执行 |
| 改到错误处理函数或退出路径 | 从新的 PC 开始执行 | 原来顺序路径上的后续代码通常不再执行 |
| 不返回，例如 OS 杀进程、裸机停机 | 不再回到原程序 | 原程序后续代码不会执行 |

### 9.1 precise exception

precise exception 要求异常看起来发生在某一条指令边界：

- 异常指令之前的指令都已完成。
- 异常指令之后的指令都没有改变架构状态。
- trap handler 能看到一致的状态。

precise exception 不是一种新的异常原因，而是 CPU 处理异常时必须满足的效果。比如下面这段指令中，`LW` 的地址非对齐：

```asm
ADD  x3, x1, x2
LW   x5, 2(x10)     # 假设 x10 为 0x1000，则访问 0x1002，word load 非对齐
ADD  x6, x5, x7
SW   x6, 0(x11)
```

当 `LW` 到 EX/MEM 计算出有效地址后，硬件发现 `0x1002` 不是 4 字节对齐地址，于是给这条 `LW` 标上 `exception_valid=1`，`exception_cause=load address misaligned`，`exception_tval=0x1002`。为了做到 precise exception，`ADD x3` 作为 older instruction 可以正常提交；`LW` 自己进入 trap 流程；后面的 `ADD x6` 和 `SW` 即使已经被取指、译码，甚至进入了前面几个 stage，也必须被 flush/kill，不能写 `x6`，更不能真的执行 store。

简单顺序五级流水线相对容易实现 precise exception，因为指令按顺序进入 WB/commit。只要所有架构副作用都集中在受 valid/kill 门控的提交边界，硬件就能在“最老的待处理异常指令”处切开流水线。

从提交视角看，precise exception 可以理解成一条边界：

```text
older instructions    exception instruction    younger instructions
已经提交或允许提交       记录异常并进入 trap       必须被 kill，不能产生副作用
```

这和 branch flush 很像，但语义更严格。branch flush 只是控制流恢复；exception flush 还要保证异常原因、异常 PC、访问地址等状态与触发异常的那条指令绑定，不能被更年轻的指令覆盖。

### 9.2 不同 stage 的异常

可能异常：

| stage | 异常示例 |
|---|---|
| IF | instruction address misaligned、instruction access fault |
| ID | illegal instruction |
| EX | branch/jump target misaligned |
| MEM | load/store address misaligned、access fault |
| WB | 通常提交状态，异常应已确定 |

异常信息要随指令在 pipeline register 中流动，不能丢失或和别的指令混淆。

一个常见做法是在 pipeline register 中携带异常字段：

```text
valid
pc
inst
exception_valid
exception_cause
exception_tval
```

如果 IF 阶段已经发现 instruction access fault，这条指令后续即使不再需要正常执行 ALU，也要把异常信息一路带到接受 trap 的位置。否则 ID 阶段重新译码出 illegal instruction，可能错误覆盖更早、更应该优先报告的 IF 异常。

异常优先级通常按“同一条指令内部的规范优先级”和“流水线中指令年龄”共同决定。简单顺序核里，older instruction 的异常应优先于 younger instruction；同一条指令如果已经有更早 stage 的异常，后级通常不应再发起会产生副作用的动作。

### 9.3 flush younger instruction

当某条指令产生 exception 并被接受：

- older instruction 应已经提交或继续提交。
- exception instruction 进入 trap 流程。
- younger instruction 必须 flush。
- PC redirect 到 trap vector。

这要求所有 younger stage 的 side effect 都受 valid/kill 控制。例如 MEM 阶段一条 load/store 发现 access fault，同时 IF/ID 里已经取入了后续 store；trap redirect 必须清掉这条 younger store，且它不能向 data memory 发起写请求。

### 9.4 interrupt 的特殊性

interrupt 是异步事件，不是当前 instruction 自己执行造成的。为了 precise exception，简单设计通常在指令边界接受 interrupt。

常见策略：

- 在 WB/commit 边界检查 pending interrupt。
- 当前指令提交后进入 trap。
- flush younger instruction。

更复杂设计会有更细的优先级和屏蔽规则，这应放到 `0803` 继续展开。

### 9.5 commit/retire 信息

为了验证和 debug，建议顺序核产生 commit trace：

```text
commit_valid
commit_pc
commit_inst
commit_rd
commit_wdata
commit_mem_addr
commit_mem_we
commit_exception
```

reference model 可以逐条比对 commit 信息，定位第一条错误提交。

---

## 第10章 系统 OS、裸机运行时与流水线的接口

### 10.0 为什么这里要提 OS

本篇的主线仍然是 CPU pipeline，不是操作系统实现。但只要 CPU 要放进 SoC 里运行裸机程序、RTOS 或 Unix-like OS，流水线里的很多控制动作都会直接变成系统软件能观察到的行为。

这里先给一个总览，后续文档会在对应硬件位置分散展开。这样做的边界是：数字 IC 学习需要理解 OS/运行时如何使用硬件接口，不需要在这里深入调度器、文件系统或完整内核实现。

| 系统软件场景 | 对流水线意味着什么 | 后续在哪里展开 |
|---|---|---|
| reset 后启动裸机 runtime | IF 必须从 reset vector (复位向量)取到第一条有效指令，异常/中断通常先关闭 | `0804` 的 boot ROM、memory map、linker script |
| trap handler 处理异常/中断 | exception instruction 要精确记录 EPC/cause/tval，younger instruction 要 flush | `0803` 的 CSR、trap entry、MRET/SRET |
| driver 访问 MMIO 外设 | load/store 可能访问慢外设，MEM 阶段可能 stall，也可能产生 access fault | `0804` 的 MMIO、bus、PLIC/CLINT |
| OS 使用虚拟内存 | IF/MEM 访问可能经历 TLB/MMU，TLB miss、page fault 会反向影响流水线 | `0805` 的 TLB、MMU、page table、page fault |
| driver 或内核使用 FENCE (内存屏障) | store buffer、cache、MMIO 顺序不能只按普通 ALU 指令理解 | `0805` 的 memory model、FENCE、device memory |

### 10.1 什么是 OS

OS 可以先通俗理解成“替所有应用程序管理整台机器的那层核心软件”。如果没有 OS，程序通常就是裸机程序：reset 后 CPU 跳到某个固定地址，从那里开始执行一段代码，这段代码自己初始化栈、自己配置外设、自己决定什么时候读写内存和寄存器。单片机里常见的裸机主循环、简单中断服务函数，就接近这种模型。

有了 OS 以后，普通应用一般不能直接控制整台机器。应用想读文件、申请内存、收发网络、等待定时器、访问屏幕或磁盘，通常要通过系统调用进入内核；内核再用更高的 privilege、页表、驱动和中断机制去管理硬件资源。这样做的目标不是让 CPU 算得更快，而是让多个程序能安全、稳定、可恢复地共享 CPU、内存和外设。

| 视角 | 没有 OS 的裸机程序 | 有 OS 的系统 |
|---|---|---|
| 谁拥有硬件 | 当前程序基本直接拥有 CPU、内存和外设 | OS 内核统一管理，应用通过系统调用请求服务 |
| 出错怎么办 | 常见做法是停机、复位、进入错误循环或由项目自定义处理 | OS 根据异常原因杀进程、发信号、修复 page fault、记录错误或重启服务 |
| 中断给谁处理 | 中断服务函数通常就是项目代码的一部分 | 先进入内核/驱动，再决定唤醒哪个任务、更新哪个设备状态 |
| 内存怎么用 | 程序通常直接使用物理地址或固定链接地址 | OS 用虚拟内存隔离进程，并通过页表控制权限和映射 |
| 对 CPU 硬件的要求 | 能启动、能执行指令、能响应必要中断即可 | 还需要可靠的 trap、CSR、权限、MMU/TLB、cache/MMIO 顺序等机制 |

从 CPU 流水线角度看，OS 不是一个神秘的软件概念，而是一类会频繁使用硬件边界的程序：它会靠 trap 进入内核，靠 `MRET/SRET` 返回，靠 page fault 发现缺页或权限错误，靠 timer interrupt 获得调度机会，靠 MMIO driver 控制外设。因此数字 IC 学习不需要在这里实现完整 OS，但需要知道 OS 会怎样观察和依赖 CPU 的精确异常、提交边界、访存顺序和中断行为。

### 10.2 OS 是软件，硬件提供机制

OS 本质上是软件。它和普通应用一样，最终也会变成 instruction，放在存储器里，由 CPU 一条条取指、译码、执行。区别在于，OS 内核运行在更高 privilege，能访问普通应用不能访问的 CSR、页表和外设控制寄存器。

可以把关系压成三层：

```text
硬件：提供机制
  privilege、CSR、trap、中断、MMU、MMIO、timer

OS：使用这些机制
  调度任务、管理内存、处理中断、驱动外设、隔离进程

应用程序：向 OS 请求服务
  读文件、申请内存、创建线程、访问网络
```

所以不能说“OS 在硬件上实现”。更准确的说法是：**OS 用软件实现，硬件实现 OS 所依赖的控制机制**。如果这些机制不可靠，OS 就无法判断哪条指令出错、从哪里返回、哪些寄存器和内存已经真的改变。

| OS 想做的事 | 硬件要提供什么 | 和流水线的关系 |
|---|---|---|
| 不让普通应用乱改外设、页表和中断 | privilege level、CSR 访问权限 | ID/EX 需要检查权限，非法访问要产生 precise exception |
| 应用进入内核请求服务 | `ECALL` 触发 trap | 记录 EPC/cause，flush younger instruction，redirect 到 trap vector |
| 定时切换任务 | timer interrupt | 在指令边界接受 interrupt，保证被打断现场精确 |
| 外设通知 CPU | external interrupt、中断控制器 | 异步信号进入 CPU 后，要按优先级和屏蔽规则接受 |
| 每个进程看到自己的地址空间 | MMU、TLB、page table、page fault | IF/MEM 访问可能产生 page fault，需要精确记录 fault PC/address |
| 驱动访问外设寄存器 | MMIO、bus、memory map | load/store 可能有外部副作用，必须受 valid/kill 和顺序规则约束 |

### 10.3 RISC-V 里 OS 依赖哪些机制

放到 RISC-V 语境下，OS 相关机制不是一条单独指令，而是一组软硬件接口。不同级别的系统需要的集合不同：裸机程序可能只需要 M-mode、基本 trap 和 timer；RTOS 常需要稳定的中断和上下文切换；Linux 这类 Unix-like OS 通常还需要 S-mode、U-mode、MMU、TLB、外部中断控制器和原子操作。

| RISC-V 机制 | OS 怎么用 | 后续文档位置 |
|---|---|---|
| M/S/U privilege | M-mode 管底层机器资源，S-mode 常运行内核，U-mode 运行普通应用 | `0803` 特权级与 CSR |
| `mstatus/sstatus` | 保存 trap 前的中断使能和特权级返回信息 | `0803` trap 状态栈 |
| `mtvec/stvec` | 指定异常、中断、系统调用进入哪段 handler | `0803` trap entry |
| `mepc/sepc` | 记录 trap 返回 PC，handler 可选择重试、跳过或改走错误路径 | `0803` trap 返回 |
| `mcause/scause`、`mtval/stval` | 告诉 handler 为什么 trap，以及 fault address/非法指令等细节 | `0803` 异常原因 |
| `ECALL`、`MRET/SRET` | `ECALL` 让应用进入内核，`MRET/SRET` 从 trap handler 返回 | `0803` 系统调用与返回 |
| CLINT/PLIC 或平台中断控制器 | 提供 timer、software、external interrupt 来源 | `0804` SoC 与外设互联 |
| MMU/TLB/page table | 支持虚拟地址、进程隔离、权限检查和 page fault | `0805` MMU/TLB |
| atomic/FENCE | 支持锁、同步和 MMIO/cache 顺序约束 | `0805` 内存模型 |

对本篇流水线来说，最核心的交叉点仍然是：RISC-V OS 依赖硬件在正确的指令边界上记录 `xepc/xcause/xtval`、更新状态、flush younger instruction，并保证被 kill 的指令不会写 GPR、memory、CSR 或 MMIO。

### 10.4 从软件栈看 CPU 硬件边界

可以把系统软件和流水线的连接压成一条链：

```text
启动代码 / OS / driver
  -> instruction fetch、load/store、CSR instruction、FENCE
  -> pipeline stage、hazard control、commit/retire
  -> trap/MMIO/cache/TLB/bus 等硬件行为
  -> 软件看到返回值、异常、中断或外设状态变化
```

软件不会看见 `IF/ID`、`ID/EX` 这类 pipeline register，但会看见它们控制是否正确带来的结果：PC trace 是否对、寄存器写回是否对、异常是不是精确、MMIO 写有没有重复或丢失、TLB 旧项有没有被清掉。

### 10.5 学到什么程度就够

对数字 IC/CPU/SoC 岗位，更合适的目标不是“会写完整 OS”，而是能把下面几件事讲成软硬件闭环：

| 需要了解的系统 OS/运行时内容 | 为什么数字 IC 需要懂 |
|---|---|
| reset vector、启动汇编、栈初始化、`.bss` 清零 | 判断 CPU 复位后是否能取到第一条指令，debug 启动卡死问题 |
| trap handler 保存/恢复现场 | 理解硬件只保存 EPC/cause/status，GPR 现场通常由软件保存 |
| MMIO driver 读写外设寄存器 | 理解 load/store 为什么会变成外设副作用，以及为什么 device memory 不能随便 cache |
| timer/external interrupt | 理解异步事件如何进入流水线提交边界，再跳到 handler |
| page table、TLB、page fault | 理解 OS 为什么要 MMU，以及硬件为什么要产生精确异常 |
| FENCE 和内存顺序 | 理解 store buffer、cache、DMA、MMIO 之间的可见顺序 |

不需要在本系列主线里深入文件系统、shell、复杂调度策略、Linux 驱动框架或完整内核工程。它们属于系统软件专题；本系列只把它们当作硬件接口的使用者。

### 10.6 一个统一判断原则

遇到 OS/裸机软件相关问题时，可以先问一句：

```text
软件依赖的状态，是否在正确的指令边界上变得可见？
```

这句话能统一很多看似分散的问题：

- branch/JALR：错路径指令不能写 GPR 或发出 MMIO store。
- exception：异常指令之前的结果可见，之后的 younger instruction 不可见。
- interrupt：异步事件通常在指令边界被接受，不能把一条指令执行到一半暴露给 handler。
- MMIO：store 一旦对外设可见，就可能触发真实动作，必须受 valid/kill 和顺序规则约束。
- TLB/page fault：OS 看到的 EPC、fault address 和权限原因必须和触发访问对应。
- FENCE：软件要求“之前的访存已经到达规定可见点”，硬件不能只把它当普通 NOP。

因此，系统 OS 视角不是额外背一套软件知识，而是提醒我们：CPU 流水线的每个 redirect、flush、stall、commit 和 side-effect gating，最后都要落到软件可见行为正确。

---

## 第11章 RTL 控制骨架

### 11.0 本章概述

本章给出五级流水线控制的骨架。真实 CPU 代码会更复杂，但核心动作离不开：

- PC write enable。
- IF/ID write enable。
- ID/EX flush。
- forwarding select。
- branch/trap redirect。
- memory stall。

### 11.1 load-use interlock 控制

```systemverilog
always_comb begin
  pc_en        = 1'b1;
  if_id_en     = 1'b1;
  if_id_flush  = 1'b0;
  id_ex_flush  = 1'b0;

  if (trap_redirect) begin
    if_id_flush = 1'b1;
    id_ex_flush = 1'b1;
  end else if (branch_redirect) begin
    if_id_flush = 1'b1;
    id_ex_flush = 1'b1;
  end else if (load_use_stall) begin
    pc_en       = 1'b0;
    if_id_en    = 1'b0;
    id_ex_flush = 1'b1;
  end
end
```

这段代码体现优先级：

```text
trap > branch > load-use stall
```

实际项目中还要加入 memory stall、debug halt、reset 等条件。

### 11.2 forwarding operand MUX

```systemverilog
always_comb begin
  unique case (fwd_a_sel)
    FWD_EX_MEM: alu_op_a = ex_mem_forward_data;
    FWD_MEM_WB: alu_op_a = mem_wb_forward_data;
    default:    alu_op_a = id_ex_rs1_value;
  endcase

  unique case (fwd_b_sel)
    FWD_EX_MEM: alu_op_b_raw = ex_mem_forward_data;
    FWD_MEM_WB: alu_op_b_raw = mem_wb_forward_data;
    default:    alu_op_b_raw = id_ex_rs2_value;
  endcase

  alu_op_b = id_ex_alu_src_imm ? id_ex_imm : alu_op_b_raw;
end
```

注意：

- rs2 的前递值可能用于 ALU，也可能用于 store data。
- 如果 ALU 第二操作数选择 immediate，rs2 前递不应影响 ALU，但可能仍影响后续 store data。

### 11.3 valid bit 与副作用屏蔽

所有会改变架构状态或外部状态的动作，都应受 valid bit 控制：

```systemverilog
assign rf_we_o  = mem_wb_valid_q && mem_wb_reg_we_q && (mem_wb_rd_q != 5'd0);
assign dmem_we_o = ex_mem_valid_q && ex_mem_mem_we_q;
```

否则 flush 出来的无效指令可能仍然写 register file 或 memory。

### 11.4 PC 选择优先级

PC next 选择常见优先级：

```text
reset vector
trap vector
branch/jump redirect
predicted next PC
pc + 4
```

如果 IF stage 因 memory stall 不能接受新 PC，则 redirect 需要被保存或让前级控制确保 PC 更新不会丢。

---

## 第12章 验证方法

### 12.0 本章概述

五级流水线验证的核心是同时证明两件事：

1. ISA 可见结果正确。
2. 微架构控制在 hazard、stall、flush 下不会丢指令、重复提交或错误写状态。

### 12.1 directed test

必须覆盖：

| 类别 | 例子 |
|---|---|
| ALU-ALU RAW | `ADD x5,...` 后立即 `SUB ...,x5,...` |
| load-use | `LW x5,...` 后立即使用 x5 |
| store data forwarding | `ADD x5,...` 后 `SW x5,...` |
| branch data hazard | 比较寄存器来自上一条指令 |
| branch taken flush | taken 后错路径不能写回 |
| branch not taken | 不应错误 flush |
| x0 相关 | 写 x0 后依赖 x0 不应 forwarding/stall |
| back-to-back load | 连续 load 和依赖使用 |
| memory stall | load 等待多拍 |
| exception flush | illegal instruction 后 younger 指令不能提交 |

### 12.2 random test 与 ISS 比对

random test 可以发现 directed test 想不到的组合，例如：

- forwarding 和 branch flush 同时出现。
- load-use stall 后紧跟 exception。
- store data forwarding 与 memory stall 重叠。
- 写 x0 和 RAW 检测重叠。

比对方式：

- DUT 产生 commit trace。
- ISS 执行同一条 instruction。
- scoreboard 比对 PC、rd、wdata、memory side effect、exception。

### 12.3 SVA 断言示例

#### 11.3.1 flush 后无效指令不能提交

```systemverilog
// 不可综合：验证断言
property p_flush_kills_if_id;
  @(posedge clk) disable iff (!rst_n)
    flush_if_id |=> !if_id_valid_q;
endproperty

assert property (p_flush_kills_if_id);
```

#### 11.3.2 写 x0 不改变架构状态

```systemverilog
// 不可综合：验证断言
property p_x0_zero_at_commit;
  @(posedge clk) disable iff (!rst_n)
    commit_valid |-> (rf_x0_value == '0);
endproperty

assert property (p_x0_zero_at_commit);
```

#### 11.3.3 load-use 需要 interlock

```systemverilog
// 不可综合：验证断言，信号名仅示意
property p_load_use_stall;
  @(posedge clk) disable iff (!rst_n)
    id_ex_valid_q && id_ex_is_load_q && (id_ex_rd_q != 5'd0) &&
    if_id_valid_q &&
    ((if_id_uses_rs1 && (if_id_rs1 == id_ex_rd_q)) ||
     (if_id_uses_rs2 && (if_id_rs2 == id_ex_rd_q)))
    |-> load_use_stall;
endproperty

assert property (p_load_use_stall);
```

### 12.4 coverage

功能覆盖建议：

- RAW 距离：相邻、隔一条、隔两条。
- 源操作数：rs1 命中、rs2 命中、二者都命中。
- forwarding 来源：EX/MEM、MEM/WB。
- 目的寄存器：x0、普通寄存器、ABI 常用寄存器。
- load-use 指令类型：ALU、branch、store。
- branch：taken、not taken、正偏移、负偏移。
- flush 与 stall 同时出现。
- memory stall 长度：0、1、多拍。
- exception stage：IF、ID、MEM。

### 12.5 波形 debug 观察点

建议波形里长期保留：

```text
if_pc, if_inst, if_valid
id_pc, id_inst, id_valid, id_rs1, id_rs2, id_rd
ex_pc, ex_inst, ex_valid, alu_op_a, alu_op_b, alu_result
mem_pc, mem_inst, mem_valid, dmem_req, dmem_we, dmem_addr
wb_pc, wb_inst, wb_valid, rf_we, wb_rd, wb_data
stall, flush, branch_redirect, trap_redirect
fwd_a_sel, fwd_b_sel
commit_valid, commit_pc, commit_inst
```

debug 时先找第一条 commit mismatch，再往前看 hazard 控制。

---

## 第13章 常见 bug、面试问法与练习题

### 13.0 常见 bug

| bug | 表现 | 修复方向 |
|---|---|---|
| forwarding 忘记排除 x0 | 依赖 x0 的指令得到错误值 | 命中条件加 `rd != 0` |
| EX/MEM 与 MEM/WB 优先级反了 | 连续写同一 rd 后读到旧值 | 更近的 EX/MEM 优先 |
| load 当成 ALU 结果前递 | load-use 得到地址而非数据 | load-use stall，load data 到 WB 再前递 |
| IF/ID stall 时 ID/EX 未 bubble | 同一指令重复进入 EX | stall 时插入 bubble |
| branch flush 没清写使能 | 错路径指令写回 | valid bit 屏蔽所有副作用 |
| store data 未前递 | store 写旧数据 | 加 store data forwarding |
| register file 同拍读写语义不一致 | 仿真过，综合后错 | 显式 WB forwarding 或固定宏行为 |
| memory stall 时前级覆盖指令 | 丢指令 | valid-ready 或全局 backpressure |
| flush 与 stall 优先级错 | 跳转后卡死或执行错路径 | 明确优先级并写断言 |
| exception 后 younger 指令提交 | 非精确异常 | exception flush younger instruction |

### 13.1 高频面试问法

#### 问题1：五级流水线每一级做什么

简洁答案：

```text
IF 取指并产生 next PC，ID 译码和读寄存器，EX 做 ALU、分支判断和地址计算，
MEM 访问数据存储器，WB 把结果写回寄存器堆。
```

深入追问：

```text
控制信号要在 ID 生成并跟随指令经过 ID/EX、EX/MEM、MEM/WB。
如果某级 stall 或 flush，数据和控制都必须一起保持或清空。
```

#### 问题2：pipeline 提高了什么

答案要点：

- 主要提高 throughput。
- 理想单发射流水线填满后每 cycle 完成一条指令。
- 单条指令 latency 不一定降低，通常是多个 cycle。
- Fmax 可能提高，因为 critical path 被切短，但 pipeline register 也有开销。

#### 问题3：三类 hazard 是什么

答案要点：

- structural hazard：资源冲突。
- data hazard：数据依赖导致读到旧值。
- control hazard：PC 流向不确定或预测错误。

#### 问题4：forwarding 解决什么问题

简洁答案：

```text
forwarding 把后面 stage 已经产生但还没写回寄存器堆的结果，直接送到前面消费者指令的操作数输入，减少 RAW stall。
```

深入追问：

```text
典型路径有 EX/MEM 到 EX、MEM/WB 到 EX。命中条件要检查 valid、reg_we、rd != x0、rd 等于消费者 rs1/rs2。
如果 EX/MEM 和 MEM/WB 同时命中，应选择更年轻的 EX/MEM。
```

#### 问题5：load-use hazard 为什么 forwarding 不够

答案要点：

- load 的数据通常在 MEM 阶段末尾才从 memory 返回。
- 紧随其后的消费者在同一 cycle 的 EX 阶段早些时候就需要操作数。
- 数据还没产生，无法前递。
- 需要 stall 一拍并插入 bubble，下一拍从 MEM/WB 前递。

#### 问题6：branch taken 时怎么处理

答案要点：

- 如果默认取 `pc + 4`，branch taken 后前面已经取入的顺序指令是错路径。
- branch 在 EX 决策时，需要 redirect PC 到 branch target。
- 同时 flush IF/ID 和 ID/EX 中 younger wrong-path instruction。

#### 问题7：flush 和 stall 同时发生怎么办

答案要点：

- 先明确二者对应的 stage 和指令年龄。
- trap/exception redirect 通常优先级最高，其次 branch redirect，再考虑普通 data stall。
- 错路径 younger instruction 必须被 kill。
- 正确路径上的 older instruction 不能被覆盖。

### 13.2 练习题

#### 练习1：画 load-use 时序

题目：

```text
LW x5, 0(x1)
ADD x6, x5, x2
```

画出需要插入 bubble 后的五级流水线。

答案：

```text
cycle:  1   2   3   4   5   6   7
LW:     IF  ID  EX  MEM WB
ADD:        IF  ID  ID  EX  MEM WB
bubble:             EX
```

#### 练习2：写 forwarding 条件

题目：

```text
EX 阶段指令 rs1 需要前递，写出从 EX/MEM 前递的条件。
```

答案要点：

```text
ex_mem_valid &&
ex_mem_reg_we &&
ex_mem_rd != 0 &&
ex_mem_rd == id_ex_rs1 &&
ex_mem_forward_data 已经可用
```

#### 练习3：判断是否需要 stall

题目：

```text
LW  x0, 0(x1)
ADD x2, x0, x3
```

是否需要 load-use stall？

答案：

不需要。x0 恒为 0，load 写 x0 无效，后续读 x0 应得到 0，不依赖 load 返回数据。

#### 练习4：连续写同一寄存器后读取

题目：

```text
ADD x5, x1, x2
SUB x5, x3, x4
OR  x6, x5, x7
```

OR 应该使用哪个结果？

答案：

OR 应使用 SUB 写入 x5 的结果，因为 SUB 比 ADD 更年轻，且在程序顺序上最后一次写 x5。forwarding 优先级应选择更近的 EX/MEM，而不是 MEM/WB 中更老的 ADD。

#### 练习5：branch flush 副作用

题目：

```text
BEQ x1, x1, target
ADD x5, x2, x3
target:
SUB x6, x4, x7
```

如果 branch 在 EX 才判断，ADD 可能已经进入 pipeline。应该如何处理？

答案要点：

- BEQ 一定 taken。
- ADD 是错路径 younger instruction。
- branch redirect 时应 flush ADD 所在的 IF/ID 或 ID/EX。
- ADD 不能写 x5。

## 第14章 与其他章节的关联

### 14.0 必须回看的章节

- `0801 RISC-V ISA基础.md`：本篇所有 hazard 处理都服务于 ISA 语义，尤其是 x0、立即数、branch/JAL/JALR、load/store 和 exception。
- `0803 CSR、异常中断与特权级.md`：trap、interrupt、CSR 写入和 xRET 都会变成特殊的 flush、redirect 和提交边界问题。
- `0804 RISC-V SoC、MMIO与外设互联.md`：MEM 阶段的 load/store 可能访问 SRAM、cache、MMIO 或慢外设，memory stall 和 bus error 会反向影响 pipeline 控制。
- `0805 Cache、TLB、MMU、分支预测与内存模型.md`：I-cache/D-cache miss、TLB miss、branch prediction 和 FENCE 会把简单五级流水线扩展成更真实的处理器前端/访存系统。
- `0806 高级微架构基础：乱序、ROB与执行后端.md`：乱序核仍然保留本篇的核心问题，但用 rename、ROB、IQ、LSQ 等结构处理更复杂的 hazard。

### 14.1 和基础专题的关系

- `030x` 流水线与握手：valid、ready、stall、bubble、flush 是通用 pipeline 控制，不只用于 CPU。
- `040x` 运算数据通路：EX 阶段的 ALU、branch comparator、乘除法单元会直接影响 forwarding 和多周期 stall。
- `060x` 存储器/cache：MEM 阶段的 SRAM、cache、byte enable、load 扩展会决定 load-use 和 memory stall 行为。
- `100x` 验证专题：五级流水线必须用 directed test、random test、ISS 比对、SVA 和 coverage 形成闭环。
- `130x` STA 专题：ID decode、forwarding MUX、branch redirect、load-use detection 都可能成为时序热点。

### 14.2 学习路径建议

本篇是从 ISA 走向 CPU 微架构的第一步。推荐按下面路径复习：

```text
先用 0801 明确每条指令最终应该改变什么
再用 0802 理解重叠执行为什么会出错、如何修正
然后用 0803/0804/0805 补齐 trap、SoC、cache/TLB/预测
最后用 0806 理解乱序核如何把同样问题推广到更大窗口
```

如果面试项目是五级流水线核，至少要能把本篇的 forwarding、load-use、branch flush、valid side effect gating 和 commit trace 讲成一个完整闭环。

## 第15章 从这里开始上手一个 RISC-V 最小教学核

看到这里，已经可以开始做一个 RISC-V 教学核项目了。更准确地说：如果目标是“用项目把 0801 和 0802 的知识落到 RTL”，现在就应该开始；如果目标是一上来就做能跑 OS、带 cache、带 MMU、带中断控制器的 SoC，那还需要继续学 0803～0805。

如果准备把本章内容真正落成一个 RV32I 最小教学核项目，具体设计流程、实现路线和后续分册规划可以继续阅读 `0820 RISC-V最小教学核设计流程与方案.md` 及 `082x` 系列文档。

教学核第一版不要追求“像真实商业 CPU 一样完整”，而要追求“边界清楚、能跑程序、能验证、能讲清每个 hazard 为什么这样处理”。推荐的第一版目标如下：

| 维度 | 第一版建议 | 为什么这样定 |
|---|---|---|
| ISA 范围 | RV32I 基础整数指令，先不做 M/C/A/F/D 扩展 | RV32I 已经覆盖译码、GPR、ALU、branch、JAL/JALR、load/store 和 x0，足够训练 CPU 主干 |
| 微架构 | 单发射、顺序执行、经典五级流水线 | 与本文内容直接对应，面试也容易讲清楚 |
| hart 数量 | 单 hart | 避免一开始引入多核一致性、原子操作和跨核中断 |
| 存储系统 | 分离 instruction memory 和 data memory，先用 1 cycle SRAM 模型 | 先绕开 cache miss、总线等待和 MMIO 慢响应，把 pipeline hazard 练扎实 |
| privilege/CSR | 第一版可以不实现 CSR、trap、interrupt | 最小教学核可以先只跑裸机测试；0803 的内容放到第二阶段 |
| SoC/外设 | 第一版不接复杂总线，只保留简单 imem/dmem 接口 | 0804 的 MMIO、bridge、UART、timer 可以等核心稳定后再加 |
| cache/MMU | 第一版不做 cache、TLB、MMU | 0805 是真实 CPU/SoC 绕不开的内容，但不是第一个教学核的启动条件 |
| 软件形态 | 裸机汇编或很小的 C 程序 | 不依赖 OS，不需要系统调用、页表和中断返回 |

这里的“最小”不是只能做玩具。一个设计干净的 RV32I 五级流水线核，已经能体现数字 IC 岗位非常看重的能力：能从 ISA 语义拆出 datapath，能写可综合 RTL，能处理 stall/flush/forwarding，能用 directed test 和 reference model 验证，能从波形解释 bug。

建议把项目分成下面几个里程碑，而不是一口气写完整 CPU。

| 阶段 | 目标 | 关键验收点 |
|---|---|---|
| 0. 搭环境 | 能编译 RTL、加载指令 memory、看波形、打印 commit trace | 仿真能跑一个 `ADDI; ADD; SW` 级别的小程序 |
| 1. 单周期或非流水骨架 | 先把 RV32I 指令语义跑通，作为后续流水线的对照 | x0 不变、立即数正确、ALU/branch/load/store 基本正确 |
| 2. 五级流水空壳 | 建 IF/ID/EX/MEM/WB pipeline register 和 valid bit | 指令能按五级流动，bubble 不产生写寄存器和写 memory 副作用 |
| 3. 完整基本数据通路 | 接好 decoder、regfile、imm_gen、ALU、LSU、writeback | 不考虑复杂相关时，顺序程序结果正确 |
| 4. data hazard | 加 EX/MEM、MEM/WB 到 EX 的 forwarding | 连续 `ADD`、`SUB`、`OR` 这类 ALU 相关不需要 stall |
| 5. load-use hazard | 加 load-use 检测和 bubble 插入 | `LW` 后紧跟使用者时结果正确，且只停必要的拍数 |
| 6. control hazard | 加 branch/JAL/JALR redirect 和 flush/kill | taken branch 后错路径指令不能写 GPR，也不能真的 store |
| 7. 验证收敛 | directed test、随机指令、commit trace 比对、基础断言 | 能定位“第几条提交指令”开始和参考模型不一致 |
| 8. 第二阶段扩展 | 再考虑 CSR/trap、MMIO timer/UART、总线或 cache | 每加一类系统功能，都有明确的测试和回归入口 |

如果你担心“一上来写五级流水线太复杂”，可以先写一个非常小的单周期 RV32I 核作为 golden model。它不一定用于最终综合，只用于帮助你确认 decode、immediate、ALU、load/store 扩展和 branch target 是否正确。等单周期版本能跑通一批基础测试，再把同样的 ISA 语义搬到五级流水线里。这样做的好处是：遇到错误时，你能区分“指令语义本身错了”还是“流水线控制错了”。

一个比较清晰的最小模块拆分可以是：

| 模块 | 主要职责 |
|---|---|
| `core_top` | 连接各 stage、imem/dmem 接口、全局 stall/flush 控制 |
| `if_stage` | 保存 PC，发起取指，计算默认 `PC+4` |
| `id_stage` | decode、读 GPR、生成 immediate 和控制信号 |
| `ex_stage` | ALU、branch compare、branch/JAL/JALR target 计算 |
| `mem_stage` | load/store 请求、byte enable、load 数据符号/零扩展 |
| `wb_stage` | 选择 ALU/load/`PC+4` 写回数据 |
| `regfile` | 32 个 GPR，保证 x0 恒为 0 |
| `decoder` / `imm_gen` | 从 instruction 生成类型、控制信号和立即数 |
| `forwarding_unit` | 根据 `rs1/rs2`、后级 `rd`、后级 write enable 选择前递数据 |
| `hazard_unit` | 检测 load-use、memory stall、flush 优先级 |
| `pipe_reg_*` | 保存每级之间的数据、控制信号、valid 和异常/调试信息 |
| `simple_rom` / `imem` | 第一版 instruction memory 模型，仿真时由 `$readmemh` 初始化，CPU 只读 |
| `simple_ram` / `dmem` | 第一版 data memory 模型，支持 load 读和 store 按 byte enable 写 |
| `commit_trace` | 仿真时打印提交 PC、instruction、rd、wdata，便于和参考模型比对 |

代码量只能粗略估计，因为风格差异很大，但可以用下面范围建立预期：

| 项目形态 | 大致 RTL 代码量 | 说明 |
|---|---:|---|
| 极简单周期 RV32I | 约 600～1200 行 | 适合作为语义验证起点，不体现 pipeline hazard |
| 干净的五级流水 RV32I 核 | 约 1500～3000 行 | 不含 CSR/cache/MMU/复杂总线，包含 forwarding、load-use、flush |
| testbench、memory model、脚本、测试程序 | 约 800～2500 行 | 项目能不能讲清楚，很大程度取决于这部分是否扎实 |
| 加最小 CSR/trap/MMIO | 额外约 500～1500 行 | 进入 0803、0804 的范围，建议核心稳定后再做 |
| 加 cache/MMU/分支预测 | 额外代码量变化很大 | 已经不是“最小教学核”，应作为后续专题项目 |

不要把行数当成目标。一个 2000 行左右但边界清楚、测试充分、波形能解释的核，比一个复制了很多功能但自己讲不清控制路径的核更适合作为学习和面试项目。

开源项目可以参考，但建议“先自己写，再对照看”，不要一开始照着抄。几个参考方向如下：

| 参考项目 | 适合看什么 | 不建议怎么用 |
|---|---|---|
| [PicoRV32](https://github.com/YosysHQ/picorv32) | 小型 RISC-V 核、可配置 RV32I/RV32IMC、测试和简单 SoC 组织方式 | 它不是经典五级流水线，不适合直接照搬 stage 划分 |
| [Ibex](https://github.com/lowRISC/ibex) | 工程化小核、异常/CSR、验证组织、代码质量 | 对第一版教学核来说复杂度偏高，不要一开始追它的完整性 |
| [riscv-sodor](https://github.com/ucb-bar/riscv-sodor) | 教学微架构、1/2/3/5 级流水思路 | 多数内容不是 SystemVerilog 风格，重点看结构思想 |
| [riscv-tests](https://github.com/riscv-software-src/riscv-tests) | 基础 ISA 汇编测试用例 | 一开始不要直接追全量通过，先挑 `rv32ui` 中简单用例逐步接入 |
| [riscv-arch-test](https://github.com/riscv/riscv-arch-test) | 架构符合性测试方向 | 更适合后期规范化验证，前期仍应先写自己的 directed test |

一个实际可执行的上手顺序可以是：

1. 自己画一张五级流水线数据通路图，把每个 stage 的输入、输出、pipeline register 字段列出来。
2. 先实现 `LUI/AUIPC/ADDI/ADD/SUB/AND/OR/XOR/SLL/SRL/SRA` 这类不访存、不跳转的指令。
3. 加 `LW/SW/LB/LH/LBU/LHU/SB/SH`，重点验证 byte enable 和 load 扩展。
4. 加 `BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR`，重点验证 target、`PC+4` 写回和 flush。
5. 加 forwarding，再用连续相关指令打穿 EX/MEM、MEM/WB 两条前递路径。
6. 加 load-use stall，明确控制动作是“冻结 PC 和 IF/ID，向 ID/EX 插入 bubble”。
7. 加 commit trace，与一个简单 reference model 或 ISS 输出对比。
8. 最后再接入更系统的测试集，并整理项目文档：支持哪些指令、不支持哪些异常、memory 假设是什么、hazard 怎么处理、验证覆盖了哪些场景。

教学核写好以后，“跑程序”并不是 testbench 代替 CPU 执行程序。testbench 只是在仿真环境里扮演板子和存储器：提供 clock/reset，把程序机器码放进 instruction memory，必要时检查 data memory、commit trace 或某个 pass/fail 地址。真正执行程序的是 CPU 核自己。

为了跑通这个闭环，环境里至少需要下面几类工具：

| 工具类别 | 常用命令 | 作用 | 当前阶段是否必须 |
|---|---|---|---|
| RTL 仿真器 | `verilator` 或 `iverilog/vvp` | 编译并运行 SystemVerilog testbench | 必须 |
| 综合/可综合性检查 | `yosys` | 检查 RTL 是否能综合，早期发现 latch、不可综合写法等问题 | 建议 |
| RISC-V 交叉编译器 | `riscv64-unknown-elf-gcc` | 把裸机汇编/C 编译、汇编、链接成 RISC-V ELF | 必须 |
| binutils 工具 | `objcopy`、`objdump`、`readelf` | ELF 转 `.mem/.hex`，反汇编，看 ELF 入口和段信息 | 必须 |
| 波形工具 | `gtkwave` 或仿真器自带波形查看器 | 看 PC、valid、stall、flush、forwarding、GPR 写回 | 强烈建议 |
| reference model/ISS | Spike、Sail、简单自写模型等 | 后期做 commit trace 比对 | 后期建议 |

完整流程可以理解为：

```text
裸机汇编/C 程序
    ↓ 交叉编译/汇编/链接
ELF 或 bin/hex/mem 机器码文件
    ↓ testbench 用 $readmemh 等方式加载到 instruction memory
CPU reset，PC 指向 reset vector
    ↓ IF 按 PC 取指，ID/EX/MEM/WB 执行
程序写寄存器、写 data memory、跳转或进入结束循环
    ↓
testbench 判断 pass/fail 或在超时后停止仿真
```

第一阶段通常跑的是 bare-metal 裸机程序，也就是没有 OS、没有进程、没有系统调用的一段固定代码。每次仿真前换一份 instruction memory 初始化文件，CPU 就执行另一段程序。一个最小汇编测试可以长这样：

```asm
.section .text
.global _start

_start:
    addi x1, x0, 3
    addi x2, x0, 4
    add  x3, x1, x2
    sw   x3, 0(x0)

done:
    jal  x0, done
```

这段程序没有 `return` 给 OS，因为根本没有 OS。它做完计算后进入死循环，testbench 可以在若干 cycle 后检查 data memory 地址 0 是否为 7。也可以约定某个特殊地址，例如 `32'h0000_1000` 是 `tohost` 地址：程序向它写 1 表示 pass，写其他值表示 fail。这个地址在第一版仿真里不一定是真外设，可以只是 testbench 或 memory model 观察的一个约定。

常见的仿真接法如下：

| 环节 | 谁负责 | 做什么 |
|---|---|---|
| 写程序 | 人或测试脚本 | 写 `.S` 汇编，后期也可以写很小的 `.c` |
| 生成机器码 | RISC-V 工具链 | 按 `-march=rv32i -mabi=ilp32` 编译/汇编/链接，导出 `.mem` 或 `.hex` |
| 加载程序 | testbench | 用 `$readmemh("test.mem", imem.mem)` 初始化 instruction memory |
| 执行程序 | CPU RTL | 从 reset PC 取指，按 ISA 语义修改 GPR、PC 和 data memory |
| 判断结果 | testbench | 检查 memory、寄存器写回 trace、`tohost` 地址或超时 |
| debug | 人和脚本 | 看 waveform、commit trace、reference model mismatch |

一个非常简化的 testbench 片段可以是：

```systemverilog
initial begin
    $readmemh("test.mem", u_imem.mem);
end

initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    repeat (200) @(posedge clk);

    if (u_dmem.mem[0] == 32'd7) begin
        $display("PASS");
    end else begin
        $display("FAIL: mem[0] = %h", u_dmem.mem[0]);
    end
    $finish;
end
```

这段 testbench 不可综合，只用于仿真。`$readmemh`、`$display`、`$finish` 都是仿真任务，不会变成硬件。真正可综合的部分是 CPU、register file、ALU、pipeline register、hazard/forwarding 控制，以及如果需要上板则替换成 FPGA block RAM 或 SRAM wrapper 的 memory 接口。

这里还要区分教学核里的 ROM 和 RAM 怎么实现。第一版常把 instruction memory 写成 `simple_rom` 或 `imem`，名字叫 ROM 是因为 CPU 执行期间只从里面取指，不通过 store 去改它；但在仿真开始前，testbench 仍然可以用 `$readmemh` 把程序内容灌进去。这个“初始化”是仿真/加载行为，不等于 CPU 正在写 ROM。data memory 则通常写成 `simple_ram` 或 `dmem`，因为 CPU 的 `LW/LH/LB` 要读它，`SW/SH/SB` 要改它。

一个最小 instruction memory 可以是异步读模型，方便入门理解：

```systemverilog
module simple_rom #(
    parameter int AW = 12
) (
    input  logic [31:0] addr_i,
    output logic [31:0] rdata_o
);
    logic [31:0] mem [0:(1 << AW)-1];

    initial begin
        $readmemh("test.mem", mem);      // 仿真初始化，不是可综合 CPU 写 ROM
    end

    assign rdata_o = mem[addr_i[AW+1:2]]; // 32-bit 指令，按 word 取址
endmodule
```

这个写法适合仿真教学，但不同综合工具对 `initial + $readmemh` 的可综合支持不同。FPGA 上经常会把它综合成初始化过的 block RAM 或 distributed ROM；ASIC 里一般不会靠 RTL 的 `initial` 生成真实 ROM，而是接工艺库 ROM macro、SRAM macro，或者由 boot ROM/外部加载链路在系统启动时提供指令。

一个最小 data memory 要支持 byte enable，因为 RV32I 有 `SB/SH/SW`：

```systemverilog
module simple_ram #(
    parameter int AW = 12
) (
    input  logic        clk_i,
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o
);
    logic [31:0] mem [0:(1 << AW)-1];

    wire [AW-1:0] word_addr = addr_i[AW+1:2];

    assign rdata_o = mem[word_addr];      // 简化成组合读，便于第一版流水线学习

    always_ff @(posedge clk_i) begin
        if (we_i) begin
            if (be_i[0]) mem[word_addr][ 7: 0] <= wdata_i[ 7: 0];
            if (be_i[1]) mem[word_addr][15: 8] <= wdata_i[15: 8];
            if (be_i[2]) mem[word_addr][23:16] <= wdata_i[23:16];
            if (be_i[3]) mem[word_addr][31:24] <= wdata_i[31:24];
        end
    end
endmodule
```

这两个 memory model 是为了让教学核先跑起来，不代表真实芯片里一定长这样。真实 SoC 里，指令可能来自 boot ROM、flash、SRAM、I-cache 或总线；数据可能来自 SRAM、D-cache、DRAM 或 MMIO 外设。第一版先把 imem/dmem 固定成简单、1 cycle、无等待的模型，是为了把注意力集中在五级流水线本身。等核心稳定后，再把固定 memory 端口替换成 valid-ready SRAM 接口、总线接口或 cache 接口，就会进入 0804 和 0805 的范围。

如果换成 FPGA 或真实 SoC，testbench 的角色会被真实硬件启动链替代：

```text
仿真阶段：testbench 加载 test.mem 到 imem
FPGA 阶段：bitstream 初始化 block RAM，或 UART/JTAG/bootloader 把程序写进 SRAM
SoC 阶段：CPU 从 boot ROM reset vector 开始，bootloader 再搬运或加载更大的程序
```

所以，第一版教学核可以先理解成“每次仿真执行一段固定裸机程序”。等后面加入 0803 的 CSR/trap、0804 的 MMIO/UART/timer、0805 的 cache/MMU 后，才会逐步接近能运行 runtime、RTOS 甚至更复杂软件栈的系统。

这个项目的第一版最好从头写。原因不是开源项目不好，而是教学核的价值在于你亲手处理那些会让 CPU 出错的细节：x0 写屏蔽、立即数拼接、load-use 停顿、branch flush、store 副作用屏蔽、JALR 前递、register file 写读同拍语义。等自己版本跑起来，再看开源项目，你会更容易看懂别人为什么那样拆模块、为什么控制信号要那样命名、为什么验证环境比 RTL 还复杂。

因此，本阶段的路线可以概括成一句话：**0801 负责告诉你每条指令“最终应该发生什么”，0802 负责告诉你多条指令重叠执行时“怎样仍然只发生这些事”，而教学核项目就是把这两件事写成 RTL 并用测试证明。**

## 第16章 本篇总结

五级流水线的核心不是背五个 stage，而是理解“重叠执行如何保持 ISA 语义不变”：

- pipeline 提高 throughput，但引入 hazard。
- structural hazard 来自资源冲突。
- data hazard 主要靠 forwarding，load-use 需要 stall。
- control hazard 需要预测、redirect 和 flush。
- valid bit 是防止错路径或空槽产生副作用的关键。
- stall、bubble、flush 的优先级必须明确。
- 验证要用 directed test、random test、SVA、coverage 和 ISS/reference model 形成闭环。

能把这些讲清楚，RISC-V 五级流水线就不再是口号，而是可以真正落到 RTL 和验证计划的工程结构。
