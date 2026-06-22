# 0832 最小 memory map 与 MMIO 外设规划

> 文档编号：0832  
> 所属系列：083x RV32I 教学核后续完善阶段  
> 文档定位：规划当前五级流水线核在完成最小 M-mode CSR/trap 后，如何加入最小 memory map、MMIO 外设和 SoC 级地址译码能力  
> 对应总规划：`0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`  
> 前置文档：`0804 RISC-V SoC、MMIO与外设互联.md`、`0826 裸机程序、ROM与RAM加载与工具链使用示例.md`、`0827 Testbench、commit trace与测试集组织.md`、`0831 最小M-mode CSR与trap规划.md`

本篇只规划“第二阶段做什么”。它不是执行阶段的 `plan.md`，因此不会写成逐文件逐端口的施工清单。

第二阶段的目标是：在当前已经能运行 M-mode trap handler 的五级流水线核外面，补上最小 SoC 地址图、MMIO 外设访问能力和未映射地址 access fault。完成后，软件不仅能访问 IMEM/DMEM，还能用普通 `lw/sw` 读写外设寄存器，例如输出 UART 字符、观察 GPIO 状态；如果访问没有映射到 RAM/MMIO 的地址，硬件会进入 load/store access fault trap。后续 timer interrupt 和 accelerator 控制也可以建立在同一套 MMIO 机制上。

## 第1章 本步目标和非目标

### 1.1 当前已经完成的基础

在进入本步之前，当前系统已经具备：

| 能力 | 当前状态 |
|---|---|
| 五级流水线主路径 | IF/ID/EX/MEM/WB、forwarding、load-use/CSR-use stall、branch/JAL/JALR redirect 已完成 |
| CSR/trap | 最小 M-mode CSR、`ECALL/EBREAK/MRET`、Zicsr、同步异常 trap 已完成 |
| trap handler 布局 | `mtvec` 默认指向 `IMEM_BASE + 0x80`，linker 已支持 `.text.trap` |
| IMEM/DMEM 容量 | `simple_rom/simple_ram` 当前各 256 KiB |
| 软件地址图 | `IMEM_BASE = 0x0000_0000`，`DMEM_BASE = 0x0004_0000` |
| C runtime | 支持 `.text.init/.text.trap/.text`，C 测试可覆盖弱符号 `__trap_handler_c` |
| testbench | 支持 PASS/FAIL、commit trace、trap/MRET trace、DMEM/stack 统计 |

因此，`plan.md` 中已经完成的“统一扩展 IMEM/DMEM 容量与地址图”可以理解为本阶段的地基：地址空间里已经有了明确的 IMEM 和 DMEM 窗口。

但这还不等于完成了 0830 中的第二阶段。第二阶段真正新增的是：**load/store 地址需要经过地址译码，访问对象不再只有 RAM，还可以是 MMIO 外设寄存器。**

当前结构可以简化理解为：

```text
CPU load/store -> simple_ram
```

本步目标结构是：

```text
CPU load/store -> data address decode
                  |-> DMEM SRAM
                  |-> MMIO UART/GPIO
                  |-> unmapped load/store access fault
```

### 1.2 本步目标

本步完成后，core 所在平台应具备：

| 能力 | 目标 |
|---|---|
| 明确 memory map | 在已有 IMEM/DMEM 基础上，新增 MMIO window 和外设寄存器地址 |
| 数据地址译码 | MEM 阶段发出的 load/store 根据地址进入 DMEM 或 MMIO |
| 最小 MMIO 外设 | 支持 UART0 和 GPIO0 两类最小外设；UART0 当前仅实现 TX |
| 软件可访问外设 | C/ASM 通过普通 `lw/sw` 访问外设寄存器 |
| 外设仿真观察 | testbench 能打印 UART 字符或观察 GPIO 寄存器变化 |
| 访问错误 trap | 未映射 load/store 进入 access fault trap，`mtval` 记录访问地址 |
| 副作用门控 | wrong-path、trap、misaligned、access fault 等情况下不能错误写 RAM/MMIO |
| 后续扩展口 | 为 timer interrupt、外部中断、accelerator MMIO 控制预留地址和 error/response 语义 |

### 1.3 本步非目标

本步不做：

| 暂不做 | 原因 |
|---|---|
| interrupt/timer interrupt | 放到 0830 第三阶段；本步只完成 timer 地址预留，不实现 `mtime/mtimecmp` 和 interrupt pending |
| memory/MMIO wait state | 当前仍假设固定响应；ready/valid/backpressure 放到第四阶段，但本步会保留 error/access fault 语义 |
| AXI/AHB/APB 完整总线 | 当前外设少，先用简单内部译码；标准总线后续再抽象 |
| DMA | accelerator 或存储搬运需求明确后再做 |
| cache/device memory 属性 | 当前无 cache，`FENCE` 仍可按 NOP 处理 |
| 多时钟域和 CDC | 当前教学平台默认单时钟 |
| PLIC/CLINT 完整模型 | 依赖 interrupt 规划，放到后续阶段 |

## 第2章 当前地址图和本步建议地址图

### 2.1 当前地址图

当前 RTL、linker 和 testbench 已经约定：

| 区域 | 起始地址 | 结束地址 | 大小 | 当前用途 |
|---|---:|---:|---:|---|
| IMEM | `0x0000_0000` | `0x0003_FFFF` | 256 KiB | 指令、`.text.init`、`.text.trap`、`.text`、部分只读内容 |
| DMEM | `0x0004_0000` | `0x0007_FFFF` | 256 KiB | 数据、测试状态、C 栈 |

对应公共常量位于 `rtl/common/core_pkg.sv`：

```systemverilog
IMEM_BASE       = 32'h0000_0000;
DMEM_BASE       = 32'h0004_0000;
IMEM_SIZE_BYTES = 32'h0004_0000;
DMEM_SIZE_BYTES = 32'h0004_0000;
MTVEC_RESET     = IMEM_BASE + 32'h0000_0080;
```

这个地址图已经足够支撑普通 C/ASM 程序和 trap handler，但软件还没有办法通过地址访问“外设动作”。

### 2.2 本步建议新增 MMIO window

建议在 DMEM 之后直接开一段 MMIO window：

| 区域 | 建议起始地址 | 建议结束地址 | 建议大小 | 用途 |
|---|---:|---:|---:|---|
| MMIO | `0x0008_0000` | `0x0008_FFFF` | 64 KiB | 最小外设寄存器窗口 |

推荐新增公共常量：

```systemverilog
MMIO_BASE       = 32'h0008_0000;
MMIO_SIZE_BYTES = 32'h0001_0000;
```

这样地址空间保持连续、直观：

```text
0x0000_0000 - 0x0003_FFFF  IMEM, 256 KiB
0x0004_0000 - 0x0007_FFFF  DMEM, 256 KiB
0x0008_0000 - 0x0008_FFFF  MMIO, 64 KiB
```

64 KiB 的 MMIO window 对当前教学 SoC 足够宽。为了后续多实例外设和 accelerator 接入，本阶段可以先把 MMIO 内部子地址图规划清楚，暂时只实例化用到的 0 号外设。

### 2.3 本步建议外设地址

建议按外设类型分配连续窗口，每个普通外设实例占 `0x100` bytes：

| 子窗口 | 起始地址 | 结束地址 | 规划 |
|---|---:|---:|---|
| GPIO | `0x0008_0000` | `0x0008_03FF` | 4 个 GPIO，每个 `0x100` |
| reserved | `0x0008_0400` | `0x0008_0FFF` | GPIO 页内预留 |
| TIMER | `0x0008_1000` | `0x0008_15FF` | 6 个 timer，每个 `0x100` |
| UART | `0x0008_2000` | `0x0008_25FF` | 6 个 UART，每个 `0x100` |
| reserved | `0x0008_3000` | `0x0008_7FFF` | 普通外设扩展预留 |
| ACCEL | `0x0008_8000` | `0x0008_BFFF` | 4 个 accelerator，每个 `0x1000` |
| reserved | `0x0008_C000` | `0x0008_FFFF` | 后续大块扩展 |

当前规划的 0 号实例：

| 外设 | 建议 base | 建议大小 | 作用 |
|---|---:|---:|---|
| GPIO0 | `0x0008_0000` | `0x100` | 软件写 OUT、读 IN，用于可观察控制寄存器 |
| TIMER0 | `0x0008_1000` | `0x100` | 本步只保留地址，后续 interrupt 阶段实现 |
| UART0 | `0x0008_2000` | `0x100` | 软件写 TXDATA，testbench 打印字符 |
| ACCEL0 | `0x0008_8000` | `0x1000` | 预留给后续 TPU/NPU 或 MAC accelerator |

本阶段只实现 GPIO0 和 UART0。GPIO1-3、UART1-5、TIMER0-5、ACCEL0-3 在对应模块未实现前都按未映射地址处理，访问时产生 access fault。这样软件地址图先稳定下来，RTL 可以按需逐步实例化。

对应公共常量可以放在 `core_pkg.sv` 或后续专门的 platform package 中。当前工程规模不大，先放 `core_pkg.sv` 更直接；等 SoC 侧内容变多，再拆成 `platform_pkg.sv` 也可以。

### 2.4 `FENCE` 当前仍可按 NOP

加入 MMIO 后，软件会更关心访问顺序。例如先写 UART 数据，再写控制寄存器，或者先配置 accelerator，再写 start。

但当前流水线仍满足几个简化条件：

- 单发射、顺序执行。
- 没有 store buffer。
- 没有 data cache。
- DMEM/MMIO 都固定响应。
- MEM 阶段一次只接受当前指令的访存副作用。

因此，在当前阶段，普通 load/store 对 RAM/MMIO 的执行顺序天然和程序顺序一致，`FENCE` 继续按 NOP 处理不会破坏这个教学平台的可见行为。

后续如果加入 cache、store buffer、异步总线、DMA 或多个 master，`FENCE` 才需要重新定义更完整的 ordering 行为。

## 第3章 MMIO 寄存器规划

### 3.1 MMIO 和 RAM 的语义差异

软件访问 MMIO 仍然使用普通 load/store，但硬件含义不同：

| 项目 | RAM | MMIO |
|---|---|---|
| store | 保存数据 | 修改控制寄存器、触发动作、清状态 |
| load | 读回存储内容 | 读状态、读输入、读计数器 |
| byte enable | 写对应 byte lane | 需要明确外设是否支持 byte/half/word 写 |
| 副作用 | 通常没有 | 常见写触发、读清、W1C |
| 未映射地址 | 通常不应访问 | 本阶段统一产生 load/store access fault |

本步应把外设寄存器设计得尽量简单，避免一开始就引入太多副作用类型。第一版只做：

- RW：普通可读写寄存器。
- RO：只读状态寄存器。
- WO 或 write-trigger：写入触发动作，读返回 0 或状态。

### 3.2 UART0 最小寄存器

UART0 第一版不需要真实串口波特率发送器，只需要提供一个 MMIO 寄存器，让 testbench 能观察字符输出。模块建议命名为 `mmio_uart`，当前只实现 TX；后续增加 RX、UART interrupt 时继续扩展同一个模块，避免再改外设名和实例名。

建议寄存器：

| offset | 名称 | 属性 | bit 定义 | 行为 |
|---:|---|---|---|---|
| `0x00` | `TXDATA` | WO | `[7:0] data` | `CTRL.enable=1` 且写 byte0 时触发 TX event，testbench 打印对应字符；读返回 0 |
| `0x04` | `STATUS` | RO | `bit0 tx_ready` | 第一版固定为 1，表示总能接收下一个字符 |
| `0x08` | `CTRL` | RW | `bit0 enable` | 复位为 0，软件需要先开启再发送 |

真正的 TX event 定义为：地址命中 UART0，当前访问是 store，offset 为 `TXDATA`，`be_i[0]` 有效，且 `CTRL.enable=1`。写 `TXDATA` 但没有写 byte0 时，只更新被使能的 byte lane，不触发字符输出。

软件最小使用路径依赖 `CTRL`、`STATUS` 和 `TXDATA`：

```c
#define UART0_BASE   0x00082000u
#define UART_TXDATA  (*(volatile unsigned int *)(UART0_BASE + 0x00))
#define UART_STATUS  (*(volatile unsigned int *)(UART0_BASE + 0x04))
#define UART_CTRL    (*(volatile unsigned int *)(UART0_BASE + 0x08))

UART_CTRL = 1u;
while ((UART_STATUS & 1u) == 0) {}
UART_TXDATA = 'A';
```

在固定响应模型下，`tx_ready` 可以一直为 1。后续阶段如果加入真实 UART 或 wait state，再让 `tx_ready` 反映发送 FIFO 状态。

### 3.3 GPIO0 最小寄存器

GPIO0 用来验证普通 RW/RO MMIO 寄存器，比 UART 更像通用外设寄存器块。

建议寄存器：

| offset | 名称 | 属性 | bit 定义 | 行为 |
|---:|---|---|---|---|
| `0x00` | `OUT` | RW | `[31:0] gpio_out` | 软件写入后保持，testbench 可观察 |
| `0x04` | `IN` | RO | `[31:0] gpio_in` | 来自 testbench 或顶层输入 |
| `0x08` | `OE` | RW | `[31:0] gpio_oe` | 输出使能，第一版可只保存不影响功能 |

UART 当前 TX 路径的仿真效果最直观，用来证明 MMIO store 能触发外设动作；GPIO 更适合验证普通 RW/RO 寄存器、byte enable 和状态保持。两者合在一起能覆盖最小 MMIO 平台最常见的两类外设语义。

### 3.4 TIMER 和 accelerator 地址预留

0830 第三阶段会做 machine interrupt 与 timer。因此本步可以先预留 `TIMER0_BASE`，但不必实现 `mtime/mtimecmp`。

后续 timer 可能包含：

| offset | 名称 | 作用 |
|---:|---|---|
| `0x00` | `MTIME_LO` | 低 32 bit 计数 |
| `0x04` | `MTIME_HI` | 高 32 bit 计数 |
| `0x08` | `MTIMECMP_LO` | 低 32 bit 比较值 |
| `0x0C` | `MTIMECMP_HI` | 高 32 bit 比较值 |
| `0x10` | `CTRL` | 使能、清 pending 等 |

后续接 TPU/NPU 或 MAC accelerator 时，也建议走 MMIO 控制面：

| offset | 名称 | 作用 |
|---:|---|---|
| `0x00` | `CTRL` | start、enable、interrupt enable |
| `0x04` | `STATUS` | busy、done、error |
| `0x08` | `SRC_ADDR` | 输入数据地址 |
| `0x0C` | `DST_ADDR` | 输出数据地址 |
| `0x10` | `LEN` | 数据长度或矩阵维度 |

因此，本步虽然只实现 UART/GPIO 这两类外设，但地址图应提前给 accelerator 留出一段整齐空间。

### 3.5 本阶段与后续阶段的衔接口径

本阶段把 memory map 的基本规则一次定清楚：

- 命中 DMEM：访问 SRAM。
- 命中 UART/GPIO：访问 MMIO 寄存器。
- 命中 TIMER/ACCEL 预留区但外设尚未实现：仍按未映射处理，进入 access fault。
- 未命中任何已实现区域：进入 access fault。

后续 0833 实现 timer 时，只需要把 `TIMER0_BASE` 对应窗口从“预留但未实现”改为“命中 timer MMIO 寄存器块”，再由 timer 产生 interrupt pending。后续 0834 实现可变延迟时，只需要把本阶段组合产生的 `access_fault/error` 放进 response channel，而不是重新定义异常语义。

## 第4章 地址译码和访问错误

### 4.1 数据访问路径

当前 `core.sv` 对外暴露一组 LSU data side 接口：

```systemverilog
lsu_re_o
lsu_we_o
lsu_be_o
lsu_addr_o
lsu_wdata_o
lsu_rdata_i
```

这组接口本质上已经接近一个最小 data bus，只是现在 testbench 直接把它连到 `simple_ram`。

本步建议在 core 和 RAM/MMIO 之间插入一个数据地址译码层：

```text
core
  lsu_* request
      |
      v
data_subsystem / data_addr_decode
      |-> simple_ram
      |-> mmio_uart
      |-> mmio_gpio
      |-> access fault
      |
      v
  lsu_rdata back to core
```

这样 CPU core 仍然只认为自己在做 load/store，SoC wrapper 决定这个地址到底访问 RAM 还是外设。

### 4.2 推荐保留 core 和 SoC 的边界

建议保持 `core.sv` 是 CPU core，不在里面实例化 UART/GPIO。更推荐新增一个 SoC 或 platform wrapper：

```text
rtl/core/core.sv                 只放 CPU core
rtl/mem/simple_rom.sv            IMEM model
rtl/mem/simple_ram.sv            DMEM SRAM model
rtl/soc/rv32i_soc.sv             core + memory + MMIO wrapper
rtl/soc/data_subsystem.sv        数据地址译码和读数据 mux
rtl/periph/mmio_uart.sv          UART 寄存器块，当前仅实现 TX
rtl/periph/mmio_gpio.sv          GPIO 寄存器块
```

这样有几个好处：

- CPU core 不被具体外设污染。
- 以后接真实总线、FPGA wrapper 或 accelerator 时，只改 SoC 外围。
- core-level test 和 SoC-level test 可以分开。
- 面试表达更清楚：core 是 CPU 微架构，SoC wrapper 是系统集成。

如果为了少改仿真，也可以先把译码层放到现有 testbench 里。但长期看，单独的 SoC wrapper 更适合作为阶段2的产物。

### 4.3 未映射地址的处理

访问不属于已实现 DMEM/MMIO 的地址时，本阶段统一产生 load/store access fault。

由于当前已经完成 CSR/trap，本步采用 access fault trap，把 access fault 作为阶段2完整目标：

| 事件 | `mcause` exception code | `mtval` |
|---|---:|---|
| load access fault | 5 | faulting address |
| store/AMO access fault | 7 | faulting address |

这需要在 `excp_cause_e` 中补：

```systemverilog
EXCEPTION_CAUSE_LOAD_ACCESS_FAULT  = 5'd5;
EXCEPTION_CAUSE_STORE_ACCESS_FAULT = 5'd7;
```

同时数据地址译码层需要告诉 core 当前访问是否 fault。由于本阶段仍是固定响应模型，只加组合错误返回，不引入 ready/valid：

```text
core -> data_subsystem : re/we/be/addr/wdata
data_subsystem -> core : rdata/access_fault
```

后续第四阶段加入 wait state 时，再把 `access_fault` 语义迁移到 response channel 的 `error` 位上。

### 4.4 对齐错误和 access fault 的优先级

当前 `mem_stage` 已经能检测 load/store address misaligned。加入地址译码后，同一条访存指令理论上可能同时满足：

- 地址不对齐。
- 地址落在未映射区。

建议优先级为：

```text
已有前级 exception > misaligned > access fault
```

原因：

- 已经和指令绑定的更早 exception 不能被 MEM 覆盖。
- RISC-V 对 misaligned 与 access fault 的具体优先级允许实现选择，教学核保持固定规则即可。
- 对学生调试来说，先报 misaligned 更直观，因为地址本身已经不满足访问宽度要求。

如果后续要严格模拟某个平台，也可以在文档中声明该平台的选择。

### 4.5 MMIO byte enable 规则

当前 core 已经为 store 生成 `lsu_be_o`。MMIO 外设应明确是否支持 byte/halfword 写。

第一版推荐规则：

| 访问类型 | 建议行为 |
|---|---|
| word store 到 32-bit MMIO 寄存器 | 支持 |
| byte/half store 到 RW 寄存器 | 按 byte enable 更新对应 byte lane |
| byte/half store 到 write-trigger 寄存器 | 可以只看低 8 bit，也可以要求 word store |
| load byte/half from MMIO | core 会从 32-bit `rdata` 中截取，外设只返回完整 32-bit word |

为了减少歧义，软件驱动第一版建议都用 32-bit volatile load/store 访问 MMIO 寄存器。byte enable 支持可以作为 RTL 完整性补充，但测试程序不必一开始依赖它。

## 第5章 流水线和副作用关系

### 5.1 MMIO 副作用发生在 MEM 边界

MMIO store 是真实副作用，语义上和写 DMEM 类似，都应只在 MEM 阶段当前指令有效且没有 exception 时发生。

当前 `mem_stage` 已经用 `valid_i`、`exception_valid_i` 和 misaligned 检测门控 `lsu_we_o`。加入 MMIO 后仍应保持同一原则：

```text
只有有效、未被 kill、未发生本条指令 exception 的 store，才能写 RAM 或 MMIO。
```

这点对 trap 后 wrong-path kill 很重要。例如：

```asm
ecall
sw x1, UART_TXDATA(x0)   # younger 指令，必须被 kill，不能真的输出字符
```

如果 trap 已经在 MEM 边界被接受，后面年轻指令的 MMIO 副作用必须被屏蔽，否则软件会看到架构上不该发生的外设动作。

### 5.2 load from MMIO 和普通 load 的关系

MMIO load 和 RAM load 在 CPU 内部大体共用路径：

```text
load address -> data subsystem -> 32-bit rdata -> mem_stage load_data_o -> WB
```

因此，对 CPU core 来说，MMIO load 不需要新的写回来源。它仍然是 `WB_MEM`，只是 `lsu_rdata_i` 的来源由 RAM 改成了 MMIO 寄存器块。

### 5.3 store to MMIO 和普通 store 的关系

MMIO store 不写 GPR，和普通 store 一样没有 WB 写回。区别只在外部数据子系统：

```text
地址命中 DMEM  -> 写 simple_ram
地址命中 UART  -> 写 UART TXDATA/CTRL
地址命中 GPIO  -> 写 GPIO OUT/OE
地址未命中     -> access fault
```

所以，第一版不需要新增一类指令，也不需要修改 decoder。所有 MMIO 行为都由 load/store 的地址决定。

### 5.4 trap、flush、kill 与 MMIO

0831 已经建立了 trap/MRET 使用 kill 的口径。本步要延续这个语义：

| 情况 | MMIO 行为 |
|---|---|
| wrong-path store 被 branch flush/kill | 不写 MMIO |
| trap 后 younger store 被 kill | 不写 MMIO |
| faulting store 自己触发 misaligned/access fault | 不写 MMIO |
| older store 已经在 MEM 合法提交 | 可以写 MMIO，不应被 younger trap 反向取消 |

这也是为什么 MMIO 副作用必须放在 MEM 边界，并且必须受 valid/exception/kill 后的访问使能控制。

## 第6章 固定响应接口和后续 backpressure

### 6.1 本步继续固定响应

本步仍建议保持：

- IMEM 组合读。
- DMEM/MMIO 组合读。
- DMEM/MMIO 同步写。
- 无 ready/valid。
- 无 MEM stall。

也就是说，本步只改变“访问哪个设备”“读数据从哪里回来”和“访问错误如何进入 trap”，不改变流水线的时序假设。

这样可以把阶段2控制在 memory map/MMIO 本身，不和第四阶段的 backpressure 混在一起。

### 6.2 为什么不直接上 APB/AHB/AXI

标准总线当然更工程化，但当前教学核还处于单 core、少量外设、固定响应阶段。直接上 AXI/APB 会把注意力从 CPU/MMIO 行为转移到协议细节。

推荐路线：

```text
阶段2：简单地址译码 + 固定响应 MMIO + access fault
阶段3：interrupt/timer
阶段4：ready/valid 或简化 bus response + MEM stall
后续：需要时再包装成 APB/AHB-Lite/AXI-Lite
```

这样每一步的学习目标更清楚。

### 6.3 后续 ready/valid 的预留方向

虽然本步不做 wait state，但接口命名可以提前考虑后续扩展：

```text
request:
  valid, write, be, addr, wdata

response:
  ready, rdata, error
```

本步的固定响应可以理解为：

```text
ready = 1
error = address decode fault
```

本阶段先把 `error/access_fault` 接进现有 trap 路径；后续第四阶段再把 `ready` 接进流水线 stall 网络，并把当前组合错误语义自然放到 response error 上。

### 6.4 和 0833/0834 的关系

本阶段做全量 access fault 后，后续两个阶段的衔接会更顺：

| 后续阶段 | 依赖本步的内容 | 后续新增内容 |
|---|---|---|
| 0833 interrupt/timer | 已有 MMIO window、`TIMER0_BASE` 预留、trap entry/MRET、地址译码框架 | 实现 timer 寄存器、`mie/mip`、interrupt pending/enable、interrupt trap |
| 0834 wait state/backpressure | 已有 request 字段、固定响应 `rdata/error` 语义、access fault trap 路径 | 增加 ready/valid、MEM stall、response 延迟返回、error 随 response 返回 |

因此，本步不是提前实现 0833/0834，而是把它们会依赖的地址图、错误语义和外设边界先稳定下来。

## 第7章 建议新增或修改的 RTL 文件

### 7.1 新增文件

建议新增：

| 文件 | 作用 |
|---|---|
| `rtl/soc/rv32i_soc.sv` | 最小 SoC wrapper，实例化 core、IMEM、DMEM、MMIO 数据子系统 |
| `rtl/soc/data_subsystem.sv` | 数据地址译码、DMEM/MMIO 选择、读数据 mux、access fault 生成 |
| `rtl/periph/mmio_uart.sv` | 最小 UART0 MMIO 寄存器块，当前写 TXDATA 时输出字符事件 |
| `rtl/periph/mmio_gpio.sv` | 最小 GPIO MMIO 寄存器块，保存 OUT/OE，读取 IN |

如果暂时不想新增 `rtl/soc` 目录，也可以把 `data_subsystem.sv` 放在 `rtl/mem`，但从工程边界看，SoC 目录更清楚。

### 7.2 需要修改的公共类型和常量

`rtl/common/core_pkg.sv` 建议新增：

| 常量 | 作用 |
|---|---|
| `MMIO_BASE/MMIO_SIZE_BYTES` | MMIO window 地址范围 |
| `GPIO_BASE/GPIO_SIZE_BYTES/GPIO_STRIDE/GPIO_NUM` | GPIO 实例窗口规划 |
| `TIMER_BASE/TIMER_SIZE_BYTES/TIMER_STRIDE/TIMER_NUM` | timer 实例窗口规划 |
| `UART_BASE/UART_SIZE_BYTES/UART_STRIDE/UART_NUM` | UART 实例窗口规划 |
| `ACCEL_BASE/ACCEL_SIZE_BYTES/ACCEL_STRIDE/ACCEL_NUM` | 后续 accelerator 控制寄存器窗口 |
| `GPIO0_BASE/GPIO0_SIZE_BYTES` | 当前实现的 GPIO0 寄存器窗口 |
| `UART0_BASE/UART0_SIZE_BYTES` | 当前实现的 UART0 寄存器窗口 |
| `TIMER0_BASE` | 预留给下一阶段 timer |
| `ACCEL0_BASE` | 预留给后续 accelerator |
| `EXCEPTION_CAUSE_LOAD_ACCESS_FAULT` | load 访问未映射或非法地址 |
| `EXCEPTION_CAUSE_STORE_ACCESS_FAULT` | store 访问未映射或非法地址 |

也可以考虑新增简单 helper 注释，说明某个地址是否落在 IMEM/DMEM/MMIO。RTL 里不一定要写 function，关键是不要在多个文件散落硬编码地址。

### 7.3 需要修改的现有模块

可能需要修改：

| 文件 | 修改方向 |
|---|---|
| `rtl/core/core.sv` | 新增数据访问错误输入并传给 `mem_stage` |
| `rtl/core/mem_stage.sv` | 合并 load/store access fault，输出对应 exception cause/tval |
| `rtl/mem/simple_ram.sv` | 保持 DMEM SRAM 行为；可补地址范围注释，不建议塞入 MMIO |
| `tb/sv/tb_core_pipeline5.sv` | 可保留 core-level TB；也可新增 SoC TB 来观察 UART/GPIO |

本阶段要求未映射地址进入 trap，因此 `core.sv` 和 `mem_stage.sv` 需要接收数据子系统给出的 access fault 信息。这样后续加入 timer、accelerator 或 ready/valid 时，不需要重新设计未映射访问的架构行为。

## 第8章 软件和链接规划

### 8.1 linker 是否需要大改

本步新增 MMIO window 后，普通 `.text/.data/.bss/stack` 仍然放在 IMEM/DMEM 中，因此 linker script 不一定需要大改。

需要同步的是：

- 文档中的地址图。
- C/ASM 使用的 MMIO base 常量。
- 如果 linker 暴露 platform symbol，可以新增 `__mmio_base`、`__uart0_base`、`__gpio0_base`。

当前 `c_baremetal.ld` 已经能支撑普通 C 程序。MMIO 驱动更适合通过 C header 暴露地址，而不是把外设寄存器放进 linker section。

### 8.2 C 侧建议新增 platform header

建议新增类似：

```text
sw/include/platform.h
sw/include/mmio.h
sw/include/uart.h
sw/include/gpio.h
```

第一版也可以合成一个简单头文件：

```c
#define MMIO_BASE      0x00080000u
#define GPIO0_BASE     0x00080000u
#define UART0_BASE     0x00082000u

static inline void mmio_write32(unsigned int addr, unsigned int value) {
    *(volatile unsigned int *)addr = value;
}

static inline unsigned int mmio_read32(unsigned int addr) {
    return *(volatile unsigned int *)addr;
}
```

关键点是使用 `volatile`，避免 C 编译器把 MMIO 访问优化掉或重排成不可观察的形式。

### 8.3 ASM 侧建议统一 `.equ`

手写汇编建议统一写：

```asm
.equ UART0_BASE,     0x00082000
.equ UART_TXDATA,    UART0_BASE + 0x00
.equ UART_STATUS,    UART0_BASE + 0x04

.equ GPIO0_BASE,     0x00080000
.equ GPIO_OUT,       GPIO0_BASE + 0x00
.equ GPIO_IN,        GPIO0_BASE + 0x04
.equ GPIO_OE,        GPIO0_BASE + 0x08
```

如果后续汇编测试变多，可以抽成公共 include 文件，避免每个 `.S` 都手写一遍地址。

### 8.4 PASS/FAIL 机制是否改到 MMIO

第一版不建议把所有测试的 PASS/FAIL 从 DMEM 改成 MMIO。

推荐保持：

- `DMEM_BASE + 0x100` 仍是统一 PASS/FAIL 状态字。
- UART/GPIO 作为额外可观察行为。
- MMIO 专项测试可以同时检查外设输出和最终 PASS。

这样不会破坏已有大量测试，也能让 MMIO 测试具备明确结束条件。

## 第9章 仿真和测试规划

### 9.1 testbench 观察点

加入 MMIO 后，testbench 应能观察：

| 观察点 | 作用 |
|---|---|
| UART TX 字符事件 | 打印软件输出字符串，例如 `Hello` |
| GPIO OUT/OE | 检查软件写寄存器是否生效 |
| MMIO load read data | 检查 `STATUS/IN` 等寄存器读值 |
| access fault trap | 检查未映射地址进入 trap |
| PASS/FAIL | 仍用 DMEM 状态字作为自动结束条件 |

UART 打印可以是简单 `$write("%c", tx_char)`；GPIO 可以在寄存器变化时 `$display`。

### 9.2 汇编测试建议

建议新增或规划：

| 测试 | 覆盖点 |
|---|---|
| `mmio_uart_smoke.S` | 写 UART TXDATA，testbench 看到字符 |
| `mmio_gpio_rw.S` | 写 GPIO OUT/OE，再读回检查 |
| `mmio_status_read.S` | 读 UART STATUS 固定 ready |
| `mmio_wrong_path_kill.S` | trap/branch wrong-path store 不能输出 UART |
| `mmio_unmapped_fault.S` | 未映射 load/store 进入 access fault trap |

### 9.3 C 测试建议

建议新增：

| 测试 | 覆盖点 |
|---|---|
| `c_mmio_uart_smoke.c` | C header + volatile store 能输出字符串 |
| `c_mmio_gpio_smoke.c` | C 读写 GPIO 寄存器 |
| `c_mmio_trap_fault.c` | C handler 检查 access fault 的 `mcause/mtval` |

C 测试的重点不是复杂算法，而是证明 C runtime、linker、MMIO header、volatile 访问和硬件外设寄存器能连起来。

### 9.4 directed test 比 UVM 更优先

本阶段建议继续以 directed test 为主。原因是 MMIO 地址、寄存器语义、trap/access fault 边界还在成型，先把功能路径跑通更重要。

等阶段2、3、4完成后，再把这些 directed test 的观察点沉淀成 UVM monitor、scoreboard 和 coverage，会更稳定。

## 第10章 完成标准

本步完成后，至少应满足：

| 项目 | 完成标准 |
|---|---|
| 地址图 | 文档、RTL 常量、软件 header/linker 说明一致 |
| 数据译码 | DMEM 地址仍正常访问 RAM，MMIO 地址进入外设 |
| UART TX | 软件写 UART TXDATA，testbench 能观察到字符 |
| GPIO | 软件能写 OUT/OE，读 IN 或读回 OUT/OE |
| 原有测试 | 不触发 MMIO 的 RV32I/CSR/trap 既有测试仍通过 |
| 副作用门控 | wrong-path 或 faulting MMIO store 不产生外设动作 |
| access fault | 未映射 load/store 能进入 trap，`mcause/mtval` 正确 |
| 文档 | `README`、simulation flow、linker/memory map 文档同步说明 MMIO window |

达到这些标准后，当前项目就从“带 CSR/trap 的裸 CPU core”推进到“有最小 SoC 地址空间的裸机平台”。这一步是后续 timer interrupt、外设驱动、accelerator 控制和 TPU/NPU 调度的基础。
