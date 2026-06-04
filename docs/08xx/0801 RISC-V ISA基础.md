# 0801 RISC-V(第五代精简指令集架构) ISA(指令集架构)基础

> 文档编号：0801  
> 所属部分：08 处理器架构、RISC-V(第五代精简指令集架构) 与 CPU(中央处理器) 微架构  
> 对应总纲小节：8.1 ISA、RISC-V 与微架构  
> 主题定位：从零系统理解 RISC-V ISA 的软件可见行为、基础整数指令、指令编码、寄存器约定、访存规则、扩展命名，以及它们如何影响 RTL(寄存器传输级) 解码、执行、验证和面试表达。  
> 目标岗位：数字 IC(集成电路) 设计、数字 IC 验证、SoC(片上系统) 前端、FPGA(现场可编程门阵列)/ASIC(专用集成电路) RTL、CPU 前端设计、处理器验证、嵌入式 SoC 相关岗位。  
> 前置知识：组合逻辑、时序逻辑、基础 SystemVerilog(系统 Verilog)、有限状态机、二进制补码、简单 ALU(算术逻辑单元)、load/store(加载/存储) 基本概念。

---

## 术语首次出现说明

本文档遵循“英文名词或缩写首次出现时给出中文名称”的规则。以下术语在后文会高频出现，后续再次出现时可直接使用英文或缩写。

| 英文术语 | 中文名称 | 英文术语 | 中文名称 | 英文术语 | 中文名称 |
|---|---|---|---|---|---|
| RISC-V | 第五代精简指令集架构 | ISA | 指令集架构 | RISC | 精简指令集计算机 |
| CPU | 中央处理器 | IC | 集成电路 | RTL | 寄存器传输级 |
| SoC | 片上系统 | FPGA | 现场可编程门阵列 | ASIC | 专用集成电路 |
| SystemVerilog | 系统 Verilog | Verilog | 硬件描述语言 Verilog | ALU | 算术逻辑单元 |
| RV32I/RV64I | 32 位/64 位基础整数指令集 | RV32E | 32 位嵌入式基础整数指令集 | XLEN | 通用寄存器宽度 |
| hart | 硬件线程 | PC | 程序计数器 | GPR | 通用寄存器 |
| ABI | 应用二进制接口 | register file | 寄存器堆 | x0 | 恒零寄存器 |
| zero/ra/sp/gp/tp | 零/返回地址/栈指针/全局指针/线程指针寄存器别名 | t0-t6 | 临时寄存器别名 | s0-s11 | 保存寄存器别名 |
| a0-a7 | 参数/返回值寄存器别名 | opcode | 操作码 | funct3/funct7 | 3 位/7 位功能码 |
| caller-saved | 调用者保存约定 | callee-saved | 被调用者保存约定 | frame pointer | 帧指针 |
| caller/callee | 调用者/被调用者 | temporary | 临时寄存器类别 | argument/saved | 参数/保存寄存器类别 |
| rd/rs1/rs2 | 目的/源 1/源 2 寄存器字段 | immediate | 立即数 | sign-extension | 符号扩展 |
| imm/offset | 立即数/偏移 | shamt | 移位量 | label | 标签 |
| zero-extension | 零扩展 | R-type | 寄存器型指令格式 | I-type | 立即数型指令格式 |
| S-type | 存储型指令格式 | B-type | 分支型指令格式 | U-type | 高位立即数型指令格式 |
| J-type | 跳转型指令格式 | instruction | 指令 | instruction word | 指令字 |
| fetch | 取指 | decode | 译码 | execute | 执行 |
| memory | 存储器/内存 | writeback | 写回 | pipeline | 流水线 |
| load/store | 加载/存储 | byte | 字节 | halfword | 半字 |
| word | 字 | doubleword | 双字 | signed/unsigned | 有符号/无符号 |
| little-endian | 小端序 | alignment | 对齐 | misaligned access | 非对齐访问 |
| LUI | 高位立即数加载指令 | AUIPC | 高位立即数加 PC 指令 | JAL/JALR | 跳转并链接/寄存器跳转并链接指令 |
| BEQ/BNE | 相等/不等分支指令 | BLT/BGE | 有符号小于/大于等于分支指令 | BLTU/BGEU | 无符号小于/大于等于分支指令 |
| ADD/SUB | 加法/减法指令 | SLT/SLTU | 有符号/无符号小于置位指令 | AND/OR/XOR | 按位与/或/异或指令 |
| SLL/SRL/SRA | 逻辑左移/逻辑右移/算术右移指令 | ADDI | 加立即数指令 | NOP | 空操作伪指令 |
| LB/LH/LW | 加载字节/半字/字指令 | LBU/LHU | 无符号加载字节/半字指令 | SB/SH/SW | 存储字节/半字/字指令 |
| LD/SD | 64 位加载/存储双字指令 | FENCE | 访存顺序屏障指令 | ECALL/EBREAK | 环境调用/断点指令 |
| CSR | 控制状态寄存器 | Zicsr | CSR 指令扩展 | Zifencei | 指令缓存同步屏障扩展 |
| M extension | 乘除法扩展 | A extension | 原子操作扩展 | C extension | 压缩指令扩展 |
| F/D extension | 单精度/双精度浮点扩展 | V extension | 向量扩展 | custom extension | 自定义扩展 |
| privilege | 特权级 | M/S/U mode | 机器/监管/用户特权级 | trap | 陷入 |
| exception | 异常 | interrupt | 中断 | precise exception | 精确异常 |
| illegal instruction | 非法指令异常 | reset vector | 复位入口地址 | boot | 启动 |
| memory map | 地址映射 | MMIO | 内存映射输入输出 | device memory | 设备内存 |
| compiler | 编译器 | assembler | 汇编器 | linker | 链接器 |
| disassembler | 反汇编器 | ELF | 可执行与可链接格式 | GNU/LLVM | 常见开源编译工具链 |
| PC redirect | 程序计数器重定向 | wrong-path instruction | 错误路径指令 | kill/flush | 杀除/冲刷 |
| ISS | 指令集模拟器 | reference model | 参考模型 | compliance test | 兼容性测试 |
| directed test | 定向测试 | random test | 随机测试 | coverage | 覆盖率 |
| scoreboard | 记分板 | SVA | SystemVerilog 断言 | UVM | 通用验证方法学 |
| DUT | 待测设计 | testbench | 测试平台 | bug | 缺陷 |
| debug | 调试 | trade-off | 权衡 | PPA | 性能、功耗、面积 |
| STA | 静态时序分析 | decode table | 译码表 | control signal | 控制信号 |
| datapath | 数据通路 | immediate generator | 立即数生成器 | branch comparator | 分支比较器 |
| LSU | 加载存储单元 | write enable | 写使能 | exception priority | 异常优先级 |
| MCU | 微控制器 | Linux | Linux 操作系统 | toolchain | 工具链 |
| overflow exception | 溢出异常 | instruction address misaligned | 指令地址非对齐异常 | instruction access fault | 指令访问错误异常 |
| access fault | 访问错误异常 | load/store address misaligned | 加载/存储地址非对齐异常 | memory transaction | 存储事务 |
| byte lane | 字节通道 | write mask | 写掩码 | write data | 写数据 |
| seed | 随机种子 | self-checking | 自检查 | PC trace | 程序计数器跟踪 |
| cache | 缓存 | cacheable | 可缓存属性 | store buffer | 存储缓冲 |
| bus | 总线 | bus beat | 总线传输拍 | memory side effect | 存储副作用 |
| instruction memory | 指令存储器 | data memory | 数据存储器 | I-cache | 指令缓存 |
| D-cache | 数据缓存 | Harvard architecture | 哈佛结构 | von Neumann architecture | 冯诺依曼结构 |
| RAM | 随机存取存储器 | ROM | 只读存储器 | SRAM | 静态随机存取存储器 |
| DRAM | 动态随机存取存储器 | OS | 操作系统 | driver | 驱动程序 |
| flash | 闪存 | NOR flash | 或非型闪存 | NAND flash | 与非型闪存 |
| non-volatile storage | 非易失存储 | volatile memory | 易失存储 | persistent storage | 持久化存储 |
| firmware | 固件 | bootloader | 启动加载程序 | boot code | 启动代码 |
| OTA | 空中升级 | RTOS | 实时操作系统 | app | 应用程序 |
| kernel | 内核 | file system | 文件系统 | executable image | 可执行镜像 |
| eMMC | 嵌入式多媒体卡 | UFS | 通用闪存存储 | SSD | 固态硬盘 |
| storage controller | 存储控制器 | block device | 块设备 | memory-mapped | 内存映射 |
| DMA | 直接存储器访问 | program image | 程序镜像 | boot ROM | 启动只读存储器 |
| XIP | 片上执行/就地执行 | block/page | 块/页 | A/B slot | A/B 启动槽 |

---

## 第0章 本专题学习地图

### 0.0 为什么先学 ISA

处理器项目里经常听到“五级流水线”“旁路”“分支预测”“cache”“中断异常”，但这些都属于微架构实现。微架构再复杂，也必须服从 ISA 定义的软件可见行为。

ISA 回答的是：

- 指令长什么样。
- 有哪些寄存器。
- 每条指令读哪些寄存器、写哪个寄存器。
- 立即数如何编码和扩展。
- load/store 如何访问内存。
- 分支和跳转如何改变 PC。
- 哪些行为会触发 exception 或 trap。
- 软件、编译器和硬件之间遵守哪些约定。

如果 ISA 没学清楚，后面做 RTL 会出现很典型的问题：

- 指令字段切错。
- B-type/J-type 立即数拼错。
- signed 和 unsigned 比较混用。
- load 的符号扩展处理错。
- x0 被错误写入。
- JALR 目标地址最低位未清零。
- store byte 的写掩码生成错。
- 分支目标 PC 加错基准。
- 指令未实现时没有给出 illegal instruction。

本篇目标不是背完整规范，而是建立面试和工程实现所需的最小完整模型：看得懂 RISC-V 基础整数指令，能解释指令格式，能写出基础译码思路，能说明 ISA 和微架构的边界。

### 0.1 小节划分与关系

本篇按以下顺序展开：

1. 第1章讲 ISA、RISC-V 和微架构的边界。
2. 第2章讲 RISC-V 的基本设计思想和命名方式。
3. 第3章讲软件可见状态：XLEN、PC、hart、GPR、x0 和 ABI。
4. 第4章讲 32 位指令格式和字段。
5. 第5章讲立即数编码，这是 RISC-V ISA 最容易在 RTL 中写错的地方之一。
6. 第6章讲 RV32I/RV64I 基础整数指令。
7. 第7章先从实际系统出发，建立程序、用户数据、ROM、RAM、flash、GPR 和 storage controller 的直觉地图。
8. 第8章讲访存、对齐、小端序、MMIO 和 FENCE。
9. 第9章讲扩展体系和兼容性边界。
10. 第10章讲如何把 ISA 落成 RTL 解码、控制信号和数据通路。
11. 第11章讲验证方法。
12. 第12章整理常见 bug 和 debug 思路。
13. 第13章给出面试问法、练习题和答案要点。
14. 第14章讲本篇与其他章节的关联。
15. 第15章总结本篇主线。

### 0.2 本篇与后续文档的关系

- `0802 RISC-V五级流水线与Hazard.md` 会把本篇的取指、译码、执行、访存、写回行为放进五级流水线，重点讲 RAW、load-use、forwarding、stall、flush。
- `0803 CSR、异常中断与特权级.md` 应继续讲 CSR、trap、exception、interrupt、M/S/U mode。
- `0804 RISC-V SoC、MMIO与外设互联.md` 应继续讲 memory map、boot ROM、SRAM、flash、storage controller、总线、PLIC、CLINT、timer 和外设寄存器。
- `0805 Cache、TLB、MMU、分支预测与内存模型.md` 应继续讲存储层次、cache、DRAM 访问、地址转换、分支预测和更高性能微架构。
- `0401` 之后的快速运算文档可支撑 M extension 的乘除法实现。
- `100x` 验证文档可支撑处理器的指令级随机验证、scoreboard 和 coverage。

---

## 第1章 ISA、RISC-V 与微架构边界

### 1.0 本章概述

处理器相关面试最常见的第一问是：

```text
ISA 和微架构有什么区别？
```

这不是概念题，而是判断候选人是否理解“软件可见规范”和“硬件实现方案”的分界。ISA 是合同，微架构是履约方式。

### 1.1 ISA 是什么

ISA 是处理器对软件暴露的抽象机器。它规定软件能依赖什么，硬件必须保证什么。

典型内容包括：

| 类别 | ISA 规定什么 | 例子 |
|---|---|---|
| 寄存器 | 有哪些软件可见寄存器、宽度是多少 | x0 到 x31，PC，部分 CSR |
| 指令编码 | 每条指令的位字段含义 | opcode、rd、rs1、rs2、funct3、funct7 |
| 指令语义 | 指令执行后寄存器和内存如何变化 | ADD 写 rd，BEQ 满足条件时跳转 |
| 访存模型 | load/store 宽度、对齐、顺序约束 | LB/LH/LW/SB/SH/SW，FENCE |
| 异常中断 | 哪些事件需要 trap | illegal instruction、ECALL、外部中断 |
| 特权架构 | 不同权限的软件能访问什么 | M mode、S mode、U mode |

换句话说，只要软件看到的结果完全符合 ISA，同一套程序就能在不同实现上运行。

### 1.2 微架构是什么

微架构是实现 ISA 的硬件组织方式。它通常不直接暴露给普通软件。

微架构可以选择：

- 单周期、多周期或 pipeline。
- 五级、七级、十几级流水线。
- 顺序执行或乱序执行。
- 是否有 forwarding。
- 是否有 branch prediction。
- cache 是几路组相联。
- ALU 有几个。
- load/store 是否乱序。
- M extension 是单周期乘法、流水乘法还是迭代乘除法。

这些实现只要不改变 ISA 可见行为，都可以不同。

例如，下面两种 CPU 都可能实现 RV32I：

| 实现 | 微架构特点 | 软件可见行为 |
|---|---|---|
| 简单微控制器核 | 多周期、无 cache、无分支预测 | 符合 RV32I |
| 高性能应用核 | 多发射、乱序、分支预测、L1/L2 cache | 仍符合 RV32I/RV64I |

### 1.3 面试中如何回答边界

简洁回答：

```text
ISA 是软件可见的指令集规范，规定寄存器、指令编码、指令语义、异常中断和内存访问规则。
微架构是实现 ISA 的具体硬件结构，比如流水线级数、旁路网络、分支预测、cache 和执行单元。
同一个 ISA 可以有不同微架构，只要最终对软件呈现的行为一致。
```

深入追问版本：

```text
例如 RISC-V 的 ADD 指令规定 rd = rs1 + rs2，x0 恒为 0，这是 ISA 语义。
至于 ADD 在单周期核里一个周期完成，还是在五级流水线 EX 阶段完成，是否经过 forwarding，
是否由乱序调度发射到某个 ALU，这些都是微架构选择。
验证时 ISA 级 reference model 检查提交结果，微架构验证还要检查 stall、flush、异常优先级和流水线状态。
```

---

## 第2章 RISC-V 的设计思想与命名

### 2.0 本章概述

RISC-V 是一种开放 ISA。它的基础整数指令集较小，扩展模块化，编码规则相对规整，适合作为教学、开源 SoC 和自研 CPU 项目的入门对象。

### 2.1 RISC-V 的几个核心特点

RISC-V 的基础设计思想可以概括为：

- load/store 架构：只有 load/store 访问 memory，普通算术逻辑指令只操作 register。
- 固定基础指令长度：基础指令通常是 32 bit，便于取指和译码。
- 规整寄存器字段：多数格式中 rd、rs1、rs2 位置固定，降低译码复杂度。
- x0 恒为 0：很多伪指令和比较、清零操作可以复用基础指令。
- 模块化扩展：基础整数指令集之外，用 M/A/C/F/D/V 等扩展增加能力。
- 可自定义扩展：为专用加速和教学实验保留 custom extension 空间。

### 2.2 RV32I、RV64I 和 XLEN

RV32I 和 RV64I 的核心差别是 XLEN：

| 名称 | XLEN | 通用寄存器宽度 | 典型用途 |
|---|---:|---:|---|
| RV32I | 32 bit | 32 bit | MCU、教学、小型嵌入式核 |
| RV64I | 64 bit | 64 bit | Linux 级 SoC、应用处理器、服务器方向 |
| RV32E | 32 bit | 32 bit，但寄存器数量减少 | 极小面积嵌入式核 |

XLEN 影响：

- GPR 宽度。
- 地址计算宽度。
- 算术结果截断宽度。
- load 的扩展宽度。
- 部分指令是否存在，例如 RV64I 有 LD/SD 和 word 操作类指令。

面试里如果题目没有特别说明，校招手撕和教学项目通常默认 RV32I。

### 2.3 基础指令集和扩展的关系

常见 RISC-V 命名类似：

```text
RV32IMAC
RV64GC
```

含义示例：

| 组成 | 含义 |
|---|---|
| RV32 | 32 位 XLEN |
| RV64 | 64 位 XLEN |
| I | 基础整数指令集 |
| M | 乘除法扩展 |
| A | 原子操作扩展 |
| C | 压缩指令扩展 |
| F | 单精度浮点扩展 |
| D | 双精度浮点扩展 |
| G | 常用通用扩展集合，通常包含 I、M、A、F、D、Zicsr、Zifencei |

对前端 RTL 岗位来说，最应该先掌握的是 RV32I。因为它包含处理器最核心的译码、寄存器堆、ALU、分支、访存和异常入口问题。

### 2.4 为什么 RISC-V 适合面试

RISC-V 面试价值高，不是因为每个岗位都要做 CPU，而是因为它把很多数字 IC 基础问题集中到一个可讨论对象里：

- 指令译码考组合逻辑和编码规则。
- 五级流水线考时序逻辑和控制。
- hazard (冒险)考数据依赖和时序。
- branch flush (分支冲刷)考控制优先级。
- load/store 考字节使能、对齐、符号扩展。
- CSR (控制状态寄存器)和 interrupt 考状态机和优先级。
- cache (高速缓存)和 MMIO (内存映射 I/O)考系统架构。
- 指令随机验证考 reference model (参考模型)和 scoreboard(记分牌)。

---

## 第3章 软件可见状态：hart、PC、GPR、x0 与 ABI

### 3.0 本章概述

软件运行在处理器上，本质上是在不断改变一组软件可见状态。理解这些状态，是理解指令语义的基础。

### 3.1 hart (硬件线程)

RISC-V 用 hart 表示一个独立执行指令流的硬件线程。一个单核简单处理器通常只有一个 hart。多核或支持硬件多线程的处理器可能有多个 hart。

从 ISA 角度看，每个 hart 至少有：

- 自己的 PC。
- 自己的 GPR。
- 自己的一组必要 CSR。
- 独立的 trap 状态。

面试中普通五级流水线项目通常只实现单 hart，不需要深入硬件多线程。

### 3.2 PC

PC 保存当前取指地址。基础 RV32I 中，如果没有 C extension，指令按 4 byte 对齐，正常顺序执行时：

$$
next\_pc = pc + 4
$$

但以下指令或事件会改变 next_pc：

- branch (分支)成立时跳到分支目标。
- JAL 跳到 PC 相对目标。
- JALR 跳到寄存器相对目标。
- trap 进入 trap handler (异常处理函数)。
- trap 返回恢复到异常返回地址。
- reset 后进入 reset vector (复位向量)。

PC 是处理器控制流的中心。后续学习五级流水线时，IF 阶段的主要任务就是根据当前 PC 取 instruction，并决定下一拍 PC 更新为多少。

### 3.3 GPR 与 x0

RV32I/RV64I 定义 32 个整数 GPR：

```text
x0, x1, ..., x31
```

其中 x0 特殊：

- 读 x0 永远得到 0。
- 写 x0 必须被丢弃。
- x0 不需要真实存储，也可以在 register file 读端特殊处理。

x0 的工程价值：

- `ADDI x0, x0, 0` 可作为 NOP。
- `ADD rd, rs, x0` 可实现寄存器复制。
- `ADDI rd, x0, imm` 可实现加载小立即数。
- `BEQ rs, x0, label` 可实现和 0 比较。

RTL 里必须保证：

```systemverilog
// 写回端：rd 是 x0 时，禁止写寄存器堆
  if (wb_en && (rd != 5'd0)) begin
      gpr[rd] <= wb_data;
  end

// 读端：rs1/rs2 是 x0 时，直接返回 0
  assign rs1_data = (rs1 == 5'd0) ? 32'b0 : gpr[rs1];
  assign rs2_data = (rs2 == 5'd0) ? 32'b0 : gpr[rs2];
```

否则软件会出现极其隐蔽的错误。

### 3.4 ABI (应用二进制接口)寄存器别名

ISA 定义寄存器编号，ABI 定义软件调用约定中这些寄存器的使用习惯。

| 寄存器 | ABI 名称 | 常见用途 | 具体说明 |
|---|---|---|---|
| x0 | zero | 常数 0 | ISA 规定读出恒为 0，写入无效。常用于 `ADDI rd, x0, imm` 产生小立即数、`BEQ rs, x0, label` 和 0 比较、`ADD rd, rs, x0` 复制寄存器、`ADDI x0, x0, 0` 表示 NOP。 |
| x1 | ra | 返回地址 | `JAL x1, func` 或伪指令 `call func` 会把下一条指令地址写入 `ra`，函数结束时常用 `JALR x0, 0(x1)` 或伪指令 `ret` 跳回调用点。非叶子函数如果还要继续调用其他函数，通常需要先把 `ra` 保存到栈上。 |
| x2 | sp | 栈指针 | 指向当前栈帧位置，函数入口常用 `ADDI sp, sp, -frame_size` 分配栈帧，函数返回前用 `ADDI sp, sp, frame_size` 释放栈帧。局部变量、溢出的参数、保存的 `ra` 和 `s` 寄存器通常放在 `sp` 相对偏移位置。 |
| x3 | gp | 全局指针 | 指向全局数据区附近，编译器可用它生成较短的全局变量访问序列，例如通过 `gp` 相对寻址访问小数据段。硬件不特殊处理 `gp`，它是链接器、启动代码和 ABI 共同维护的软件约定。 |
| x4 | tp | 线程指针 | 指向线程局部存储区域，操作系统或运行时为每个线程设置不同的 `tp`。访问 thread-local storage 时，编译器会生成基于 `tp` 的地址计算。普通裸机程序可能很少显式使用它。 |
| x5-x7 | t0-t2 | 临时寄存器 | 调用者保存寄存器，函数调用后允许被被调函数改写。编译器常把短生命周期中间值、地址计算结果、临时 ALU 结果放在这些寄存器里；调用函数前如果调用者还需要其中的值，需要自己保存。 |
| x8-x9 | s0-s1 | 被调用者保存寄存器 | 被调函数如果使用这些寄存器，必须在入口保存、返回前恢复。`s0` 也常作为 frame pointer，用来在栈帧大小变化或调试回溯时稳定访问局部变量和保存区。 |
| x10-x17 | a0-a7 | 参数和返回值 | 函数调用时前 8 个整数/指针参数通常放在 `a0-a7`，返回值通常放在 `a0`，较宽或双返回值可能使用 `a0-a1`。系统调用约定中也常用 `a7` 放 syscall number，`a0-a5` 放参数。 |
| x18-x27 | s2-s11 | 被调用者保存寄存器 | 适合保存跨函数调用仍然需要保留的变量，例如循环外层状态、长期使用的指针、函数内多次调用之间不希望被破坏的数据。使用代价是函数入口/出口需要保存和恢复。 |
| x28-x31 | t3-t6 | 临时寄存器 | 与 `t0-t2` 类似，也是调用者保存寄存器，常用于表达式求值、地址生成、复杂指令序列展开或编译器寄存器分配压力较大时的额外临时值。 |

这里最容易困惑的是：为什么 `t`、`s`、`a` 不按功能连续排列，而是被拆成了 `t0-t2`、`s0-s1`、`a0-a7`、`s2-s11`、`t3-t6` 这种形状。原因是 ABI 不是在给硬件寄存器堆重新分区，而是在给函数调用约定分配责任。

函数调用前后，寄存器值是否需要保持不变，决定了它属于哪一类：

| 类别 | ABI 名称 | 调用返回后是否保证不变 | 谁负责保存 | 典型适用场景 |
|---|---|---|---|---|
| temporary | `t0-t6` | 不保证 | 调用者 caller | 短生命周期中间值、地址计算、表达式临时结果 |
| argument | `a0-a7` | 不保证 | 调用者 caller | 函数入口参数、函数返回值、系统调用参数 |
| saved | `s0-s11` | 保证不变 | 被调用者 callee | 跨函数调用仍要保留的变量、长期使用的指针、循环状态 |

考虑一段 C 代码：

```c
int f(int x) {
    int y = x + 1;
    int z = g(x);
    return y + z;
}
```

如果编译器把 `y` 放在 `t0`，那么执行 `g(x)` 之后，`t0` 可能已经被 `g` 改写。因为 `t0` 是 caller-saved(调用者保存) 寄存器，调用者 `f` 如果还需要 `y`，就要在调用 `g` 之前自己把它保存到栈上或搬到别的安全位置。

如果编译器把 `y` 放在 `s0`，则 `g` 返回后 `s0` 必须仍然保持调用前的值。因为 `s0` 是 callee-saved(被调用者保存) 寄存器，任何被调用函数只要使用了 `s0`，就必须在函数入口保存、函数返回前恢复。这个约定让调用者更轻松，但会增加被调用函数的函数序言和尾声开销。

所以 `t` 和 `s` 的区别不是“一个更快、一个更慢”，也不是“硬件通路不同”，而是谁承担保存代价：

- 临时值生命周期很短，函数调用后不再需要，适合放在 `t` 或 `a`。
- 一个值跨越函数调用还要继续使用，适合放在 `s`。
- 如果使用 `s` 寄存器，被调用函数需要承担保存/恢复开销；如果使用 `t` 寄存器，调用者需要在必要时自己保存。

至于为什么 `a0-a7` 插在 `s0-s1` 和 `s2-s11` 中间，一个重要原因是 RISC-V 要兼顾压缩指令 C extension(压缩指令扩展) 的编码效率。很多 16 位压缩指令只能高效访问一个较小的寄存器窗口，常见窗口是 `x8-x15`：

```text
x8   = s0 / fp
x9   = s1
x10  = a0
x11  = a1
x12  = a2
x13  = a3
x14  = a4
x15  = a5
```

这组寄存器覆盖了非常高频的软件对象：`s0/fp` 可作为 frame pointer(帧指针)，`a0-a1` 常用于返回值和前两个参数，`a0-a5` 覆盖多数短参数函数，`s1` 提供一个常用的被调用者保存寄存器。把它们放进压缩指令容易编码的窗口里，可以提高代码密度。

因此 ABI 编号看起来像是把 `t`、`s`、`a` 打散了，本质上是对函数调用约定、常用寄存器频率、压缩指令编码空间和历史/工具链习惯的折中。硬件执行 `ADD x10, x11, x12` 时只看寄存器编号和读写端口，并不知道 `x10` 叫 `a0`；这些语义主要由编译器、汇编器、链接器、操作系统和运行时遵守。

对硬件来说，除了 x0 之外，x1、x2、x3、x4 以及其他 ABI 别名都没有特殊加法器或特殊寄存器。`ra`、`sp`、`gp`、`tp` 的“特殊性”来自编译器、汇编器、链接器、操作系统和运行时约定，而不是来自寄存器堆硬件。硬件必须特殊处理的主要是 x0。

### 3.5 面试常见追问

问题：x0 有什么用？

简洁回答：

```text
x0 读出恒为 0，写入无效。它可以简化指令集，让清零、移动、和 0 比较、NOP 等操作复用已有指令。
```

深入回答：

```text
硬件实现时 x0 可以不占真实寄存器，读端检测 rs 是否为 0 并返回 0，写端检测 rd 是否为 0 并屏蔽写使能。
验证时要覆盖所有写 x0 的指令，确保后续读 x0 仍为 0。
```

### 3.6 ISA 状态、微架构状态与 commit 视角

软件可见状态这一章容易被讲成“PC 加 32 个寄存器”的清单，但工程上更重要的是分清：哪些状态属于 ISA 合同，哪些状态只是硬件为了跑得更快而临时维护的内部状态。

ISA 状态是软件和 reference model 能观察到的状态。只要这些状态在每条指令提交后的结果一致，软件就认为处理器正确。微架构状态则是实现手段，例如流水线寄存器、forwarding 选择、cache tag、branch predictor 表项，它们可以在不同 CPU 中完全不同。

| 状态类别 | 例子 | 软件是否直接依赖 | 验证关注点 |
|---|---|---|---|
| ISA 架构状态 | PC、GPR、部分 CSR、memory 可见内容 | 是 | commit 后必须和 reference model 一致 |
| 控制流架构状态 | next PC、trap 返回地址、异常原因 | 是 | branch/jump/trap 后 PC 序列正确 |
| 微架构临时状态 | IF/ID、ID/EX、EX/MEM、MEM/WB pipeline register | 否 | stall/flush 后不能产生错误提交 |
| 性能结构状态 | cache、BTB、BHT、TLB、store buffer | 通常否 | 命中/未命中、预测/恢复不能改变 ISA 结果 |
| debug/trace 状态 | commit trace、性能计数器 | 取决于实现 | 不能反向污染执行语义 |

这也是为什么处理器验证常以 commit 为边界。以顺序五级流水线为例，一条指令在内部可能经历取指、译码、执行、访存和写回；但 scoreboard 不需要逐拍强制内部状态和 ISS 一样，它只需要在指令 commit 时比较：

```text
commit_pc
commit_inst
commit_rd / commit_wdata
commit_mem_addr / commit_mem_wdata / commit_mem_rdata
commit_exception
commit_next_pc
```

如果第一条 commit mismatch 发生在某条 `BEQ`，debug 的方向通常不是先怀疑 register file，而是沿着这条指令向前看：立即数是否拼对、比较类型是否正确、branch target 是否使用当前 `pc`、flush 是否杀掉了错路径写回。

这也解释了一个初学流水线时很常见的困惑：如果一条 branch 或 JALR 到 EX 甚至更晚才算出真实 next PC，那它后面的顺序指令不是已经被 IF 取出来了吗？答案是：取出来不等于已经被 ISA 接受执行。那些指令在微架构内部可以进入 IF/ID，甚至继续流到某些前级，但只要真实控制流发现它们不该执行，硬件就必须对它们做 kill/flush(杀除/冲刷)，并通过 valid/kill 信号禁止它们产生任何架构副作用。

例如默认按 `pc + 4` 取指时，`BEQ` 在 EX 阶段才发现 taken：

```text
cycle:       1    2    3
BEQ I0:      IF   ID   EX(taken, redirect)
I1=pc+4:          IF   ID(killed)
I2=pc+8:               IF(killed)
```

从微架构视角看，`I1` 和 `I2` 确实被取过，可能还被部分译码过；从 ISA 视角看，它们不是已执行指令，因为它们没有 commit，也不能写 GPR、写 memory、更新 CSR 或触发可见 trap。处理器需要在 branch resolution 后发出 PC redirect(程序计数器重定向)，把 PC 改到 branch target，同时清掉这些 wrong-path instruction(错误路径指令)。这正是 `0802` 中 control hazard、flush 和 valid side-effect gating 要解决的问题。

从 RTL 设计角度看，软件可见状态还决定了副作用的门控边界。无论内部流水线怎么流动，写 GPR、写 memory、更新 CSR、进入 trap 都必须绑定到“有效且未被 kill 的指令”。这条原则会在 `0802` 的 valid、stall、flush 中继续展开。

---

## 第4章 指令格式与字段

### 4.0 本章概述

RISC-V 基础指令通常是 32 bit。指令格式看起来多，但核心字段位置尽量保持一致，方便硬件译码。

### 4.1 基础字段

一条 32 bit instruction word 常见字段如下：

| 字段 | 位宽 | 位置 | 含义 |
|---|---:|---|---|
| opcode | 7 | `[6:0]` | 主操作码 |
| rd | 5 | `[11:7]` | 目的寄存器 |
| funct3 | 3 | `[14:12]` | 次级功能码 |
| rs1 | 5 | `[19:15]` | 源寄存器 1 |
| rs2 | 5 | `[24:20]` | 源寄存器 2 |
| funct7 | 7 | `[31:25]` | 扩展功能码 |

很多格式保持 rd、rs1、rs2 位置不变，是为了让 register file 地址译码更直接。

### 4.2 六种基础格式

#### 4.2.1 R-type

R-type 用于寄存器-寄存器运算。

```text
31      25 24   20 19   15 14  12 11    7 6      0
+----------+-------+-------+------+-------+--------+
| funct7   | rs2   | rs1   |funct3| rd    | opcode |
+----------+-------+-------+------+-------+--------+
```

典型汇编形式：

| 指令 | 汇编形式 | 简要作用 | 从格式看出的操作数关系 |
|---|---|---|---|
| ADD | `ADD rd, rs1, rs2` | 加法 | 两个源寄存器，一个目的寄存器 |
| SUB | `SUB rd, rs1, rs2` | 减法 | 两个源寄存器，一个目的寄存器 |
| AND | `AND rd, rs1, rs2` | 按位与 | 两个源寄存器，一个目的寄存器 |
| OR | `OR rd, rs1, rs2` | 按位或 | 两个源寄存器，一个目的寄存器 |
| XOR | `XOR rd, rs1, rs2` | 按位异或 | 两个源寄存器，一个目的寄存器 |
| SLL | `SLL rd, rs1, rs2` | 逻辑左移 | 移位量来自 `rs2` |
| SRL | `SRL rd, rs1, rs2` | 逻辑右移 | 移位量来自 `rs2` |
| SRA | `SRA rd, rs1, rs2` | 算术右移 | 移位量来自 `rs2` |
| SLT | `SLT rd, rs1, rs2` | 有符号小于置位 | 比较两个源寄存器，结果写 `rd` |
| SLTU | `SLTU rd, rs1, rs2` | 无符号小于置位 | 比较两个源寄存器，结果写 `rd` |

#### 4.2.2 I-type

I-type 用于立即数运算、load、JALR、部分 system 指令。

```text
31                  20 19   15 14  12 11    7 6      0
+---------------------+-------+------+-------+--------+
| imm[11:0]           | rs1   |funct3| rd    | opcode |
+---------------------+-------+------+-------+--------+
```

典型汇编形式：

| 指令 | 汇编形式 | 简要作用 | 从格式看出的操作数关系 |
|---|---|---|---|
| ADDI | `ADDI rd, rs1, imm` | 加立即数 | 一个源寄存器加一个立即数 |
| ANDI | `ANDI rd, rs1, imm` | 按位与立即数 | 一个源寄存器加一个立即数 |
| ORI | `ORI rd, rs1, imm` | 按位或立即数 | 一个源寄存器加一个立即数 |
| XORI | `XORI rd, rs1, imm` | 按位异或立即数 | 一个源寄存器加一个立即数 |
| SLTI | `SLTI rd, rs1, imm` | 有符号小于立即数置位 | 一个源寄存器和立即数比较 |
| SLTIU | `SLTIU rd, rs1, imm` | 无符号小于立即数置位 | 一个源寄存器和立即数比较 |
| SLLI | `SLLI rd, rs1, shamt` | 逻辑左移立即数 | 移位量来自立即数字段 |
| SRLI/SRAI | `SRLI rd, rs1, shamt` / `SRAI rd, rs1, shamt` | 逻辑/算术右移立即数 | 移位量来自立即数字段 |
| LB/LH/LW/LBU/LHU | `LW rd, offset(rs1)` | 从内存加载数据 | 地址基址来自 `rs1`，偏移来自立即数字段 |
| JALR | `JALR rd, offset(rs1)` | 寄存器间接跳转并保存返回地址 | 跳转基址来自 `rs1`，返回地址写 `rd` |
| ECALL/EBREAK | `ECALL` / `EBREAK` | 环境调用/断点 | 编码属于 I-type，但不使用通用寄存器操作数 |

#### 4.2.3 S-type

S-type 用于 store。它没有 rd，因为 store 写 memory，不写 GPR。

```text
31      25 24   20 19   15 14  12 11    7 6      0
+----------+-------+-------+------+-------+--------+
| imm[11:5]| rs2   | rs1   |funct3|imm[4:0]| opcode|
+----------+-------+-------+------+-------+--------+
```

典型汇编形式：

| 指令 | 汇编形式 | 简要作用 | 从格式看出的操作数关系 |
|---|---|---|---|
| SB | `SB rs2, offset(rs1)` | 存储 byte | `rs2` 是写入数据，`rs1 + offset` 是地址 |
| SH | `SH rs2, offset(rs1)` | 存储 halfword | `rs2` 是写入数据，`rs1 + offset` 是地址 |
| SW | `SW rs2, offset(rs1)` | 存储 word | `rs2` 是写入数据，`rs1 + offset` 是地址 |
| SD | `SD rs2, offset(rs1)` | 存储 doubleword | RV64I store doubleword，仍然没有 `rd` |

#### 4.2.4 B-type

B-type 用于条件分支。它不写 rd，立即数表示 PC 相对偏移。

```text
31 30    25 24   20 19   15 14  12 11  8 7 6      0
+--+--------+-------+-------+------+-----+-+--------+
|i12|imm10:5| rs2   | rs1   |funct3|imm4:1|i11|opcode|
+--+--------+-------+-------+------+-----+-+--------+
```

注意 B-type 立即数最低位隐含为 0，表示至少 2 byte 对齐的跳转偏移。

典型汇编形式：

| 指令 | 汇编形式 | 简要作用 | 从格式看出的操作数关系 |
|---|---|---|---|
| BEQ | `BEQ rs1, rs2, label` | 相等则分支跳转 | 比较两个源寄存器，`label` 会被汇编成 PC 相对 offset |
| BNE | `BNE rs1, rs2, label` | 不相等则分支跳转 | 比较两个源寄存器，`label` 会被汇编成 PC 相对 offset |
| BLT | `BLT rs1, rs2, label` | 有符号小于则分支跳转 | 比较两个源寄存器，`label` 会被汇编成 PC 相对 offset |
| BGE | `BGE rs1, rs2, label` | 有符号大于等于则分支跳转 | 比较两个源寄存器，`label` 会被汇编成 PC 相对 offset |
| BLTU | `BLTU rs1, rs2, label` | 无符号小于则分支跳转 | 比较两个源寄存器，`label` 会被汇编成 PC 相对 offset |
| BGEU | `BGEU rs1, rs2, label` | 无符号大于等于则分支跳转 | 比较两个源寄存器，`label` 会被汇编成 PC 相对 offset |

注意：load/store/JALR 中的 `offset(rs1)` 是“以 `rs1` 为基址的地址偏移”；B-type/J-type 中的 `label` 是控制流目标，汇编器会把它转换成 PC-relative offset。

#### 4.2.5 U-type

U-type 用于构造高 20 位立即数。

```text
31                              12 11    7 6      0
+---------------------------------+-------+--------+
| imm[31:12]                      | rd    | opcode |
+---------------------------------+-------+--------+
```

典型汇编形式：

| 指令 | 汇编形式 | 简要作用 | 从格式看出的操作数关系 |
|---|---|---|---|
| LUI | `LUI rd, imm` | 构造高位立即数 | 只有目的寄存器和高位立即数 |
| AUIPC | `AUIPC rd, imm` | 构造 PC 相对地址的一部分 | 只有目的寄存器和 PC 相对高位立即数 |

#### 4.2.6 J-type

J-type 用于 JAL。它写返回地址到 rd，并跳到 PC 相对目标。

```text
31 30          21 20 19      12 11    7 6      0
+--+-------------+--+----------+-------+--------+
|i20| imm[10:1]  |i11|imm[19:12]| rd    | opcode |
+--+-------------+--+----------+-------+--------+
```

J-type 立即数最低位也隐含为 0。

典型汇编形式：

| 指令 | 汇编形式 | 简要作用 | 从格式看出的操作数关系 |
|---|---|---|---|
| JAL | `JAL rd, label` | 无条件跳转并保存返回地址 | `label` 会被汇编成 PC 相对 offset，返回地址写 `rd` |

### 4.3 为什么立即数字段看起来不连续

RISC-V 的 B-type 和 J-type 立即数不是按自然顺序放在指令中，这常被问到。

可以从硬件角度回答：RISC-V 优先让寄存器字段稳定，再接受 immediate generator 稍微复杂一些。原因是寄存器字段会直接进入 register file 读地址，处在 ID 阶段早期关键路径上；立即数拼接虽然也重要，但通常只是若干 bit 的重排、补零和符号扩展，更容易做成局部组合逻辑。

| 设计选择 | 解决什么问题 | 硬件收益 | RTL/验证风险 |
|---|---|---|---|
| `rd`、`rs1`、`rs2` 位置尽量固定 | decode 后尽快读 register file | 读地址切片直接、ID 路径规整 | 对某些格式误以为都有 `rs2`，导致假 hazard |
| `opcode` 固定在低 7 位 | 快速判断大类指令 | 一级译码简单 | custom/非法 opcode 漏判 |
| B/J 低位隐含 0 | 分支/跳转目标按 2 byte 对齐 | 少编码一位偏移，扩大相对范围 | 忘记补 `1'b0`，目标地址错一半 |
| 符号位统一放在 `inst[31]` | 负偏移和负立即数扩展统一 | sign-extension 简单 | RV64I 扩展宽度写死成 32 |
| 立即数字段拆散 | 保持主数据字段稳定 | register file 和主译码更顺 | B/J 拼接顺序非常容易写错 |

面试回答不要只说“规范就是这样”，要能联系硬件译码路径。

一个更工程化的说法是：RISC-V 把复杂度集中在 immediate generator 这个可单独验证的小模块里，换取主译码字段、register file 读地址和大部分数据通路选择的规整性。验证时也应该顺着这个结构做，把每一种 immediate 的边界值、正负跳转和最低位补零单独覆盖，而不是只靠跑 C 程序间接发现。

---

## 第5章 立即数生成与符号扩展

### 5.0 本章概述

立即数生成是 RISC-V RTL 中最容易出错的模块之一。错误常见于：

- B-type/J-type 位拼接顺序错。
- 忘记补最低位 0。
- 忘记 sign-extension。
- U-type 左移位数理解错。
- RV64I 中扩展到 XLEN 的宽度处理错。

### 5.1 各格式立即数拼接

以 RV32I 为例，常用立即数可以写成：

$$
\begin{aligned}
imm_I &= \operatorname{sign\_extend}(inst[31:20]) \\
imm_S &= \operatorname{sign\_extend}(\{inst[31:25], inst[11:7]\}) \\
imm_B &= \operatorname{sign\_extend}(\{inst[31], inst[7], inst[30:25], inst[11:8], 1'b0\}) \\
imm_U &= \{inst[31:12], 12'b0\} \\
imm_J &= \operatorname{sign\_extend}(\{inst[31], inst[19:12], inst[20], inst[30:21], 1'b0\})
\end{aligned}
$$

其中 B-type 和 J-type 的符号位仍然是 `inst[31]`。

### 5.2 立即数生成器的工程边界

立即数生成器不是“把几段 bit 拼起来”这么简单。它位于 decode 和执行之间，直接影响 ALU 操作数、load/store 地址、branch target、JAL target、JALR target 和 CSR 立即数字段。这个模块一旦错，表现往往像随机跳转、访存错地址或 signed/unsigned 比较异常，debug 成本很高。

可以把 immediate generator 的职责拆成四件事：

| 职责 | 典型格式 | 硬件动作 | 常见 bug |
|---|---|---|---|
| 字段重排 | S/B/J-type | 从 instruction word 抽取非连续字段 | B-type 的 `inst[7]` 和 `inst[11:8]` 顺序写错 |
| 隐含低位补零 | B/J-type | 在最低位补 `1'b0` | target 少乘 2，所有 label 跳偏 |
| 符号扩展 | I/S/B/J-type | 按 `inst[31]` 扩展到 XLEN | 负 offset 变成大正数或 RV64I 高位错误 |
| 高位构造 | U-type | 低 12 位补零 | LUI/AUIPC 地址高位错 |

从数据通路看，同一个 immediate 在不同指令中会进入不同加法器或 MUX：

```text
I-type ALU  : rs1 + imm_I / rs1 op imm_I
load/store  : rs1 + imm_I_or_S -> address
branch      : pc  + imm_B      -> branch target
JAL         : pc  + imm_J      -> jump target
JALR        : rs1 + imm_I      -> clear bit0 -> jump target
LUI         : imm_U            -> writeback
AUIPC       : pc  + imm_U      -> writeback
```

因此验证 immediate generator 时，不能只比对 `imm_o` 本身，还要让它穿过真实使用路径。例如 B-type 立即数要检查 PC trace，S-type 立即数要检查 store 地址，U-type 立即数要检查 LUI 和 AUIPC 两条指令的写回结果。

### 5.3 PC 相对跳转立即数与隐含低位 0

先把这类指令放回上下文里看：B-type 条件分支和 J-type `JAL` 都不是用立即数做普通 ALU 运算，而是用立即数改变 PC。

| 指令类型 | 典型指令 | 汇编里看到的形式 | 立即数的含义 | 目标地址计算 |
|---|---|---|---|---|
| B-type | `BEQ/BNE/BLT/BGE` | `BEQ rs1, rs2, label` | 从当前分支指令 PC 到 `label` 的有符号 PC 相对偏移 | $branch\_target = pc + imm_B$ |
| J-type | `JAL` | `JAL rd, label` | 从当前 JAL 指令 PC 到 `label` 的有符号 PC 相对偏移 | $jal\_target = pc + imm_J$ |

这里的 `label` 是汇编层面的符号，硬件看不到 `label`。汇编器/链接器会把 `label` 转换成一个相对当前 PC 的 offset(偏移地址)。硬件真正拿到的是 instruction word 里的立即数字段，然后 immediate generator 把它拼成 `imm_B` 或 `imm_J`。

容易让人困惑的是：很多资料会说 branch offset “要左移一位”或“乘 2”。这个说法的背景是，RISC-V 的 B-type/J-type 编码没有显式存储目标地址偏移的 bit 0。由于指令地址至少按 2 byte 对齐，合法控制流目标的最低位必然是 0，因此 ISA 把这个 0 省掉，用同样的编码位数表达更大的跳转范围。

换句话说，指令编码里保存的不是完整字节偏移的所有 bit，而是省略了最低位 0 的偏移字段。RTL 生成真正 byte offset 时，必须把这个低位 0 补回来：

```text
instruction bits 中的 B/J 立即数字段  ->  补上最低位 1'b0  ->  可直接与 PC 相加的 byte offset
```

所以在本文件 5.1 的写法中：

$$
\begin{aligned}
imm_B &= \operatorname{sign\_extend}(\{inst[31], inst[7], inst[30:25], inst[11:8], 1'b0\}) \\
imm_J &= \operatorname{sign\_extend}(\{inst[31], inst[19:12], inst[20], inst[30:21], 1'b0\})
\end{aligned}
$$

`imm_B` 和 `imm_J` 已经是补过低位 0 的 byte offset，不是还需要再次左移的半成品。因此目标地址直接写成：

$$
branch\_target = pc + imm_B
$$

J-type 同理：

$$
jal\_target = pc + imm_J
$$

对只支持 RV32I 且不支持 C extension 的简单核，还要再区分“编码单位”和“最终目标对齐要求”：

- B/J immediate 编码按 2 byte 对齐设计，所以最低位隐含 0。
- **如果实现不支持 C extension，实际有效 instruction 通常要求 4 byte 对齐**。
- branch/JAL 目标如果不是实现要求的取指对齐边界，可能触发 instruction address misaligned 类异常。
- 很多教学核会先简化为只允许 4 byte 对齐，但 immediate generator 仍应按 ISA 格式补 `1'b0`，而不是擅自补两个 0。

常见错误有两类：

| 错误写法 | 错误原因 | 现象 |
|---|---|---|
| 拼接时没有补 `1'b0` | 把编码字段当成完整 byte offset | 目标地址少乘 2，label 跳偏 |
| 拼接时补了 `1'b0`，target 计算又写 `imm << 1` | 对“左移一位”的概念重复实现 | 目标地址多乘 2，正向跳过头，负向循环跑飞 |

因此面试或写 RTL 时，更严谨的说法不是“branch offset 一定要再左移”，而是：

```text
B-type/J-type 编码省略了 byte offset 的 bit0。
immediate generator 需要在拼接时补回 1'b0。
补完后的 imm_B/imm_J 已经是 byte offset，target adder 直接做 pc + imm。
```

### 5.4 SystemVerilog 立即数生成示例

下面是可综合 immediate generator 示例。为了聚焦 ISA，不展开完整异常逻辑。

```systemverilog
typedef enum logic [2:0] {
  IMM_I,
  IMM_S,
  IMM_B,
  IMM_U,
  IMM_J,
  IMM_Z
} imm_sel_e;

module rv_imm_gen #(
  parameter int XLEN_P = 32
) (
  input  logic [31:0]    inst_i,
  input  imm_sel_e       imm_sel_i,
  output logic [XLEN_P-1:0] imm_o
);
  always_comb begin
    unique case (imm_sel_i)
      IMM_I: imm_o = {{(XLEN_P-12){inst_i[31]}}, inst_i[31:20]};
      IMM_S: imm_o = {{(XLEN_P-12){inst_i[31]}}, inst_i[31:25], inst_i[11:7]};
      IMM_B: imm_o = {{(XLEN_P-13){inst_i[31]}}, inst_i[31], inst_i[7],
                      inst_i[30:25], inst_i[11:8], 1'b0};
      IMM_U: imm_o = {{(XLEN_P-32){inst_i[31]}}, inst_i[31:12], 12'b0};
      IMM_J: imm_o = {{(XLEN_P-21){inst_i[31]}}, inst_i[31], inst_i[19:12],
                      inst_i[20], inst_i[30:21], 1'b0};
      IMM_Z: imm_o = {{(XLEN_P-5){1'b0}}, inst_i[19:15]};
      default: imm_o = '0;
    endcase
  end
endmodule
```

说明：

- `IMM_Z` 常用于 CSR 立即数字段，RV32I 基础整数最小核可暂不实现。
- `IMM_U` 在 RV32I 中就是 `{inst[31:12], 12'b0}`；参数化到 RV64I 时要明确高位扩展策略。
- 如果工具不支持变长 replication 为 0 的情况，需要对 `XLEN_P == 32` 等场景单独处理。

### 5.5 立即数验证点

directed test (定向测试)应覆盖：

- 正立即数、负立即数。
- 最大正数和最小负数。
- B-type 向前跳和向后跳。
- J-type 大偏移。
- U-type 高位全 0、全 1、交替位。
- 所有格式的 `inst[31]` 为 0 和 1。

---

## 第6章 RV32I/RV64I 基础整数指令

### 6.0 本章概述

本章不背完整编码表，而是从硬件行为角度理解基础整数指令。面试中最重要的是说清：

- 指令读什么。
- 指令写什么。
- ALU 做什么。
- PC 怎么变。
- memory 是否访问。
- 是否可能产生 exception。

本章和第4.2节六种基础格式的对应关系如下：

| 第6章小节 | 指令类别 | 对应第4.2节格式 |
|---|---|---|
| 6.1 算术逻辑指令 | 寄存器-寄存器类 | 4.2.1 R-type |
| 6.1 算术逻辑指令 | 立即数类、移位立即数类 | 4.2.2 I-type |
| 6.2 LUI 与 AUIPC | 高位立即数类 | 4.2.5 U-type |
| 6.3 分支指令 | 条件分支类 | 4.2.4 B-type |
| 6.4 JAL/JALR | JAL | 4.2.6 J-type |
| 6.4 JAL/JALR | JALR | 4.2.2 I-type |
| 6.5 load 指令 | 加载类 | 4.2.2 I-type |
| 6.6 store 指令 | 存储类 | 4.2.3 S-type |
| 6.7 system/FENCE/NOP | system/FENCE | 主要是 4.2.2 I-type |
| 6.7 system/FENCE/NOP | NOP 伪指令 | `ADDI x0, x0, 0`，编码为 4.2.2 I-type |

把指令按执行资源再分一层，会更接近 RTL：

| 指令类别 | 主要执行资源 | 写回来源 | 可能的副作用/异常 |
|---|---|---|---|
| ALU register/immediate | ALU、shifter、comparator | ALU result | 通常无 overflow exception |
| branch | branch comparator、target adder | 无 GPR 写回 | target misaligned、flush wrong-path |
| JAL/JALR | target adder、PC+4 adder | `pc + 4` | target misaligned、JALR bit0 清零 |
| load | LSU address adder、byte lane、load extender | memory read data | misaligned/access fault、bus wait |
| store | LSU address adder、write mask/data shifter | 无 GPR 写回 | misaligned/access fault、memory side effect |
| system/CSR | CSR file、trap control | CSR read data 或无 | illegal、ECALL、EBREAK、privilege violation |

这张表的意义是：decode 不是只输出一个 `alu_op`(ALU 操作码)。一条指令被识别后，需要同时决定操作数来源、执行单元、写回来源、是否访问 memory、是否写 GPR、是否可能触发 exception，以及如果后续 pipeline flush 时哪些副作用必须取消。

### 6.1 算术逻辑指令

本节包含两种格式：寄存器-寄存器类对应 4.2.1 R-type；立即数类和移位立即数类对应 4.2.2 I-type。

寄存器-寄存器类(R-type)：

| 指令 | Type | 汇编格式 | 行为 | 易错点 |
|---|---|---|---|---|
| ADD | R-type | `ADD rd, rs1, rs2` | `rd = rs1 + rs2`，结果截断到 XLEN 位写回 | 溢出不触发异常 |
| SUB | R-type | `SUB rd, rs1, rs2` | `rd = rs1 - rs2`，用 `rs1` 减 `rs2` 后写回 | 用 funct7 区分 ADD/SUB |
| AND | R-type | `AND rd, rs1, rs2` | `rd = rs1 & rs2`，逐 bit 取与 | 控制信号不要和 OR/XOR 混 |
| OR | R-type | `OR rd, rs1, rs2` | 逐 bit 取或，结果写 `rd` | 控制信号不要和 AND/XOR 混 |
| XOR | R-type | `XOR rd, rs1, rs2` | `rd = rs1 ^ rs2`，逐 bit 取异或 | 控制信号不要和 AND/OR 混 |
| SLL | R-type | `SLL rd, rs1, rs2` | `rd = rs1 << shamt`，低位补 0，`shamt` 来自 `rs2` 低位 | shift amount 只取低若干位 |
| SRL | R-type | `SRL rd, rs1, rs2` | `rd = rs1 >> shamt`，逻辑右移，高位补 0 | 高位补 0 |
| SRA | R-type | `SRA rd, rs1, rs2` | `rd = rs1 >>> shamt`，算术右移，高位补原符号位 | 高位补符号位 |
| SLT | R-type | `SLT rd, rs1, rs2` | 若 `$signed(rs1) < $signed(rs2)`，则 `rd = 1`，否则 `rd = 0` | signed 比较 |
| SLTU | R-type | `SLTU rd, rs1, rs2` | 若 `rs1 < rs2` 按无符号数成立，则 `rd = 1`，否则 `rd = 0` | unsigned 比较 |

立即数类(I-type)：

| 指令 | Type | 汇编格式 | 行为 | 易错点 |
|---|---|---|---|---|
| ADDI | I-type | `ADDI rd, rs1, imm` | `rd = rs1 + imm_I`，立即数先符号扩展 | imm 符号扩展 |
| ANDI | I-type | `ANDI rd, rs1, imm` | `rd = rs1 & imm_I`，立即数符号扩展后逐 bit 取与 | imm 符号扩展后参与按位运算 |
| ORI | I-type | `ORI rd, rs1, imm` | 立即数符号扩展后和 `rs1` 逐 bit 取或，结果写 `rd` | imm 符号扩展后参与按位运算 |
| XORI | I-type | `XORI rd, rs1, imm` | `rd = rs1 ^ imm_I`，立即数符号扩展后逐 bit 取异或 | imm 符号扩展后参与按位运算 |
| SLTI | I-type | `SLTI rd, rs1, imm` | 若 `$signed(rs1) < $signed(imm_I)`，则 `rd = 1`，否则 `rd = 0` | signed 比较 |
| SLTIU | I-type | `SLTIU rd, rs1, imm` | 立即数先符号扩展；若 `rs1 < imm_I` 按无符号数成立，则 `rd = 1`，否则 `rd = 0` | 先符号扩展，再 unsigned 比较 |
| SLLI | I-type | `SLLI rd, rs1, shamt` | `rd = rs1 << shamt`，移位量来自 shamt 字段 | shamt 位宽取决于 XLEN |
| SRLI | I-type | `SRLI rd, rs1, shamt` | `rd = rs1 >> shamt`，逻辑右移，高位补 0 | 用 funct7 区分 SRLI/SRAI |
| SRAI | I-type | `SRAI rd, rs1, shamt` | `rd = rs1 >>> shamt`，算术右移，高位补原符号位 | 用 funct7 区分 SRLI/SRAI |

这里的 signed/unsigned 只影响“比较时如何解释同一串 bit”。例如 XLEN=32 时，`32'hFFFF_FFFF` 按 signed 看是 `-1`，按 unsigned 看是 `4294967295`。`SLT/SLTI` 写回的不是较小的那个数，而是布尔结果：条件成立写 `1`，否则写 `0`。

重点：RISC-V 整数加减溢出不产生 overflow exception。硬件只保留 XLEN 位结果。

### 6.2 LUI 与 AUIPC(U-type)

本节两条指令都对应 4.2.5 U-type。

| 指令 | Type | 汇编格式 | 行为 | 常见用途/易错点 |
|---|---|---|---|---|
| LUI | U-type | `LUI rd, imm` | `rd = imm_U`，把 U-type 立即数放到高位，低 12 位为 0 | 构造大立即数的高 20 位 |
| AUIPC | U-type | `AUIPC rd, imm` | `rd = pc + imm_U`，用当前指令 PC 加高位立即数 | 常用于位置无关地址计算，不是用 `pc + 4` |

其中：

$$
imm_U = inst[31:12] \ll 12
$$

AUIPC 常用于位置无关代码，和 JALR 或 load/store 组合形成较大范围地址。

### 6.3 分支指令(B-type)

本节所有条件分支指令都对应 4.2.4 B-type。

条件分支不写 GPR，只改变 PC。

| 指令 | Type | 汇编格式 | 判断条件 | 成立时行为 | 比较说明 |
|---|---|---|---|---|---|
| BEQ | B-type | `BEQ rs1, rs2, label` | `rs1 == rs2` | `next_pc = pc + imm_B` | bit 值完全相等就跳转 |
| BNE | B-type | `BNE rs1, rs2, label` | `rs1 != rs2` | `next_pc = pc + imm_B` | bit 值不完全相等就跳转 |
| BLT | B-type | `BLT rs1, rs2, label` | `$signed(rs1) < $signed(rs2)` | `next_pc = pc + imm_B` | 按补码有符号数比较 |
| BGE | B-type | `BGE rs1, rs2, label` | `$signed(rs1) >= $signed(rs2)` | `next_pc = pc + imm_B` | signed 大于等于时跳转 |
| BLTU | B-type | `BLTU rs1, rs2, label` | `rs1 < rs2` 按无符号数比较 | `next_pc = pc + imm_B` | 都当作非负整数比较 |
| BGEU | B-type | `BGEU rs1, rs2, label` | `rs1 >= rs2` 按无符号数比较 | `next_pc = pc + imm_B` | unsigned 大于等于时跳转 |

分支成立：

$$
next\_pc = pc + imm_B
$$

其中：

$$
imm_B = target\_addr - pc
$$

`imm_B` 由汇编器（以及可能的链接器）根据汇编指令中的 `label` 对应地址与当前指令 `PC` 的差值计算得到，并作为 B-type 指令机器码的一部分编码存储在指令中。

分支不成立：

$$
next\_pc = pc + 4
$$

易错点：

- signed/unsigned 比较混用。
- branch target 用当前分支指令的 PC，而不是 `pc + 4`。
- 立即数忘记最低位 0。
- flush 逻辑属于微架构，ISA 只关心最终 PC 序列。

### 6.4 跳转指令 JAL/JALR

本节包含两种格式：JAL 对应 4.2.6 J-type；JALR 对应 4.2.2 I-type。

| 指令 | Type | 汇编格式 | 行为 | 易错点 |
|---|---|---|---|---|
| JAL | J-type | `JAL rd, label` | `rd = pc + 4` 保存返回地址；`next_pc = pc + imm_J` | target 用当前指令 PC 加 `imm_J` |
| JALR | I-type | `JALR rd, offset(rs1)` | `rd = pc + 4` 保存返回地址；`next_pc = (rs1 + imm_I) & ~1` | 目标地址 bit 0 必须清零 |

JAL 和 JALR 都会做两件事：第一，把返回地址 `pc + 4` 写入 `rd`；第二，改变 `next_pc`。如果 `rd = x0`，写回会被丢弃，此时它就变成“只跳转、不保存返回地址”的形式。

JAL 使用 `label`，和 B-type 分支类似，`label` 会被汇编器/链接器转换成相对当前指令 PC 的偏移：

$$
imm_J = target\_addr - pc
$$

所以 JAL 的目标地址是：

$$
next\_pc = pc + imm_J
$$

JALR 不直接使用 `label`，而是使用 `offset(rs1)` 这种“基址寄存器 + 偏移”的形式。这里的 `offset` 是 I-type 指令里的 12 bit 有符号立即数，也就是本章写的 `imm_I` (该指令是 **I-type**)；`rs1` 里存着一个基址地址，可能是函数指针、跳转表入口、或者 `ra` 返回地址。

因此：

$$
\begin{aligned}
base &= rs1 \\
offset &= imm_I \\
raw\_target &= base + offset \\
next\_pc &= raw\_target \mathbin{\&} \sim 1
\end{aligned}
$$

也就是说，`JALR rd, offset(rs1)` 的直观含义是：

```text
把 pc + 4 写入 rd 作为返回地址；
把 rs1 里的地址加上 offset，得到跳转目标；
把目标地址 bit0 清零后写入 next_pc。
```

例如函数返回常用伪指令 `ret`，真实编码通常等价于：

```text
JALR x0, 0(x1)
```

其中 `x1` 是 ABI 里的 `ra`，保存着调用者下一条指令地址；`offset = 0` 表示不额外偏移；`rd = x0` 表示不需要再保存新的返回地址。因此它的行为就是：

$$
next\_pc = (ra + 0) \mathbin{\&} \sim 1
$$

再比如通过函数指针调用：

```text
JALR x1, 0(x5)
```

如果 `x5` 中保存了函数入口地址，那么这条指令跳到 `x5` 指向的函数，同时把返回地址 `pc + 4` 写入 `x1(ra)`。

为什么最后要 `& ~1`？RISC-V 规定 JALR 计算出的目标地址最低 bit 要清零。这样做有两个工程意义：

- 保证跳转目标至少 2 byte 对齐，和可能存在的 C extension 压缩指令对齐规则兼容。
- 允许软件在函数指针最低 bit 存放少量标记信息，硬件跳转时自动清掉 bit0，不把它当成真实取指地址的一部分。

注意这里和 B-type/J-type 的 `imm_B/imm_J` 不一样：B/J 的低位 0 是 immediate generator 在拼接立即数时补进去；JALR 的 `imm_I` 本身没有隐含低位 0，硬件先做 `rs1 + imm_I`，再对最终 target 清 bit0。

JALR 易错点：

- 目标地址 bit 0 必须清零。
- rd 可以是 x0，此时只跳转不保存返回地址。
- rs1 常是 ra，但硬件不应把 ra 特殊化。

### 6.5 load 指令(I-type)

本节所有 load 指令都对应 4.2.2 I-type。

load 从 memory 读数据写入 rd。

常见 load 指令：

| 指令 | Type | 汇编格式 | 访问宽度 | 行为 |
|---|---|---|---:|---|
| LB | I-type | `LB rd, offset(rs1)` | 8 bit | 读 1 byte，按 bit 7 sign-extension 后写 `rd` |
| LH | I-type | `LH rd, offset(rs1)` | 16 bit | 读 2 byte，按 bit 15 sign-extension 后写 `rd` |
| LW | I-type | `LW rd, offset(rs1)` | 32 bit | RV32I 直接写 32 bit；RV64I sign-extension 到 64 bit |
| LBU | I-type | `LBU rd, offset(rs1)` | 8 bit | 读 1 byte，高位补 0 zero-extension 后写 `rd` |
| LHU | I-type | `LHU rd, offset(rs1)` | 16 bit | 读 2 byte，高位补 0 zero-extension 后写 `rd` |
| LWU | I-type | `LWU rd, offset(rs1)` | 32 bit | 仅 RV64I：读 4 byte，zero-extension 到 64 bit |
| LD | I-type | `LD rd, offset(rs1)` | 64 bit | 仅 RV64I：读 8 byte，直接写入 64 bit `rd` |

注意 `LW` 在 RV32I 和 RV64I 中都存在，但扩展规则不同：RV32I 直接写 32 bit，RV64I 要把 32 bit 读数 sign-extension 到 64 bit。`LWU/LD` 只属于 RV64I。

地址计算：

$$
addr = rs1 + imm_I
$$

对于 byte/halfword 类型 load，需要根据地址低位从 memory 返回的 32 bit 数据中选择对应部分：

- byte 访问（LB/LBU）使用 `addr[1:0]` 选择 byte lane：

| `addr[1:0]` | 读取 byte |
|---|---|
| `2'b00` | `mem_rdata[7:0]` |
| `2'b01` | `mem_rdata[15:8]` |
| `2'b10` | `mem_rdata[23:16]` |
| `2'b11` | `mem_rdata[31:24]` |

- halfword 访问（LH/LHU）使用 `addr[1]` 选择低/高 halfword：

| `addr[1]` | 读取 halfword |
|---|---|
| `1'b0` | `mem_rdata[15:0]` |
| `1'b1` | `mem_rdata[31:16]` |

其中对齐 halfword 访问时 `addr[0]` 应为 0。

易错点：

- byte lane 选择错。
- LB/LH 的符号位取错。
- LBU/LHU 错做符号扩展。
- RV64I 的 LW 扩展规则错。
- 非对齐访问处理策略不清晰。

### 6.6 store 指令(S-type)

本节所有 store 指令都对应 4.2.3 S-type。

store 把 `rs2` 的低位写到 memory。地址同样由基址寄存器和 S-type 立即数相加得到：

| 指令 | Type | 汇编格式 | 访问宽度 | 行为 |
|---|---|---|---:|---|
| SB | S-type | `SB rs2, offset(rs1)` | 8 bit | 计算 `addr = rs1 + imm_S`，写 `rs2[7:0]` |
| SH | S-type | `SH rs2, offset(rs1)` | 16 bit | 计算 `addr = rs1 + imm_S`，写 `rs2[15:0]` |
| SW | S-type | `SW rs2, offset(rs1)` | 32 bit | 计算 `addr = rs1 + imm_S`，写 `rs2[31:0]` |
| SD | S-type | `SD rs2, offset(rs1)` | 64 bit | RV64I：计算 `addr = rs1 + imm_S`，写 `rs2[63:0]` |

地址计算：

$$
addr = rs1 + imm_S
$$

对于 byte/halfword 类型 store，需要根据地址低位决定写入哪个 byte lane：

- SB 使用 `addr[1:0]` 选择目标 byte lane，并写入 `rs2[7:0]`。
- SH 使用 `addr[1]` 选择低/高 16 bit，并写入 `rs2[15:0]`。
- SW 直接写完整 `rs2[31:0]`。

因此 store 实现通常需要：

- byte enable / write mask。
- write data shift/alignment。
- 对齐检查。
- bus request。
- 等待 memory response。

### 6.7 system 指令、FENCE 和 NOP(主要是I-type)

本节的 ECALL、EBREAK、FENCE 主要按 4.2.2 I-type 编码；NOP 是 `ADDI x0, x0, 0` 这条 I-type 指令的伪指令写法。

基础实现中常见 system/FENCE/NOP：

| 指令/伪指令 | Type | 汇编格式 | 行为 | 易错点 |
|---|---|---|---|---|
| ECALL | I-type/system | `ECALL` | 环境调用，通常产生 exception，进入 trap 流程 | 不能当普通 NOP 忽略 |
| EBREAK | I-type/system | `EBREAK` | 断点指令，通常用于 debug 或触发断点异常 | debug/异常行为要和实现约定一致 |
| CSR 指令 | I-type/CSR | `CSRRW/CSRRS/CSRRC ...` | 若实现 Zicsr，需要读写 CSR，并可能写回旧 CSR 值 | CSR 原子读改写和权限检查容易漏 |
| FENCE | I-type/fence | `FENCE pred, succ` | 约束前后访存顺序 | 有 cache/store buffer/MMIO 时不能随便忽略 |
| NOP | I-type pseudo | `ADDI x0, x0, 0` | 不改变架构状态，只占一条指令位置 | 本质是 ADDI 写 x0，仍要保证 x0 写入无效 |

简单单核、强顺序、无 cache 的教学核可以把 FENCE 实现成 NOP，但如果有 cache、store buffer、外设访问或多 master 系统，就不能随便忽略。

NOP 不是独立真实指令，常见编码为：

```text
ADDI x0, x0, 0
```

---

## 第7章 程序、用户数据与存储单元的直觉地图

### 7.0 本章概述

前面已经讲了 PC、GPR、指令格式和 load/store。到这里很容易出现一个疑问：指令到底存在哪里？照片、短信、系统更新这些掉电不能丢的数据又存在哪里？GPR、RAM、ROM、flash、cache、MMIO 到底是不是同一种“存储”？

本章先不深入存储器电路，也不展开文件系统、NAND 控制器或 cache 一致性。这里的目标是建立一张实际系统里的直觉地图：CPU 看到的是地址和指令，用户看到的是程序和文件，中间由 boot code、OS、driver、memory map、cache 和 storage controller 把这些层连接起来。

### 7.1 从用户视角看：程序和数据不只一种

用户日常看到的“程序”和“数据”，在硬件系统里会分成很多类：

| 用户或软件概念 | 例子 | 是否希望掉电保留 | 硬件上通常在哪里 |
|---|---|---:|---|
| 芯片启动代码 | reset 后第一段代码、厂商固化启动流程 | 是 | boot ROM 或固定映射 flash |
| 固件/系统镜像 | MCU firmware、手机 bootloader、RTOS image、OS kernel | 是 | NOR flash、NAND flash、eMMC、UFS、SSD |
| OTA 更新包 | 系统更新、固件升级包、A/B 分区镜像 | 是 | flash/eMMC/UFS/SSD 的某个分区 |
| app 程序 | 用户安装的应用程序 | 是 | 文件系统中的可执行文件或包，底层在 flash/eMMC/UFS/SSD |
| 用户数据 | 照片、短信、聊天记录、配置文件 | 是 | 文件系统管理的非易失存储 |
| 运行时变量 | 栈、堆、全局变量、临时缓冲区 | 否，重启后重建或重新加载 | SRAM/DRAM |
| 当前指令操作数 | ALU 正在相加的两个数、地址基址、函数参数 | 否 | GPR/register file |

因此，ROM 不是“所有掉电不丢数据”的总称。ROM 更强调“只读或出厂固化”；照片、短信、app、OTA 包这类需要运行后继续写入和更新的数据，通常放在可改写的 non-volatile storage，例如 NAND flash、eMMC、UFS 或 SSD。

### 7.2 从 CPU 视角看：先取指，再通过 load/store 取数据

CPU 真正直接执行的是 instruction。PC 指向某个地址，IF 阶段按这个地址取回 instruction word，然后 decode、execute。数据运算则遵循 load/store 架构：

```text
持久存储/内存中的数据
  -> load 到 GPR
  -> ALU 使用 GPR 做运算
  -> 结果写回 GPR
  -> store 回 memory 或通过 MMIO 触发外设
```

这条线容易和日常说法混淆。比如“程序在手机存储里”是真的，但 CPU 并不是直接在 NAND flash cell 上执行每一条 app 指令。更常见的流程是：

```text
app 文件在 UFS/eMMC/SSD
  -> OS 通过文件系统找到文件块
  -> storage controller 读取 block/page
  -> DMA 或 CPU 执行拷贝循环把内容放进 DRAM
  -> CPU 从 DRAM/cache 取指和 load 数据
```

对 MCU 或简单 SoC，流程可能更直接：

```text
reset
  -> CPU 从 boot ROM 或 NOR flash 的 reset vector 取第一条指令
  -> boot code 初始化 SRAM、栈和必要外设
  -> 跳到正式 firmware
```

有些 NOR flash 支持 XIP，CPU 可以像访问 memory 一样直接从 flash 地址空间取指；但 NAND/eMMC/UFS/SSD 更常被当作 block device，需要 storage controller 读出块数据后再放进 DRAM/SRAM 使用。

### 7.3 GPR、RAM、ROM、flash 和 cache 的角色区分

下面这张表先建立直觉。它不是工艺分类表，而是处理器学习中最常用的角色划分：

| 名称 | 掉电后是否保留 | CPU 是否每条指令直接操作 | 典型容量/速度直觉 | 常见用途 | 后续在哪里深入 |
|---|---:|---:|---|---|---|
| GPR/register file | 否 | 是，指令用 `rs1/rs2/rd` 编号直接读写 | 极小、最快 | ALU 操作数、地址基址、函数参数、返回值 | `0802` 的 ID/WB、forwarding、hazard |
| pipeline register | 否 | 否，软件不可见 | 极小、每级暂存 | 保存 IF/ID/EX/MEM/WB 之间的 PC、数据和控制信号 | `0802` 的 pipeline register、stall/flush |
| boot ROM | 是 | 可被取指或读，但通常不能写 | 小、较慢但稳定 | reset 后第一段启动代码、芯片固化逻辑 | `0804` 的 boot ROM 和启动流程 |
| NOR flash | 是 | 可能 memory-mapped，可 XIP | 中等、读较方便、写/擦慢 | MCU 固件、启动镜像、参数区 | `0804` 的 memory map，`0805` 的 cacheable 属性 |
| NAND flash/eMMC/UFS/SSD | 是 | 通常不能像普通 RAM 一样直接字节随机执行 | 大、块/page 访问、需控制器 | app、照片、短信、OTA 包、文件系统 | `0804` 的 storage controller/DMA，`0805` 的 cache/一致性 |
| SRAM | 否 | 可以作为普通 memory 访问 | 小到中等、快 | 片上数据区、栈、堆、小程序、cache array | `0804` 的片上 SRAM，`0805` 的 cache SRAM |
| DRAM | 否 | 作为普通 memory 访问，通常经 cache/MMU | 大、比 SRAM 慢 | OS、app 运行时内存、文件缓存、大数组 | `0805` 的 cache/TLB/MMU |
| cache | 否 | CPU 访问 memory 时自动命中/缺失 | 小、快 | 保存近期 instruction/data 副本，隐藏 DRAM/flash 延迟 | `0805` 的 I-cache/D-cache |
| MMIO register | 通常由外设状态决定 | 通过 load/store 访问，但有副作用 | 小、延迟不固定 | UART、GPIO、timer、PLIC、storage controller 控制寄存器 | `0804` 的 MMIO 和外设互联 |

一个实用判断是：**GPR 是指令直接点名的操作数仓库；RAM/flash/ROM 是地址空间里的存储资源；cache 是性能优化副本；MMIO 是地址映射出来的硬件动作入口。**

### 7.4 指令存储和数据存储：概念路径不等于物理块

后续 `0802` 讲流水线时会频繁出现 instruction memory 和 data memory：

```text
IF  阶段：PC -> instruction memory -> instruction
MEM 阶段：load/store address -> data memory/cache/bus -> load/store result
```

这两个名字首先是**流水线访问路径**，不一定代表物理上必须有两块完全独立的 RAM。

| 说法 | 在讲什么 | 可能的真实实现 |
|---|---|---|
| instruction memory (指令内存) | IF 阶段取指看到的访问端口或路径 | boot ROM、flash、SRAM、I-cache、统一 cache、总线返回的 instruction |
| data memory (数据内存) | MEM 阶段 load/store 看到的访问端口或路径 | SRAM、D-cache、DRAM、MMIO、外设总线、非法地址响应 |
| Harvard architecture (哈佛结构) | 指令和数据访问路径分离 | I-cache + D-cache，或独立 instruction SRAM/data SRAM |
| von Neumann architecture (冯・诺依曼结构) | 指令和数据共享同一存储空间或通路 | 统一内存、统一 cache、共用总线 |

教科书五级流水线常假设 instruction memory 和 data memory 分离，是为了避免 IF 取指和 MEM 访存同拍抢同一个单端口 RAM。真实 SoC 则可能前端有 I-cache，后端有 D-cache，再通过互联访问同一片 DRAM 或 flash；结构上更复杂，但 ISA 仍然只要求最终取到正确指令、load/store 得到正确语义。

### 7.5 程序更新、OTA 和启动链路的直觉

“程序存在哪里”还要考虑更新。一个系统出厂后，程序可能经历多层更新：

```text
boot ROM       通常不更新，负责最早启动和安全检查
bootloader     可更新，负责选择系统镜像、校验、回滚
firmware/kernel 可通过 OTA 或刷写更新
app 程序        用户安装、升级、卸载
用户数据        长期保存，更新程序时通常不能丢
```

典型 OTA 不会把新系统直接覆盖正在运行的代码，而会写入另一个分区或备用镜像：

| 阶段 | 软件动作 | 硬件相关点 |
|---|---|---|
| 下载更新包 | 网络或外设把数据写入持久存储 | storage controller、DMA、DRAM 缓冲、flash 写入 |
| 校验镜像 | bootloader/OS 检查签名、版本、完整性 | CPU 从 DRAM/cache 执行校验代码，读取 storage 数据 |
| 切换启动槽 | 修改少量启动元数据 | 持久化配置区、写顺序、掉电保护 |
| 重启进入新镜像 | boot ROM/bootloader 选择新镜像 | reset vector、memory map、取指路径 |
| 失败回滚 | 启动失败时回到旧镜像 | bootloader 状态机、持久标志位 |

这就是为什么 SoC 设计不能只关心“CPU 会执行 ADD”。真实系统还需要保证：reset 后能从固定地址取到第一条指令；storage controller 能把系统镜像读出来；DRAM/SRAM 足够承载运行时；MMIO 寄存器能让软件可靠地控制外设；cache/FENCE/DMA 不会破坏数据可见性。

### 7.6 本章和后续文档的分工

本章只建立直觉，后面会分层展开：

| 主题 | 本章建立的直觉 | 后续展开位置 |
|---|---|---|
| GPR 与 register file | 指令直接读写的 32 个通用寄存器 | `0802` 的 ID/WB、forwarding、load-use hazard |
| instruction/data memory | 流水线视角的取指路径和访存路径 | `0802` 的 IF/MEM structural hazard |
| boot ROM、SRAM、flash、MMIO | SoC 地址空间中的不同区域 | `0804` 的 memory map、boot flow、外设互联 |
| storage controller、DMA、块设备 | 用户数据和 app 镜像常在大容量持久存储中 | `0804` 的总线和 DMA，后续 `070x` 总线专题 |
| cache、DRAM、TLB/MMU | CPU 运行时通常通过 cache/MMU 访问大内存 | `0805` 的 cache、TLB、MMU、memory model |
| OTA、app、文件系统 | 程序和数据更新依赖 OS/bootloader/storage 协作 | `0804` 的系统启动视角，`0805` 的缓存和一致性视角 |

---

## 第8章 访存语义、对齐、小端序与 MMIO

### 8.0 本章概述

RISC-V 是 load/store 架构。算术逻辑指令不直接访问 memory，访存都通过 load/store 指令完成。这让 ALU 数据通路和 LSU 边界更清晰。

### 8.1 load/store 架构的硬件意义

load/store 架构带来几个工程好处：

- ALU 指令格式规整，执行单元简单。
- memory 访问集中在 LSU，便于处理对齐、byte enable、cache、bus。
- pipeline 里可以把 EX(执行阶段) 用于地址计算，把 MEM(访存阶段) 用于实际访存。
  > CPU 流水线（pipeline）里标准的阶段缩写：IF → ID → EX → MEM → WB，即 取指→译码→执行→访存→写回。
- 验证可以把寄存器运算和 memory transaction 分开建模。

代价是：

- 程序可能需要更多指令完成 memory 与 register 之间的数据搬运。
- 性能更依赖 cache(高速缓冲存储器)、预取和编译器寄存器分配。

更工程化地说，load/store 不是“ALU 算个地址然后连 memory”的一根线，而是一条 LSU 数据通路。它至少要完成地址生成、对齐检查、byte lane 选择、读数据扩展、写数据移位、异常记录、总线请求和 response 等动作。

```text
rs1 + imm
  -> effective address
  -> alignment check
  -> byte lane / write mask
  -> data memory, cache or bus
  -> load data align / sign or zero extension
  -> writeback
```

对简单 RV32I 核，LSU 常常是 MEM 阶段的主要复杂度来源；对带 cache 或 MMIO 的 SoC，它还会成为 ISA、总线协议和外设副作用之间的边界。

### 8.2 小端序

RISC-V 通常采用 little-endian。即，低地址存低字节，高地址存高字节。
对一个 32 bit word `0x11223344` 存到地址 `A`：

| 地址 | 字节 |
|---|---|
| `A + 0` | `0x44` |
| `A + 1` | `0x33` |
| `A + 2` | `0x22` |
| `A + 3` | `0x11` |

RTL 里 load byte/halfword 的选择必须和小端序一致。

### 8.3 对齐与非对齐访问

自然对齐示例：

| 访问类型   | 占 bit 数 | 占字节数 | 自然对齐地址要求  | 说明 |
| ---------- | -------- | -------- | ----------------- | ---- |
| byte       | 8 bit    | 1 字节   | 任意地址          | 单字节存储，无对齐约束 |
| halfword   | 16 bit   | 2 字节   | 地址 bit0 = 0     | 需 2 字节对齐，地址为偶数 |
| word       | 32 bit   | 4 字节   | 地址 bit[1:0] = 00 | 需 4 字节对齐，地址为 4 的倍数 |
| doubleword | 64 bit   | 8 字节   | 地址 bit[2:0] = 000 | 需 8 字节对齐，地址为 8 的倍数 |

非对齐访问是否硬件支持，取决于实现和特权架构要求。简单核常选择：

- 检测 misaligned access。
- 产生 exception。
- 不在硬件中拆成多次访问。

如果要支持非对齐访问，硬件复杂度会增加：

- 可能跨两个 bus beat。
- 需要组合和移位数据。
- 需要处理异常的精确性。
- 验证空间显著变大。

对齐检查可以直接从地址低位得到：

$$
\begin{aligned}
halfword\_misaligned &= addr[0] \ne 1'b0 \\
word\_misaligned &= addr[1:0] \ne 2'b00 \\
doubleword\_misaligned &= addr[2:0] \ne 3'b000
\end{aligned}
$$

这里的关键不是公式本身，而是异常优先级和副作用边界：如果一条 store 非对齐并选择产生 exception，它不能同时向 bus 发出部分写；如果一条 load 非对齐被 trap，不能把不完整或错误扩展的数据写回 rd。验证时应检查“异常发生时无 memory write、无 GPR write 或只产生规定的 trap side effect”。

### 8.4 Byte Lane、Write Mask 与 Load 扩展

在 32 bit little-endian 数据总线上，地址低两位决定 byte lane。对 store 来说，`SB/SH/SW` 不是只改写 `rs2` 的低位，还要把数据移动到对应 lane (通道)，并生成 byte enable。

| 访问 | `addr[1:0]` | byte enable 示例 | 写入数据放置 |
|---|---|---|---|
| `SB` | `2'b00` | `4'b0001` | `wdata[7:0] = rs2[7:0]` |
| `SB` | `2'b01` | `4'b0010` | `wdata[15:8] = rs2[7:0]` |
| `SB` | `2'b10` | `4'b0100` | `wdata[23:16] = rs2[7:0]` |
| `SB` | `2'b11` | `4'b1000` | `wdata[31:24] = rs2[7:0]` |
| `SH` | `2'b00` | `4'b0011` | `wdata[15:0] = rs2[15:0]` |
| `SH` | `2'b10` | `4'b1100` | `wdata[31:16] = rs2[15:0]` |
| `SW` | `2'b00` | `4'b1111` | `wdata[31:0] = rs2[31:0]` |

对 load 来说，过程反过来：先根据地址低位选出 byte 或 halfword，再按指令选择 sign-extension 或 zero-extension。`LB/LBU`、`LH/LHU` 的差异不在 memory 读出来的数据，而在写回前的扩展方式。

因此 LSU directed test 不应只检查整字 load/store，还要使用类似 `0xA1B2C3D4` 的 memory pattern 覆盖每个 byte lane。很多 store mask bug 会在 `SW` 下完全看不出来，只在 `SB/SH` 和相邻字节保持性检查中暴露。

### 8.5 MMIO 与普通 memory 的区别

MMIO 把外设寄存器映射到地址空间中，CPU 用 load/store 访问外设。

普通 memory 和 device memory 的典型差异：

| 项目 | 普通 memory | MMIO/device memory |
|---|---|---|
| 读副作用 | 通常无 | 可能有，例如读清状态 |
| 写副作用 | 写入存储 | 可能启动硬件动作 |
| cacheable | 通常可 cache | 通常不可 cache |
| 合并/重排 | 可能允许 | 通常严格限制 |
| 延迟 | 相对可预测 | 取决于外设和总线 |

> 读副作用：指读取地址数据时，除了返回数值，还会额外改变硬件或寄存器状态，并非单纯的读取操作。  
> 写副作用：指向地址写入数据时，除了存入数值，还会触发硬件执行具体动作，而非只完成存储。  
> Cacheable：表示该地址空间能否被 CPU 的高速缓存（Cache）缓存，决定访问是走快速缓存还是直接访问原始设备。  
> 合并 / 重排：是 CPU 或总线的性能优化行为，可将多次读写调整顺序、合并操作，减少访问次数。  
> 延迟：指 CPU 发出读写请求到完成操作的耗时，反映访问该地址空间的速度快慢与稳定性。

所以在更完整的 SoC 中，FENCE、cache 属性、bus ordering 都会影响 MMIO 正确性。

### 8.6 FENCE 的直觉(内存屏障指令)

FENCE 是一条同步指令，用来约束 CPU 对内存的读写顺序，强制：

- 指令之前的访存操作全部完成
- 再执行后面的访存操作

简单说：堵一下，让前面的读写都走完，再放行后面的。

FENCE 不是“清空所有东西”的简单按钮，而是对某些访问顺序建立约束。

在简单顺序核里：

- 没有 cache。
- 没有 store buffer。
- 没有乱序访存。
- 每条 load/store 都等完成再提交。

此时 FENCE 可以作为 NOP 处理。

在复杂系统里：

- store 可能暂存在 buffer。
- load 可能绕过某些 store。
- cache 可能延迟写回。
- 外设寄存器写入顺序有语义。

此时 FENCE 必须影响微架构，否则软件驱动可能出错。

---

## 第9章 扩展体系与实现边界

### 9.0 本章概述

RISC-V 的一个特点是基础小、扩展多。对面试来说，重点不是背所有扩展，而是能说明扩展解决什么问题，以及“不实现某扩展时硬件应该怎么处理相关指令”。

### 9.1 M extension

M extension 提供整数乘除法，例如乘法、除法、取余。

硬件实现选择：

| 方案 | 延迟 | 面积 | 适用场景 |
|---|---:|---:|---|
| 组合乘法器 | 低 | 高 | 频率不高或面积允许 |
| 流水乘法器 | 吞吐高 | 中高 | DSP、控制处理器 |
| 迭代乘法器 | 高 | 低 | 小面积 MCU |
| 软件 emulation | 很高 | 最低 | 不实现 M extension 的核 |

如果 CPU 声称只支持 RV32I，则遇到 M extension 指令应产生 illegal instruction，而不是随便当 NOP。

### 9.2 A extension

A extension 提供原子内存操作，用于多核同步、锁、无锁数据结构。

它会牵涉：

- cache coherence。
- memory ordering。
- 总线原子事务。
- load-reserved/store-conditional 类状态。

普通五级流水线入门核可以不实现 A extension，但要知道它是多核软件同步的重要基础。

### 9.3 C extension

C extension 提供 16 bit 压缩指令，目标是减小代码体积。

硬件影响：

- 取指不再只按 4 byte 步进。
- PC 可能 `+2` 或 `+4`。
- 指令对齐和取指缓冲复杂化。
- 译码前可能需要先解压成等价 32 bit 指令。

很多教学核先不支持 C extension，以保持 IF 和 decode 简单。

### 9.4 F/D/V extension

F/D extension 增加浮点计算。V extension 增加向量计算能力。

它们会引入：

- 独立寄存器堆或扩展寄存器。
- 新执行单元。
- 舍入模式。
- 异常标志。
- 更复杂的 scoreboard 和随机验证。

这些通常不是入门五级流水线的第一步，但在 AI 加速、DSP 和高性能处理器方向会很重要。

### 9.5 custom extension

自定义扩展常用于专用加速，例如：

- 加密算法指令。
- 位操作指令。
- AI 加速指令。
- DSP 饱和运算。
- 访存加速指令。

设计 custom extension 时要明确：

- 编码空间是否合法。
- 是否破坏标准工具链。
- 编译器如何产生该指令。
- 反汇编和仿真如何支持。
- 异常、中断、调试如何处理长延迟指令。

---

## 第10章 从 ISA 到 RTL：译码、控制和数据通路

### 10.0 本章概述

ISA 文档最终要落到 RTL。最小 RV32I 核通常需要：

- IF 取指。
- decode 解析字段和生成控制信号。
- register file 读写。
- ALU 执行。
- branch comparator 判断分支。
- LSU 访问 memory。
- writeback 选择写回数据。
- exception 处理非法指令和访存异常。

本章先不展开完整流水线，只说明 ISA 如何驱动 RTL 模块划分。

### 10.1 基础数据通路

一个极简 RV32I 数据通路可以抽象为：

```text
              +----------------+
       PC --->| instruction mem |---- inst
        ^     +----------------+
        |              |
        |          +--------+
        |          | decode |
        |          +--------+
        |              |
        |      rs1/rs2/rd/control
        |              |
        |       +-------------+
        |       | register    |
        |       | file        |
        |       +-------------+
        |          |       |
        |          |       +------------------+
        |          v                          v
        |       +-----+     addr/data     +--------+
        +-------| ALU |------------------>| memory |
 next_pc        +-----+                   +--------+
                   |                          |
                   +----------+---------------+
                              v
                          writeback
```

### 10.2 字段提取

字段提取通常是纯组合逻辑：

```systemverilog
logic [6:0] opcode;
logic [4:0] rd;
logic [2:0] funct3;
logic [4:0] rs1;
logic [4:0] rs2;
logic [6:0] funct7;

assign opcode = inst_i[6:0];
assign rd     = inst_i[11:7];
assign funct3 = inst_i[14:12];
assign rs1    = inst_i[19:15];
assign rs2    = inst_i[24:20];
assign funct7 = inst_i[31:25];
```

这些字段位置固定，所以 decode 可以很早给 register file 提供读地址。

### 10.3 控制信号

一条指令译码后，通常生成如下 control signal：

| 控制信号 | 含义 |
|---|---|
| `reg_we` | 是否写 GPR |
| `alu_op` | ALU 执行什么操作 |
| `alu_src_a_sel` | ALU 操作数 A 选择 rs1 还是 PC |
| `alu_src_b_sel` | ALU 操作数 B 选择 rs2 还是 immediate |
| `imm_sel` | immediate generator 选择哪种格式 |
| `mem_req` | 是否发起 memory 访问 |
| `mem_we` | 是否写 memory |
| `mem_size` | byte/halfword/word/doubleword |
| `mem_unsigned` | load 是否 zero-extension |
| `wb_sel` | 写回选择 ALU、memory、PC+4、CSR |
| `branch_op` | 分支比较类型 |
| `jump` | 是否 JAL/JALR |
| `illegal` | 是否非法指令 |

### 10.4 简化译码示例

下面代码只演示风格，不覆盖完整 RV32I。

```systemverilog
always_comb begin
  ctrl_o = '0;
  ctrl_o.illegal = 1'b0;

  unique case (opcode)
    7'b0110011: begin // R-type
      ctrl_o.reg_we = 1'b1;
      ctrl_o.alu_src_a_sel = ALU_A_RS1;
      ctrl_o.alu_src_b_sel = ALU_B_RS2;
      ctrl_o.wb_sel = WB_ALU;

      unique case ({funct7, funct3})
        {7'b0000000, 3'b000}: ctrl_o.alu_op = ALU_ADD;
        {7'b0100000, 3'b000}: ctrl_o.alu_op = ALU_SUB;
        {7'b0000000, 3'b111}: ctrl_o.alu_op = ALU_AND;
        {7'b0000000, 3'b110}: ctrl_o.alu_op = ALU_OR;
        {7'b0000000, 3'b100}: ctrl_o.alu_op = ALU_XOR;
        default: ctrl_o.illegal = 1'b1;
      endcase
    end

    7'b0010011: begin // I-type ALU
      ctrl_o.reg_we = 1'b1;
      ctrl_o.imm_sel = IMM_I;
      ctrl_o.alu_src_a_sel = ALU_A_RS1;
      ctrl_o.alu_src_b_sel = ALU_B_IMM;
      ctrl_o.wb_sel = WB_ALU;

      unique case (funct3)
        3'b000: ctrl_o.alu_op = ALU_ADD; // ADDI
        3'b111: ctrl_o.alu_op = ALU_AND; // ANDI
        3'b110: ctrl_o.alu_op = ALU_OR;  // ORI
        3'b100: ctrl_o.alu_op = ALU_XOR; // XORI
        default: ctrl_o.illegal = 1'b1;
      endcase
    end

    default: begin
      ctrl_o.illegal = 1'b1;
    end
  endcase
end
```

工程提醒：

- 真实设计要覆盖所有支持的指令。
- 不支持的 opcode/funct 组合必须标记 illegal instruction。
- 对 shift immediate 类指令，还要检查 funct7 和 shamt 高位。
- decode 默认值要安全，避免 latch。

### 10.5 branch comparator

分支比较器通常独立于 ALU，也可以复用 ALU。独立比较器便于缩短分支决策路径。

```systemverilog
always_comb begin
  unique case (branch_op_i)
    BR_EQ:  branch_taken_o = (rs1_i == rs2_i);
    BR_NE:  branch_taken_o = (rs1_i != rs2_i);
    BR_LT:  branch_taken_o = ($signed(rs1_i) <  $signed(rs2_i));
    BR_GE:  branch_taken_o = ($signed(rs1_i) >= $signed(rs2_i));
    BR_LTU: branch_taken_o = (rs1_i <  rs2_i);
    BR_GEU: branch_taken_o = (rs1_i >= rs2_i);
    default: branch_taken_o = 1'b0;
  endcase
end
```

易错点是 `$signed` 只包住一个操作数或位宽不一致。建议明确保证两边同宽。

### 10.6 load 数据扩展

load 数据扩展是另一个高频 bug 点：

```systemverilog
always_comb begin
  unique case (load_size_i)
    MEM_BYTE: begin
      load_data_o = load_unsigned_i
                  ? {{(XLEN_P-8){1'b0}}, byte_data}
                  : {{(XLEN_P-8){byte_data[7]}}, byte_data};
    end
    MEM_HALF: begin
      load_data_o = load_unsigned_i
                  ? {{(XLEN_P-16){1'b0}}, half_data}
                  : {{(XLEN_P-16){half_data[15]}}, half_data};
    end
    MEM_WORD: begin
      load_data_o = {{(XLEN_P-32){word_data[31]}}, word_data};
    end
    default: load_data_o = '0;
  endcase
end
```

对于 RV32I，MEM_WORD 直接等于 32 bit。对于 RV64I，LW 是符号扩展，LWU 才是零扩展。

---

## 第11章 验证方法

### 11.0 本章概述

RISC-V ISA 验证的关键思想是：硬件执行结果要和 ISA reference model 一致。微架构内部可以很复杂，但提交到软件可见状态的结果必须正确。

### 11.1 directed test

directed test 适合覆盖明确边界：

- 每条指令的基本功能。
- 正负立即数。
- x0 写屏蔽。
- signed/unsigned 比较差异。
- branch taken/not taken。
- JAL/JALR 返回地址。
- load byte/halfword/word 扩展。
- store byte enable。
- illegal instruction。
- misaligned access。

示例测试思想：

```text
1. 把 x1 设置为 -1。
2. 把 x2 设置为 1。
3. 执行 SLT x3, x1, x2，期望 x3 = 1。
4. 执行 SLTU x4, x1, x2，期望 x4 = 0。
```

这个测试能抓 signed/unsigned 比较混用。

### 11.2 random test

random test 可以随机生成指令序列，再用 ISS 或 reference model 比对结果。

关键问题：

- 随机指令必须合法，或者非法时 reference model 也要能处理。
- memory 地址要受约束，避免访问无效区域。
- 分支和跳转要避免跑飞，或使用受控代码块。
- self-checking 程序要能把结果写到约定地址。
- 随机测试要能复现，必须记录 seed。

### 11.3 scoreboard

处理器验证的 scoreboard 通常比较：

- 每条提交指令的 PC。
- 指令编码。
- 写回 rd。
- 写回数据。
- memory 访问地址。
- memory 读写数据。
- exception 类型。
- next PC。

简单顺序核可以逐条比对。乱序核则要按 commit 顺序比对，而不是按执行完成顺序。

### 11.4 coverage

功能覆盖率应包含：

- opcode 覆盖。
- funct3/funct7 覆盖。
- rd/rs1/rs2 是否覆盖 x0 和非 x0。
- immediate 边界值。
- branch taken/not taken。
- branch 正偏移/负偏移。
- load/store 各宽度和地址低位。
- signed/unsigned 比较。
- illegal instruction 类别。

代码覆盖率高不代表 ISA 正确。必须有功能覆盖率和 reference model 比对。

### 11.5 SVA 断言示例

以下是简化断言思想，实际信号名需按设计调整。

```systemverilog
// 不可综合：验证断言
property p_x0_always_zero;
  @(posedge clk) disable iff (!rst_n)
    rf_x0_value == '0;
endproperty

assert property (p_x0_always_zero);

property p_write_x0_blocked;
  @(posedge clk) disable iff (!rst_n)
    commit_valid && commit_reg_we && (commit_rd == 5'd0) |-> (commit_wdata == '0);
endproperty

assert property (p_write_x0_blocked);
```

注意第二条只是示意。有些设计对写 x0 的 commit_wdata 仍会产生非零值，但 register file 不写入。更严谨的断言应该检查架构状态中 x0 保持为 0。

---

## 第12章 常见 bug、边界条件和 debug

### 12.0 高频 RTL bug

| bug | 典型后果 | 定位方法 |
|---|---|---|
| B-type 立即数拼错 | 分支跳到错误位置 | 打印 PC trace，对比反汇编 |
| J-type 立即数拼错 | 函数调用或长跳转失败 | directed test 跳转前后标签 |
| x0 被写入 | 程序随机崩溃 | 断言 x0 恒为 0 |
| signed/unsigned 混用 | 比较类测试失败 | 专门测试 `-1` 与 `1` |
| JALR 未清 bit 0 | 跳转到奇地址 | 检查 target 低位 |
| LB/LBU 扩展错 | 字节数据符号错误 | memory pattern 测试 |
| store mask 错 | 相邻字节被破坏 | byte lane 覆盖 |
| illegal instruction 没处理 | 跑飞或误执行 | 随机非法编码 |
| FENCE 随意忽略 | 外设顺序错误 | MMIO 顺序测试 |
| RV64I word 操作扩展错 | 64 位软件异常 | 32 位结果到 64 位扩展测试 |

### 12.1 PC trace debug

处理器 debug 最重要的输出之一是 PC trace。

建议仿真时打印：

```text
cycle, pc, inst, rd, wdata, mem_addr, mem_we, exception
```

配合 disassembler，可以快速定位：

- 第一条执行错误指令。
- branch 是否跳错。
- load/store 是否访问错地址。
- 写回数据是否错误。

### 12.2 最小化复现

遇到随机测试失败，不要直接看几万条指令波形。更有效的方法：

1. 保存 random seed。
2. 找到第一条架构状态不一致的 commit。
3. 截取该点前几十条指令。
4. 用反汇编看数据依赖。
5. 构造 directed test 复现。

### 12.3 规格不清比 RTL bug 更危险

入门项目常犯的错误是“先写 RTL，后想规格”。建议在写 RISC-V 核前先明确：

- 支持 RV32I 还是 RV64I。
- 是否支持 M extension。
- 是否支持 C extension。
- reset vector 是多少。
- 非对齐访存如何处理。
- illegal instruction 如何处理。
- memory map 如何规划。
- 是否有 CSR。
- FENCE 如何处理。
- ECALL/EBREAK 如何处理。

规格写清楚，验证才知道什么是正确。

---

## 第13章 面试问法、练习题与答案要点

### 13.0 高频面试问法

#### 问题1：ISA 和微架构区别是什么

简洁答案：

```text
ISA 是软件可见规范，定义寄存器、指令编码、指令语义、访存、异常中断等。
微架构是硬件实现方式，比如几级流水、是否有 cache、旁路、分支预测和执行单元数量。
同一 ISA 可以有不同微架构。
```

深入追问：

```text
验证时 ISA 级检查关注提交后的 PC、寄存器、memory 和 exception 是否符合 reference model；
微架构检查还要关注 pipeline stall、flush、hazard、内部状态机和时序路径。
```

#### 问题2：RISC-V 为什么是 load/store 架构

答案要点：

- 算术指令只操作寄存器，memory 访问集中在 load/store。
- 指令格式和执行单元更规整。
- pipeline 中 EX 做地址计算，MEM 做访存，边界清楚。
- 代价是某些程序需要更多数据搬运指令。

#### 问题3：RISC-V 有哪些基础指令格式

答案要点：

- R-type：寄存器-寄存器运算。
- I-type：立即数运算、load、JALR。
- S-type：store。
- B-type：branch。
- U-type：LUI/AUIPC。
- J-type：JAL。

#### 问题4：为什么 B-type/J-type 立即数不连续

答案要点：

- 保持寄存器字段位置规整，简化译码和 register file 读地址生成。
- 跳转偏移低位隐含为 0。
- 硬件需要 immediate generator 拼接，但主数据字段稳定。

#### 问题5：x0 怎么实现

答案要点：

- 读 x0 恒为 0，写 x0 无效。
- register file 可以不存 x0，也可以存但写使能屏蔽。
- 断言和 directed test 要覆盖写 x0 后仍读 0。

#### 问题6：JAL 和 JALR 区别

答案要点：

- JAL 使用 J-type PC 相对立即数跳转。
- JALR 使用 rs1 + I-type immediate 计算目标，并清除最低位。
- 二者都把 `pc + 4` 写入 rd，rd 为 x0 时不保存返回地址。

#### 问题7：LB 和 LBU 区别

答案要点：

- LB 读取 8 bit 后符号扩展。
- LBU 读取 8 bit 后零扩展。
- LH/LHU 同理。

### 13.1 练习题

#### 练习1：写出 B-type 立即数拼接

题目：

```text
给定 inst[31:0]，写出 RV32I B-type immediate 的拼接方式。
```

答案要点：

$$
imm_B = \operatorname{sign\_extend}(\{inst[31], inst[7], inst[30:25], inst[11:8], 1'b0\})
$$

#### 练习2：解释 `ADDI x0, x0, 0`

答案要点：

- rs1 是 x0，读出 0。
- immediate 是 0。
- 结果写 rd=x0，但写 x0 无效。
- 架构状态不变，因此可作为 NOP。

#### 练习3：判断 signed/unsigned 比较

题目：

```text
x1 = 32'hFFFF_FFFF，x2 = 32'h0000_0001。
SLT x3, x1, x2 和 SLTU x4, x1, x2 的结果分别是什么？
```

答案：

- SLT 把 x1 看成 -1，`-1 < 1`，所以 x3 = 1。
- SLTU 把 x1 看成 4294967295，`4294967295 < 1` 为假，所以 x4 = 0。

#### 练习4：store byte 写掩码

题目：

```text
32 bit little-endian memory 总线，执行 SB，地址低两位为 2'b10，应该使能哪个 byte lane？
```

答案要点：

- 地址低两位为 2，写第 2 个 byte lane。
- write enable 通常为 `4'b0100`。
- write data 要把 `rs2[7:0]` 放到对应 byte lane。

## 第14章 与其他章节的关联

### 14.0 必须回看的章节

- `0802 RISC-V五级流水线与Hazard.md`：把本篇 ISA 语义放进 IF/ID/EX/MEM/WB，理解 forwarding、stall、flush 如何保持 ISA 结果不变。
- `0803 CSR、异常中断与特权级.md`：继续扩展 CSR、ECALL/EBREAK、illegal instruction、misaligned access、trap 和 privilege。
- `0804 RISC-V SoC、MMIO与外设互联.md`：继续看 load/store 如何通过 memory map 访问 boot ROM、SRAM、flash、MMIO 外设、storage controller 和中断控制器。
- `0805 Cache、TLB、MMU、分支预测与内存模型.md`：继续看 cache、DRAM、地址转换、cacheable/device 属性、page fault、FENCE 和 branch prediction。
- `0806 高级微架构基础：乱序、ROB与执行后端.md`：理解同一 ISA 如何被乱序、rename、ROB、LSQ 等更复杂微架构实现。

### 14.1 和前置基础的关系

- `020x` RTL/SystemVerilog：字段提取、case decode、寄存器堆、组合/时序逻辑写法是实现 ISA 的基础。
- `030x` FSM/流水线/握手：PC redirect、stall、flush、valid bit 都依赖通用控制结构。
- `040x` 运算数据通路：ALU、shifter、comparator、乘除法扩展需要算术模块基础。
- `060x/070x` 存储器和总线：load/store、byte lane、write mask、memory transaction 需要存储和互联知识支撑。
- `100x` 验证专题：ISA reference model、directed/random test、scoreboard、coverage 是处理器验证闭环。

### 14.2 学习路径建议

学完本篇后，不建议直接跳到乱序核。更稳的顺序是：

```text
0801 ISA
  -> 0802 五级流水线与 hazard
  -> 0803 CSR/trap/privilege
  -> 0804 SoC/MMIO/外设互联/boot 与 storage
  -> 0805 cache/TLB/MMU/分支预测/内存模型
  -> 0806 乱序、ROB 与执行后端
```

这样能先建立“软件可见语义”和“程序/数据住在哪里”的直觉，再逐步增加流水线、系统、存储层次和高级微架构复杂度。

## 第15章 本篇总结

RISC-V ISA 的学习重点不是机械背编码表，而是理解软件可见行为如何约束硬件：

- 指令格式决定 decode。
- immediate 决定地址和 PC。
- GPR/x0 决定 register file 行为。
- 程序、用户数据、ROM/RAM/flash 和 MMIO 的区别决定 load/store 背后可能访问什么系统资源。
- load/store 决定 LSU。
- branch/JAL/JALR 决定 next PC。
- illegal instruction、ECALL、misaligned access 决定 exception 入口。
- 扩展命名决定支持边界。

把这些掌握清楚，再学习五级流水线和 hazard 时，就能区分“ISA 要求的最终结果”和“微架构为了得到结果所做的内部控制”。
