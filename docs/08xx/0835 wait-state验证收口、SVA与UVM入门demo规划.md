# 0835 wait-state 验证收口、SVA 与 UVM 入门 demo 规划

> 文档编号：0835  
> 所属系列：083x RV32I 教学核后续完善阶段  
> 文档定位：规划在 0834 完成 data-side request/response、wait-state 和 MEM backpressure 后，如何把新增时序边界沉淀为 directed regression、SVA、monitor/scoreboard 和第一版 UVM demo  
> 对应总规划：`0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`  
> 前置文档：`0804 RISC-V SoC、MMIO与外设互联.md`、`0827 Testbench、commit trace与测试集组织.md`、`0828 波形debug、常见bug与定位清单.md`、`0829 综合、FPGA上板与SoC扩展方向.md`、`0834 可变延迟memory与MMIO、简化内部总线与backpressure规划.md`

本篇只规划“第五阶段做什么”。它不是执行阶段的 `plan.md`，因此不会写逐文件逐行的施工步骤。

0834 解决的是 RTL 功能问题：CPU data-side 从固定响应变成单 outstanding request/response，MEM wait 会 backpressure 流水线，DMEM/MMIO 可以插入 response delay，delayed error 能进入精确 trap。

0835 解决的是验证资产问题：这些新增的时序边界不能只靠少量软件程序样例证明。第五阶段应在不继续扩 CPU 功能的前提下，把 0834 的关键协议和微架构约束转化为可复用的 monitor、SVA、scoreboard、coverage 和一个小范围 UVM demo。

本阶段的核心目标不是“立刻写完整 CPU UVM”，而是：

```text
保留现有 Verilator 软件自检回归；
新增 VCS 路径，用 SVA 和小范围 UVM demo 验证 simple data bus/peripheral 边界；
为 0836 AXI-Lite 和 0837 AXI-Lite UVM 打基础。
```

## 第1章 本步目标和非目标

### 1.1 当前已经完成的基础

进入本步之前，系统已经具备：

| 能力 | 当前状态 |
|---|---|
| data-side simple bus | core LSU 到 data_subsystem 已是 request/response 模型 |
| single outstanding | 当前 CPU data-side 同一时刻只允许一笔未完成事务 |
| MEM backpressure | memory wait 期间 PC/IF/ID/EX/MEM 按 0834 口径保持 |
| delayed response | DMEM/GPIO0/UART0/TIMER0 可以由 TB 配置 response delay |
| delayed error | MMIO unknown offset 或未映射访问可转为 response error，再进入 access fault |
| MMIO 副作用 | GPIO W1C、UART TX/RX、TIMER32 语义已有 directed test 覆盖 |
| 软件自检测试 | 现有 ASM/C 程序通过 PASS/FAIL 状态字结束仿真 |
| TB mailbox | 软件可请求 TB 注入 GPIO/UART 激励，并配置 response delay |
| 结构体化 data bus | data request/response 已可用结构体表达，便于 monitor/UVM 观察 |

这些基础已经足够让 0835 不再大改 CPU 功能，而是围绕“证明这些行为真的稳定”展开。

### 1.2 本步目标

本步完成后，应具备：

| 能力 | 目标 |
|---|---|
| directed 回归保留 | 当前 ASM/C self-check regression 继续作为端到端功能回归 |
| wait-state 验证收口 | 0834 新增 wait-state 测试场景有明确分类和回归入口 |
| simple data bus monitor | 能观察 request accepted、response、error、target、delay 等事务边界 |
| SVA 基础 | 对 single outstanding、payload stable、response matched、no duplicate request 等关键性质建立断言 |
| scoreboard 基础 | 对 simple data bus/peripheral 事务结果做参考检查 |
| coverage 基础 | 覆盖 target、read/write、delay、OK/error、byte enable、side effect 等维度 |
| UVM 入门 demo | 建立一个小范围 UVM 环境，先验证 simple-bus/peripheral，不直接验证整颗 CPU |
| 仿真器分工 | Verilator 继续跑快速 directed，VCS 用于 UVM/SVA/coverage |
| 后续可扩展 | 0836 AXI-Lite 和 0837 AXI-Lite UVM 可以复用本阶段方法和工程组织 |

### 1.3 本步非目标

本步不做：

| 暂不做 | 原因 |
|---|---|
| 新 CPU 功能 | 0835 是验证收口，不继续扩 RV32I、CSR、interrupt 或流水线功能 |
| 新外设 ABI | GPIO/UART/TIMER32 寄存器语义已经在 0832/0833/0834 稳定 |
| AXI-Lite RTL | 放到 0836；0835 先验证 simple data bus |
| AXI-Lite UVM agent | 放到 0837；0835 的 UVM demo 先从项目内部 simple bus 入门 |
| SoC/CPU 级完整 UVM | 放到 0838；零基础阶段不建议直接验证整颗 CPU |
| ISS lockstep | 工作量大，且当前阶段重点是 wait-state/backpressure 边界 |
| full random instruction | 不适合作为 UVM 入门第一步，后续可作为更大验证专题 |
| 替代现有 directed test | UVM/SVA 是补充，不替代当前软件自检回归 |

本阶段允许因为验证发现真实 bug 而修 RTL。但这种修改属于 bug fix，不应变成新增功能规划。

## 第2章 为什么 0835 要单独成阶段

### 2.1 directed test 的价值

当前软件自检 directed test 有很强的价值：

| 优点 | 说明 |
|---|---|
| 端到端 | CPU 真的取指、执行、访存、进 trap/handler、访问 MMIO |
| 接近软件视角 | 能验证 `platform.h`、crt0、handler、外设寄存器 ABI |
| 速度快 | Verilator 路径适合频繁跑回归 |
| debug 直观 | commit/trap/data trace 能定位到指令和 PC |
| 展示度高 | 面试时容易说明“这套程序在真实 CPU/SoC 上跑过” |

因此 0835 不应抛弃现有测试体系。它仍然是功能回归主线。

### 2.2 directed test 的局限

0834 引入的是一类时序协议问题，仅靠软件程序不容易充分证明。

例如一个 C 程序能 PASS，只说明某条路径在某个 delay 配置下没有错；它很难系统证明：

| 性质 | 为什么 directed test 不够强 |
|---|---|
| payload stable | 软件看不到 `valid && !ready` 期间地址和数据是否抖动 |
| single outstanding | 软件通常只能观察最终结果，很难知道内部是否短暂接受了第二笔 |
| response matched | 软件只看到 load 值，不能保证每个 response 都对应正确 request |
| no duplicate side effect | UART TX 多打一拍、W1C 多清一次，有时程序结果未必立刻暴露 |
| stall hold | pipeline register 是否真的保持，需要内部观察点或断言 |
| wrong-path request | wrong-path MMIO request 可能极短暂，需要 monitor 才容易抓住 |
| coverage | 程序 PASS 不等于覆盖了不同 target、delay、error、byte enable 组合 |

这就是 0835 的意义：把“样例正确”推进到“协议性质被持续检查”。

### 2.3 为什么先做小范围 UVM demo

UVM 可以做得很大，但零基础时直接上整颗 CPU UVM 不划算。

整颗 CPU UVM 会同时遇到：

- 指令生成。
- memory image 管理。
- trap/interrupt handler。
- commit reference model。
- CSR reference model。
- MMIO side effect。
- reset/timeout/结束条件。
- 总线协议 monitor。

这些内容都重要，但不适合作为第一个 UVM 环境。

0835 更适合先选一个“小而真实”的验证对象：

```text
simple data bus + data_subsystem/peripheral wrapper
```

这个对象足够真实，因为它包含：

- valid/ready。
- response delay。
- read/write。
- byte enable。
- OK/error response。
- GPIO/UART/TIMER32 register behavior。
- W1C/读副作用/UART TX event。

同时它又足够小，因为不需要 CPU 指令流、GPR、CSR、trap handler 和 `.mem` 程序。

## 第3章 仿真器分工

### 3.1 Verilator 继续负责快速 directed regression

Verilator 适合继续维护现有路径：

```text
sim/soc_asm
sim/soc_c
tb/sv/tb_rv32i_soc.sv
sw/asm
sw/c
```

这条路径继续使用：

- ASM/C 程序。
- `imem/dmem` `.mem` 初始化。
- PASS/FAIL 状态字。
- commit/trap/data trace。
- TB mailbox。
- 0 wait-state 与 wait-state directed tests。

Verilator 的优势是快。它适合每次 RTL 修改后快速确认“CPU 还能跑完整软件回归”。

### 3.2 VCS 负责 SVA/UVM/coverage

0835 新增的验证能力建议放在 VCS 路径：

```text
sim/uvm_simple_bus
tb/uvm/simple_bus
```

原因：

| 能力 | 更适合 VCS 的原因 |
|---|---|
| UVM class | VCS 支持完整 SystemVerilog class/UVM 方法学 |
| sequence/driver/monitor | Verilator 不适合作为 UVM 主力 |
| SVA | VCS 对 concurrent assertion、bind、覆盖等支持更完整 |
| coverage | functional coverage 和 assertion coverage 更适合商业仿真器 |
| 调试 | VCS/Verdi 类工具链更适合 UVM/SVA debug |

这条路径不需要替代 Verilator。两者分工应清楚：

```text
Verilator: 快速软件自检端到端回归
VCS      : SVA/UVM/coverage 验证资产
```

### 3.3 SVA 与 Verilator 路径的隔离

SVA 可以通过宏或独立 filelist 控制：

```text
+define+ASSERT_ON
```

建议原则：

- Verilator 的现有 directed 回归不强制编译 UVM 文件。
- Verilator 路径不应因为 UVM/SVA 文件存在而变慢或变复杂。
- SVA 可以以 bind 文件或 interface 内 assertion 的形式接入 VCS。
- 若某些简单 immediate assertion 能被 Verilator 支持，可以作为额外增强，但不是 0835 主线。

## 第4章 验证对象和层次

### 4.1 两条验证线并行存在

0835 后工程里应长期保留两条验证线：

| 验证线 | 主要对象 | 是否需要 `.mem` | 主要价值 |
|---|---|---|---|
| SoC directed | `rv32i_soc + core + data_subsystem + 软件程序` | 需要 | 端到端功能回归 |
| UVM simple bus | `data_subsystem/peripheral wrapper/simple bus slave` | 不需要 | 协议、寄存器、副作用和覆盖 |

第一条线证明“软件能在 CPU 上跑通”。

第二条线证明“总线协议和外设寄存器语义在更多组合下成立”。

### 4.2 为什么 UVM demo 不需要测试程序

UVM 环境里，driver 本身就是“软件访问的替身”。

现有 directed test 的访问路径是：

```text
C/ASM 程序
  -> CPU 执行 load/store
  -> simple data bus
  -> data_subsystem/peripheral
```

UVM simple-bus demo 的访问路径是：

```text
UVM sequence
  -> simple_bus_driver
  -> simple data bus
  -> data_subsystem/peripheral
```

因此 UVM demo 不需要 `.mem` 文件，也不需要 crt0、linker script 或 trap handler。它直接发事务：

```text
write GPIO_OUT
read GPIO_OUT
write UART_TXDATA
read UART_STATUS
write TIMER32_MTIME
访问 unknown offset
随机 wait-state 下重复读写
```

这使验证对象更小，也更适合学习 UVM 的 transaction、sequence、driver、monitor、scoreboard。

### 4.3 UVM 第一版的 DUT 范围

第一版 UVM demo 不建议直接实例化整颗 `rv32i_soc`。

更推荐的 DUT 范围是：

```text
simple_bus master agent
  -> data_subsystem 或 data_subsystem 专用 harness
  -> simple_ram model
  -> GPIO0/UART0/TIMER0 register block
```

这里的 harness 可以完成：

- clock/reset。
- 连接 DMEM 模型。
- 连接 GPIO/UART 输入激励。
- 配置 response delay。
- 暴露 GPIO/UART/TIMER event 给 monitor。

这种 harness 属于验证环境，不是 SoC 真实功能。

### 4.4 为什么不直接验证 core

core 级 UVM 的价值很高，但不适合作为 0835 第一目标。

原因：

| 问题 | 说明 |
|---|---|
| stimulus 难 | 需要生成合法指令流、内存镜像和 handler |
| checker 难 | 需要参考模型或大量 commit 规则 |
| debug 难 | 失败可能来自 decoder、hazard、CSR、trap、MMIO、bus 中任意一层 |
| 方法学学习负担大 | UVM 还没熟时，不适合同时处理 CPU 级复杂度 |

0835 的 UVM demo 应先证明你会把一个小型协议/寄存器块验证环境搭起来。后续 0838 再把 UVM 观察点扩展到 SoC/CPU 级。

## 第5章 simple data bus 验证语义

### 5.1 simple data bus 信号

0834 后的 simple data bus 语义可以抽象为：

```text
request:
  valid
  ready
  write
  be
  addr
  wdata

response:
  valid
  rdata
  error
```

其中 `ready` 是 responder 给 master 的反压信号，不属于 request payload。

`valid/write/be/addr/wdata` 可以用 `data_req_t` 描述。

`valid/rdata/error` 可以用 `data_resp_t` 描述。

### 5.2 事务生命周期

一次事务的生命周期是：

```text
IDLE
  -> request valid
  -> request accepted: req.valid && req.ready
  -> outstanding
  -> response valid
  -> DONE
```

0 wait-state 允许：

```text
request accepted 与 response valid 同拍发生
```

非 0 wait-state 则是：

```text
request accepted 后等待若干拍，再返回 response valid
```

0835 的 monitor 和 SVA 都应围绕这个生命周期观察。

### 5.3 single outstanding 约束

当前 CPU data-side 是 single outstanding。

这意味着：

- 一笔 request accepted 后，在 response 返回前不能再接受第二笔。
- response 必须对应当前 outstanding request。
- 不需要 transaction ID。
- response 顺序天然等于 request 顺序。

这个约束非常适合第一版 SVA 和 scoreboard，因为状态空间小、错误也容易定位。

### 5.4 response error 约束

`resp.error=1` 表示本次事务失败。

对于 UVM simple-bus/peripheral demo：

| 情况 | 期望 |
|---|---|
| DMEM 合法访问 | `error=0` |
| GPIO/UART/TIMER 已定义 offset | `error=0` |
| GPIO/UART/TIMER unknown offset | `error=1` |
| 未映射地址 | `error=1` 或按 DUT 当前设计定义同拍 error |
| error response | 不应产生成功读写副作用 |

在 SoC directed 线中，error 会被 core 转换为 load/store access fault。

在 UVM simple-bus 线中，scoreboard 可以直接检查 `error` 和副作用关系，不需要 trap handler。

## 第6章 SVA 规划

### 6.1 SVA 的定位

SVA 不是为了替代 test，而是为了持续检查“协议绝不能违反”的性质。

适合 SVA 的性质通常有三个特点：

1. 和某个时序窗口有关。
2. 一旦违反就是设计 bug。
3. 用软件最终结果不容易观察。

0835 的 SVA 应先覆盖 simple data bus 和 MEM backpressure 的关键性质，不追求一次写完整形式验证。

### 6.2 simple data bus 断言方向

建议断言方向：

| 性质 | 说明 |
|---|---|
| payload stable | `req.valid && !req.ready` 时 `write/be/addr/wdata` 保持稳定 |
| single outstanding | accepted 后 response 前不再 accepted 第二笔 |
| response matched | 每个 response 必须发生在 idle accepted 同拍或 outstanding 状态 |
| no orphan response | 没有 outstanding 且本拍没有 accepted 时，不允许 response |
| response one-cycle pulse | 若协议定义 response 是脉冲，则 response 不应无条件保持 |
| no request during reset | reset 有效时不应产生真实 request/response |
| write strobe legal | store byte enable 不应为全 0，或按项目口径定义 |

这些断言可以挂在 simple bus interface 上，未来 AXI-Lite 前也可作为内部 bus 协议检查器复用。

### 6.3 CPU/MEM backpressure 断言方向

如果把 SVA 接回 SoC TB，可以考虑：

| 性质 | 说明 |
|---|---|
| mem_wait hold PC | MEM wait 期间 PC 不被 younger 指令覆盖 |
| IF/ID hold | MEM wait 期间 IF/ID 保持，除非 reset/trap kill |
| ID/EX hold | MEM wait 期间 ID/EX 保持，避免 consumer 越过 |
| EX/MEM hold | outstanding memory instruction 所在 MEM 边界保持 |
| MEM/WB hold source | memory wait 期间必要 forwarding source 不丢 |
| no duplicate commit | MEM/WB hold 不导致同一条指令重复 commit |
| no wrong-path request | kill/flush 后的 wrong-path 指令不发 data request |
| interrupt boundary | outstanding 未完成前不接受 interrupt trap |

这类断言更靠近 CPU 内部，依赖内部观察口。0835 可以先挑最关键、最稳定的少量性质，不必一次覆盖全部。

### 6.4 MMIO 副作用断言方向

MMIO 副作用很适合用 assertion/monitor 辅助检查：

| 外设 | 关注点 |
|---|---|
| GPIO W1C | 一次 accepted write 最多清一次 pending |
| GPIO input sync | bus wait 不影响输入同步与触发检测继续运行 |
| UART TX | 一次 TXDATA write 最多产生一次 tx_valid pulse |
| UART RXDATA read | 一次 RXDATA read 最多触发一次读清 |
| TIMER32 write | 写 MTIME/MTIMECMP/CTRL 的副作用只绑定一次访问 |
| TIMER32 count | bus wait 不暂停 timer 自增 |

对于这些性质，scoreboard 与 assertion 可以配合：assertion 检查“不能发生的时序”，scoreboard 检查“最终寄存器值和事件序列是否符合模型”。

### 6.5 SVA 接入方式

推荐 SVA 以两种形式组织：

| 形式 | 适用场景 |
|---|---|
| interface 内 assertion | simple bus 协议断言，和 bus 信号绑定紧密 |
| bind 文件 | 对现有 RTL 内部信号做检查，不污染可综合 RTL 主体 |

建议用宏控制：

```text
ASSERT_ON
```

这样 Verilator 路径可以继续保持轻量，VCS 路径负责 assertion 编译和运行。

## 第7章 UVM 入门 demo 规划

### 7.1 UVM 环境最小组成

第一版 UVM demo 应包含下列概念对象：

| 对象 | 作用 |
|---|---|
| transaction item | 描述一次 read/write 事务 |
| sequencer | 向 driver 提供 transaction |
| sequence | 生成 directed 或随机事务 |
| driver | 按 simple bus 协议驱动 request，并等待 ready/response |
| monitor | 被动观察 request accepted 和 response |
| agent | 封装 sequencer/driver/monitor |
| scoreboard | 根据参考模型检查 response 和外设副作用 |
| env | 组合 agent、scoreboard、coverage |
| test | 配置 env，选择 sequence 和验证场景 |

学习价值在于：这些就是后续 AXI-Lite UVM、SoC UVM 的基本骨架。

### 7.2 transaction item 内容

simple bus transaction 可以抽象为：

| 字段 | 含义 |
|---|---|
| `write` | 1 表示 write，0 表示 read |
| `addr` | byte address |
| `be` | byte enable |
| `wdata` | write data |
| `rdata` | observed read data |
| `error` | observed response error |
| `delay_hint` | 可选，用于约束或记录 response delay |
| `target` | 可选，monitor/scoreboard 根据地址译码得到 |

item 不需要包含 CPU 指令、PC 或 CSR 状态。它验证的是 bus/peripheral 事务，不是 CPU 执行流。

### 7.3 driver 语义

driver 的职责是把 transaction 转成 simple bus request：

```text
拉高 req.valid
驱动 write/be/addr/wdata
等待 req.ready
accepted 后撤销或准备下一笔
等待 resp.valid
把 resp.rdata/error 回填给 transaction 或发给 scoreboard
```

由于当前协议 single outstanding，driver 第一版不需要支持 pipeline outstanding 或乱序 response。

### 7.4 monitor 语义

monitor 是被动观察者，不驱动 DUT。

它应至少观察：

- request accepted 的周期。
- request payload。
- response valid 的周期。
- response rdata/error。
- response delay。
- target decode。
- UART TX/GPIO IRQ/TIMER IRQ 等外设事件。

monitor 输出的 transaction 应比 driver 更可信，因为它反映 DUT 引脚真实发生的事件。

### 7.5 scoreboard 语义

scoreboard 应维护一个轻量 reference model。

第一版可覆盖：

| 对象 | scoreboard 检查 |
|---|---|
| DMEM | write 后 read 返回对应 byte enable 合成结果 |
| GPIO OUT/OE | RW 寄存器读回正确 |
| GPIO IRQ_PENDING | W1C 清位、硬件事件置位、STATUS 镜像 |
| UART TXDATA | 合法 write 产生一次 TX event |
| UART RXDATA | RX valid 后读数据正确，读清语义正确 |
| UART IRQ_PENDING | RX 事件置位，W1C 清除，STATUS 镜像一致 |
| TIMER32 | MTIME/MTIMECMP/CTRL/STATUS 基本语义 |
| unknown offset | response error，且不产生成功副作用 |

scoreboard 不需要模拟 CPU pipeline，也不需要 trap/CSR。

### 7.6 sequence 规划

0835 的 sequence 应分两类。

第一类是 directed sequence：

| sequence | 覆盖 |
|---|---|
| simple read/write smoke | DMEM 和一个外设的基本读写 |
| byte enable sequence | DMEM byte/half/word 写掩码 |
| mmio register sequence | GPIO/UART/TIMER 已定义寄存器 |
| error sequence | unknown offset 和未映射地址 |
| side effect sequence | W1C、读清、UART TX pulse |

第二类是 constrained random sequence：

| sequence | 覆盖 |
|---|---|
| random target | DMEM/GPIO/UART/TIMER 混合访问 |
| random delay | 不同 response delay 组合 |
| random read/write | 合法寄存器读写组合 |
| random error | 合法和非法 offset 混合 |
| random byte enable | DMEM strobe 组合 |

第一版 random 不追求很大规模。目标是建立方法学和覆盖点，不是替代后续完整 UVM。

## 第8章 coverage 规划

### 8.1 为什么需要 coverage

directed test 的 PASS 只说明某个测试结果正确，不能说明验证空间覆盖多少。

coverage 的作用是回答：

```text
我们到底测到了哪些 target、访问类型、delay、error 和副作用组合？
```

0835 的 coverage 不需要非常复杂，但应能展示验证思路。

### 8.2 basic functional coverage

建议覆盖点：

| coverpoint | bin 示例 |
|---|---|
| target | DMEM、GPIO0、UART0、TIMER0、UNDEFINED |
| access type | read、write |
| response | OK、ERROR |
| delay | 0、1、2..3、4..7、8+ |
| byte enable | 0001、0010、0100、1000、0011、1100、1111、other |
| address kind | base、last defined offset、unknown offset、window boundary |
| side effect | W1C、read-clear、TX event、timer compare |

### 8.3 cross coverage 方向

0835 可以先选少量有意义的 cross：

| cross | 价值 |
|---|---|
| target x access type | 每个 target 都有 read/write 覆盖 |
| target x response | 每个外设的 OK/error 都被覆盖 |
| target x delay | 每个 target 都经历过 0 和非 0 wait-state |
| access type x byte enable | DMEM 写掩码和读写组合覆盖 |
| side effect x delay | 副作用寄存器在 wait-state 下也覆盖 |

不建议一开始追求 100% coverage。第一版 coverage 的价值是把验证空间显式化。

## 第9章 工程结构建议

### 9.1 目录划分

建议新增验证目录，但不影响现有 SoC directed test：

```text
tb/
  sv/
    tb_rv32i_soc.sv

  uvm/
    simple_bus/
      simple_bus_if.sv
      simple_bus_assert.sv
      simple_bus_pkg.sv
      simple_bus_item.sv
      simple_bus_sequencer.sv
      simple_bus_driver.sv
      simple_bus_monitor.sv
      simple_bus_agent.sv
      simple_bus_scoreboard.sv
      simple_bus_env.sv
      simple_bus_base_test.sv
      simple_bus_smoke_test.sv
      simple_bus_random_wait_test.sv
      tb_data_subsystem_uvm.sv

sim/
  uvm_simple_bus/
    filelist.f
    run_test.sh
    run_all.sh
```

这只是建议结构，不是强制施工步骤。实际实现时可以先合并文件，等环境稳定后再拆细。

### 9.2 filelist 和 package 关系

VCS/UVM 路径应有独立 filelist，避免影响 Verilator 路径。

filelist 大致分层：

```text
RTL common package
RTL DUT
UVM interface/assertion
UVM package/classes
UVM top
```

原则：

- `core_pkg.sv`、`soc_pkg.sv`、`data_bus_pkg.sv` 等公共包先编译。
- DUT RTL 后编译。
- UVM class package 再编译。
- top 最后编译。

### 9.3 VCS 脚本口径

VCS 脚本应服务 UVM/SVA，不复用 Verilator 的软件构建流程。

概念上应支持：

```text
+UVM_TESTNAME=<test>
+define+ASSERT_ON
+ntb_random_seed=<seed>
```

第一版不需要很复杂的命令行系统。关键是能稳定运行一个 smoke test、一个 wait-state/random test，并保留 log。

### 9.4 和现有脚本的关系

现有目录继续保留：

```text
sim/soc_asm
sim/soc_c
```

新目录只负责：

```text
sim/uvm_simple_bus
```

不要把 UVM 编译选项塞进现有 Verilator 脚本，也不要让现有 directed test 依赖 VCS。

## 第10章 和现有 SoC testbench 的关系

### 10.1 现有 testbench 继续保留

`tb/sv/tb_rv32i_soc.sv` 仍然是端到端 directed test 平台。

它负责：

- 连接 `rv32i_soc`。
- 加载 `.mem`。
- 监听 PASS/FAIL。
- 打印 commit/trap/data trace。
- TB mailbox 外部激励。
- 快速回归。

0835 不应把它改成 UVM testbench。

### 10.2 可以共享的观察思想

虽然 UVM 环境相对独立，但可以复用当前 TB 已经证明有效的观察口径：

| 观察点 | 用途 |
|---|---|
| request accepted | 区分访问意图和真实事务开始 |
| response event | 区分事务完成和指令提交 |
| mem_wait | 观察 backpressure |
| target hit | 判断 DMEM/GPIO/UART/TIMER/UNDEFINED |
| trap trace | SoC directed 中观察 delayed error |
| UART/GPIO/TIMER event | 观察外设副作用 |

这些概念在 UVM monitor 中会以 transaction/event 的形式重建。

### 10.3 后续可把 monitor 接回 SoC

0835 第一版 UVM 不验证整颗 CPU。

但 simple bus monitor/assertion 可以设计成未来可复用：

```text
0835: monitor 接 simple-bus UVM harness
0838: 同一个 monitor 接 rv32i_soc data bus 观察口
```

这样后续 SoC/CPU 级 UVM 不需要重写基础 bus monitor。

## 第11章 debug 和日志口径

### 11.1 UVM log 分层

UVM log 不应一开始就非常复杂，但应区分：

| 层级 | 内容 |
|---|---|
| test summary | test 名、seed、PASS/FAIL、coverage 摘要 |
| transaction log | request/response、target、addr、data、delay、error |
| scoreboard error | 期望值、实际值、相关历史事务 |
| assertion failure | 断言名、时间、关键信号 |

### 11.2 失败定位思路

验证失败时，优先按层次定位：

1. driver 是否发出了正确 request。
2. monitor 是否观察到 accepted request。
3. DUT response 是否按协议返回。
4. scoreboard reference model 是否合理。
5. assertion 是否揭示协议层问题。
6. 若是 SoC directed，再结合 commit/trap trace 定位 CPU 指令边界。

这个思路比直接看大波形更可维护。

## 第12章 和后续阶段的关系

### 12.1 和 0836 AXI-Lite 的关系

0836 会把 simple data bus 包装到 AXI-Lite。

0835 建立的经验会直接迁移：

| 0835 simple bus | 0836/0837 AXI-Lite |
|---|---|
| request accepted | AW/AR/W handshake |
| response valid | B/R response |
| payload stable | AXI VALID 未握手前 payload stable |
| response matched | read/write response 配对 |
| error response | SLVERR/DECERR |
| byte enable | WSTRB |
| target decode | AXI-Lite interconnect decode |

因此 0835 不只是验证当前 simple bus，也是为后续标准总线验证打基础。

### 12.2 和 0837 AXI-Lite UVM 的关系

0837 的目标会更标准化：

- AXI-Lite master/slave agent。
- 五通道握手。
- AW/W/B 和 AR/R 配对。
- AXI-Lite response。
- AXI-Lite coverage。

如果 0835 已经熟悉 item、driver、monitor、scoreboard、coverage，0837 就不再是从零开始。

### 12.3 和 0838 SoC/CPU UVM 的关系

0838 才适合把 UVM 接到更完整的 SoC/CPU 级：

- monitor commit。
- monitor trap。
- monitor bus。
- monitor interrupt。
- scoreboard PASS/FAIL、trap cause、MMIO side effect。

0835 应避免提前做这些，防止验证环境被 CPU 级复杂度拖垮。

## 第13章 本阶段完成标准

本阶段完成后，应能用一句话描述：

```text
当前项目保留 Verilator 软件自检快速回归，同时新增 VCS/SVA/UVM 验证路径；
0834 新增的 simple data bus、wait-state、response error 和 MMIO 副作用边界，
已经从 directed test 样例提升为可监控、可断言、可计分和可覆盖的验证资产。
```

更具体地说，应满足：

| 标准 | 判断 |
|---|---|
| directed 保留 | 现有 ASM/C self-check regression 不因 UVM 引入而退化 |
| 仿真器分工清楚 | Verilator 跑 directed，VCS 跑 SVA/UVM |
| SVA 可运行 | simple data bus 至少有 payload stable、single outstanding、response matched 等关键断言 |
| UVM smoke | simple-bus/peripheral UVM demo 能发起基本 read/write 并检查 response |
| scoreboard 基础 | 至少能检查 DMEM 基本读写和一个或多个 MMIO 寄存器语义 |
| wait-state 覆盖 | UVM 或 directed 能覆盖 0/非 0/random delay |
| error 覆盖 | unknown offset 或未映射访问能被 checker/scoreboard 检查 |
| 副作用覆盖 | UART TX、W1C、读清或 TIMER32 语义至少覆盖一类 wait-state 场景 |
| coverage 有输出 | 能看到 basic covergroup 或 assertion coverage 的结果 |
| 后续可复用 | monitor/interface/assertion 组织能迁移到 0837 AXI-Lite 或 0838 SoC UVM |

达到这些标准后，0835 就完成了它的阶段价值：不是把验证平台一次做到最终形态，而是让项目从“有 directed tests”升级到“开始具备工业验证方法学”。下一阶段 `0836` 再进入 AXI-Lite adapter/interconnect 与 accelerator 控制窗口定义。
