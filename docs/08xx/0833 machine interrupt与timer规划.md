# 0833 machine interrupt 与 timer 规划

> 文档编号：0833  
> 所属系列：083x RV32I 教学核后续完善阶段  
> 文档定位：规划当前五级流水线 SoC 在完成最小 M-mode CSR/trap 与 MMIO 外设后，如何加入 machine interrupt、timer 和最小中断软件约定  
> 对应总规划：`0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`  
> 前置文档：`0803 CSR、异常中断与特权级.md`、`0804 RISC-V SoC、MMIO与外设互联.md`、`0825 Hazard控制：forwarding、stall、flush与kill.md`、`0831 最小M-mode CSR与trap规划.md`、`0832 最小memory map与MMIO外设规划.md`

本篇只规划“第三阶段做什么”。它不是执行阶段的 `plan.md`，因此不会写成逐文件逐端口的施工清单。

第三阶段的目标是：在当前已经能处理同步 exception、能访问 MMIO 外设的 M-mode-only RV32I SoC 上，补上最小 machine interrupt 能力。完成后，软件可以配置 `mstatus/mie/mtvec`，通过 MMIO timer 产生 `MTIP`，通过 GPIO/UART 产生 `MEIP`，硬件在精确指令边界进入 trap handler，handler 处理完 pending 后执行 `MRET` 返回。

本阶段的关键不是“多加一个跳转”，而是把下面几件事说清楚：

- interrupt 是异步事件，但硬件必须在同步时钟边界接受它。
- interrupt 不属于某条 faulting instruction，因此和同步 exception 的 `mepc/kill` 口径不同。
- timer 本质上是 MMIO 外设加一根 pending 信号，依赖 0832 的地址图和外设译码。
- 软件 handler 必须正确区分 exception 和 interrupt，并在 `MRET` 前清掉或推迟 pending，否则会立刻再次进入中断。

## 第1章 本步目标和非目标

### 1.1 当前已经完成的基础

在进入本步之前，当前系统已经具备：

| 能力 | 当前状态 |
|---|---|
| 五级流水线主路径 | IF/ID/EX/MEM/WB、forwarding、load-use/CSR-use stall、branch/JAL/JALR redirect 已完成 |
| precise trap | 非法指令、`ECALL/EBREAK`、访存不对齐、data access fault 等同步异常已进入 trap |
| CSR/trap return | `mstatus/mtvec/mscratch/mepc/mcause/mtval`、Zicsr、`MRET` 已完成 |
| trap handler 布局 | `mtvec` 默认指向 `IMEM_BASE + 0x80`，linker 支持 `.text.trap` |
| MMIO 平台 | 已有 SoC wrapper、data subsystem、GPIO0、UART0、MMIO access fault |
| 地址图 | `TIMER0_BASE = 0x0008_1000` 已在 MMIO 地址图中预留 |
| testbench 观察 | 已有 commit trace、trap/MRET trace、UART/GPIO MMIO 观察基础 |

因此，本阶段不是从零做 trap，也不是从零做外设，而是在这两条基础上加：

```text
CSR/trap entry + MMIO timer + interrupt pending/enable + precise interrupt accept
```

### 1.2 本步目标

本步完成后，平台应具备：

| 能力 | 目标 |
|---|---|
| machine interrupt CSR | 支持 `mie/mip` 的 machine timer/external interrupt 位；software interrupt 位仅保留说明，本阶段不实现 |
| interrupt cause | `mcause[31]` 能区分 interrupt，低位保存 interrupt code |
| global interrupt enable | 使用 `mstatus.MIE/MPIE/MPP` 完成 interrupt entry 和 `MRET` 恢复 |
| timer MMIO | 实现 32-bit TIMER0，产生 `MTIP` |
| GPIO external interrupt | GPIO 按 bit 配置中断使能和触发类型，命中后置 pending，并汇总到 `MEIP` |
| UART external interrupt | UART 增加仿真 RX，RX 事件产生 UART pending，并汇总到 `MEIP` |
| software interrupt | `MSIP` 本阶段不实现；后续如有多 hart/IPI 或自触发测试需求再补 |
| precise interrupt | 在 MEM/commit 边界接受 interrupt，kill younger instruction，保证 architectural state 精确 |
| handler 返回 | `MRET` 返回到被中断程序的正确下一条指令 |
| 最小软件约定 | 软件能配置 timer、开中断、在 handler 中判断 `mcause` 并清 pending |

### 1.3 本步非目标

本步不做：

| 暂不做 | 原因 |
|---|---|
| S-mode/U-mode interrupt | 当前仍是 M-mode-only 裸机平台 |
| delegation | 没有 S/U mode，不需要 `medeleg/mideleg` |
| PLIC 完整模型 | 多外部中断源优先级和 claim/complete 机制后续再做 |
| CLINT 完整模型 | 本步只做教学版 timer interrupt，不追求完整 SoC IP 兼容 |
| `MSIP` software interrupt | 当前单 hart 不需要 IPI，本阶段明确不实现 |
| vectored `mtvec` | 当前仍保持 direct mode，所有 trap 进入同一个 handler |
| nested interrupt 完整策略 | 第一版 trap entry 会清 `MIE`，handler 默认不主动重开中断 |
| `WFI` | 可等 interrupt 基础稳定后再补 |
| 多时钟域 timer | 当前平台默认单时钟，timer 每个 `clk_i` 或配置 tick 递增 |
| wait-state/backpressure | 放到 0834；本步 timer/MMIO 仍按固定响应处理 |
| 标准总线 | APB/AHB/AXI-Lite 等在后续总线化阶段再考虑 |

## 第2章 interrupt 的基本语义

### 2.1 exception 和 interrupt 的差异

同步 exception 和异步 interrupt 都会进入 trap handler，但二者来源不同：

| 项目 | 同步 exception | 异步 interrupt |
|---|---|---|
| 来源 | 当前指令自身，例如非法指令、访存不对齐、access fault | 外部事件或 timer pending，与当前正在执行的指令没有直接因果关系 |
| 发现阶段 | 随指令流动，在 ID/EX/MEM 等阶段发现 | pending 信号可随时变化，但硬件只在选定提交边界接受 |
| `mepc` | faulting instruction 的 PC | interrupt 返回后要继续执行的 PC |
| `mcause[31]` | 0 | 1 |
| `mtval` | 根据异常类型写指令编码或 fault address | 第一版统一写 0 |
| 当前指令 | faulting instruction 不作为普通指令提交 | interrupt 应理解为在两条指令之间插入 handler |
| younger instruction | kill | kill |

这也是本阶段最容易写错的地方：不能把 interrupt 简单当成“又一种 MEM exception”。同步 exception 属于当前指令，因此当前指令不能继续作为普通指令进入 WB；interrupt 不属于当前指令，更合理的口径是在一个精确边界接受 interrupt，让已经提交的旧指令保持提交结果，再 kill 更年轻的指令。

**为什么异常不需要 next_pc？** 异常总有 faulting instruction，硬件只需保存 `mepc = fault_pc`。是否跳过失灵指令（ECALL 需要 +4，非法指令需要重试）是软件 handler 的判断，硬件不参与。所以异常不需要 next_pc。

**为什么中断必须用 next_pc？** 中断发生在指令之间，被中断的可能是任意指令——包括 taken branch/JAL/JALR。软件 handler 拿到 `mepc` 后自己做 +4 是不行的：如果被中断的是 `jal target`，`mepc + 4` 是 `target + 4`，不是正确的 `target`。硬件必须把**当前已提交指令的实际下一条地址**（可能是 pc+4，也可能是跳转 target）写入 mepc。这就是 next_pc 必须由硬件携带的原因。

### 2.2 异步事件也要同步接受

timer/external interrupt 的 pending 可以在任意周期变成 1，但流水线不能在 IF/ID/EX 任意位置随便跳走。否则会出现：

- 有些旧指令提交了，有些旧指令没提交，现场不精确。
- wrong-path 或 younger MMIO store 可能产生错误副作用。
- `mepc` 很难定义到底应该回到哪条指令。

因此，本项目采用下面的接受策略：

```text
interrupt pending 可以异步到来；
core 在 MEM/commit 边界同步采样并决定是否接受；
接受后写 CSR、redirect 到 mtvec、kill younger instruction。
```

这里的“MEM/commit 边界”是当前五级流水线已有 trap/MRET 控制的自然位置。它让 interrupt 和已有 precise trap 共用大部分 redirect/kill 框架，但仍需要在 `mepc` 和 MEM/WB kill 语义上区分同步 exception。

### 2.3 interrupt 的 `mepc` 口径

本项目把 interrupt 看成发生在指令边界：

```text
older instruction 已经完成；
younger instruction 还没有提交；
handler 返回后继续执行第一条未提交指令。
```

因此，interrupt 写入 `mepc` 的值应是“返回后要执行的 PC”，而不是简单使用当前 MEM 指令的 `pc`。

对于顺序指令，返回 PC 通常是：

```text
mem_pc + 4
```

但不能永远这样写。若当前 MEM 指令是已经在 EX 解析过的 taken branch、`JAL` 或 `JALR`，正确的下一条架构 PC 是跳转目标，而不是 `pc + 4`。因此 RTL 规划上应为 MEM 边界准备一个“当前提交指令的实际下一条 PC”信号，例如：

```text
interrupt_return_pc / commit_next_pc / mem_next_pc
```

生成规则可以概括为：

| 当前提交指令类型 | interrupt 返回 PC |
|---|---|
| 普通非控制指令 | `pc + 4` |
| not-taken branch | `pc + 4` |
| taken branch | branch target |
| `JAL` | jump target |
| `JALR` | jalr target |
| `MRET` | 第一版不和 interrupt 同拍接受，先完成 MRET redirect |

如果后续为了简单选择“接受 interrupt 时 replay 当前 MEM 指令”，可以把 `mepc` 写成 `mem_pc`，但这会要求同拍屏蔽当前 MEM 指令的所有副作用，否则 store/MMIO store 可能被执行两次。当前项目已经有 MMIO 副作用，推荐采用“当前旧指令完成、kill younger、`mepc` 指向下一条未提交指令”的口径。

### 2.4 trap 优先级

同一个 MEM/commit 边界上，优先级为：

```text
已有同步 exception > MRET > interrupt > 普通指令提交
```

含义如下：

| 优先级 | 事件 | 原因 |
|---|---|---|
| 1 | 同步 exception | 当前指令已经发生架构异常，必须先进入 exception handler |
| 2 | `MRET` | `MRET` 会恢复 `mstatus.MIE` 并 redirect 到 `mepc`，pending interrupt 可在后续边界再接受 |
| 3 | interrupt | 只有在没有同步 exception、没有正在提交的 `MRET` 时接受 |
| 4 | 普通提交 | 没有 trap/return/interrupt 时正常流动 |

这个优先级不是为了处理常见同拍冲突，而是为了让所有边界都有确定行为。正常软件中，一条合法 `MRET` 自己不会同时带同步 exception；如果返回后 `MIE=1` 且 pending 仍然存在，硬件可以在后续指令边界再次接受 interrupt。

## 第3章 CSR 扩展规划

### 3.1 新增 CSR

0831 已经实现：

```text
mstatus, mtvec, mscratch, mepc, mcause, mtval
misa, mvendorid, marchid, mimpid, mhartid
```

本阶段需要新增：

| CSR | 地址 | 属性 | 作用 |
|---|---:|---|---|
| `mie` | `12'h304` | 读写 | machine interrupt enable，软件写入各类 interrupt enable bit |
| `mip` | `12'h344` | 只读 | machine interrupt pending，反映当前 pending 状态 |

RISC-V machine interrupt 编码里常见的三类来源如下：

| 名称 | bit | `mcause` interrupt code | 来源 |
|---|---:|---:|---|
| `MSIP` / `MSIE` | 3 | 3 | machine software interrupt |
| `MTIP` / `MTIE` | 7 | 7 | machine timer interrupt |
| `MEIP` / `MEIE` | 11 | 11 | machine external interrupt |

本阶段确定实现 `MTIP` 和 `MEIP`，不实现 `MSIP`。`MSIP/MSIE` 仍在表格中列出，是为了提前理解 RISC-V 的 machine software interrupt 编码；实际 RTL 中可以让 `mip.MSIP` 恒为 0，`mie.MSIE` 写入后读回 0 或按 WARL 忽略。

`mie/mip` 位布局如下：

```text
mie / mip：第一版只实现 machine interrupt 相关 bit

 31                   12 11   10 9    8 7     6 5    4 3     2 1    0
+----------------------+-------+-------+-------+-------+-------+-------+
|          0           | MEIx  |   0   | MTIx  |   0   | MSIx  |   0   |
+----------------------+-------+-------+-------+-------+-------+-------+

mie[3]  = MSIE，machine software interrupt enable
mie[7]  = MTIE，machine timer interrupt enable
mie[11] = MEIE，machine external interrupt enable

mip[3]  = MSIP，machine software interrupt pending
mip[7]  = MTIP，machine timer interrupt pending
mip[11] = MEIP，machine external interrupt pending

本阶段实际实现：
mie[7] / mip[7]   = timer interrupt
mie[11] / mip[11] = external interrupt
mie[3] / mip[3]   = 暂不实现，读 0，写入按 WARL 忽略
未列出的 bit      = 读 0，写入按 WARL 忽略
```

这里表里的 `x` 表示同一个 bit 在 `mie` 里叫 enable，在 `mip` 里叫 pending。

### 3.2 `mstatus` 的 interrupt 相关行为

0831 已经实现了 `mstatus.MIE/MPIE/MPP` 的基础行为，本阶段要把它用于 interrupt。

`mstatus` 关键位：

```text
 31                13 12    11 10     8 7      6 5      4 3      2 0
+-------------------+--------+---------+--------+--------+--------+----+
|         0         |  MPP   |    0    |  MPIE  |   0    |  MIE   | 0  |
+-------------------+--------+---------+--------+--------+--------+----+

MIE  = 全局 machine interrupt enable
MPIE = trap entry 前的 MIE 备份，MRET 时恢复给 MIE
MPP  = trap entry 前的 privilege mode，当前 M-only 下保持 M-mode 合法值 2'b11
```

trap entry 时：

```text
MPIE <= MIE
MIE  <= 0
MPP  <= M
```

`MRET` 时：

```text
MIE  <= MPIE
MPIE <= 1
MPP  <= M     // 当前 M-only 实现保持 M-mode 合法值
```

这样做的结果是：进入 handler 后默认关中断，避免 handler 尚未保存现场或清 pending 时被再次打断。后续如果要支持 nested interrupt，可以由软件在 handler 中显式重新设置 `mstatus.MIE`，但这不是本阶段目标。

### 3.3 `mcause` 的 interrupt bit

0831 当前把 `excp_cause_e` 作为 5-bit exception code 使用。本阶段不能继续只写低 5 bit，因为 interrupt 需要设置 `mcause[31]`。

`mcause` 布局：

```text
mcause

 31 30                                      5 4                      0
+---+----------------------------------------+------------------------+
| I |                   0                    |      cause code        |
+---+----------------------------------------+------------------------+

I = 0：exception
I = 1：interrupt
```

本阶段在 RTL 语义上区分两个信息：

```text
trap_is_interrupt
trap_cause_code
```

而不是把 interrupt 也塞进原来的 exception-only enum。这样可以保持低位 cause code 的可读性，同时让 `csr_file` 写 `mcause` 时明确决定最高位：

```text
exception : mcause = {1'b0, 低位 exception code}
interrupt : mcause = {1'b1, 低位 interrupt code}
```

对应 machine interrupt code：

| interrupt | code | `mcause` RV32 值 |
|---|---:|---:|
| machine software interrupt | 3 | `0x8000_0003` |
| machine timer interrupt | 7 | `0x8000_0007` |
| machine external interrupt | 11 | `0x8000_000B` |

### 3.4 `mip` 的来源和写入策略

`mie` 是软件可写的 enable CSR；`mip` 更接近 pending 状态观察口。

本阶段采用：

| bit | 来源 | CSR 写入策略 |
|---|---|---|
| `mip.MTIP` | timer 比较结果 `MTIME >= MTIMECMP` | 硬件拥有，软件写 `mip` 不直接清它 |
| `mip.MEIP` | GPIO interrupt 和 UART interrupt 汇总 | 硬件拥有，软件通过对应外设 ack/clear 清 pending |
| `mip.MSIP` | 本阶段不实现 | 读 0，写入按 WARL 忽略 |

`MSIP` 是 machine software interrupt，真实系统中常用于多 hart 之间互相打断，也就是 IPI。例如 hart0 写 hart1 的 software interrupt pending，让 hart1 进入 handler。当前项目是单 hart 教学 SoC，本阶段没有 IPI 需求，因此不实现 `MSIP`。

后续如果需要补 `MSIP`，可以选择：

| 方案 | 特点 |
|---|---|
| 作为 SoC/testbench 输入 | RTL 简单，适合先验证 core interrupt 接受路径 |
| 作为 MMIO/CSR 可写 pending bit | 更像软件中断，适合后续多 hart 或自触发测试 |

无论后续选择哪种，`mip` 的读值都应反映“当前实际 pending”，而不是只反映上一次 CSR 写入值。

## 第4章 interrupt 源规划

### 4.1 总体结构

本阶段把 interrupt 输入抽象成两根真正实现的 machine-level pending：

```text
mtip_raw
meip_raw
```

CSR 和 trap 控制逻辑再根据：

```text
mstatus.MIE
mie.MTIE/MEIE
mip.MTIP/MEIP
```

决定当前是否有可接受 interrupt。

可接受条件为：

```text
global_enable = mstatus.MIE
enabled_pending = mie & mip & machine_interrupt_mask
interrupt_pending = global_enable && (enabled_pending != 0)
```

其中 `machine_interrupt_mask` 本阶段只包含 `MTIP` 和 `MEIP`，不包含 `MSIP`。

### 4.2 `MTIP`：timer interrupt

`MTIP` 由 TIMER0 产生：

```text
MTIP = timer_enable && (MTIME >= MTIMECMP)
```

`MTIP` 是 level pending，不是单周期 pulse。只要 `MTIME >= MTIMECMP` 条件仍然成立，它就保持为 1。因此 handler 必须在 `MRET` 前执行以下动作之一：

- 把 `MTIMECMP` 写到未来时间。
- 关闭 timer。

否则 `MRET` 恢复 `MIE` 后，core 很可能马上再次接受同一个 timer interrupt。

### 4.3 `MEIP`：external interrupt

`MEIP` 表示 machine external interrupt。当前阶段不做完整 PLIC，采用简单汇总输入：

```text
meip_raw = gpio_irq | uart_irq
```

本阶段确定实现两个 external interrupt 来源：

| 来源 | 适合场景 |
|---|---|
| GPIO 按 bit 配置的触发事件 | 验证普通外设输入在使能和触发类型命中时产生 external interrupt |
| UART RX 事件 | 验证外设接收事件触发 external interrupt |

外部 interrupt 也通常是 level pending。handler 需要通过外设寄存器 ack，或让 testbench 拉低输入，否则 `MRET` 后会再次进入。

### 4.4 `MSIP`：software interrupt

`MSIP` 是 machine software interrupt。真实多 hart 系统里，它常用于 IPI；单 hart 也可以把它做成软件自触发事件，但当前教学 SoC 没有这个需求。

本阶段明确不实现 `MSIP`：

- `mip.MSIP` 读 0。
- `mie.MSIE` 可以读 0、写忽略。
- interrupt 选择逻辑不考虑 `MSIP`。

后续如果加入多 hart，或希望软件用 CSR/MMIO 自己触发一次 interrupt，再单独补 `MSIP`。

### 4.5 多个 interrupt 同时 pending 的优先级

本阶段实现 `MEIP` 和 `MTIP`，固定优先级为：

```text
MEIP > MTIP
```

理由是：

- external interrupt 通常来自外部设备，最需要尽快响应。
- timer interrupt 是周期性或延迟触发事件，放在 external interrupt 之后更符合当前外设验证需求。

软件不应依赖多个 pending 同拍时的细节顺序；若后续接入 PLIC/CLINT 或想更贴近某个平台规范，只需要调整 interrupt select 的优先级选择块和文档声明。

## 第5章 TIMER0 MMIO 规划

### 5.1 timer 在当前地址图中的位置

0832 已经预留：

| 外设 | base | size | 当前状态 |
|---|---:|---:|---|
| TIMER0 | `0x0008_1000` | `0x100` | 本阶段实现 |
| TIMER1-5 | `0x0008_1100` 起 | 每个 `0x100` | 继续预留 |

本阶段只需要实现 TIMER0。其它 timer 仍可保持未映射或预留状态，访问时按当前 SoC 规则产生 access fault。

### 5.2 TIMER0 采用 32-bit 教学计数器

真实 RISC-V 平台常见 timer 会提供 64-bit `mtime/mtimecmp`，但当前 testbench 默认仿真周期只有约 20000 cycles，本阶段不需要 64-bit 计数范围。为了避免 RV32I 下拆 high/low word、处理 64-bit 写入瞬时 pending 等额外复杂度，TIMER0 直接采用 32-bit 教学计数器。

本阶段 TIMER0 寄存器：

| offset | 名称 | 属性 | 作用 |
|---:|---|---|---|
| `0x00` | `MTIME` | RW | 当前 32-bit 计数值 |
| `0x04` | `MTIMECMP` | RW | 32-bit 比较值 |
| `0x08` | `CTRL` | RW | bit0: timer enable |
| `0x0C` | `STATUS` | RO | bit0: raw `MTIP` |

`MTIME` 本阶段允许软件写入。这样 directed test 可以快速设置计数初值，不必为了等 timer 到期消耗大量仿真周期。

### 5.3 `MTIME` 递增规则

本阶段固定采用：

```text
若 CTRL.enable = 1，则 MTIME 每个 clk_i + 1。
若 CTRL.enable = 0，则 MTIME 保持。
```

这样仿真完全确定，不需要额外分频器。后续如果要模拟真实时钟频率，可以在新的 timer 版本里加入 prescaler、tick 输入或 64-bit 计数器，但这不影响本阶段 core interrupt 机制。

### 5.4 `MTIMECMP` 和 pending 规则

`MTIP` 由 32-bit 比较产生：

```text
MTIP = CTRL.enable && (MTIME >= MTIMECMP)
```

`MTIP` 是 level pending，不是 pulse。只要比较条件成立，它就保持为 1。handler 需要在 `MRET` 前把 `MTIMECMP` 写到未来，或关闭 `CTRL.enable`，否则返回后会立即再次进入 timer interrupt。

由于本阶段 `MTIMECMP` 是 32-bit 寄存器，一次 `sw` 即可完整写入，不存在 64-bit high/low word 写入过程中的中间值问题。软件配置 timer 的基本顺序可以是：

```text
CTRL.enable = 0
MTIME       = start_value
MTIMECMP    = target_value
CTRL.enable = 1
```

如果只想推迟下一次 timer interrupt，handler 中可以直接写：

```text
MTIMECMP = MTIME + delta
```

### 5.5 timer access fault

timer 属于 MMIO 外设，仍沿用 0832 的访问规则：

- 命中已定义寄存器：正常读写。
- 命中 TIMER0 窗口但 offset 未定义：load/store access fault。
- 未实现的 TIMER1-5：按未映射处理，load/store access fault。
- 访存不对齐仍优先于 access fault。

这保证 timer 不需要额外异常类型，仍复用已有 load/store access fault trap。

## 第6章 流水线接入规划

### 6.1 接入位置

当前 `trap_ctrl` 已经在 MEM 附近汇总：

- 随流水线传来的同步 exception。
- CSR illegal exception。
- `MRET`。

本阶段继续让 `trap_ctrl` 作为 interrupt 接受点。新增 interrupt 后，可以理解为：

```text
trap_ctrl = 同步 exception 选择 + MRET 选择 + interrupt 选择 + redirect/kill 控制
```

这样 interrupt 不会散落在 IF、ID、EX 各处，也更容易保持 precise state。

### 6.2 interrupt 不应简单复用 exception 的 kill_mem_wb

0831 的同步 exception 逻辑会阻止当前 MEM 指令作为普通指令进入 MEM/WB，因为 faulting instruction 自己不能提交。

interrupt 不同。推荐口径是：

```text
当前 MEM 边界的旧指令正常完成；
interrupt 在该指令之后被接受；
IF/ID/EX 等 younger instruction 被 kill；
handler 返回到第一条未提交指令。
```

因此，interrupt redirect 时：

| 对象 | 行为 |
|---|---|
| 当前 MEM 指令 | 若无同步 exception，允许按普通指令完成 |
| IF/ID | kill |
| ID/EX | kill |
| EX/MEM | kill |
| MEM/WB 输入 | 不因为 interrupt 本身 kill；只有同步 exception 才需要阻止 faulting instruction 进入普通 WB |

这和同步 exception 的最大差异在 MEM/WB。若实现上为了简单把 interrupt 也接到 `kill_mem_wb`，就等价于 replay 当前 MEM 指令，必须额外证明 store/MMIO 副作用不会被执行两次。当前已有 UART/GPIO/MMIO，因此不推荐这种口径。

### 6.3 interrupt 返回 PC 需要随流水线携带

为了支持 taken branch/JAL/JALR 后的 interrupt，MEM 边界需要知道当前提交指令的实际下一条 PC。

本阶段需要新增一类随指令流动的控制信息：

```text
next_pc / commit_next_pc / interrupt_return_pc
```

它的作用不是给普通 PC redirect 用，而是在接受 interrupt 时写入 `mepc`。

可以按下面方式理解：

```text
EX 阶段已经知道当前指令是否改变控制流；
把该指令的实际 next PC 一路带到 MEM；
trap_ctrl 接受 interrupt 时使用这个 next PC 写 mepc。
```

若只使用 `mem_pc + 4`，普通顺序程序大多能过，但在 branch/jump 附近接受 timer interrupt 时会返回错误位置。这类 bug 很隐蔽，应该在规划阶段就避免。

### 6.4 trap 控制输出口径

本阶段 `trap_ctrl` 的输出语义从“只处理 exception/MRET”扩展为：

| 输出类别 | 语义 |
|---|---|
| trap entry valid | exception 或 interrupt 被接受 |
| trap kind / is_interrupt | 区分写 `mcause[31]` |
| trap cause code | 写入 `mcause` 低位 |
| trap mepc | exception 时为 faulting PC，interrupt 时为 return PC |
| trap tval | exception 按类型写，interrupt 写 0 |
| MRET valid | `MRET` 被接受 |
| redirect valid/pc | trap entry 或 MRET 的 PC 重定向 |
| kill younger | trap entry/MRET 都需要 kill younger |
| kill current MEM/WB | 仅同步 exception 需要；interrupt 不使用 |

这里可以看出，本阶段最好不要继续把 `trap_pc` 理解为“发生错误的指令 PC”。对 exception 它是 fault PC，对 interrupt 它更准确地说是 `mepc` 写入值。

### 6.5 和 branch redirect 的优先级

interrupt redirect 仍应优先于年轻指令产生的 branch/JAL/JALR redirect。

原因是：如果 MEM 边界接受了 interrupt，那么 EX 阶段的 branch 是 younger instruction，已经被 kill，它的 redirect 不应改变 PC。当前已有 trap/MRET redirect 高于 EX redirect 的口径，本阶段继续沿用即可。

## 第7章 SoC 接入规划

### 7.1 顶层 interrupt 关系

当前 SoC 已经有：

```text
core
simple_rom
data_subsystem
mmio_gpio
mmio_uart
```

本阶段扩展为：

```text
core
  |<- mtip/meip
  |
data_subsystem
  |-> mmio_timer -> mtip
  |-> mmio_gpio  -> gpio_irq ----\
  |-> mmio_uart  -> uart_irq ----+-> meip
```

core 不需要知道 timer/GPIO/UART 寄存器细节，只需要看到 pending 输入或由 CSR 文件汇总后的 pending 状态。timer 也不需要知道流水线状态，只负责维护 `MTIME/MTIMECMP` 并输出 `mtip_raw`。

### 7.2 `mmio_timer` 的定位

`mmio_timer` 和当前 `mmio_uart/mmio_gpio` 一样，是教学 SoC 外设模型：

- 它通过 MMIO 被 load/store 访问。
- 它在硬件侧产生 `mtip_raw`。
- 它暂时固定响应，不产生 wait state。
- 它不属于 CPU core 内部。

这样划分后，后续如果接标准总线或做 FPGA wrapper，只需要替换 SoC 外围连接，不污染 core 微架构。

### 7.3 GPIO interrupt 规划

GPIO 当前只有 `OUT/IN/OE`。本阶段要让 GPIO 成为 `MEIP` 的来源之一，需要把 GPIO 从普通 MMIO 寄存器块升级为 interrupt-capable peripheral。

GPIO interrupt 不是“任意输入变化都中断”。每个 GPIO bit 都要先经过外设内部寄存器配置：

```text
输入变化/电平
  -> 按 bit 触发类型检测
  -> 与 IRQ_EN 按 bit 相与
  -> 置 IRQ_PENDING
  -> gpio_irq_o = |IRQ_PENDING
  -> meip_raw 包含 gpio_irq_o
```

GPIO0 本阶段寄存器规划：

| offset | 名称 | 属性 | 作用 |
|---:|---|---|---|
| `0x00` | `OUT` | RW | GPIO 输出值，当前供 testbench/外部观察 |
| `0x04` | `IN` | RO | GPIO 输入值，来自 `gpio_in_i` |
| `0x08` | `OE` | RW | GPIO 输出使能，当前保存为普通配置寄存器 |
| `0x0C` | `IRQ_EN` | RW | 每 bit 中断总使能，1 表示该 bit 允许置 pending |
| `0x10` | `IRQ_RISE_EN` | RW | 每 bit 上升沿触发使能 |
| `0x14` | `IRQ_FALL_EN` | RW | 每 bit 下降沿触发使能 |
| `0x18` | `IRQ_HIGH_EN` | RW | 每 bit 高电平触发使能 |
| `0x1C` | `IRQ_LOW_EN` | RW | 每 bit 低电平触发使能 |
| `0x20` | `IRQ_PENDING` | R/W1C | 每 bit pending；读出当前 pending，写 1 清对应 bit，写 0 保持 |
| `0x24` | `IRQ_STATUS` | RO | `IRQ_PENDING & IRQ_EN` 的结果，用于软件快速判断有效中断源 |

触发检测可以描述为：

```text
rise_hit  =  gpio_in_curr & ~gpio_in_prev
fall_hit  = ~gpio_in_curr &  gpio_in_prev
high_hit  =  gpio_in_curr
low_hit   = ~gpio_in_curr

trigger_hit =
    (IRQ_RISE_EN & rise_hit) |
    (IRQ_FALL_EN & fall_hit) |
    (IRQ_HIGH_EN & high_hit) |
    (IRQ_LOW_EN  & low_hit)

IRQ_PENDING <= IRQ_PENDING | (IRQ_EN & trigger_hit)
gpio_irq_o  = |(IRQ_PENDING & IRQ_EN)
```

这样可以同时覆盖边沿触发和电平触发：

- 边沿触发适合按钮、外部事件 pulse 等场景。
- 电平触发适合外部设备一直请求服务的场景。
- 软件通过写 `IRQ_PENDING` 的 1 来清除已经处理的 bit。
- 若配置为电平触发，且外部电平仍保持触发状态，即使软件清 pending，下一拍也会再次置 pending；这是 level interrupt 的正常行为。

### 7.4 UART RX interrupt 规划

UART 当前只有 TX 仿真输出。本阶段要让 UART 成为 `MEIP` 的来源之一，需要补一个简化 RX 路径，但不需要做真实串口采样、波特率、起始位/停止位。

仿真 UART RX 可以理解为：

```text
testbench/SoC 输入 uart_rx_valid_i + uart_rx_data_i
mmio_uart 保存 RXDATA，并置 rx_valid/rx_irq_pending
软件读取 RXDATA 或写 clear 寄存器后清 pending
uart_irq = rx_irq_pending && rx_irq_enable
meip_raw 包含 uart_irq
```

UART0 本阶段寄存器规划：

| offset | 名称 | 属性 | 作用 |
|---:|---|---|---|
| `0x00` | `TXDATA` | WO | 发送数据字节（只写，读返回 0）；`CTRL.enable=1` 时写入触发 TX event |
| `0x04` | `STATUS` | RO | `[0]=tx_ready`（当前固定 1），`[1]=rx_valid`（RX 数据有效），`[2]=irq_pending`（`IRQ_PENDING[0]` 的只读镜像） |
| `0x08` | `CTRL` | RW | `[0]=tx_enable`，`[1]=rx_irq_enable`；其余 bit 读 0 写忽略 |
| `0x0C` | `RXDATA` | RO | 接收数据字节，来自 `uart_rx_data_i`；读操作同时清 `irq_pending` |
| `0x10` | `IRQ_PENDING` | R/W1C | 读表示 RX 中断 pending；写 1 清 pending（当不使用 RXDATA 读取清除时） |

UART RX event 必须被保存成 pending 状态，不能只输出单周期 pulse。否则 core 没有在同一拍接受 interrupt 时，UART 中断会丢失。

## 第8章 软件和测试注意事项

### 8.1 平台头文件

0832 已经引入了 MMIO 平台概念。本阶段软件侧集中补一个平台头文件，例如：

```text
sw/include/platform.h
```

其中应包含：

| 类别 | 内容 |
|---|---|
| MMIO base | `GPIO0_BASE`、`UART0_BASE`、`TIMER0_BASE` |
| timer offset | `TIMER_MTIME`、`TIMER_MTIMECMP`、`TIMER_CTRL`、`TIMER_STATUS` |
| GPIO irq offset/mask | `IRQ_EN`、`IRQ_RISE_EN`、`IRQ_FALL_EN`、`IRQ_HIGH_EN`、`IRQ_LOW_EN`、`IRQ_PENDING`、`IRQ_STATUS` 相关 offset 和 bit mask |
| UART RX/irq offset/mask | UART `RXDATA`、RX valid、RX interrupt enable、pending/clear 相关 offset 和 bit mask |
| CSR bit mask | `MSTATUS_MIE`、`MSTATUS_MPIE` |
| interrupt enable mask | `MIE_MTIE`、`MIE_MEIE`；`MIE_MSIE` 可只作为后续保留说明 |
| interrupt pending mask | `MIP_MTIP`、`MIP_MEIP`；`MIP_MSIP` 可只作为后续保留说明 |
| mcause helper | `MCAUSE_INTERRUPT_BIT`、`MCAUSE_CODE_MASK` |

这样 C/ASM 测试不需要在每个文件里重复硬编码地址和 bit。

### 8.2 handler 需要区分 exception 和 interrupt

`mcause[31]` 是 handler 的第一层分发依据：

```text
mcause[31] = 0 -> exception
mcause[31] = 1 -> interrupt
```

随后再看低位 code：

| `mcause` | 含义 |
|---:|---|
| `0x8000_0003` | machine software interrupt |
| `0x8000_0007` | machine timer interrupt |
| `0x8000_000B` | machine external interrupt |

测试程序中不要只比较低 5 bit，否则会把 exception code 7 和 timer interrupt code 7 混淆。

### 8.3 timer handler 必须清 pending

timer interrupt 是 level pending。handler 最少要做：

```text
读取/计算下一次触发时间
写 MTIMECMP 到未来
必要时记录测试进度
MRET
```

如果 handler 只打印或写 pass flag，却不更新 `MTIMECMP`，`MTIP` 会保持为 1。`MRET` 恢复 `MIE` 后，core 会再次进入同一个 timer interrupt。

### 8.4 external interrupt handler 必须 ack

external interrupt 也通常是 level pending。本阶段 `MEIP` 来自 GPIO 和 UART，handler 需要读取外设 pending/status 判断来源，再通过对应方式清除来源：

| 来源 | 清除方式 |
|---|---|
| GPIO edge pending | 软件写 `IRQ_PENDING` 的 W1C bit 清除 |
| GPIO level pending | 软件清 pending 前后还要确认外部输入已不满足触发电平，否则会再次置 pending |
| UART RX pending | 软件读取 RXDATA 或写 clear 寄存器，按 UART 寄存器定义清除 |

如果来源不清，`MRET` 后同样会立刻再次中断。

### 8.5 异步测试不要依赖精确周期

timer 和 external interrupt 对软件来说是异步事件。测试应避免写成：

```text
第 N 周期必须进入 handler
```

更稳妥的检查方式是：

- 在 bounded cycle 内观察到 trap entry。
- handler 执行后某个 MMIO/DMEM flag 增加。
- `mepc` 返回后主程序继续前进。
- pending 清除后不会无限重复进入 handler。

后续仿真方案可以再细化，但本阶段规划上应明确：interrupt 测试看“最终状态和有界响应”，不看完全固定的每拍时序。

### 8.6 后续测试方向

RTL 完成后，可以考虑按下面方向补 directed test：

| 测试方向 | 关注点 |
|---|---|
| timer interrupt smoke | 配置 `MTIMECMP`，打开 `mie.MTIE` 和 `mstatus.MIE`，观察进入 handler |
| interrupt mask | pending=1 但 `MIE=0` 或 `MTIE=0` 时不进入 |
| `MRET` return | handler 返回后主程序继续执行正确路径 |
| pending clear | handler 更新 `MTIMECMP` 或清外设 pending 后不会立即重复中断 |
| exception over interrupt | 同边界有同步 exception 时先处理 exception |
| branch/jump nearby interrupt | 验证 `mepc` 使用实际 next PC，而不是简单 `pc+4` |
| GPIO interrupt smoke | 配置 GPIO bit 的 enable/触发类型，输入命中后进入 external interrupt handler，并在 W1C clear 后返回 |
| UART RX interrupt smoke | testbench 注入 RX 字符后进入 external interrupt handler，软件读/清 RX pending 后返回 |
| C trap smoke | C handler 根据 `mcause[31]` 分发 timer interrupt |

具体文件命名和脚本组织可以等 RTL 改完后再进入 `plan.md` 详细设计。

## 第9章 预计影响的工程对象

本章只统计大类，不列逐行施工步骤。

### 9.1 RTL 影响范围

预计会涉及：

| 区域 | 可能变化 |
|---|---|
| `rtl/common/core_pkg.sv` | 新增 `CSR_ADDR_MIE/MIP`、interrupt code、`mcause` interrupt bit 相关常量 |
| `rtl/common/soc_pkg.sv` | 补 TIMER0 offset、GPIO IRQ offset、UART RX/IRQ offset、timer/GPIO/UART bit mask 等平台常量 |
| `rtl/core/csr_file.sv` | 新增 `mie/mip`，扩展 `mcause` 写入，接入 raw pending |
| `rtl/core/trap_ctrl.sv` | 新增 interrupt pending 选择、优先级、interrupt entry 输出 |
| `rtl/core/core.sv` | 新增 interrupt 输入/观察信号，传递 interrupt return PC |
| `rtl/common/pipeline_pkg.sv` | 新增 next PC / interrupt return PC 字段 |
| `rtl/core/ex_stage.sv` | 生成当前指令实际 next PC |
| `rtl/soc/rv32i_soc.sv` | 实例化 timer，汇总 `mtip`、GPIO irq 和 UART irq |
| `rtl/soc/data_subsystem.sv` | 将 TIMER0 窗口从预留改为已实现外设 |
| `rtl/periph/mmio_timer.sv` | 新增 timer MMIO 寄存器块 |
| `rtl/periph/mmio_gpio.sv` | 新增 GPIO interrupt enable/pending/clear 逻辑和 `gpio_irq_o` |
| `rtl/periph/mmio_uart.sv` | 新增仿真 RX、RX pending/clear 逻辑和 `uart_irq_o` |

### 9.2 软件影响范围

预计会涉及：

| 区域 | 可能变化 |
|---|---|
| `sw/include/platform.h` | 新增 MMIO 地址、timer/GPIO/UART irq offset、CSR/interrupt bit mask |
| `sw/c_runtime/crt0.S` | 若 C handler 需要统一入口，可能扩展 trap wrapper 保存现场和调用 C 分发函数 |
| `sw/asm` | 新增 timer、GPIO external interrupt、UART RX external interrupt directed tests |
| `sw/c` | 新增 C interrupt smoke 或 timer/GPIO/UART demo |
| linker script | 通常无需为 interrupt 单独改，仍复用 `.text.trap`；除非要拆多个 handler section |

### 9.3 仿真影响范围

预计会涉及：

| 区域 | 可能变化 |
|---|---|
| SoC testbench | 观察 timer interrupt、GPIO 输入变化、UART RX 注入、trap entry、handler 写 flag |
| run script | 加入新的 interrupt 测试分组 |
| trace 打印 | `mcause` 需要显示 interrupt/exception，timer 测试需要避免过多无关 commit 打印 |
| timeout | interrupt 测试可能需要比普通 smoke 更长 timeout |

本阶段仿真方案不在本文细化。原因是 interrupt RTL 完成后，`trap_valid`、`mepc`、timer 输出和 handler 约定的真实形态会更明确，再写测试计划更稳。

## 第10章 和后续阶段的关系

### 10.1 和 0834 wait-state/backpressure 的关系

本阶段仍假设 MMIO 固定响应：

```text
timer load/store 当拍可得到 rdata/access_fault
timer store 当拍或下一拍更新内部寄存器
无 ready/valid
无 MEM stall
```

0834 会引入可变延迟 memory/MMIO。到那时，timer 和其它外设需要通过 response channel 返回 `rdata/error`，MEM 阶段需要在 response 未回来前 stall。

因此，0833 只应把 interrupt 机制和 timer 功能做正确，不要提前把 wait-state 混进来。

### 10.2 和后续总线化的关系

本阶段的 timer、GPIO、UART 仍可以接在简单 data subsystem 后面。等 0834 的 ready/valid 边界稳定后，再考虑：

- 把 data subsystem 改成项目内部简化总线。
- 包装 APB-Lite 给低速外设。
- 为 accelerator 控制面预留 AXI-Lite/APB-Lite slave。
- 如果 accelerator 需要主动读写内存，再讨论 DMA/master 接口。

也就是说，本阶段 timer 是为了完成 machine interrupt，不是为了引入标准总线。

### 10.3 和 accelerator/NPU 的关系

timer interrupt 完成后，项目会具备一套完整的“CPU 配置外设、外设完成后通知 CPU、CPU handler 处理结果”的基本闭环：

```text
CPU 写 MMIO 配置外设
外设工作
外设产生 interrupt pending
CPU 进入 handler
handler 读取状态并清 pending
MRET 返回主程序
```

这个闭环后续可以直接迁移到 accelerator/NPU：

- CPU 通过 MMIO 写 accelerator `SRC/DST/LEN/CTRL`。
- accelerator 完成后置 `done` 和 interrupt pending。
- handler 读取 `STATUS`，清 pending，唤醒主程序。

因此，0833 虽然只做 timer，但它建立的是后续“CPU 调度外设/加速器”的中断控制框架。
