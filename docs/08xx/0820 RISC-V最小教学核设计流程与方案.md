# 0820 RISC-V 最小教学核设计流程与方案

> 文档编号：0820  
> 所属部分：08 处理器架构、RISC-V 与 CPU 微架构  
> 文档定位：RISC-V 最小教学核项目实践总纲  
> 前置文档：`0801 RISC-V ISA基础.md`、`0802 RISC-V五级流水线与Hazard.md`  
> 建议读者：已经理解 RV32I 基础指令语义、五级流水线、forwarding、stall、flush，并希望把这些内容落成一个可仿真、可验证、可讲清楚的 RTL 项目。

本篇不是又一篇“CPU 原理概念文档”，而是把 `0801` 和 `0802` 里的知识组织成一个可以动手实现的项目方案。它回答的问题是：

1. 最小教学核第一版到底做什么，不做什么。
2. 为什么建议先从 RV32I、单 hart、顺序五级流水线开始。
3. 从空目录到能跑裸机汇编程序，应该按什么顺序推进。
4. 哪些内容放在本篇讲思路，哪些内容拆到后续 `082x` 文档作为参考手册。
5. 这个项目做到什么程度，才适合作为学习成果和面试项目来讲。

本篇和后续 `082x` 系列属于“项目实践文档”。按照本项目规划，`0820` 会写得相对详细，重点讲设计取舍、阶段路线和项目思维；`0821`～`0829` 主要写成参考手册，方便实现时查表、查接口、查控制条件，不强制套用常规专题文档模板。

## 第0章 本系列文档的定位与写作规则

### 0.1 为什么需要单独的 0820 系列

`0801` 解决的是“每条指令在架构上应该发生什么”。例如 `ADD` 要把两个 GPR 读出来相加，结果写回 `rd`；`LW` 要从地址 `rs1 + imm` 读 memory；`BEQ` 要比较两个寄存器，相等时修改 PC。

`0802` 解决的是“多条指令重叠执行时，怎样仍然保持这些架构语义不变”。例如：

- 后一条指令需要前一条指令的结果时，要 forwarding 还是 stall。
- branch 已经跳转时，旧路径上已经取进来的指令要 flush/kill。
- load 的数据还没从 memory 回来时，不能假装 ALU 已经算出了结果。
- bubble 和错路径指令不能产生 GPR 写回、memory 写入等副作用。

但是，从“我懂这些原理”到“我能写出一个能跑程序的核”，中间还有一层工程组织问题：

- 文件怎么拆。
- 模块接口怎么定。
- 第一版到底支持哪些指令。
- 先写单周期还是直接写流水线。
- memory 怎么建模。
- 程序怎么放进 instruction memory。
- 仿真结束条件怎么定义。
- 怎么知道 bug 是 decode 错、immediate 错、forwarding 错，还是 flush 错。

这些问题不完全属于 `0801` 或 `0802` 的原理章节，却是做教学核项目时最容易卡住的地方。因此 `0820` 系列单独承担“项目路线与实现手册”的角色。

### 0.2 0820 与 0821～0829 的分工

`0820` 是总纲，重点讲“为什么这样做”和“按什么顺序做”。它允许篇幅长一些，因为第一次从文档学习切到项目实现，最重要的是建立正确路线。

`0821`～`0829` 是分册，重点讲“实现时查什么”。这些文档不追求每篇都写成完整专题，而更接近工程参考书：表格、接口定义、控制条件、测试清单、脚本示例、波形 debug 线索会比大段概念更重要。

建议规划如下：

| 编号 | 建议文档名 | 主要作用 | 写作风格 |
|---|---|---|---|
| `0820` | `RISC-V最小教学核设计流程与方案` | 总纲，定义项目范围、路线、分册边界和阶段验收 | 讲思路，篇幅较长 |
| `0821` | `RV32I最小教学核指令集、编码与译码参考` | 汇总第一版支持的指令、格式、立即数、控制信号 | 表格为主，可查阅 |
| `0822` | `最小教学核工程目录、顶层接口与命名约定` | 定义文件结构、模块边界、端口命名和公共类型 | 规范手册 |
| `0823` | `从单周期语义模型到五级流水线` | 说明为什么可以先做非流水版本，再演进到五级流水 | 步骤说明 |
| `0824` | `数据通路、流水线寄存器与控制信号参考` | 展开每级保存哪些字段、哪些控制信号随指令流动 | 接口/字段表 |
| `0825` | `Hazard控制：forwarding、stall、flush与kill` | 专门给出相关判断、优先级、bubble 插入和错路径屏蔽方案 | 控制条件手册 |
| `0826` | `裸机程序、ROM与RAM加载与工具链使用示例` | 讲汇编/C 程序如何变成 memory image，以及仿真如何加载 | 命令和流程示例 |
| `0827` | `Testbench、commit trace与测试集组织` | 讲 directed test、scoreboard、参考模型、pass/fail 机制 | 验证手册 |
| `0828` | `波形debug、常见bug与定位清单` | 汇总常见错误现象、可能原因、应观察的信号 | debug checklist |
| `0829` | `综合、FPGA上板与SoC扩展方向` | 讲 Yosys/FPGA/总线/MMIO/CSR/cache 的后续扩展入口 | 工程延伸 |

这个划分不是为了把文档数量堆满，而是为了保持职责清楚。后续如果某个分册暂时用不到，可以先不写；如果实际项目中发现某一块内容很大，也可以继续拆分。

### 0.3 082x 系列的显式写作规范

本系列是 `AGENTS.md` 默认专题模板的例外。后续 `0820`～`0829` 按下面规则写：

| 项目 | 规定 |
|---|---|
| 术语表 | 不强制添加 `术语首次出现说明`，除非某篇分册引入大量全新系统术语，且术语表确实有助于阅读 |
| 固定框架 | 不强制套用“第0章学习地图、概念、结构、RTL、验证、面试题”的专题模板 |
| 文档目标 | 以“项目实现时能直接查阅”为优先，而不是面面俱到地讲完整理论 |
| 讲解深度 | 必要处讲背景和设计取舍；纯参考表、命令、接口、checklist 不强行扩写 |
| 篇幅 | `0820` 可以较长；`0821`～`0829` 原则上精炼，够用即可 |
| 代码风格 | RTL 仍默认使用 SystemVerilog，保持 `logic`、`always_ff`、`always_comb` 风格 |
| 公式 | 若出现位宽、地址、偏移、性能等计算，仍使用 LaTeX |
| 命名 | 模块名、信号名、stage 名、控制信号含义应在 `082x` 系列内保持一致 |
| 工具命令 | 具体编译、objdump、objcopy、仿真命令集中放到 `0826`，不要散落到每篇文档 |
| 交叉引用 | 每篇开头说明它解决项目中的哪一类问题，结尾指出相关 `08xx` 和 `082x` 文档 |
| 项目假设 | 如果某篇依赖“1 cycle imem/dmem”“不支持 CSR”“不支持 wait state”等前提，必须明确写出 |
| 术语新增 | 非必要不机械补充术语表；只有新增明显新话题且术语密集时才单独处理 |

这个规则的目的不是降低质量，而是让项目手册更像项目手册。实现 CPU 时最需要的是边界、表格、接口、控制条件和可验证路径；如果每篇都写成完整理论专题，反而会降低查阅效率。

## 第1章 最小教学核到底是什么

### 1.1 “最小”不是功能越少越好

这里的“最小教学核”不是只会执行一两条指令的玩具，也不是商业 CPU 的缩小版。它的目标是：用尽量少的系统复杂度，把 CPU 设计中最核心、最能训练 RTL 能力的主干跑通。

一个合格的第一版教学核应该能体现这些能力：

| 能力 | 在教学核中的体现 |
|---|---|
| ISA 到硬件的映射 | 能把 RV32I 指令拆成 decode、立即数、ALU、GPR、memory、PC 更新 |
| 流水线时序 | 能让多条指令在 IF/ID/EX/MEM/WB 中重叠流动 |
| 数据相关处理 | 能处理 EX/MEM、MEM/WB forwarding 和 load-use stall |
| 控制流处理 | 能处理 branch/JAL/JALR redirect 和错路径 flush/kill |
| 副作用控制 | bubble、invalid、wrong-path 指令不能写 GPR，也不能写 memory |
| 验证闭环 | 能用 directed test、commit trace、波形和参考结果定位错误 |
| 工程表达 | 能清楚说明支持什么、不支持什么、为什么这样拆模块 |

所以，“最小”的真正含义是：第一版只保留能训练 CPU 主干能力的部分，把 OS、cache、MMU、复杂总线、多核一致性这类系统复杂度先拿掉。

### 1.2 第一版建议边界

第一版推荐边界如下：

| 维度 | 第一版建议 | 说明 |
|---|---|---|
| ISA | RV32I 可执行子集 | 支持整数计算、load/store、branch、JAL/JALR、LUI/AUIPC；系统类指令先不作为主线 |
| 数据宽度 | 32 bit | 与 RV32I 对应，GPR、ALU、PC、memory data 都先用 32 bit |
| hart | 单 hart | 不引入多核、原子操作、多核中断和 cache 一致性 |
| 发射方式 | 单发射 | 每周期最多让一条新指令进入流水线 |
| 执行方式 | 顺序五级流水线 | IF、ID、EX、MEM、WB，按程序顺序提交 |
| memory | 分离 imem/dmem | 先避免取指和访存抢同一个单端口 memory |
| memory 时延 | 第一版固定 1 cycle 或组合读教学模型 | 先不处理 wait state、bus ready、cache miss |
| privilege | 不实现 privilege mode | 第一版不跑 OS，不做异常返回 |
| CSR/trap/interrupt | 暂不实现或只保留仿真停止约定 | 0803 的内容放第二阶段 |
| cache/MMU | 不实现 | 0805 是后续扩展，不是第一版启动条件 |
| 外设/总线 | 不接 APB/AXI/AHB | 0804 的 MMIO、timer、UART 后续再接 |
| 软件形态 | 裸机汇编为主，小 C 程序为辅 | 不依赖 libc、系统调用、进程、页表 |

这里有一个容易混淆的点：如果第一版不做 `ECALL/EBREAK/trap/CSR`，就不要在文档里声称“完整支持 RV32I 架构测试”。更准确的说法是：第一版支持 RV32I 中用于教学核主干验证的可执行子集，等后续加入 CSR/trap 后，再朝更完整的架构兼容方向推进。

例如：

- `FENCE` 第一版可以暂时按 NOP 处理，前提是测试程序不依赖真实内存顺序设备语义。
- `ECALL/EBREAK` 第一版可以不支持，也可以在仿真里约定为停止指令，但这不是完整 trap 语义。
- 未实现指令第一版可以在仿真中报错或进入非法状态，但如果要做规范异常，就进入 `0803` 的范围。

### 1.3 第一版不做什么

第一版明确不做下面这些内容：

| 暂不做的内容 | 为什么暂不做 |
|---|---|
| M 扩展乘除法 | 会引入多周期 MDU、结构冲突、结果返回时序；可以作为流水线稳定后的扩展 |
| C 压缩指令 | 会改变取指对齐、PC 增量、解码前端复杂度 |
| A 原子扩展 | 单 hart 教学核没有必要一开始做 LR/SC/AMO |
| F/D 浮点扩展 | 会引入浮点寄存器堆、舍入、异常标志和复杂数据通路 |
| CSR 完整读写 | 需要理解特权规范、CSR 指令副作用、异常入口 |
| 外部中断 | 需要中断控制器、优先级、屏蔽位、handler 返回 |
| cache/TLB/MMU | 会把问题从流水线主干扩展到存储层级和地址转换 |
| AXI/APB 总线 | 需要 ready/valid、响应、地址译码和外设协议 |
| OS/RTOS | 需要 trap、timer、栈、链接脚本、启动代码和运行时支持 |

这些内容不是不重要，而是不应该抢在第一版教学核之前。第一版的价值在于把“能取指、能执行、能处理 hazard、能验证”这条主线走通。

## 第2章 从 0801/0802 到 RTL 项目的思维转换

### 2.1 ISA 语义是项目的第一张合同

写 CPU 最容易犯的错误，是一上来先画流水线、先写 stage，然后再去想每条指令应该怎么执行。更稳的顺序是反过来：先把 ISA 语义当成合同。

例如 `ADD x3, x1, x2` 的合同是：

| 项目 | 合同内容 |
|---|---|
| 读 | 从 GPR 读 `x1` 和 `x2` |
| 算 | 把两个 32 bit 值相加，忽略溢出异常 |
| 写 | 把低 32 bit 结果写入 `x3` |
| PC | 正常情况下下一条为 `PC + 4` |
| x0 | 如果 `rd = x0`，结果必须丢弃 |

流水线实现可以有 forwarding、stall、flush、bubble，但最终提交到架构状态的效果必须和这份合同一致。

这里的“架构状态”主要包括：

| 架构状态 | 第一版教学核中的含义 |
|---|---|
| PC | 当前程序执行位置，控制下一条取指 |
| GPR | 32 个通用寄存器，`x0` 恒为 0 |
| data memory | load/store 可见的数据存储 |

第一版没有 CSR、异常状态、特权级状态，所以架构状态比较少。等后续加入 `mepc/mcause/mstatus` 等 CSR 后，架构状态会变多，验证也会更复杂。

### 2.2 微架构是实现合同的方法

ISA 只规定“结果应该是什么”，不规定“硬件内部怎么做”。五级流水线就是一种微架构选择。

同一条 `ADD`，可以这样实现：

| 实现方式 | 行为 |
|---|---|
| 单周期核 | 一拍内取指、译码、读寄存器、ALU、写回全部完成 |
| 多周期核 | 多拍复用硬件资源，状态机控制每一步 |
| 五级流水线核 | IF/ID/EX/MEM/WB 重叠执行，提高吞吐 |
| 乱序核 | 指令可乱序执行，但最终按程序顺序提交 |

教学核选择五级流水线，不是因为它最先进，而是因为它刚好把 CPU 设计中最核心的矛盾暴露出来：

- 指令重叠执行带来 throughput。
- 重叠执行导致 data/control/structural hazard。
- hazard 处理必须保证 ISA 语义不被破坏。
- 控制信号必须跟着指令流过 pipeline register。
- valid bit 必须决定这一级是否允许产生副作用。

所以，写教学核时要不断问自己一个问题：这个 RTL 细节是在保证哪条 ISA 合同不被流水线破坏？

### 2.3 项目不要从“完整 CPU”开始

更实际的路线是先做一个能闭环的最小系统：

```text
testbench
    ├── clock/reset
    ├── instruction memory 初始化
    ├── data memory 观察
    └── pass/fail 判断

core_top
    ├── IF/ID/EX/MEM/WB
    ├── GPR
    ├── ALU
    ├── hazard/forwarding/flush
    └── imem/dmem 简单接口
```

第一阶段程序也不要一上来写复杂 C。先用非常短的裸机汇编，例如：

```asm
addi x1, x0, 3
addi x2, x0, 4
add  x3, x1, x2
sw   x3, 0(x0)
```

只要这几条能正确取指、执行、写 memory，项目就已经有了闭环。之后每加一类指令、每加一种 hazard 处理，都可以在这个闭环里验证。

## 第3章 总体实现路线

### 3.1 推荐里程碑

建议按下面顺序推进：

| 阶段 | 目标 | 关键产物 | 验收点 | 对应分册 |
|---|---|---|---|---|
| 0 | 明确项目边界 | 支持范围、不支持范围、目录草图 | 能说清第一版为什么不做 CSR/cache/OS | `0820`、`0822` |
| 1 | 建立指令语义表 | 指令清单、imm 规则、控制信号草表 | 每条支持指令知道读谁、算什么、写哪里 | `0821` |
| 2 | 跑通最小仿真闭环 | TB、imem/dmem、最短汇编程序 | 仿真能结束并判断 pass/fail | `0826`、`0827` |
| 3 | 写非流水语义模型 | 单周期或顺序执行 core | 基础 ALU/load/store/branch 程序正确 | `0823` |
| 4 | 搭五级流水空壳 | pipeline register、valid bit | 指令能按 stage 流动，bubble 无副作用 | `0824` |
| 5 | 接完整数据通路 | decoder、GPR、ALU、LSU、WB | 无相关顺序程序能跑通 | `0824` |
| 6 | 加 data hazard 处理 | forwarding、load-use stall | 相关指令测试通过 | `0825` |
| 7 | 加 control hazard 处理 | branch/JAL/JALR redirect、flush/kill | taken branch 错路径无写回和 store | `0825` |
| 8 | 加强验证 | directed test、trace、断言、回归脚本 | bug 能定位到指令编号和 stage | `0827`、`0828` |
| 9 | 工程化扩展 | 综合、FPGA、MMIO、CSR、cache 方向 | 知道下一阶段如何接 0803～0805 | `0829` |

不要把这些阶段理解成严格瀑布流程。实际写代码时，经常会来回调整。例如第 5 阶段发现控制信号设计太乱，可能要回到第 1 阶段重新整理译码表；第 7 阶段发现 flush 优先级影响 load-use stall，也可能要回到第 6 阶段重构 hazard unit。

### 3.2 每个阶段都要有可观察结果

教学核项目最忌讳“写了很多代码，但不知道哪里错了”。每个阶段都要设计一个可以观察的验收点。

| 阶段 | 不好的验收方式 | 更好的验收方式 |
|---|---|---|
| 写 decoder | 看起来 case 都写了 | 每条指令跑一个 directed test，trace 中控制信号符合预期 |
| 写 GPR | 仿真没报错 | 专门测试 x0 写屏蔽、同拍写读、不同寄存器读写 |
| 写 branch | PC 好像跳了 | taken/not-taken、正负 offset、边界目标、错路径 store 都测试 |
| 写 forwarding | 连续 ADD 过了 | EX/MEM、MEM/WB、rs1/rs2、rd=x0、load 后继使用分别覆盖 |
| 写 load-use stall | 程序结果对 | 确认只停必要拍数，bubble 不写回，下一拍能前递 load data |
| 写 flush | 跳转结果对 | 确认被 kill 的指令不会写 GPR，不会写 dmem，不会打印 commit |

能观察，才能 debug；能 debug，项目才会继续向前。

### 3.3 先做“可跑通”，再做“更真实”

第一版可以使用很多教学简化：

- imem 组合读。
- dmem 组合读、同步写。
- load 数据下一拍就能用于 forwarding。
- branch 在 EX 决策。
- 不支持 memory wait。
- 不支持异常。

这些简化不是偷懒，而是为了把最核心的流水线控制先练清楚。后续如果要更接近真实硬件，可以逐步替换：

| 教学简化 | 后续真实化方向 |
|---|---|
| imem 组合读 | 同步 SRAM、取指 ready/valid、I-cache |
| dmem 组合读 | 同步 SRAM、load data valid、D-cache |
| 固定 1 cycle memory | wait state、总线响应、cache miss |
| EX 决策 branch | ID 提前比较、简单预测、BTB |
| 无异常 | precise exception、CSR、trap handler |
| 无外设 | MMIO、timer、UART、PLIC/CLINT |

每一次“真实化”都会引入新的控制问题。第一版先不要把这些问题混在一起。

## 第4章 第一版功能范围

### 4.1 指令支持策略

第一版建议支持的主线指令如下，完整编码和控制信号放到 `0821`：

| 类别 | 指令 | 为什么需要 |
|---|---|---|
| U-type | `LUI`、`AUIPC` | 构造大立即数、测试 `PC + imm` 写回 |
| I-type ALU | `ADDI`、`SLTI`、`SLTIU`、`XORI`、`ORI`、`ANDI`、`SLLI`、`SRLI`、`SRAI` | 覆盖立即数、比较、逻辑、移位 |
| R-type ALU | `ADD`、`SUB`、`SLT`、`SLTU`、`XOR`、`OR`、`AND`、`SLL`、`SRL`、`SRA` | 覆盖双寄存器 ALU 和 forwarding 主场景 |
| load | `LB`、`LH`、`LW`、`LBU`、`LHU` | 覆盖地址计算、byte/halfword/word 读取和符号扩展 |
| store | `SB`、`SH`、`SW` | 覆盖 byte enable、store data forwarding 和副作用屏蔽 |
| branch | `BEQ`、`BNE`、`BLT`、`BGE`、`BLTU`、`BGEU` | 覆盖控制相关、signed/unsigned 比较 |
| jump | `JAL`、`JALR` | 覆盖无条件跳转、返回地址写回、寄存器间接跳转 |

第一版可以暂不支持或特殊处理：

| 指令/类别 | 第一版处理建议 |
|---|---|
| `FENCE` | 可先当 NOP，后续涉及 memory ordering 时再认真处理 |
| `ECALL`、`EBREAK` | 可暂不支持；也可在仿真里作为停止约定，但不要声称完整 trap |
| CSR 指令 | 暂不支持，等 `0803` 和后续扩展阶段 |
| M/C/A/F/D 扩展 | 暂不支持 |

这里再次强调：支持 RV32I 主线指令和完整通过官方架构测试不是一回事。第一版教学核的目标是训练 CPU 主干，不是一步到位做完整处理器产品。

### 4.2 数据通路范围

第一版数据通路至少要覆盖：

| 数据通路 | 必要内容 |
|---|---|
| PC path | `PC+4`、branch target、JAL target、JALR target 选择 |
| instruction path | imem 读指令，指令随 pipeline register 流动 |
| GPR read | ID 读 `rs1/rs2`，x0 恒为 0 |
| immediate path | I/S/B/U/J 各类立即数生成 |
| ALU path | 加减、比较、逻辑、移位、地址计算 |
| branch compare | signed/unsigned 比较和相等比较 |
| dmem path | load/store 地址、写数据、byte enable、读数据扩展 |
| writeback path | ALU 结果、load 数据、`PC+4`、`AUIPC/LUI` 结果选择 |

这些数据通路的核心原则是：每个写回来源、每个 PC 来源、每个 memory 副作用，都必须有明确的控制信号。

### 4.3 控制范围

第一版控制逻辑至少包括：

| 控制逻辑 | 作用 |
|---|---|
| decoder | 从 instruction 生成 ALU op、imm type、load/store 类型、branch 类型、writeback 选择 |
| forwarding unit | 在 EX 阶段为 `rs1/rs2` 选择 GPR 原值、EX/MEM 结果或 MEM/WB 结果 |
| load-use detector | 检测 load 后一条立即使用，插入 bubble |
| branch/jump redirect | 产生 next PC 选择和 flush 请求 |
| valid gating | 控制 invalid 指令不能写 GPR、不能写 dmem、不能 commit |
| stall/flush priority | 明确 stall、bubble、flush 同时出现时谁优先 |

后续 `0825` 会把这些控制条件展开成查表式规则。本篇只先给出设计边界。

## 第5章 建议模块划分

### 5.1 顶层结构

一个适合教学核的顶层结构可以这样理解：

```text
                 +------------------+
imem_rdata_i --->|                  |---> dmem_addr_o
                 |    core_top      |---> dmem_wdata_o
imem_addr_o  <---|                  |---> dmem_we_o
                 +------------------+---> dmem_be_o
                         |
                         v
              commit/debug trace signals
```

第一版可以让 `core_top` 直接连接简单 imem/dmem。后续如果要接 SoC，总线转换和地址译码不应该塞进 `core_top` 的流水线内部，而应该通过接口层或 wrapper 处理。

### 5.2 内部模块建议

推荐模块拆分如下：

| 模块 | 职责 | 备注 |
|---|---|---|
| `core_top` | 实例化 stage、regfile、hazard/forwarding，连接 imem/dmem | 顶层只做连接和全局控制汇总 |
| `pc_reg` | 保存当前取指 PC，按 reset/redirect/stall/PC+4 更新 | 前端唯一的 PC 状态寄存器 |
| `if_stage` | 纯组合取指数据通路，输出 `imem_addr_o`、当前 PC、`PC+4` 和 instruction | 不保存 PC，不处理 redirect/stall |
| `id_stage` | decode、读寄存器、生成 immediate | 控制信号从这里开始随指令流动 |
| `ex_stage` | ALU、branch compare、target 计算 | forwarding 通常在进入 ALU 前完成 |
| `mem_stage` | load/store 访问、地址低位对齐检查、byte enable、load 扩展 | 第一版 dmem 简化；不实现 trap/CSR，但应输出 misaligned/error 供外层 halt 或禁止副作用，后续可加 ready |
| `wb_stage` | writeback 数据选择 | 写回 GPR 的最后一站 |
| `regfile` | 32 个 GPR，x0 恒为 0 | 读写同拍语义必须明确 |
| `decoder` | 指令 opcode/funct 译码 | 尽量只产生控制，不掺杂 stage 状态 |
| `imm_gen` | 生成 I/S/B/U/J 立即数 | 单独拆出便于验证 |
| `alu` | 算术逻辑运算 | 地址加法可复用 ALU 或单独加法器 |
| `branch_unit` | branch 条件判断 | 也可放在 EX 内 |
| `forwarding_unit` | 数据前递选择 | 根据后级 `rd/we/valid` 判断 |
| `hazard_unit` | load-use stall、flush 优先级 | 只做控制，不直接改数据 |
| `pipe_reg_*` | stage 间寄存器 | 保存 data、control、valid、debug PC/instruction |
| `commit_trace` | 仿真 debug 输出 | 可用 `ifdef` 包起来，避免影响综合 |

模块拆分不必一开始过度抽象。比如 `branch_unit` 可以先放在 `ex_stage` 中，等逻辑变复杂再拆。真正重要的是边界清楚：decoder 不应该知道波形怎么打印，testbench 不应该替 CPU 执行指令，hazard unit 不应该偷偷修改 GPR。

#### 5.2.1 先把 CPU 看成几条路径

只看模块名时，容易觉得 CPU 是一堆零散小盒子。更适合入门实现的看法是：一个最小教学核主要由几条路径拼起来，每条路径解决一种问题。

| 路径 | 涉及模块 | 解决的问题 | 典型例子 |
|---|---|---|---|
| PC/取指路径 | `pc_reg`、`if_stage`、imem、redirect 控制 | 下一拍应该从哪里取 instruction | 普通指令取 `PC+4`，branch taken 后取 branch target |
| 译码/控制路径 | `decoder`、`imm_gen`、pipeline register | 当前 instruction 是什么，后面各级应该怎么处理它 | `LW` 要读 `rs1`、生成 I-imm、做 load、写 `rd` |
| 寄存器/执行路径 | `regfile`、forwarding、`alu`、`branch_unit` | 从 GPR 取操作数，在 EX 做计算或比较 | `ADD` 做加法，`BEQ` 比较相等，`SW` 计算地址 |
| 访存/写回路径 | `mem_stage`、dmem、`wb_stage`、`regfile` | load/store 怎样访问数据存储，结果怎样写回 | `LW` 读 dmem 后写 `rd`，`SW` 写 dmem 不写 GPR |
| hazard/有效性路径 | `hazard_unit`、`forwarding_unit`、valid gating | 指令重叠执行时，怎样不破坏 ISA 语义 | load-use stall，taken branch flush 错路径 |

真正写 RTL 时，不建议一开始就问“我要写几个 stage 文件”。更好的问题是：“这条指令从取指到写回，沿着哪几条路径走，每条路径需要哪些控制信号？”

#### 5.2.2 每个模块第一版具体要实现什么

下面这张表比 5.2 的职责表更贴近实现。它不是完整接口规范，具体字段仍然看 `0824`，但它可以帮助你判断每个模块到底要写哪些逻辑。

| 模块 | 第一版要实现的功能 | 暂时不要放进去的内容 |
|---|---|---|
| `core_top` | 实例化各模块，连接 pipeline register，汇总 stall/flush/redirect，接 imem/dmem 端口 | 不在顶层写大段指令语义，不在顶层直接修改 GPR 或 memory |
| `pc_reg` | 保存 `pc_q`，按 `reset/redirect/stall/pc_plus4` 更新 PC，输出当前取指 PC 和 PC valid | 不读取 imem，不处理 instruction，不做分支判断 |
| `if_stage` | 输入 `pc_reg` 给出的 PC，输出 `imem_addr_o`、`if_pc`、`if_pc_plus4`、`if_instr`、`if_valid` | 不保存 PC，不处理 redirect/stall/reset，不做复杂分支预测 |
| `id_stage` | 从 instruction 取出 `opcode/funct/rs/rd`，调用 `decoder/imm_gen`，读 `regfile`，把数据和控制送入 ID/EX | 不在 ID 里真正执行 ALU 运算，不直接写 GPR |
| `decoder` | 根据 `opcode/funct3/funct7` 产生 `alu_op`、`imm_sel`、`op_a_sel`、`op_b_sel`、`mem_re/we`、`wb_sel`、`branch_op` 等控制 | 不关心当前流水线是否 stall，不根据后级 forwarding 改控制 |
| `imm_gen` | 生成 I/S/B/U/J 五类 32 bit 立即数，包括符号扩展和 B/J 低位补 0 | 不判断这条指令是否合法，不决定是否跳转 |
| `regfile` | 提供两个读口、一个写口，保证 `x0` 恒为 0，定义同拍读写行为 | 不实现 CSR，不把 memory 临时数据塞进 GPR 外部状态 |
| `ex_stage` | 选择 ALU 输入，接收 forwarding 后操作数，做 ALU 运算、branch 比较、jump/branch target 计算 | 不访问 dmem，不在 EX 直接写回 GPR |
| `alu` | 根据 `alu_op` 做 RV32I 主线需要的加减、比较、逻辑、移位，也可复用来算 load/store 地址 | 不做乘除法、浮点、饱和运算 |
| `branch_unit` | 对 `BEQ/BNE/BLT/BGE/BLTU/BGEU` 判断 taken，区分 signed/unsigned 比较 | 不保存历史，不预测未来分支 |
| `mem_stage` | 对 load/store 输出 dmem 地址、写数据、byte enable，并对 load data 做 byte/half/word 提取和符号/零扩展；检查 `LH/LHU/SH` 的 `addr[0]` 和 `LW/SW` 的 `addr[1:0]` 是否满足对齐 | 不处理 cache、总线等待、完整 trap/CSR；第一版只输出 `mem_misaligned` 类错误信号，外层用它 halt、禁止错误 store 写 memory，并禁止错误 load 写回 `rd` |
| `wb_stage` | 在 `ALU/load/PC+4/imm` 中选择写回数据，配合 `reg_we` 写 GPR | 不重新译码，不修改 PC |
| `forwarding_unit` | 比较 EX 阶段源寄存器和后级 `rd`，为 `rs1/rs2/store_data` 选择前递来源 | 不负责插 bubble，不负责改 PC |
| `hazard_unit` | 检测 load-use，产生 stall/bubble；接收 redirect，产生 flush/kill；定义优先级 | 不直接改数据值，不替 stage 执行指令 |
| `pipe_reg_*` | 在 stage 边界保存 `valid`、`pc`、`instr`、寄存器编号、数据和控制信号 | 不包含复杂组合逻辑，不凭空生成新控制 |

这里的核心原则是：`decoder` 负责“这条指令想做什么”，`hazard_unit` 负责“现在能不能让它继续走”，pipeline register 负责“把这条指令自己的数据和控制保存到下一拍”。

#### 5.2.3 ALU 到底要做哪些运算

`ALU` 不是一句“算术逻辑运算”就结束。对第一版 RV32I 教学核来说，它至少要覆盖下面这些操作。表里把常见编码字段也列出来，是为了说明 decoder 写 RTL 时可以先看 `opcode` 分大类，再看 `funct3/funct7` 分小类。

| `alu_op` 示例 | 指令/场景 | opcode | funct3 | funct7 或 `imm[11:5]` | ALU 行为 | RTL 译码规律 |
|---|---|---|---|---|---|---|
| `ALU_ADD` | `ADD` | `0110011` | `000` | `0000000` | `rs1 + rs2` | R-type ALU 指令；`funct3=000` 且 `funct7=0000000` 是加法 |
| `ALU_ADD` | `ADDI` | `0010011` | `000` | 不是功能码，是立即数高位 | `rs1 + immI` | I-type ALU 指令；ALU B 选符号扩展后的 I-imm |
| `ALU_ADD` | `LB/LH/LW/LBU/LHU` 地址计算 | `0000011` | `000/001/010/100/101` | 不是功能码，是地址 offset 高位 | `rs1 + immI` | load 的 `funct3` 区分读宽度和是否符号扩展；ALU 都只是算地址 |
| `ALU_ADD` | `SB/SH/SW` 地址计算 | `0100011` | `000/001/010` | 不是功能码，是 S-imm 高位 | `rs1 + immS` | store 的 `funct3` 区分写宽度；ALU 都只是算地址 |
| `ALU_ADD` | `AUIPC` | `0010111` | 无 | 无 | `pc + immU` | U-type 没有 `funct3/funct7`；A 选 `pc`，B 选 U-imm |
| `ALU_ADD` | `JALR` target 计算 | `1100111` | `000` | 不是功能码，是 offset 高位 | `rs1 + immI` | target 还要清 bit0：`(rs1 + immI) & ~32'd1` |
| `ALU_SUB` | `SUB` | `0110011` | `000` | `0100000` | `rs1 - rs2` | 和 `ADD` 共用 `funct3=000`，靠 `funct7` 区分 |
| `ALU_SUB` | `BEQ/BNE` 可选比较实现 | `1100011` | `000/001` | 无 | `rs1 - rs2` | branch 也可不用 ALU，单独比较 `rs1 == rs2` 更直观 |
| `ALU_SLT` | `SLT` | `0110011` | `010` | `0000000` | `$signed(rs1) < $signed(rs2)` | R-type 有符号小于 |
| `ALU_SLT` | `SLTI` | `0010011` | `010` | 不是功能码，是立即数高位 | `$signed(rs1) < $signed(immI)` | I-type 有符号小于；`immI` 是符号扩展后的 I-imm |
| `ALU_SLT` | `BLT/BGE` 可选比较实现 | `1100011` | `100/101` | 无 | `$signed(rs1) < $signed(rs2)` | branch comparator 可以复用同类比较，但通常另设 `branch_op` |
| `ALU_SLTU` | `SLTU` | `0110011` | `011` | `0000000` | `unsigned(rs1) < unsigned(rs2)` | R-type 无符号小于 |
| `ALU_SLTU` | `SLTIU` | `0010011` | `011` | 不是功能码，是立即数高位 | `unsigned(rs1) < unsigned(immI)` | 立即数先符号扩展，再按 unsigned 比较 |
| `ALU_SLTU` | `BLTU/BGEU` 可选比较实现 | `1100011` | `110/111` | 无 | `rs1 < rs2` | branch comparator 可以复用 unsigned 比较 |
| `ALU_XOR` | `XOR` | `0110011` | `100` | `0000000` | `rs1 ^ rs2` | R-type 位异或 |
| `ALU_XOR` | `XORI` | `0010011` | `100` | 不是功能码，是立即数高位 | `rs1 ^ immI` | I-type 位异或；ALU B 选 I-imm |
| `ALU_OR` | `OR` | `0110011` | `110` | `0000000` | `rs1 \| rs2` | R-type 位或 |
| `ALU_OR` | `ORI` | `0010011` | `110` | 不是功能码，是立即数高位 | `rs1 \| immI` | I-type 位或；ALU B 选 I-imm |
| `ALU_AND` | `AND` | `0110011` | `111` | `0000000` | `rs1 & rs2` | R-type 位与 |
| `ALU_AND` | `ANDI` | `0010011` | `111` | 不是功能码，是立即数高位 | `rs1 & immI` | I-type 位与；ALU B 选 I-imm |
| `ALU_SLL` | `SLL` | `0110011` | `001` | `0000000` | `rs1 << rs2[4:0]` | R-type 左移，移位量来自 `rs2[4:0]` |
| `ALU_SLL` | `SLLI` | `0010011` | `001` | `0000000` | `rs1 << immI[4:0]` | shift-immediate 要检查 `instr[31:25]`，移位量实际来自 `instr[24:20]` |
| `ALU_SRL` | `SRL` | `0110011` | `101` | `0000000` | `rs1 >> rs2[4:0]` | 和 `SRA` 共用 `funct3=101`，靠 `funct7` 区分 |
| `ALU_SRL` | `SRLI` | `0010011` | `101` | `0000000` | `rs1 >> immI[4:0]` | shift-immediate 逻辑右移，高位补 0 |
| `ALU_SRA` | `SRA` | `0110011` | `101` | `0100000` | `$signed(rs1) >>> rs2[4:0]` | 和 `SRL` 共用 `funct3=101`，靠 `funct7` 区分 |
| `ALU_SRA` | `SRAI` | `0010011` | `101` | `0100000` | `$signed(rs1) >>> immI[4:0]` | shift-immediate 算术右移，高位补符号位 |
| `ALU_COPY_B` 或 `ALU_PASS_IMM` | `LUI` | `0110111` | 无 | 无 | `immU` | U-type 没有 `funct3/funct7`；也可以不经过 ALU，WB 直接选择 U-imm |

从这张表可以看出几个适合写进 RTL 的规律：

1. `opcode=0110011` 是 R-type ALU 大类，通常由 `funct3` 先选运算族，再用 `funct7` 区分 `ADD/SUB`、`SRL/SRA`。
2. `opcode=0010011` 是 I-type ALU 大类，`funct3` 仍然很有规律；但非 shift 指令的 `instr[31:20]` 是立即数，不应把 `instr[31:25]` 当成 `funct7` 去检查。
3. `LOAD/STORE/JALR/AUIPC` 虽然不是普通 ALU 指令，但会复用 `ALU_ADD` 算地址或 target；它们的 `funct3` 多数是在描述访存宽度或合法编码，不是在选择加减乘除。
4. `BRANCH` 可以复用 ALU 的减法/比较，也可以单独做 `branch_cmp`。教学核里更推荐单独定义 `branch_op`，这样 `alu_op` 只描述 EX 阶段要产生的普通 ALU 结果或地址结果。

ALU 的输入不一定总是两个 GPR。`decoder` 会通过 `op_a_sel/op_b_sel` 决定输入来源：

| 指令场景 | ALU A | ALU B | ALU 输出含义 |
|---|---|---|---|
| `add rd, rs1, rs2` | `rs1` | `rs2` | 写回 `rd` 的加法结果 |
| `addi rd, rs1, imm` | `rs1` | `immI` | 写回 `rd` 的加法结果 |
| `lw rd, imm(rs1)` | `rs1` | `immI` | dmem 访问地址 |
| `sw rs2, imm(rs1)` | `rs1` | `immS` | dmem 访问地址，`rs2` 是写入数据 |
| `auipc rd, imm20` | `pc` | `immU` | 写回 `PC + immU` |
| `lui rd, imm20` | `0` 或不用 | `immU` | 写回 `immU` |
| `jal rd, offset` | 可不用 ALU | 可不用 ALU | 常用单独加法得到 `PC + immJ`，写回 `PC+4` |
| `jalr rd, imm(rs1)` | `rs1` | `immI` | target 为 `(rs1 + immI) & ~1` |

因此，ALU 是很多指令共用的执行硬件，不是只给 `ADD/SUB` 服务。第一版最容易漏掉的是 load/store 的地址也通常由 ALU 算出来。

#### 5.2.4 一条指令会怎样使用这些模块

下面用几类指令串一下模块协作。先不用管 forwarding/stall，先看正常路径。

| 指令 | IF | ID | EX | MEM | WB |
|---|---|---|---|---|---|
| `add x3, x1, x2` | 取 instruction，得到 `pc_plus4` | decode 为 R-type，读 `x1/x2` | ALU 做 `x1 + x2` | 不访问 dmem | ALU 结果写 `x3` |
| `addi x3, x1, 5` | 同上 | decode 为 I-type，读 `x1`，生成 `immI=5` | ALU 做 `x1 + immI` | 不访问 dmem | ALU 结果写 `x3` |
| `lw x3, 8(x1)` | 同上 | 读 `x1`，生成 `immI=8`，标记 load | ALU 算地址 `x1 + 8` | dmem 读，按宽度扩展 | load data 写 `x3` |
| `sw x2, 8(x1)` | 同上 | 读 `x1/x2`，生成 `immS=8`，标记 store | ALU 算地址 `x1 + 8`，准备 store data | dmem 写，使用 byte enable | 不写 GPR |
| `beq x1, x2, label` | 同上 | 读 `x1/x2`，生成 `immB`，标记 branch | 比较 `x1 == x2`，taken 时产生 redirect PC | 不访问 dmem | 不写 GPR |
| `jal x1, label` | 同上 | 生成 `immJ`，标记 jump 和写 `rd` | 计算 target，产生 redirect | 不访问 dmem | `PC+4` 写 `x1` |
| `jalr x0, 0(x1)` | 同上 | 读 `x1`，生成 `immI=0`，标记 JALR | 计算 `(x1+0)&~1`，产生 redirect | 不访问 dmem | `rd=x0`，实际不写 GPR |

这张表说明了一个关键点：同一个模块会被不同指令以不同方式复用。例如 ALU 在 `ADD` 中产生写回结果，在 `LW/SW` 中产生地址，在 `AUIPC/JALR` 中参与 PC 相关计算。CPU 的设计工作，本质就是把这些复用关系用控制信号描述清楚。

#### 5.2.5 这些模块怎样组合成一个 CPU

组合成 CPU 时，不是把所有模块随便接在一起，而是要形成“数据随指令流动，控制也随指令流动”的结构。

```text
+----------+     +----------+     +----------+       +----------+       +----------+
| IF       |---->| ID       |---->| EX       |------>| MEM      |------>| WB       |
| pc/imem  |IF/ID| decode   |ID/EX| alu/br   |EX/MEM | dmem     |MEM/WB |regfile   |
+----------+     | imm/GPR  |     | target   |       | load ext |       | write    |
                 +----------+     +----------+       +----------+       +----------+
                       ^                ^                 ^               |
                       |                |                 |               |
                    regfile read     forwarding        side effect    regfile write
                                        ^              valid gating       |
                                        |                                 |
                              hazard/flush/stall control <----------------+
```

从实现顺序看，可以按下面方式下手：

1. 先写 `types/package`，定义 `alu_op_e`、`imm_sel_e`、`wb_sel_e`、`branch_op_e` 这类枚举。
2. 写 `alu`、`imm_gen`、`regfile` 这三个容易单独验证的小模块。
3. 写 `decoder`，让每条支持指令能生成稳定的控制信号。
4. 写一个简单非流水或单周期路径，把 `imem -> decoder -> regfile -> alu -> dmem/wb` 跑通。
5. 再加 IF/ID、ID/EX、EX/MEM、MEM/WB，把同一套数据通路拆进五级流水。
6. 最后补 `forwarding_unit` 和 `hazard_unit`，解决流水线重叠后产生的数据相关和控制相关。

也就是说，第一版可以从 `alu/imm_gen/regfile/decoder` 这些“能独立写、独立测”的模块开始，而不是一上来就写完整 `core_top`。等这些小模块语义可靠，再把它们放进 stage，CPU 主体就会自然成形。

#### 5.2.6 stage valid 传递与 flush/kill 边界

本项目建议把 stage 尽量写成纯组合数据通路，把真正的流水槽状态放在 `pipe_reg_*` 中。为了让接口边界清楚，每个参与流水线连接的 stage 可以保留 `valid_i` 和 `valid_o`：

| 信号 | 含义 | 常见处理 |
|---|---|---|
| `valid_i` | 当前 stage 输入槽是否是一条有效指令 | 用来门控本级可能产生的副作用 |
| `valid_o` | 当前 stage 输出给下一级流水寄存器的有效位 | 普通组合 stage 默认 `valid_o = valid_i` |

`valid_o = valid_i` 的含义只是：这个 stage 本身不主动丢弃当前指令，也不主动制造 bubble。它不表示流水线不需要 flush、kill 或 stall。第一版中，`if_stage/id_stage/ex_stage/mem_stage/wb_stage` 大多可以按这个规则透传 valid；如果某个 stage 后续会自己发现异常、访问错误或需要 replay，再单独增加 `kill_o/error_o`，或让 `valid_o` 结合本级 kill 条件。

`flush/kill/stall` 更适合集中体现在 `hazard_unit` 和 `pipe_reg_*` 的更新逻辑中：

| 控制 | 推荐作用位置 | 行为 |
|---|---|---|
| `stall` | `pc_reg` 和对应 `pipe_reg_*` | 保持当前 `valid/data/control` 不变 |
| `bubble` | 写入后级的 `pipe_reg_*` | 写入 `valid=0` 的空槽 |
| `flush` | 清空错误路径上的 `pipe_reg_*` | 把 younger 指令的 `valid` 清 0 |
| `kill` | `pipe_reg_*` 或副作用门控 | 让某条指令不能写 GPR、写 dmem 或 commit |

例如 branch 在 EX 阶段判断 taken 时，EX 中这条 branch 自己通常仍然有效并继续向后流动；需要被清掉的是 IF/ID、ID/EX 中已经取进来的错误路径 younger 指令。因此不应该简单把 `ex_stage.valid_o` 置 0，而应该由 redirect 控制去 flush 前面更年轻的流水槽。

凡是会改变架构状态或外部可见状态的输出，都必须使用对应阶段的 valid 门控。第一版至少包括：

| 副作用 | 推荐门控 |
|---|---|
| PC redirect | `ex_valid && redirect_condition` |
| dmem 写 | `mem_valid && mem_we && !mem_misaligned` |
| dmem 读请求 | `mem_valid && mem_re && !mem_misaligned` |
| GPR 写回 | `wb_valid && reg_we && !wb_exception` |
| commit/debug trace | `wb_valid && commit_en && !wb_exception` |

这里的 `wb_exception` 是提交阶段看到的异常/错误汇总，不是 GPR 自己理解 `mem_misaligned`。第一版暂不实现 trap/CSR 时，可以先把 `mem_misaligned` 作为 debug/halt/error 信号使用；后续加入异常处理后，应让异常信息随流水线进入提交或 trap 路径，再由提交控制决定是否写 GPR、是否 commit。

单周期 demo 中可以把 valid 简化成一条贯穿全路径的有效位；五级流水线中则由 IF/ID、ID/EX、EX/MEM、MEM/WB 分别保存自己的 valid。两者的接口可以保持一致：stage 组合逻辑接收 `valid_i`，输出 `valid_o`；是否保持、清空或插入 bubble，由相邻的状态寄存器和控制单元决定。

### 5.3 pipeline register 中应该保存什么

五级流水线的核心不是“有五个模块”，而是每级之间保存了该指令继续执行所需的信息。

常见字段如下：

| pipeline register | 典型字段 |
|---|---|
| IF/ID | `valid`、`pc`、`pc_plus4`、`instr` |
| ID/EX | `valid`、`pc`、`pc_plus4`、`instr`、`rs1`、`rs2`、`rd`、`rs1_rdata`、`rs2_rdata`、`imm`、控制信号 |
| EX/MEM | `valid`、`pc`、`instr`、`rd`、`alu_result`、`store_data`、branch/jump 信息、load/store 控制、writeback 控制 |
| MEM/WB | `valid`、`pc`、`instr`、`rd`、`alu_result`、`load_data`、`pc_plus4`、writeback 控制 |

不要只保存数据而忘记保存控制信号。流水线里每一级处理的是“某条指令的数据 + 这条指令自己的控制意图”。如果控制信号没有随指令流动，后面就很容易出现“数据是第 N 条指令的，控制却像第 N+1 条指令”的错配。

## 第6章 实现顺序建议

### 6.1 第一步：先定义项目假设

动手写 RTL 前，建议先写一个很短的项目假设文件或 README，至少明确：

| 假设 | 示例 |
|---|---|
| reset PC | `32'h0000_0000` |
| 指令对齐 | 第一版只取 32 bit 指令，PC 按 4 字节对齐 |
| imem 行为 | CPU 只读，仿真开始前初始化，第一版无 wait |
| dmem 行为 | 支持 byte enable，第一版无 wait |
| 未实现指令 | 仿真报错或进入 stop，不做 precise trap |
| 程序结束 | 死循环、超时检查、或写 `tohost` 地址 |
| GPR 语义 | x0 恒为 0，同拍写读语义明确 |
| branch 决策级 | 第一版在 EX 决策，taken 时 flush IF/ID 和 ID/EX 中错路径 |

这些假设越早写清楚，后面 debug 时越少争论。

### 6.2 第二步：整理指令语义表

不要一上来写一个巨大 `casez`。先整理表格，至少包括：

| 字段 | 为什么需要 |
|---|---|
| 指令名 | 明确支持范围 |
| type | R/I/S/B/U/J，决定立即数和字段解释 |
| 汇编格式 | 方便写测试 |
| opcode/funct3/funct7 | 译码依据 |
| 读寄存器 | 是否读 `rs1/rs2` |
| 写寄存器 | 是否写 `rd` |
| ALU 操作 | EX 阶段做什么 |
| memory 操作 | 是否 load/store，宽度和符号扩展 |
| PC 操作 | `PC+4`、branch target、JAL/JALR |
| writeback 来源 | ALU、load、`PC+4`、immediate |

这个表后续就是 `0821` 的核心内容。

### 6.3 第三步：先跑一个最短程序

最短程序不是为了覆盖全部指令，而是为了验证端到端路径：

```text
取指 -> 译码 -> 读GPR -> ALU -> 写GPR -> store -> testbench检查dmem
```

最短程序能跑通，说明你的仿真框架、memory 初始化、reset、PC、GPR、ALU、store 大方向是连起来的。之后再逐类扩展指令。

### 6.4 第四步：先写语义模型，再切流水线

如果直接写五级流水线，bug 来源会很多：

- immediate 拼错。
- ALU op 选错。
- GPR 写回错。
- load 符号扩展错。
- forwarding 选错。
- stall 多停或少停。
- flush 没屏蔽 store。

初学项目更稳的做法是先写一个单周期或顺序执行模型。它不一定最终保留，但能作为“指令语义正确性”的对照。

当单周期模型能跑通一批基础 directed test 后，再切成五级流水线。此时如果某个测试在单周期过、流水线不过，就大概率是 hazard、valid、flush、pipeline register 字段的问题。

### 6.5 第五步：让流水线先“空跑正确”

在接完整指令前，可以先观察 instruction、PC、valid 在五级之间如何移动：

```text
cycle 0: instr0 IF
cycle 1: instr0 ID, instr1 IF
cycle 2: instr0 EX, instr1 ID, instr2 IF
cycle 3: instr0 MEM, instr1 EX, instr2 ID, instr3 IF
cycle 4: instr0 WB, instr1 MEM, instr2 EX, instr3 ID, instr4 IF
```

这里先不追求复杂结果，只确认：

- reset 后 valid 清零。
- 第一条有效指令从 IF/ID 开始向后流动。
- stall 时该冻结的 stage 冻结。
- bubble 插入后 valid 为 0。
- invalid 指令不会写 GPR、不会写 dmem。

### 6.6 第六步：逐类打开功能

建议按下面顺序打开：

| 顺序 | 功能 | 原因 |
|---|---|---|
| 1 | `LUI`、`ADDI`、简单 R-type ALU | 不依赖 memory 和 branch，先验证 GPR/ALU/WB |
| 2 | 更多 I/R ALU 和 shift/compare | 补齐 ALU op、signed/unsigned 比较 |
| 3 | `SW`、`LW` | 验证地址计算、dmem、load writeback |
| 4 | `SB/SH/LB/LH/LBU/LHU` | 验证 byte enable 和 load 扩展 |
| 5 | forwarding | 让连续相关 ALU 指令通过 |
| 6 | load-use stall | 处理 load 数据晚到的问题 |
| 7 | branch | 处理 conditional redirect 和 flush |
| 8 | `JAL/JALR` | 处理无条件跳转、`PC+4` 写回和寄存器间接跳转 |
| 9 | 更系统测试 | directed/random/trace 比对 |

这个顺序的好处是每一步只引入一类新问题。

## 第7章 Hazard 和控制优先级总览

### 7.1 第一版必须处理的 hazard

第一版教学核必须处理这些情况：

| hazard | 典型例子 | 处理方式 |
|---|---|---|
| EX/MEM 到 EX 的 ALU forwarding | `add x3,x1,x2; sub x4,x3,x5` | 下一条在 EX 需要上一条 ALU 结果，直接从 EX/MEM 前递 |
| MEM/WB 到 EX 的 forwarding | 中间隔一条或 load 返回后使用 | 从 MEM/WB 写回数据前递到 EX |
| load-use | `lw x3,0(x1); add x4,x3,x5` | 冻结 PC 和 IF/ID，向 ID/EX 插入 bubble |
| store data forwarding | `add x3,x1,x2; sw x3,0(x4)` | store 的写数据也可能需要前递 |
| branch operand forwarding | `add x1,x2,x3; beq x1,x0,L` | branch 比较操作数需要使用最新值 |
| branch/JAL/JALR flush | taken 后旧路径已有指令 | redirect PC，并 kill 错路径指令 |

如果这些处理不完整，教学核很容易“简单程序对，稍微相关就错”。

### 7.2 stall、bubble、flush、kill 的关系

这几个词在项目里必须定义清楚：

| 概念 | 项目中的含义 |
|---|---|
| stall | 某些 pipeline register 保持不变，通常用于等待数据或资源 |
| bubble | 向后级插入一条 invalid 空槽，让当前指令晚一拍进入后级 |
| flush | 清掉已经在错误路径上的年轻指令 |
| kill | 标记某条已经进入流水线的指令不允许产生架构副作用 |

一个常见 load-use 控制动作是：

```text
PC       保持
IF/ID    保持
ID/EX    写入 bubble
EX/MEM   让原来的 load 正常前进
```

一个常见 taken branch 控制动作是：

```text
PC       改为 branch target
IF/ID    flush
ID/EX    flush 或 kill，取决于 branch 决策级和时序
后级      已经比 branch 更老的指令继续完成
```

具体优先级放到 `0825` 展开。本篇先要求：项目中不能只写一个 `stall_o` 就结束，必须说明它控制哪些寄存器保持、哪些寄存器写 bubble、哪些副作用被屏蔽。

### 7.3 valid bit 是副作用闸门

流水线里的每条“指令槽”都应该有 `valid`。`valid = 0` 表示这个槽不是一条应该提交的真实指令。

凡是会改变架构状态的动作，都应该被 valid gating：

| 副作用 | gating 条件示例 |
|---|---|
| GPR 写回 | `wb_valid && wb_reg_we && (wb_rd != 5'd0)` |
| dmem 写 | `mem_valid && mem_store_en` |
| commit trace | `wb_valid && commit_en` |
| trap/异常提交 | 第一版没有；后续也必须只对 valid 指令生效 |

错路径指令最危险的不是它在流水线里流过，而是它流过时偷偷写了寄存器或 memory。所以 flush/kill 的本质不是“把波形变好看”，而是“保证错误路径不会改变架构状态”。

## 第8章 程序、memory 与 testbench 的边界

### 8.1 CPU 执行程序，testbench 不执行程序

第一版教学核跑程序时，角色分工是：

| 角色 | 负责什么 |
|---|---|
| 裸机程序 | 提供要执行的 RISC-V 指令 |
| 工具链 | 把汇编/C 变成机器码文件 |
| testbench | 初始化 memory、提供时钟复位、判断 pass/fail |
| CPU RTL | 真正按 PC 取指、译码、执行、写回 |
| memory model | 响应 imem/dmem 访问 |

testbench 不应该替 CPU 算 `ADD`，也不应该替 CPU 改 PC。它最多观察结果、提供输入、在超时时停止仿真。

### 8.2 第一版为什么用裸机程序

裸机程序就是没有 OS 的程序。它没有进程、线程、系统调用、页表、文件系统，也没有“执行完返回操作系统”这件事。

第一版常见结束方式有三种：

| 方式 | 说明 |
|---|---|
| 死循环 | 程序完成后跳到自身，testbench 等固定 cycle 后检查结果 |
| 写 pass/fail 地址 | 程序向约定地址写 1 表示 pass，写其他值表示 fail |
| 特殊停止指令 | 把 `EBREAK` 等约定成仿真停止，但这不是完整 trap 语义 |

后续如果想跑 C 程序，还需要链接脚本、启动代码、栈指针初始化、全局变量初始化等内容。这些属于 `0826` 的范围。

### 8.3 ROM 和 RAM 在教学核中的含义

第一版常说：

- `imem/simple_rom` 存指令。
- `dmem/simple_ram` 存数据。

这里的 ROM/RAM 是教学建模用语，不等同于真实芯片最终物理实现。

| 名称 | 第一版含义 |
|---|---|
| instruction ROM | CPU 执行期间只读；仿真开始前可以由 testbench 初始化 |
| data RAM | CPU 可以 load 读取，也可以 store 修改 |
| `$readmemh` | 仿真初始化 memory 的方式，不是 CPU 在写 ROM |
| FPGA block RAM | 上板时可能用 bitstream 初始化，也可能由 bootloader 加载 |
| ASIC ROM/SRAM macro | 真实芯片中常由工艺库 macro 或 boot chain 提供 |

第一版不必一开始区分 flash、DDR、SRAM、cache、boot ROM 的完整系统关系，但要知道：真实产品中的程序和用户数据可能存在不同非易失介质中，CPU 启动后通过 boot ROM、bootloader、外部存储控制器、SRAM/DRAM 等链路逐步运行。教学核先把这些复杂启动链折叠成“testbench 把程序放进 imem”。

## 第9章 验证路线

### 9.1 directed test 先行

第一版不要直接上大规模随机测试。先写 directed test，因为它能精确回答“这条功能是否正确”。

建议测试顺序：

| 测试类别 | 重点 |
|---|---|
| 基础 ALU | 每个 ALU op 至少一个正例、边界值、x0 写屏蔽 |
| immediate | I/S/B/U/J 立即数正负数、边界 bit |
| load/store | byte/halfword/word、地址低位、符号扩展、byte enable |
| branch | taken/not-taken、signed/unsigned、正负 offset |
| jump | JAL/JALR target、`PC+4` 写回、JALR bit0 清零 |
| forwarding | EX/MEM、MEM/WB、rs1/rs2、rd=x0 |
| load-use | 紧邻使用、隔一条使用、不使用 |
| flush/kill | taken branch 后错路径写 GPR、错路径 store 都必须无效 |

每个 directed test 都应该尽量短。一个测试只证明一件事，定位 bug 才快。

### 9.2 commit trace 是 CPU 项目的生命线

只看最终 memory 是否等于某个值，debug 经常很痛苦。更好的方式是打印每条提交指令：

```text
cycle pc        instr     rd  wdata     mem_we mem_addr mem_wdata
12    00000000  00300093  x1  00000003  0      -------- --------
13    00000004  00400113  x2  00000004  0      -------- --------
14    00000008  002081b3  x3  00000007  0      -------- --------
15    0000000c  00302023  --  --------  1      00000000 00000007
```

commit trace 的价值在于：你能知道第几条提交指令开始偏离预期。后续可以把它和简单参考模型或 ISS 输出对比。

第一版 commit 的定义可以简单一些：WB 阶段 valid 指令到达时，认为它提交。对于 store，也可以在 MEM 阶段记录 memory 写入事件。等后续加入异常、CSR、可变延迟 memory 后，commit 定义需要更严格。

### 9.3 断言应该盯住不变量

第一版可以加少量高价值断言，不必一开始写复杂形式验证。

高价值不变量包括：

| 不变量 | 说明 |
|---|---|
| x0 恒为 0 | 无论任何指令写 `x0`，读出必须为 0 |
| invalid 不写 GPR | `valid=0` 的槽不能产生写回 |
| invalid 不写 dmem | bubble/flush 指令不能 store |
| PC 对齐 | 第一版 32 bit 指令下，取指 PC 应 4 字节对齐 |
| load-use stall 动作 | 检测到 load-use 时，PC/IFID 保持，IDEX 变 bubble |
| flush 优先级 | taken branch 后 younger 指令不能 commit |

这些断言比“代码看起来没问题”可靠得多。

### 9.4 debug 时先缩小问题空间

常见 debug 顺序：

1. 看第一条错误提交指令的 PC 和 instruction。
2. 判断它是取错了、译错了、操作数错了、ALU 错了、memory 错了，还是写回错了。
3. 如果操作数错，看 GPR 读值和 forwarding 选择。
4. 如果 PC 错，看 branch compare、target、redirect、flush。
5. 如果 memory 错，看地址、byte enable、store data、load 扩展。
6. 如果结果偶发错，看 valid、stall、flush 同时出现时的优先级。

`0828` 后续会把这些整理成表格化 checklist。

## 第10章 工程目录与命名建议

### 10.1 目录建议

一个教学项目可以先按下面结构组织：

```text
rv32i_teaching_core/
    rtl/
        core/
        common/
        mem/
    tb/
        sv/
        tests/
        model/
    sim/
        verilator/
        iverilog/
    sw/
        asm/
        c/
        linker/
    scripts/
    docs/
```

这只是建议，不是强制。关键是 RTL、testbench、测试程序、脚本、文档不要混在一起。

### 10.2 命名建议

命名要稳定，后续 `082x` 尽量沿用：

| 类别 | 建议 |
|---|---|
| 时钟复位 | `clk_i`、`rst_n_i` |
| 输入输出 | `_i`、`_o` 后缀 |
| pipeline valid | `if_valid`、`id_valid`、`ex_valid`、`mem_valid`、`wb_valid` |
| pipeline register | `if_id_*`、`id_ex_*`、`ex_mem_*`、`mem_wb_*` |
| GPR 地址 | `rs1_addr`、`rs2_addr`、`rd_addr` |
| GPR 数据 | `rs1_rdata`、`rs2_rdata`、`rd_wdata` |
| 控制信号 | `reg_we`、`mem_we`、`mem_re`、`wb_sel`、`alu_op` |
| hazard | `stall_if`、`stall_id`、`bubble_ex`、`flush_ifid` |
| redirect | `redirect_valid`、`redirect_pc` |

不要频繁改信号名。CPU 项目里，debug 和文档高度依赖信号名稳定。

## 第11章 行数、时间和难度预期

### 11.1 代码量预期

粗略代码量可以参考：

| 内容 | 大致规模 |
|---|---:|
| 单周期或顺序语义模型 | 600～1200 行 RTL |
| 五级流水 RV32I 主体 | 1500～3000 行 RTL |
| 简单 memory model | 100～300 行 RTL/TB |
| testbench 和 directed test 框架 | 500～1500 行 |
| 汇编测试程序 | 300～1500 行 |
| 脚本和工具 glue | 100～500 行 |
| 项目说明文档 | 视整理程度而定 |

行数不是目标。一个 2000 行但每条线都能解释的核，比一个 8000 行但大量复制粘贴的核更有学习价值。

### 11.2 难度主要不在 ALU

ALU 本身通常不难。教学核真正容易出错的地方是：

| 难点 | 典型错误 |
|---|---|
| immediate 拼接 | B/J-type bit 位放错，符号扩展错 |
| PC 更新 | branch target 用错 PC，JALR 没清 bit0 |
| x0 | 写屏蔽漏掉，forwarding 从 rd=x0 前递了错误值 |
| load 扩展 | `LB/LH/LBU/LHU` 符号扩展或 byte 选择错 |
| store byte enable | `SB/SH` 写错 lane |
| forwarding 优先级 | EX/MEM 和 MEM/WB 同时匹配时选旧值 |
| load-use | 该停没停，或多停一拍 |
| flush/kill | 错路径 store 已经写进 dmem |
| valid | bubble 仍然触发 commit trace 或写回 |
| TB | 程序加载地址和 reset PC/link 地址不一致 |

这些点也正是面试追问最有价值的地方。

## 第12章 开源项目应该怎么参考

### 12.1 先自己写，再对照看

开源项目很有价值，但不建议一开始照抄。原因是：CPU 项目的学习价值来自亲手处理那些细节，比如 x0、immediate、flush、load-use、store data forwarding、commit trace。如果直接复制开源代码，短期看进展快，长期很难讲清楚。

更合适的使用方式是：

1. 先自己写出能跑 directed test 的最小版本。
2. 带着具体问题看开源项目，例如“它的 flush 优先级怎么处理”“它怎么组织测试”。
3. 只借鉴结构思想，不把别人的代码风格硬塞进自己的项目。
4. 看完后回到自己的设计，用自己的接口和命名实现。

### 12.2 推荐参考方向

| 项目 | 适合看什么 | 注意点 |
|---|---|---|
| PicoRV32 | 小型 RISC-V 核、测试、简单 SoC 组织 | 不是经典五级流水线，不适合照搬 stage |
| Ibex | 工程化小核、CSR/异常/验证组织 | 对第一版偏复杂，适合后期学习 |
| riscv-sodor | 教学微架构、不同流水级设计 | 语言和工程风格与本系列可能不同 |
| riscv-tests | 基础 ISA 测试思路 | 前期挑简单用例，不追求一口气全过 |
| riscv-arch-test | 架构符合性测试方向 | 更适合后期规范化验证 |

## 第13章 阶段验收标准

### 13.1 第一版完成标准

一个第一版教学核可以认为“基本完成”，至少要满足：

| 标准 | 说明 |
|---|---|
| 支持范围明确 | 文档写清支持和不支持的指令/功能 |
| 基础程序能跑 | 能运行多段裸机汇编测试 |
| hazard 正确 | forwarding、load-use、branch flush 都有 directed test |
| 错路径无副作用 | taken branch 后的错路径写回/store 被证明无效 |
| x0 正确 | 写 x0 不改变读值，forwarding 不从 x0 产生假相关 |
| memory 正确 | byte enable、load 符号扩展、store data forwarding 正确 |
| trace 可用 | 能打印或记录提交指令，便于定位 mismatch |
| 可综合性检查 | 至少用综合/静态检查工具发现明显不可综合写法 |
| 文档能讲清楚 | 能画出数据通路、控制优先级和测试闭环 |

### 13.2 面试项目表达标准

如果把这个项目放到简历或面试里，不要只说“实现了一个 RISC-V 五级流水线 CPU”。更好的表达是：

- 支持哪些 RV32I 指令，哪些暂不支持。
- 采用什么微架构，为什么选择五级顺序流水线。
- 每一级做什么，pipeline register 保存什么。
- data hazard 怎么处理，哪些情况 forwarding，哪些情况 stall。
- control hazard 怎么处理，branch 在哪一级决策，flush 哪些 stage。
- load-use 为什么 forwarding 不能解决。
- wrong-path store 如何避免。
- testbench 如何加载程序，如何判断 pass/fail。
- commit trace 如何帮助定位 bug。
- 项目还有哪些未完成的真实 CPU 功能，例如 CSR、异常、中断、MMIO、cache。

能讲清这些，比堆功能更重要。

## 第14章 后续扩展路线

### 14.1 从教学核到更像 MCU

当第一版稳定后，可以按下面顺序扩展：

| 扩展 | 对应前置知识 | 说明 |
|---|---|---|
| 最小 CSR | `0803` | 加 `mstatus/mepc/mcause/mtvec` 等基础 CSR |
| 异常/中断 | `0803` | 非法指令、地址不对齐、timer interrupt |
| MMIO | `0804` | 用地址映射访问 timer、UART、GPIO |
| 简单总线 | `0804` | 从固定 imem/dmem 走向片上互联 |
| wait state | `0804`、`0805` | memory 或外设不是固定 1 cycle |
| I-cache/D-cache | `0805` | 引入 cache miss、stall、refill |
| 分支预测 | `0805` | 降低 control hazard 代价 |
| M 扩展 | `0802`、`0806` | 乘除法、多周期执行单元、结构冒险 |

这条路线可以把 08 部分其他文档逐步接回项目。

### 14.2 什么情况下可以开始第二阶段

不要在第一版还不稳定时急着加功能。建议至少满足：

1. 基础 RV32I 主线 directed test 能稳定通过。
2. hazard 相关测试不是靠“刚好程序没触发”通过，而是专门覆盖过。
3. commit trace 能定位第一条错误提交。
4. 你能画出当前数据通路和控制优先级。
5. 你知道第一版 memory 假设是什么。

满足这些后，再加 CSR/MMIO/cache，学习收益会更高。

## 第15章 本篇总结

`0820` 系列的核心目标，是把 `0801` 的 ISA 语义和 `0802` 的流水线控制变成一个可实现、可验证、可解释的 RTL 项目。

第一版教学核建议保持克制：

- RV32I 主线可执行子集。
- 单 hart。
- 单发射顺序五级流水线。
- 分离 imem/dmem。
- 简单 1 cycle memory 假设。
- 裸机汇编程序。
- 不做 CSR、trap、interrupt、cache、MMU、复杂总线和 OS。

这不是降低目标，而是把目标对准最关键的能力：让指令在流水线中重叠执行，同时仍然保持 ISA 语义正确。等这个闭环跑通，后续 `0821`～`0829` 会分别把指令表、接口、流水寄存器、hazard 控制、工具链、验证、debug 和扩展方向拆成更便于查阅的项目手册。
