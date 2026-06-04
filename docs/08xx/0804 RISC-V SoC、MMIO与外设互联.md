# 0804 RISC-V(第五代精简指令集架构) SoC(片上系统)、MMIO(内存映射输入输出)与外设互联

> 文档编号：0804  
> 所属部分：08 处理器架构、RISC-V(第五代精简指令集架构) 与 CPU(中央处理器) 微架构  
> 对应总纲小节：8.8 RISC-V SoC、MMIO 与外设互联  
> 主题定位：系统讲清 RISC-V SoC 的 memory map(地址映射)、MMIO 寄存器块、bus(总线) 与 interconnect(互联) 结构、APB/AHB/AXI 三类常见片上总线的差异、PLIC/CLINT/timer 等外设中断链路，以及这些内容如何落到 RTL(寄存器传输级)、验证和面试表达。  
> 目标岗位：数字 IC(集成电路) 设计、数字 IC 验证、SoC(片上系统) 前端、嵌入式 SoC、CPU SoC 集成、FPGA(现场可编程门阵列)/ASIC(专用集成电路) RTL 相关岗位。  
> 前置知识：建议先阅读 `0801 RISC-V ISA基础.md`、`0802 RISC-V五级流水线与Hazard.md`、`0803 CSR、异常中断与特权级.md`；需要理解 load/store(加载/存储)、trap(陷入)、interrupt(中断)、SystemVerilog(系统 Verilog)、basic handshake(基础握手) 和寄存器读写概念。

---

## 术语首次出现说明

本文档遵循“英文名词或缩写首次出现时给出中文名称”的规则。以下术语在后文会高频出现，后续再次出现时可直接使用英文或缩写。

| 英文术语 | 中文名称 | 英文术语 | 中文名称 | 英文术语 | 中文名称 |
|---|---|---|---|---|---|
| RISC-V | 第五代精简指令集架构 | CPU | 中央处理器 | IC | 集成电路 |
| SoC | 片上系统 | MMIO | 内存映射输入输出 | bus | 总线 |
| RTL | 寄存器传输级 | FPGA | 现场可编程门阵列 | ASIC | 专用集成电路 |
| SystemVerilog | 系统 Verilog | load/store | 加载/存储 | basic handshake | 基础握手 |
| interconnect | 互联 | master | 主设备 | slave | 从设备 |
| bridge | 桥接器 | address decode | 地址译码 | register block | 寄存器块 |
| ROM | 只读存储器 | SRAM | 静态随机存取存储器 | flash | 闪存 |
| GPIO | 通用输入输出 | UART | 通用异步收发器 | SPI | 串行外设接口 |
| I2C | 集成电路间总线 | timer | 定时器 | interrupt | 中断 |
| PLIC | 平台级中断控制器 | CLINT | 核局部中断控制器 | DMA | 直接存储器访问 |
| APB | 高级外设总线 | AHB | 高级高性能总线 | AXI | 高级可扩展接口总线 |
| handshake | 握手 | valid-ready | 有效-就绪握手 | backpressure | 反压 |
| byte enable | 字节使能 | burst | 突发传输 | align | 对齐 |
| cacheable | 可缓存 | device memory | 设备内存 | endian | 字节序 |
| read-modify-write | 读-改-写 | side effect | 副作用 | reset | 复位 |
| W1C | 写 1 清 0 | W1S | 写 1 置 1 | W1T | 写 1 翻转 |
| RO | 只读 | RW | 可读可写 | WO | 只写 |
| RC | 读清零 | WSTRB | 写字节掩码 | bus timeout | 总线超时 |
| clock domain crossing | 时钟域跨越 | synchronizer | 同步器 | async interrupt | 异步中断 |
| boot ROM | 启动只读存储器 | reset vector | 复位入口地址 | debug module | 调试模块 |
| memory map | 地址映射 | address map | 地址映射 | polling | 轮询 |
| trap | 陷入 | software interrupt | 软件中断 | timer interrupt | 定时器中断 |
| external interrupt | 外部中断 | bug | 缺陷 | debug | 调试 |
| scoreboard | 记分板 | SVA | SystemVerilog 断言 | coverage | 覆盖率 |
| directed test | 定向测试 | random test | 随机测试 | PPA | 性能、功耗、面积 |
| Fmax | 最高工作频率 | CDC | 跨时钟域 | STA | 静态时序分析 |
| OS | 操作系统 | bare-metal | 裸机软件 | runtime | 运行时 |
| driver | 驱动程序 | linker script | 链接脚本 | memory layout | 内存布局 |
| descriptor | 描述符 | doorbell | 门铃寄存器 | RTOS | 实时操作系统 |
| DRAM | 动态随机存取存储器 | NOR flash | 或非型闪存 | NAND flash | 与非型闪存 |
| eMMC | 嵌入式多媒体卡 | UFS | 通用闪存存储 | SSD | 固态硬盘 |
| storage controller | 存储控制器 | block device | 块设备 | file system | 文件系统 |
| firmware | 固件 | bootloader | 启动加载程序 | OTA | 空中升级 |
| app | 应用程序 | user data | 用户数据 | XIP | 片上执行/就地执行 |
| persistent storage | 持久化存储 | block/page | 块/页 | A/B slot | A/B 启动槽 |
| debug master | 调试主设备 | DRAM controller | 动态内存控制器 | memory controller | 存储器控制器 |
| outstanding | 未完成事务 | QoS | 服务质量 | ID | 事务标识 |

---

## 第0章 本专题学习地图

### 0.0 这篇文档到底解决什么

RISC-V 的指令集只规定了“CPU 如何算”和“软件如何看见寄存器、异常和中断”。一旦系统里出现 ROM、SRAM、UART、GPIO、定时器、DMA、外部中断控制器和调试模块，就必须有一层把 load/store 映射到具体硬件行为的 SoC 互联。

这篇文档要解决的是：

- 软件如何通过地址访问外设寄存器。
- CPU 和外设如何共享一张 memory map。
- 总线如何把地址、数据、字节掩码和握手协议传递到设备端。
- 低速外设为什么常挂 APB，高速路径为什么常挂 AHB/AXI。
- PLIC/CLINT 如何把外设事件变成 CPU 可见的 interrupt。
- MMIO 寄存器该如何设计，才能既好用又不容易出 bug。

### 0.1 小节关系

本篇按下面顺序展开：

1. 第1章讲 SoC、MMIO、程序/用户数据存储和 memory map 的基本概念。
2. 第2章讲 memory map、地址译码和总线分层，说明 APB/AHB/AXI 的适用场景。
3. 第3章讲 MMIO 寄存器的设计模式，包括 RO/RW/WO/W1C/W1S/RC 和 byte enable。
4. 第4章讲 SoC 级外设互联，重点是 PLIC、CLINT、timer、UART、GPIO、DMA 和 boot 流程。
5. 第5章讲 RTL 结构，给出地址译码、寄存器块、桥接和中断同步的骨架。
6. 第6章讲验证方法：定向测试、随机测试、scoreboard、SVA 和 coverage。
7. 第7章讲时序、CDC、综合和后端影响。
8. 第8章讲常见 bug、边界条件和 debug 方法。
9. 第9章讲面试问法。
10. 第10章讲练习题与答案要点。
11. 第11章讲和其他章节的关联。

### 0.2 和前后文的关系

- `0803 CSR、异常中断与特权级.md` 讲的是 trap 和 privilege；本篇讲的是 trap 之外的外设与系统控制面。
- `0805 Cache、TLB、MMU、分支预测与内存模型.md` 会继续讲 cacheable/device memory、TLB、MMU、memory model 和预测。
- `070x` 总线、DMA 和 SoC 互联专题可作为本篇的结构延伸。

---

## 第1章 SoC 和 MMIO 是什么

当前阶段建议：简单了解本章，重点建立 ROM/SRAM、memory map、MMIO 和外设寄存器的直觉，最小教学核可先用简单 imem/dmem 代替完整 SoC。

### 1.0 为什么 SoC 需要 memory map

`0801` 第7章先从用户视角建立了直觉：程序、OTA 更新包、app、照片和短信这些东西，最终会落在不同类型的存储资源上；CPU 真正执行时，又需要通过取指、load/store、cache、MMIO 和 storage controller 把它们连接起来。本章从 SoC 角度继续回答：这些资源如何被放进地址空间，软件又如何可靠地访问它们。

SoC 里不仅有 CPU core，还有 ROM、SRAM、DRAM controller、UART、GPIO、timer、PLIC、CLINT、DMA、debug module 等模块。CPU core 只会发出比较统一的取指、load/store 或总线请求；它并不知道“这个地址后面接的是 UART 还是 SRAM”。SoC 需要一张地址规划，把不同地址范围分配给不同硬件模块，这张规划就是 memory map。

可以先把 memory map 理解成“地址空间里的城市地图”：

| 概念 | 直觉 | 硬件含义 |
|---|---|---|
| address space | CPU 能发出的地址范围 | 例如 RV32 下常见 32 bit 地址空间 |
| region/window | 一段连续地址窗口 | 分配给 ROM、SRAM、UART、PLIC 等 |
| base | 窗口起始地址 | 地址译码比较的基准 |
| size | 窗口大小 | 决定这个设备占多少地址 |
| offset | 地址在窗口内部的偏移 | 外设内部用来选择具体寄存器 |

例如 UART 基地址是 `0x4000_0000`，`STATUS` 寄存器偏移是 `0x04`，那么软件读 `0x4000_0004`，硬件先通过高位地址选中 UART，再把低位 offset 交给 UART 寄存器块选择 `STATUS`。

最简单、最通用的方式就是把外设寄存器和片上存储器放进同一个地址空间。

这样软件只需执行普通 load/store，就能：

- 读写 UART 控制寄存器。
- 配置 GPIO 方向和输出值。
- 读取 timer 当前值。
- 使能中断。
- 访问 DMA 描述符或状态寄存器。

这就是 MMIO。

系统 OS 视角下，memory map 是硬件平台和软件镜像之间的契约。裸机启动代码、链接脚本、OS 内核和外设驱动都要知道“哪些地址是 ROM/SRAM，哪些地址是 UART/timer/PLIC/CLINT”。硬件若改了地址映射，软件头文件、链接脚本和驱动没有同步，表现就不是“软件小错”，而是 CPU 取不到指令、栈落到错误区域、或者驱动写到错误外设。

### 1.1 MMIO 和普通内存的区别

MMIO 看起来像内存地址，CPU 访问它也常用普通 `LW/SW`。但它的语义通常不同于普通 SRAM/DRAM：普通内存主要是“保存数值”，MMIO 主要是“控制硬件或观察硬件状态”。

| 项目 | 普通内存 | MMIO |
|---|---|---|
| 目标 | 存放数据和程序 | 控制硬件、读状态、触发动作 |
| 缓存 | 通常可缓存 | 通常不可缓存 |
| 读写副作用 | 通常没有 | 常见读清零、写触发、W1C |
| 顺序要求 | 受 memory model 约束 | 往往更强，常需屏障 |
| 错误处理 | 可能是 page fault | 可能是 bus error / access fault |

同样一条 store，目标不同，含义就完全不同：

```text
SW x5, 0(x10)

如果 x10 指向 SRAM:
  把 x5 的值存到内存单元，之后读回来应得到同一个值。

如果 x10 指向 UART TXDATA:
  可能表示发送一个字符；寄存器本身未必真的“保存”这个值。

如果 x10 指向 TIMER CTRL:
  可能表示启动、停止或清除计数器。
```

这就是 MMIO 最容易让初学者困惑的地方：ISA 层还是 load/store，但 SoC 层已经变成“总线事务 + 外设寄存器语义 + 硬件副作用”。

### 1.2 一个典型 SoC 的资源图

```text
          +----------------------+
          |        CPU core      |
          +----------+-----------+
                     |
                 load/store
                     |
          +----------v-----------+
          |  interconnect/bridge |
          +---+------+-----+-----+
              |      |     |
              |      |     +-------------------+
              |      |                         |
            ROM    SRAM/DRAM                peripheral bus
             |        |                       /   |     \
          boot code runtime data           UART  GPIO  TIMER
                                                  |      \
                                              storage   PLIC/CLINT
                                             controller
                                                  |
                                           flash/eMMC/UFS/SSD
```

图里有两类访问路径要分开：

| 路径 | 典型用途 | 访问特点 |
|---|---|---|
| memory path | 取指、读写普通数据、访问 DRAM/SRAM | 追求带宽和延迟，可能经过 cache |
| peripheral path | 配置 UART/GPIO/timer/PLIC 等 | 追求语义准确，通常不可缓存，访问频率较低 |

很多系统 bug 正是因为把两类路径混了：把外设寄存器当普通 memory cache，或者把普通 DRAM 当 device memory 访问，都会让性能或正确性出问题。

### 1.3 典型 memory map

地址规划是平台设计的一部分，没有统一固定值。下面只是常见示意：

| 区域 | 作用 | 访问特征 |
|---|---|---|
| boot ROM | 复位后执行的启动代码 | 只读、低速、对齐访问 |
| SRAM | 片上快速数据/代码存储 | 可读写、通常可缓存 |
| DRAM | 大容量运行时内存 | 可读写，通常经 cache/MMU 访问 |
| NOR flash | 固件或 XIP 代码存储 | 非易失，读方便，写/擦慢 |
| NAND/eMMC/UFS/SSD | app、文件系统、用户数据、OTA 包 | 非易失，常通过 storage controller 按 block/page 访问 |
| peripheral window | 外设寄存器窗口 | MMIO、常见不可缓存 |
| interrupt controller | 中断控制器寄存器 | MMIO、寄存器语义复杂 |
| DMA / descriptor window | DMA 控制区 | MMIO 或描述符内存 |

对系统软件来说，这张表会进一步落实为 linker script、启动汇编和驱动头文件：代码段放在哪里、栈从哪里开始、`.bss` 清零覆盖哪个范围、外设基地址是多少，都依赖同一份 memory map。数字 IC 不需要深入链接器实现，但需要知道硬件地址规划会直接决定软件能不能启动和访问外设。

需要特别区分两类“掉电不丢”的区域：boot ROM 通常是芯片出厂固化的最早启动代码，运行时一般不能改；flash/eMMC/UFS/SSD 这类 persistent storage 则用于固件镜像、app、OTA 包和 user data，可以通过控制器更新。后者经常不是 CPU 随便 `LW` 一个地址就能读到某张照片，而是 OS/driver 配置 storage controller，控制器按 block/page 读出数据，再通过 DMA 或 CPU 执行拷贝循环放入 DRAM/SRAM，之后 CPU 才从普通 memory/cache 中处理这些数据。

### 1.4 MMIO 的工程本质

MMIO 的本质不是“在地址空间里放一段 RAM”，而是把地址译码结果映射到硬件动作：

- 读某个地址返回状态。
- 写某个地址修改控制位。
- 写某个位触发一次脉冲。
- 读某个地址清除 pending 位。

因此 MMIO 的 RTL 关键不是加法，而是副作用控制。

可以用三个层次理解一次 MMIO 写：

```text
软件层:
  *(UART_CTRL) = enable;

CPU/总线层:
  发出一次 store，带 addr/wdata/wstrb/protection 等信息。

外设层:
  UART 寄存器块看到 CTRL offset 被写，更新 enable 位或触发动作。
```

如果目标是 RAM，写事务的核心是“这个字节 lane 被写成什么值”；如果目标是 MMIO，核心还包括“写入是否触发一次 pulse、是否清 pending、是否允许部分写、是否需要返回错误”。所以 MMIO register spec 必须先讲清软件可见语义，再谈 RTL。

从 CPU 的角度看，一次 MMIO 访问只是普通 load/store；从 SoC 的角度看，它会被拆成完整事务：

```text
CPU load/store
  -> LSU 计算地址、生成 size/wstrb
  -> interconnect 地址译码
  -> bridge 协议转换
  -> peripheral register block
  -> 读返回、写响应或错误响应
  -> CPU commit 或 exception
```

这条链路里任何一级都可能改变系统行为。地址译码错会访问到错误外设，bridge 丢请求会导致软件偶发卡死，寄存器副作用没定义清楚会导致驱动程序和硬件互相误解。因此，SoC/MMIO 的设计重点不是“能读写寄存器”，而是把软件可见语义、总线事务和硬件副作用对齐。

| 观察层次 | 软件看到什么 | 硬件必须保证什么 | 典型 bug |
|---|---|---|---|
| ISA/CPU | 一条 load/store | 地址、宽度、异常和顺序符合规则 | 非法 MMIO 未产生 access fault |
| Interconnect | 一个地址范围 | decode 唯一、响应不丢失 | 多个 slave 同时响应 |
| Bridge | 协议转换 | valid/ready 或 APB setup/access 阶段保持稳定 | backpressure 下地址变化 |
| Register block | 寄存器读写 | W1C/RO/RC/WO 等语义准确 | 写 1 清零写成普通 RW |
| 外设逻辑 | 状态和事件 | 事件锁存、清除、触发边界明确 | 中断脉冲丢失或重复 |

---

## 第2章 总线和互联

当前阶段建议：简单了解本章，先知道 CPU 访问存储器和外设需要地址译码、总线事务和握手；复杂 APB/AHB/AXI 细节可暂时跳过。

### 2.0 为什么不能所有模块都直接连 CPU

如果每个外设都直接拉到 CPU 总线上：

- 地址线会爆炸。
- 仲裁会难看。
- 时序会很差。
- 复用和扩展性几乎没有。

所以需要 interconnect 和 bridge，把 CPU 侧的通用访问转成各外设能接受的局部协议。

更具体地说，CPU 侧通常希望看到一个统一接口：

```text
addr + read/write + wdata + wstrb -> response/rdata/error
```

但每个外设内部只关心自己的寄存器偏移和局部控制信号。interconnect 负责“这笔请求该送到谁”，bridge 负责“协议和节拍怎么转换”，外设寄存器块负责“这个 offset 的读写语义是什么”。这三件事拆开，系统才容易扩展和验证。

从 `0802` 第7章 structural hazard 的视角看，总线和互联就是把“多个访问者抢同一访问路径”的问题系统化：CPU、DMA、debug master 或其他外设都可能想访问同一个 SRAM、DRAM controller 或 MMIO bus。简单系统用单 master、单 outstanding 避开大部分冲突；复杂系统则必须用仲裁、buffer、ID 和 backpressure 明确谁先用资源、请求如何等待、响应回到哪里。

### 2.1 master / slave / bridge

| 角色 | 作用 | 例子 | 设计时最关心什么 |
|---|---|---|---|
| master | 发起读写请求的一方 | CPU、DMA、debug master | 请求什么时候发、能否等待、响应回到哪里 |
| slave | 响应请求的一方 | SRAM、UART、GPIO、PLIC、CLINT | 地址 offset 怎么解释、何时返回 ready/error |
| bridge | 在不同协议、宽度或速度之间做转换 | AXI-to-APB bridge、AHB-to-register bridge | 请求保持、节拍转换、错误映射、CDC |

master/slave 只是总线方向上的角色，不等于软件权限高低。比如 DMA 是 master，因为它能主动读写 memory；UART 寄存器块是 slave，因为它只响应 CPU 或 DMA 的访问。

### 2.2 APB、AHB、AXI 的定位

| 总线 | 典型定位 | 优点 | 代价 |
|---|---|---|---|
| APB | 低速外设寄存器 | 简单、面积小、易验证 | 吞吐低，单事务粒度小 |
| AHB | 中等带宽片上总线 | 比 APB 更高性能 | 控制复杂度上升 |
| AXI | 高性能、多主设备系统 | 并发能力强、吞吐高 | 通道多、实现和验证复杂 |

这三者不是“越高级越好”，而是面向不同带宽和复杂度。UART/GPIO/timer 这类寄存器访问很少需要 burst 和多 outstanding，用 APB 反而面积小、验证简单；DRAM、DMA、显示或 AI 加速器这类高带宽路径才更需要 AXI 的并发能力。

常见策略是：

- CPU/DRAM/高速 DMA 走 AXI 或类似高性能通道。
- UART/GPIO/I2C/SPI/timer 走 APB。
- 中间用 bridge 把高性能通道转换成简单寄存器访问。

### 2.3 地址译码

地址译码要做的事很直接：

$$
sel_i = ((addr \mathbin{\&} mask_i) = base_i)
$$

但工程上要特别注意：

- 区域是否重叠。
- 地址是否对齐。
- 不同区域是否有不同访问宽度。
- 非法地址是否返回 error。

地址译码最好被当成 SoC 规格的一部分，而不是 RTL 里随手写的 `case`。一个地址窗口通常至少需要定义：

| 字段 | 例子 | 作用 |
|---|---|---|
| `base` | `32'h4000_0000` | 区域起始地址 |
| `size` | `64KB` | 地址窗口大小 |
| `mask` | `32'hFFFF_0000` | 用于快速匹配 |
| attribute | device/uncached/cacheable | 决定是否进 cache、是否允许合并 |
| access | R/W/X、privilege | 决定非法访问是否报错 |
| slave | UART/GPIO/TIMER | 决定请求路由 |

两个工程约束非常关键：

$$
\sum_i sel_i \le 1
$$

表示同一请求最多命中一个 slave；如果所有 `sel_i` 都为 0，则应进入默认错误响应或空洞区域处理。

```text
addr hits exactly one slave -> route request
addr hits no slave          -> return bus error / access fault
addr hits multiple slaves   -> SoC integration bug
```

在验证里，地址窗口边界要重点测：`base-1`、`base`、`base+size-1`、`base+size`。很多 decode bug 都发生在窗口闭开区间定义不一致。

还要注意，地址译码不只是“选 slave”。它常常也给后续模块提供属性：

```text
这个地址是否 cacheable？
是否允许执行取指？
低权限能不能访问？
访问失败时返回 bus error 还是触发 access fault？
```

这些属性会继续影响 `0805` 里的 cache/MMU/PMA/PMP，也会影响 `0803` 里的 trap 原因。因此 memory map、地址译码和异常处理不是三套孤立逻辑。

### 2.4 事务和握手

对外设来说，一次总线访问不是“线上的值变化一下”就结束，而是一笔事务。事务至少要明确：请求何时被接受、读数据何时有效、写副作用何时发生、错误如何返回。

事务通常可抽象为：

- `valid`：请求是否有效。
- `ready`：对方是否接受。
- `addr`：访问地址。
- `wdata`：写数据。
- `rdata`：读返回。
- `wstrb`：字节写掩码。

在有反压的系统里，`ready` 不一定一直为 1。慢外设可能需要多拍响应，这时 bridge 或 interconnect 必须保留请求状态，不能丢事务。

一个最小 valid-ready 读写事务可以理解为：

$$
fire = valid \land ready
$$

只有 `fire` 成立时，请求才算被对端接受。若 `valid=1` 且 `ready=0`，请求方必须保持关键字段稳定：

```text
valid = 1, ready = 0:
  addr
  write/read
  wdata
  wstrb
  protection/attribute
都不能随意变化
```

这条规则是 bridge 和慢外设最容易出 bug 的地方。比如 CPU 连续写 UART，然后 APB bridge 因外设未 ready 暂停，如果 bridge 没有锁存第一笔事务，第二笔事务的地址或数据可能覆盖第一笔，软件看到的就是“偶尔少写一个字符”。

常见事务类型可以这样区分：

| 事务 | 请求阶段 | 响应阶段 | 设计重点 |
|---|---|---|---|
| posted write | 发出后不等最终完成 | 可能只有接受响应 | 延迟低，但错误上报和顺序更复杂 |
| non-posted write | 等写完成响应 | 有明确完成点 | 简单可靠，吞吐较低 |
| blocking read | 等读数据返回 | 必须返回 rdata/error | 需要保存 outstanding request |
| pipelined read | 可连续发多笔读 | 响应可能排队 | 需要 ID 或严格顺序规则 |

入门 SoC 通常选择单 outstanding、按序响应，这样验证和精确异常更简单；高性能 AXI 系统则会支持多个 outstanding，需要 ID、reorder、timeout 和更复杂的 scoreboard。

这里和 CPU pipeline 的 stall 很像：`ready=0` 并不是错误，而是下游告诉上游“这拍先别把事务交给我”。上游可以停住、保持请求，也可以在有 buffer 的情况下继续接收新请求；但不管怎么做，已经被接受的事务都必须最终有清楚的响应，否则软件会卡在一次 load/store 上。

---

## 第3章 MMIO 寄存器设计模式

当前阶段建议：可以先简单了解，等教学核要接 UART/GPIO/timer 等外设时再详细看寄存器类型、副作用和 byte enable。

### 3.0 为什么 MMIO 最容易出 bug

CPU 看见的是地址，软件看见的是寄存器名，硬件看见的是副作用。三者如果没对齐，系统就会在最难调的地方出问题。

普通 memory 的行为相对单纯：写进去什么，之后读出来什么。MMIO register 的行为由规格定义，可能是“写 1 清零”“读一次弹出 FIFO”“写任意值触发一次 start pulse”。因此 MMIO bug 往往不是单纯的数据位错，而是软件和硬件对“这次读写代表什么动作”的理解不一致。

### 3.1 常见寄存器类型

| 类型 | 语义 | 典型用途 | 直觉 |
|---|---|---|---|
| RO | 只读，软件写无效或报错 | 状态寄存器、计数器值 | 硬件告诉软件当前状态 |
| RW | 可读可写 | 控制位、配置位 | 软件保存一个配置，硬件按配置工作 |
| WO | 只写，读值无意义或固定 | 触发脉冲、命令门铃 | 软件写一下表示“做一次动作” |
| W1C | 写 1 清 0，写 0 不影响 | 中断 pending、错误标志 | 软件只清自己确认过的事件 |
| W1S | 写 1 置 1，写 0 不影响 | 使能位、门控位 | 只打开某些位，不误改其他位 |
| W1T | 写 1 翻转，写 0 不影响 | 某些调试或特殊控制位 | 用写脉冲翻转状态 |
| RC | 读后清零或读后弹出 | FIFO 弹出、事件计数脉冲 | 读取本身就是消费动作 |

W1C 特别常见，因为它适合清中断 pending。假设 `IRQ_STATUS[3:0]` 有多个事件同时 pending，软件只想清 bit0。如果这是普通 RW，软件要先读旧值、改 bit0、再写回；在读写之间新事件可能到来。W1C 则允许软件直接写 `4'b0001`，只清 bit0，其他位保持或由硬件事件继续置位。

### 3.2 读写副作用

MMIO 的读写经常带副作用：

- 读某个寄存器会清除 pending 位。
- 写某个位会启动一次传输。
- 读数据寄存器会把 FIFO 的下一项弹出。

这类寄存器最怕被错误 cache、错误重读或错误合并写。

副作用的关键是“读写不再只是搬数据”。比如：

| 寄存器 | 普通读写直觉 | 实际 MMIO 语义 |
|---|---|---|
| UART `RXDATA` | 读一个数 | 可能同时把 FIFO 中这个字节弹出 |
| DMA `START` | 写一个数 | 可能启动一次 DMA 传输 |
| `IRQ_STATUS` | 写一个数 | 写 1 可能清除 pending |
| `ERROR_LOG` | 读一个数 | 可能清除 sticky error 或移动读指针 |

所以编译器优化、cache、speculative read、总线重试和 bridge 重放都可能影响 MMIO 正确性。对带副作用的寄存器，必须明确副作用发生在“请求接受”还是“响应完成”，并避免 wrong-path/speculative 访问真正触发外设动作。

副作用寄存器要先定义“副作用发生在什么时候”。对同步总线，通常应在事务真正被接受或响应完成时触发，而不是只要地址译码命中就触发。

| 副作用类型 | 触发点建议 | 常见用途 | 风险 |
|---|---|---|---|
| write pulse | 写事务 `fire` 时产生一拍脉冲 | start、kick、doorbell | ready=0 时提前触发 |
| W1C | 写事务生效时按 1 清位 | IRQ pending、error flag | 事件同拍置位/清位优先级不清 |
| RC | 读响应被接受时清位 | FIFO pop、计数器快照 | CPU speculative read 或重复读造成丢事件 |
| RO sticky | 硬件置位，软件通过 W1C 清 | 错误状态 | 硬件事件和软件清除同拍冲突 |

W1C 中最常见的同拍冲突是：硬件事件置位 `status[0]`，软件同一拍写 1 清 `status[0]`。必须在规格中写清优先级。很多外设会选择“新事件优先”，避免软件清除旧事件时丢掉新到事件：

$$
status_{next} = (status_{old} \mathbin{\&} \sim w1c\_mask) \lor event\_set
$$

如果选择“清除优先”，也不是不可以，但软件驱动要知道存在丢边沿风险，并用额外 pending/计数机制补偿。

### 3.3 byte enable 与部分写

外设寄存器通常按 32 位或 64 位组织，但总线可能支持字节粒度写。

因此需要考虑：

- 哪些字节写掩码有效。
- 部分写是否允许。
- 小端序和大端序的字节 lane 映射。
- 半字/字/双字访问是否都支持。

对 32 bit 小端寄存器，`WSTRB` 与字节 lane 的关系通常是：

| `WSTRB` bit | 对应数据位 | 对应地址低位 |
|---|---|---|
| `wstrb[0]` | `wdata[7:0]` | `addr[1:0] = 2'b00` |
| `wstrb[1]` | `wdata[15:8]` | `addr[1:0] = 2'b01` |
| `wstrb[2]` | `wdata[23:16]` | `addr[1:0] = 2'b10` |
| `wstrb[3]` | `wdata[31:24]` | `addr[1:0] = 2'b11` |

如果寄存器字段跨 byte，例如 `MODE[9:0]`，部分写就要特别谨慎。软件可能先写低字节再写高字节，中间硬件不应短暂启动一个非法模式。常见处理方式包括：

- 对配置寄存器允许 byte write，但启动动作必须由单独 `START` 位触发。
- 对关键寄存器只允许整字写，非法 `WSTRB` 返回 error。
- 使用 shadow register，软件写完多个字段后再 commit。

### 3.4 一个典型寄存器块

| 寄存器 | 类型 | 作用 | 软件通常怎么用 |
|---|---|---|---|
| `CTRL` | RW | 使能、模式选择 | 初始化时配置模式，必要时启动/停止模块 |
| `STATUS` | RO | 忙闲、错误、完成状态 | polling 或 debug 时读取 |
| `IRQ_EN` | RW/W1S | 中断使能 | driver 打开某些事件的中断 |
| `IRQ_STATUS` | W1C | 中断 pending | handler 读状态后写 1 清除已处理事件 |
| `DATA_IN` | WO | 写入发送数据 | 软件写入一个待发送字节或命令 |
| `DATA_OUT` | RO/RC | 读出接收数据 | 软件读取接收数据，可能同时弹出 FIFO |

一个常见 driver 流程如下：

```text
初始化:
  写 CTRL 配置模式
  写 IRQ_EN 打开需要的中断

运行:
  读 STATUS 判断是否 busy
  写 DATA_IN 发送数据
  中断到来后读 IRQ_STATUS
  处理对应事件
  写 IRQ_STATUS 的 W1C 位清 pending
```

这条软件流程反过来决定硬件寄存器语义：`STATUS` 不能读清零，`IRQ_STATUS` 应该能单独清某些位，`DATA_IN` 的写副作用不能在总线事务未完成时提前发生。

### 3.5 工程要点

- 对应寄存器的默认值要定义清楚。
- 只读位不能被写覆盖。
- W1C 位不能写成普通清零。
- 读清零必须只清应清的位。
- 软件经常会做 read-modify-write，所以寄存器语义要避免歧义。

一个成熟的 MMIO register spec 至少要写清：

| 项目 | 为什么重要 |
|---|---|
| reset value | 驱动初始化和仿真 reset 后检查依赖它 |
| access type | RO/RW/W1C/RC/WO 决定 RTL 更新函数 |
| write mask 支持 | 决定 byte/halfword write 是否合法 |
| side effect | 决定读写是否能被缓存、合并、重复 |
| clock/reset domain | 决定 CDC/RDC 和同步策略 |
| interrupt relation | 决定 pending、enable、clear 的优先级 |
| reserved bits | 软件写保留位时硬件如何处理 |

面试里讲寄存器块，不要只说“我做了几个寄存器”。更好的表达是：我把寄存器类型和硬件事件分开建模，RW 走写掩码函数，W1C 走清位函数，硬件事件有明确置位优先级，读副作用只在事务完成点触发，最后用 directed test 和 SVA 验证每类语义。

---

## 第4章 外设、中断和启动路径

当前阶段建议：先简单了解 boot ROM、timer、PLIC/CLINT 和中断链路的角色；最小无中断教学核可以暂时不实现这些模块。

### 4.0 PLIC 和 CLINT 的角色

RISC-V SoC 里最常见的两类中断控制模块是：

- `CLINT`：提供本地 timer interrupt 和 software interrupt。
- `PLIC`：汇聚、优先级排序和分发外部中断。

它们解决的问题不同：

- `CLINT` 负责“这个 hart 自己的本地中断”。
- `PLIC` 负责“很多外设来的外部中断该先响谁、谁来回应”。

可以这样建立直觉：

| 模块 | 管理对象 | 更像什么 | 常见输出 |
|---|---|---|---|
| CLINT | 每个 hart 相关的软件中断、定时器中断 | 每个 CPU 附近的本地闹钟和核间通知 | `msip/mtip` 等本地中断 pending |
| PLIC | 多个外设共享的外部中断源 | 全局中断调度台 | external interrupt pending 到某个 hart/context |

对支持 OS 的系统，timer interrupt 常用于调度时间片，software interrupt 常用于 hart 之间互相通知，external interrupt 常用于 UART、网卡、存储控制器等外设服务。具体哪些中断进 M-mode，哪些委派给 S-mode，要和 `0803` 的 `mie/mip/mideleg`、`stvec/mtvec` 配合。

### 4.1 外设中断链路

外设中断一般不会直接进 CPU，而是先经过控制器和同步逻辑：

```text
UART/SPI/I2C/GPIO/timer
        |
        v
   pending/priority
        |
      PLIC/CLINT
        |
        v
   interrupt sync
        |
        v
      CPU trap
```

一条外设中断从事件到 CPU trap，通常经历四层状态：

| 层次 | 状态 | 作用 |
|---|---|---|
| 外设内部 | event/status | 记录 UART 收到数据、timer 到点等原始事件 |
| 外设寄存器 | irq_status/irq_en | 软件可见 pending 和使能 |
| 中断控制器 | source pending/priority/target | 聚合多个外设并选择目标 hart |
| CPU CSR | `mip/mie/mstatus` | 决定当前 privilege 是否接受 trap |

这几层不能混成一个信号。外设可以已经 pending，但 PLIC 还没选择它；PLIC 可以已经拉起 external interrupt，但 CPU 因全局中断关闭暂不进入 trap；CPU 进入 trap 后，handler 还要通过 MMIO claim/complete 或写 W1C 清除源头。debug 中断问题时要沿这条链逐级查。

以 UART 接收中断为例，一条比较完整的链路是：

```text
UART RX FIFO 非空
  -> UART 内部 event 置位
  -> IRQ_STATUS 置位，且 IRQ_EN 允许
  -> PLIC 看到 UART source pending
  -> PLIC 根据 priority/target 拉起 external interrupt
  -> CPU CSR pending 位可见
  -> 当前 privilege 和全局 enable 允许时进入 trap
  -> handler 通过 PLIC claim 知道是 UART
  -> driver 读 UART 数据并清 UART pending
  -> handler 对 PLIC complete
```

这解释了为什么“中断来了但 CPU 没进 handler”不能只看一根 irq 线。任何一层的 enable、priority、target、pending、delegation 或 global interrupt 都可能让中断暂时停在那里。

### 4.2 timer、software、external interrupt

| 中断类型 | 常见来源 | 典型用途 | 硬件/软件关注点 |
|---|---|---|---|
| timer interrupt | 计数器达到 compare 值 | 调度、超时、周期任务 | compare 更新、计数器宽度、跨时钟域 |
| software interrupt | 软件写 pending 位 | 处理器间通信、软触发 | 多 hart 定向、pending 清除 |
| external interrupt | 外设事件经 PLIC 汇聚 | UART 收到字节、GPIO 边沿、DMA 完成 | priority、claim/complete、源头 pending 清除 |

timer/software interrupt 通常更靠近 hart 本地控制；external interrupt 通常从外设侧汇聚而来。对 CPU core 来说，它们最终都会表现成 CSR pending/enable 条件满足后的 trap；对 SoC 来说，它们的源头、同步和清除路径完全不同。

### 4.3 boot ROM 和启动流程

常见启动顺序：

1. 复位后 PC 指向 `reset vector`。
2. CPU 从 `boot ROM` 取第一段启动代码。
3. 初始化时钟、内存控制器、外设和栈。
4. 拷贝或跳转到 SRAM/flash 中的正式程序。
5. 配置中断控制器、使能 timer、打开外设。

boot ROM 的工程边界也很重要。复位后 cache、TLB、中断、外设时钟可能都还没准备好，因此 reset vector 附近的代码通常依赖最保守的访问路径：

- 指令来源是 ROM 或固定映射 SRAM。
- MMIO 区域不可缓存。
- 中断默认关闭，避免初始化过程中进入未设置好的 handler。
- 栈指针、全局指针和 `.bss` 清零由启动代码建立。
- 多 hart 系统要定义 secondary hart 停在哪里。

硬件需要保证 reset 后 memory map 至少包含一条可取指路径。如果 reset vector 指向的 ROM decode、取指总线、时钟门控或权限属性有问题，CPU 会在第一条指令前就卡死，波形里只看到 repeated fetch 或 access fault。

系统 OS 视角下，boot ROM 是软件栈的第一层。它不一定是完整 OS，很多时候只是最小 runtime：设置 `sp/gp`，清 `.bss`，建立 trap vector，初始化必要 MMIO，然后跳到裸机 `main`、RTOS 入口或 OS kernel。硬件验证启动路径时，不应只看 ROM 能读，还要看 reset vector、取指权限、MMIO 默认值、中断默认屏蔽和栈所在 SRAM 是否在同一套 memory map 下自洽。

如果系统支持 OTA 或 app 更新，bootloader 还会承担“选择哪个程序镜像启动”的职责。一个常见设计是 persistent storage 中保留 A/B 两个系统镜像槽，更新时先把新镜像写到备用槽，校验通过后只修改少量启动元数据；下次 reset 后 bootloader 根据元数据选择新镜像，失败时还能回滚到旧镜像。对硬件来说，这会牵涉 storage controller、DMA、flash 写入完成状态、掉电保护和 MMIO 顺序；对验证来说，要覆盖“写镜像、写启动标志、reset 后取指地址变化”这一整条链路。

### 4.4 debug module

`debug module` 通常用于：

- halt CPU。
- 单步。
- 读写寄存器。
- 设置断点和观察点。

它和普通 MMIO 外设不同，常常拥有更高权限和更强控制能力，验证时不能把它当普通寄存器块看待。

debug module 的特殊性在于：它可能在 CPU 正常执行流之外介入系统。普通 UART/GPIO 只是响应 CPU 访问；debug master 可能让 hart halt、读写 GPR/CSR/memory、插入抽象命令或设置断点。因此它必须和 reset、trap、WFI、总线仲裁、权限边界一起定义优先级。否则可能出现 CPU 已经 halt 但总线事务未完成、debug 写 memory 与 CPU store buffer 冲突、或断点触发后 trap/debug 两套入口互相覆盖的问题。

---

## 第5章 RTL 结构：地址译码、桥接、寄存器块和中断同步

### 5.0 SoC 级结构

```text
                 +------------------+
CPU master  ---> | interconnect     | ----> SRAM/ROM
                 +----+--------+----+
                      |        |
                      |        +----> AXI/AHB high-speed slaves
                      |
                      +----> bridge ----> APB peripheral bus
                                          /   |    |     \
                                       UART  GPIO  TIMER  PLIC
```

这个图里最容易被忽略的是 bridge。CPU 侧可能是带 burst、byte strobe、error response、outstanding 的高性能协议；外设侧常常只是“地址、写使能、写数据、读数据”的简单寄存器接口。bridge 要负责把复杂事务约束成外设能处理的一笔或多笔局部访问。

| 模块 | 主要职责 | 关键验证点 |
|---|---|---|
| interconnect | 地址译码、仲裁、路由、返回响应 | one-hot decode、无死锁、响应回到正确 master |
| bridge | 协议转换、节拍保持、宽度转换、错误映射 | ready=0 时请求稳定、响应不丢 |
| register block | 寄存器语义、副作用、中断 pending | W1C/RC/RO/RW、byte enable |
| interrupt sync | CDC、边沿捕获、pending 锁存 | 窄脉冲不丢、清 pending 不误清新事件 |

对入门 RISC-V SoC，建议先做“单 master、单 outstanding、按序响应”的互联。这样 CPU 的精确异常和 MMIO 顺序更容易讲清楚；等这个闭环稳定后，再考虑 DMA、多 master、AXI outstanding 和 QoS。

这也是结构资源冲突在 SoC 层面的展开：当多个 master 共享 interconnect、SRAM 端口、memory controller 或 APB bridge 时，硬件必须仲裁；当目标 slave 或 bridge 暂时不能接收请求时，就通过 ready/valid backpressure 让上游等待。它和 `0802` 中 IF/MEM 抢 single-port RAM 的本质相同，只是资源从“一个 RAM 端口”扩展成了“总线、桥、队列和存储控制器”。

### 5.1 地址译码骨架

```systemverilog
module soc_decode (
  input  logic [31:0] addr,
  output logic        rom_sel,
  output logic        sram_sel,
  output logic        periph_sel,
  output logic        addr_err
);
  always_comb begin
    rom_sel    = 1'b0;
    sram_sel   = 1'b0;
    periph_sel = 1'b0;
    addr_err   = 1'b0;

    unique case (addr[31:28])
      4'h0: rom_sel    = 1'b1;
      4'h2: sram_sel   = 1'b1;
      4'h4: periph_sel = 1'b1;
      default: addr_err = 1'b1;
    endcase
  end
endmodule
```

实际 SoC 不建议把 `addr[31:28]` 这种硬编码散落在多个模块里。更稳妥的做法是集中维护地址表，并从同一份参数生成 decode、文档和验证约束。否则 RTL 改了地址，软件头文件没改，驱动会访问到旧地址。

地址译码还要给错误路径留出口。对非法地址，常见策略有：

| 策略 | 行为 | 适用 |
|---|---|---|
| 返回 error response | CPU 转成 load/store access fault | 推荐，便于 debug |
| 返回固定值 | 读返回 0 或全 1，写丢弃 | 某些简单 MCU |
| hang/timeout | 等待直到 timeout | 不推荐作为默认行为 |

如果总线没有 error response，也最好加 bus timeout，把“外设没响应”转成可观测错误，而不是让 CPU 永久 stall。

### 5.2 MMIO 寄存器块骨架

```systemverilog
module mmio_regs (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [11:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  input  logic        timer_event,
  output logic [31:0] resp_rdata,
  output logic        resp_ready
);
  logic [31:0] ctrl_q;
  logic [31:0] irq_en_q;
  logic [31:0] irq_status_q;
  logic [31:0] timer_cmp_q;

  function automatic logic [31:0] apply_wstrb(
    input logic [31:0] oldv,
    input logic [31:0] newv,
    input logic [3:0]  wstrb
  );
    logic [31:0] tmp;
    begin
      tmp = oldv;
      if (wstrb[0]) tmp[7:0]   = newv[7:0];
      if (wstrb[1]) tmp[15:8]  = newv[15:8];
      if (wstrb[2]) tmp[23:16] = newv[23:16];
      if (wstrb[3]) tmp[31:24] = newv[31:24];
      return tmp;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_q       <= '0;
      irq_en_q     <= '0;
      irq_status_q <= '0;
      timer_cmp_q  <= '1;
    end else begin
      if (req_valid && req_write) begin
        unique case (req_addr[7:2])
          6'h00: ctrl_q      <= apply_wstrb(ctrl_q, req_wdata, req_wstrb);
          6'h01: irq_en_q    <= apply_wstrb(irq_en_q, req_wdata, req_wstrb);
          6'h02: irq_status_q<= irq_status_q & ~req_wdata; // W1C 示例
          6'h03: timer_cmp_q <= apply_wstrb(timer_cmp_q, req_wdata, req_wstrb);
          default: ;
        endcase
      end

      if (timer_event)
        irq_status_q[0] <= 1'b1;
    end
  end

  always_comb begin
    resp_rdata = '0;
    resp_ready = req_valid;
    unique case (req_addr[7:2])
      6'h00: resp_rdata = ctrl_q;
      6'h01: resp_rdata = irq_en_q;
      6'h02: resp_rdata = irq_status_q;
      6'h03: resp_rdata = timer_cmp_q;
      default: resp_rdata = '0;
    endcase
  end
endmodule
```

上面代码刻意把读写、字节掩码和 W1C 分开，方便面试时解释 MMIO 设计的关键点：写数据不是直接进寄存器，必须经过寄存器语义层。

这个示例还有两个真实项目中必须补齐的点：

- `req_valid` 和 `resp_ready` 如果不是同拍完成，必须锁存 `req_addr/req_write/req_wdata/req_wstrb`。
- 读副作用寄存器不能简单放在组合读 MUX 里清除，必须在读事务完成点产生清除脉冲。

对慢外设，一个常见寄存器接口状态机是：

```text
IDLE
  | req_valid
  v
HOLD_REQ   -- wait peripheral_done -->
  |
  v
RESP       -- response accepted -->
  |
  v
IDLE
```

在 `HOLD_REQ` 中，地址和写数据必须保持不变；在 `RESP` 中，读数据和错误响应必须保持到 CPU 或上游 bridge 接受。

### 5.3 异步中断同步

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    irq_sync_0 <= 1'b0;
    irq_sync_1 <= 1'b0;
  end else begin
    irq_sync_0 <= irq_async_in;
    irq_sync_1 <= irq_sync_0;
  end
end
```

如果外部中断是脉冲型，还要做脉冲拉伸或 pending 锁存，避免跨域后丢边沿。

---

## 第6章 验证方法

### 6.0 验证目标

MMIO 和互联类设计的验证重点不是“某个寄存器写没写进去”，而是：

- 地址译码是否唯一。
- 所有副作用是否只发生一次。
- 慢外设是否正确反压。
- 中断是否不会丢、不会重、不会乱序。
- 复位、异常和调试是否能打断正常事务。

### 6.1 directed test

建议至少覆盖：

| 场景 | 关注点 |
|---|---|
| ROM 读 | 只读区域是否返回稳定值 |
| SRAM 读写 | 普通存储路径是否正确 |
| 外设 RW 寄存器 | 写后读回是否一致 |
| W1C 寄存器 | 写 1 是否只清对应位 |
| RC 寄存器 | 读后是否清零 |
| byte enable | 半字/字节写是否只改对应 lane |
| 非法地址 | 是否返回错误或预期空读 |
| 慢外设反压 | handshake 是否保持请求 |
| timer interrupt | 定时到点是否置位 |
| external interrupt | 异步输入是否被正确同步 |
| reset | 复位后寄存器默认值是否正确 |

### 6.2 random test 与 scoreboard

随机测试可以把地址、读写、字节掩码、等待周期和中断事件打乱，最容易抓住：

- decode overlap。
- byte lane 错位。
- W1C 没清干净。
- 请求被反压后丢失。
- pending 位重复置位。

scoreboard 最好同时维护：

- 寄存器镜像。
- pending 中断状态。
- 总线未完成事务。
- 读副作用历史。

对互联和 MMIO，scoreboard 不能只做“写后读回”。它还要建模事务生命周期：

```text
request accepted
  -> outstanding queue push
response returned
  -> outstanding queue pop
  -> update register mirror / check read data / check error
side effect fired
  -> update pending/status model
```

如果设计是单 outstanding，queue 深度可以是 1；如果有 AXI ID 或多个 master，就必须按 ID、地址范围和响应顺序建模。否则 random test 很容易把“响应回错 master”和“寄存器值错”混在一起，定位困难。

| scoreboard 对象 | 需要记录 | 检查内容 |
|---|---|---|
| 地址译码模型 | base/size/attribute | RTL decode 与规格一致 |
| 寄存器镜像 | reset value、access type、wstrb | 读数据和副作用一致 |
| outstanding 事务 | addr、write、wdata、wstrb、master/id | response 不丢、不重复、不串线 |
| 中断模型 | event、enable、pending、clear | pending 置位/清除和 CPU irq 一致 |
| 错误模型 | illegal addr、timeout、access fault | 错误响应和 CPU exception 一致 |

### 6.3 SVA

#### 6.3.1 地址译码必须互斥

```systemverilog
// 不可综合：验证断言
assert property (@(posedge clk) disable iff (!rst_n)
  $onehot0({rom_sel, sram_sel, periph_sel})
);
```

#### 6.3.2 W1C 只清 1 的位

```systemverilog
// 不可综合：验证断言
property p_w1c_clear;
  @(posedge clk) disable iff (!rst_n)
    req_valid && req_write && w1c_sel
    |=> (irq_status_q == ($past(irq_status_q) & ~$past(req_wdata)));
endproperty

assert property (p_w1c_clear);
```

如果硬件事件和 W1C 清除可能同拍发生，上面断言需要按规格优先级改写。例如事件优先时，应检查：

```systemverilog
// 不可综合：验证断言，示意 event 优先于 W1C clear
property p_w1c_event_priority;
  @(posedge clk) disable iff (!rst_n)
    req_valid && req_write && w1c_sel && irq_event
    |=> irq_status_q[0];
endproperty

assert property (p_w1c_event_priority);
```

#### 6.3.3 中断事件应锁存为 pending

```systemverilog
// 不可综合：验证断言
property p_irq_event_latched;
  @(posedge clk) disable iff (!rst_n)
    $rose(irq_sync_1) |=> irq_pending_q;
endproperty

assert property (p_irq_event_latched);
```

### 6.4 coverage

覆盖建议：

- 地址区间：ROM/SRAM/peripheral/illegal。
- 访问类型：读/写/读改写/只写。
- 字节掩码：4'b0001 到 4'b1111。
- 寄存器类型：RO/RW/WO/W1C/W1S/RC。
- 等待状态：0、1、多拍。
- 中断来源：timer、software、external。
- 复位场景：上电复位、软复位、局部复位。

---

## 第7章 时序、CDC、综合和后端影响

### 7.0 为什么 MMIO 也会卡 Fmax

外设逻辑看起来简单，但 SoC 级控制路径常常很长：

- 地址译码扇出大。
- 一堆寄存器块并联。
- 中断汇聚路径长。
- bridge 里还可能有等待状态管理。

### 7.1 时序热点

常见热点：

- CPU 地址 -> decode -> select。
- select -> register read mux -> rdata。
- interrupt pending -> CPU trap 入口。
- timer compare -> pending set。

优化方向：

- 分层译码。
- 低速外设独立时钟或独立桥。
- 热寄存器旁路读。
- 中断 pending 先寄存再汇总。

### 7.2 CDC

真正危险的地方通常是：

- 外部中断输入。
- timer 跨时钟域比较事件。
- debug 请求。
- 复位释放。

这些信号必须经过同步器、脉冲拉伸或握手桥，不然 pending 位会随机抖动。

### 7.3 综合和后端

综合与布局布线时要注意：

- 地址译码不要写成极深的 if-else 链。
- 高扇出中断线要做缓冲或局部汇聚。
- 寄存器块不要跨太多区域散布。
- 低速外设可以单独放在独立逻辑区，减少对 CPU 热路径的拖累。

### 7.4 PPA 权衡

| 方案 | 优点 | 缺点 |
|---|---|---|
| 完全平铺译码 | 简单直观 | 扇出大，时序差 |
| 分层译码 | 更容易收敛 | 结构复杂 |
| 高速总线直连所有外设 | 吞吐高 | 面积和验证成本高 |
| 先桥接到 APB 再下挂外设 | 简单稳定 | 单次事务延迟增加 |

---

## 第8章 常见 bug、边界条件和 debug 方法

### 8.0 常见 bug

| bug | 现象 | 修复方向 |
|---|---|---|
| 地址译码重叠 | 多个外设同时响应 | 统一 base/mask，加入 one-hot 断言 |
| byte lane 搞错 | 半字写错到别的字节 | 按小端序重建 wstrb |
| W1C 实现成普通清零 | 写 1 后整寄存器被清 | 按位与反掩码 |
| 读清零读成普通读 | pending 不掉 | 只在读有效时清位 |
| 写只读寄存器 | 软件写不生效或污染镜像 | 只允许 RO 返回，写忽略 |
| 反压下丢请求 | 慢外设偶发丢事务 | 保存请求直到 ready |
| 中断脉冲过窄 | 异步事件偶发消失 | 同步器 + pending 锁存 |
| timer compare off-by-one | 超时提前或延后 | 明确比较点和清除点 |
| MMIO 被 cache | 软件看见旧值 | 设备区必须标成 device memory |
| reset 默认值不一致 | 上电行为不稳定 | 所有寄存器明确复位值 |

### 8.1 边界条件

- 非对齐访问是否允许，必须在设计早期定义。
- 部分写是按字节还是按半字处理，要和软件约定一致。
- 某些寄存器是否允许连续写，连续写会不会丢事件，要明确。
- timer 和中断控制器是否支持多 hart，要提前定义路由和归属。

### 8.2 debug 方法

建议按这个顺序看：

1. 地址是否译到正确区域。
2. 写掩码是否正确。
3. 寄存器写使能是否真正到位。
4. 读路径是否返回了镜像值。
5. 副作用是否发生在正确时刻。
6. 中断 pending 是否被同步到核心域。
7. bridge 是否因反压而停住请求。

---

## 第9章 面试问法

### 9.0 基础题

#### 1. MMIO 和普通内存有什么区别

简洁答法：

```text
普通内存主要存数据，MMIO 是把外设寄存器映射到地址空间。
MMIO 常有副作用，通常不可缓存，访问时要格外注意顺序和字节掩码。
```

#### 2. APB、AHB、AXI 的区别是什么

答题要点：

- APB 简单、低速、适合寄存器。
- AHB 更高性能、适合中等带宽。
- AXI 并发能力最强，适合高性能互联。

#### 3. PLIC 和 CLINT 分别干什么

答题要点：

- `CLINT` 管本地 timer/software interrupt。
- `PLIC` 管外设来的 external interrupt。

### 9.1 进阶追问

#### 1. 为什么 W1C 很常见

要点：

- 中断 pending 和错误标志常常需要软件清除。
- W1C 避免读改写时把别的位误改掉。

#### 2. 设备寄存器为什么通常不可缓存

要点：

- 读写有副作用。
- 必须保持顺序和可见性。
- 缓存可能导致旧值、重复写或丢写。

#### 3. 外部中断为什么要同步

要点：

- 外部输入可能跨时钟域。
- 直接采样会有亚稳态风险。
- 需要同步器或脉冲拉伸。

### 9.2 项目追问

#### 1. 你的 SoC 怎么把 UART 接到 CPU

回答框架：

- UART 挂在 MMIO 窗口。
- CPU 通过地址译码访问 UART 控制寄存器。
- UART 收发事件通过 interrupt 控制器送到 CPU。
- 软件通过状态寄存器和数据寄存器完成收发。

#### 2. 如何设计一个 timer 外设

回答框架：

- 提供计数器、比较器、使能位、清除位和 pending 位。
- 到点后置位中断。
- 软件写比较值或清除 pending。
- 要考虑时钟域和复位同步。

#### 3. 怎样避免 MMIO 读到旧值

回答框架：

- 不要把设备区标成 cacheable。
- 对需要强顺序的访问加合适的 fence。
- 对有副作用的寄存器使用明确协议。

---

## 第10章 练习题与答案要点

### 10.1 练习题 1：设计 GPIO 寄存器

题目：

```text
设计一个 GPIO 外设，至少包含方向寄存器、输出寄存器、输入寄存器和中断寄存器。
```

答案要点：

- `DIR` 控制输入/输出方向。
- `OUT` 保存输出值。
- `IN` 只读返回引脚状态。
- `IRQ_STATUS` 用 W1C。
- `IRQ_EN` 使能边沿/电平中断。

### 10.2 练习题 2：为什么部分写容易出错

答案要点：

- 总线写粒度和寄存器粒度不一定相同。
- 小端序下字节 lane 映射容易写反。
- WSTRB 必须和目标位宽对齐。

### 10.3 练习题 3：外部中断丢边沿怎么办

答案要点：

- 用同步器。
- 若是脉冲型，增加 pending 锁存或脉冲拉伸。
- 不能只靠单拍采样。

### 10.4 练习题 4：桥接为什么不能直接丢请求

答案要点：

- 慢外设会反压。
- 如果请求没有被保存，软件会看见随机丢读丢写。
- 所以 bridge 必须保留 transaction 状态直到完成。

---

## 第11章 与其他章节的关联

### 11.1 必须回看的章节

- `0803 CSR、异常中断与特权级.md`：trap、优先级、M/S/U 和中断入口。
- `0805 Cache、TLB、MMU、分支预测与内存模型.md`：cacheable/device memory、TLB 和一致性。
- `070x` 总线、DMA、SoC 互联专题：更完整的总线协议和互联设计。
- `050x` CDC / RDC 相关文档：跨时钟域中断和复位同步。
- `130x` STA 文档：地址译码、桥接和中断汇聚的时序收敛。

### 11.2 本篇总结

SoC 和 MMIO 的本质，是把软件的普通 load/store 变成对硬件寄存器和控制动作的访问。

如果你能把下面几件事讲清楚，SoC 面试里的互联和外设问题基本就站稳了：

- 记忆图怎么分。
- 不同总线为什么要分层。
- MMIO 寄存器为什么要定义 RO/RW/W1C/W1S/RC。
- PLIC 和 CLINT 分别解决什么问题。
- 为什么外设中断要同步。
- 为什么 bridge、byte enable 和反压经常是 bug 源头。
