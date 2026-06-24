# RV32I SoC

本仓库是一个 RV32I SoC 实现仓库，维护对象包括五级流水线核 `core.sv`、MMIO 外设（GPIO/UART/TIMER32）、SoC 集成顶层 `rv32i_soc.sv` 及 SoC 级 testbench。已完成最小 M-mode CSR/trap、MMIO 地址图及外设、machine timer/external interrupt 支持。

## 当前特性（已经过定向验证）

- **40 条 RV32I 指令**：完整 ALU、分支、跳转、访存、LUI/AUIPC、FENCE（当前为 nop）、ECALL、EBREAK 全量支持。
- **五级流水线**：IF/ID/EX/MEM/WB 经典五级流水线结构。
- **数据 hazard**：forwarding（EX/MEM、MEM/WB）+ load-use stall + CSR-use stall。
- **控制 hazard**：branch/JAL/JALR/trap redirect flush + wrong-path kill。
- **CSR 寄存器及访问指令**：6 条 Zicsr 指令（CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI），最小 M-mode CSR（mstatus/mtvec/mscratch/mepc/mcause/mtval + 只读 CSR）。
- **同步异常**：instruction address misaligned、illegal instruction、breakpoint、load/store address misaligned、 load/store access fault、ECALL/EBREAK from M-mode。
- **MRET**：trap handler 返回。
- **trap 精确提交**：在 MEM 边界接受，kill 年轻指令，不影响 older instruction。
- **MMIO 地址图及外设**：GPIO0、UART0、TIMER0 已集成于 data_subsystem，寄存器 ABI 见 `rtl/periph/readme.md`，SoC 地址图规划在 `soc_pkg.sv`，平台常量见 `sw/include/platform.h`。
- **MMIO access fault**：未实现外设或预留地址空间访问触发 load/store access fault。
- **machine timer interrupt**：TIMER0.MTIME ≥ MTIMECMP 触发 MTIP，level pending 输出到 mtip_o。
- **machine external interrupt**：GPIO 按 bit 独立配置边沿/电平触发、UART RX 事件，汇总为 MEIP（中断优先级 MEIP > MTIP）。
- **中断精确提交**：CSR 写同拍中断接受、MRET 同拍中断重入、mepc 记录当前提交边界的 interrupt return PC。
- **设计可综合**：CPU 核及子模块采用可综合 rtl 编写；综合对象为 CPU 核顶层 `core.sv`，综合结果不作为项目重点。SoC 侧 MEM 单元为仿真内存模型，MMIO 外设模型为简化模型，未面向真实 IO 单元、真实串口协议或 PPA 做优化。

---

## 验证能力

- **SoC 级程序自检定向测试**：汇编/C 测试程序通过 PASS/FAIL 状态字结束仿真，覆盖 ISA、流水线 hazard、trap/CSR、MMIO 和 machine interrupt 场景。
- **TB mailbox 外部激励协议**：`sw/include/tb_rv32i_soc_test.h` 与 `tb/sv/tb_rv32i_soc.sv` 约定保留 DMEM store 命令，由测试程序按自身进度请求 testbench 驱动 GPIO 输入、UART RX 事件。该协议只属于当前 testbench，不是 SoC 真实 MMIO ABI。
- **interrupt directed test**：覆盖 timer interrupt、GPIO/UART external interrupt、MEIP/MTIP 优先级、CSR 写同拍中断、MRET 同拍中断重入和周期 GPIO 输入测量。

---

## 系统架构

```
+----------------------------------------------------------------------------------+
|                                    rv32i_soc                                     |
|                                                                                  |
|  +-----------------------+    instr     +-------------------------------------+  |
|  | simple_rom / IMEM     | -----------> | core.sv                             |  |
|  | 0x0000_0000  256 KiB  |              | RV32I 5-stage pipeline              |  |
|  +-----------------------+              | IF / ID / EX / MEM / WB             |  |
|                                         | fwd + stall + redirect              |  |
|                                         | CSR + trap + precise interrupt      |  |
|                                         +-------------------+-----------------+  |
|                                                             | LSU load/store     |
|                                                             v                    |
|  +----------------------------------------------------------------------------+  |
|  | data_subsystem: fixed DMEM/MMIO decoder                                    |  |
|  |                                                                            |  |
|  |  0x0004_0000  DMEM    simple_ram 256 KiB                                   |  |
|  |  0x0008_0000  GPIO0   OUT / IN / OE / edge-level IRQ  ---+                 |  |
|  |  0x0008_2000  UART0   single-cycle TX/RX + IRQ        ---+--> MEIP         |  |
|  |  0x0008_1000  TIMER0  MTIME / MTIMECMP level IRQ     --------> MTIP        |  |
|  +----------------------------------------------------------------------------+  |
|                                                                                  |
|  observable: commit / trap / data bus / GPIO / UART / IRQ                        |
+-----------------------------------------+----------------------------------------+
                                          ^
                                          | TB mailbox
                                          v
+-----------------------------------------+----------------------------------------+
| tb_rv32i_soc                                                                     |
| memory images | PASS/FAIL monitor | commit/trap trace                            |
| TB mailbox store commands -> GPIO input stimulus / UART RX event                 |
+----------------------------------------------------------------------------------+
```

---

## 目录结构

| 目录 | 说明 |
|------|------|
| `rtl/` | RTL 源码（core_pkg、pipeline_pkg、core 各阶段模块、memory 封装） |
| `tb/` | testbench（当前维护 SoC 级 testbench） |
| `sim/` | 编译和仿真脚本（按汇编/C 分目录） |
| `sw/` | 汇编和 C 裸机测试程序 |
| `scripts/` | 辅助脚本（bin2mem32 等） |
| `build/` | 编译产物（.elf、.dump、.bin、.mem） |
| `docs/` | 说明文档 |

---

## 项目时间戳

| 核（相对于上版本的改动） | 顶层 | 状态 | release 版本 | 备注 |
|---|------|------|------|------|
| 单周期 RV32I | `core_single_cycle.sv` | 历史版本已完成，当前不再维护 | v1.0 | 最终兼容版本为 v2.0，自 v2.10 起删除该文件 |
| 五级流水线 RV32I（data hazard + control hazard） | `core_pipeline5.sv` | 已完成 | v2.0 | 后续开发持续在该文件上累积 |
| 同步异常扩展、CSR 与最小特权级（CSR/exception trap） | `core_pipeline5.sv` | 已完成 | v3.0 | 自 v3.4 起，将 `core_pipeline5.sv` 改名为 `core.sv` |
| 增加 MMIO 最简外设与 SoC 平台集成 | CPU 核 `core.sv` + SoC 平台 `rv32i_soc` | 已完成 | v4.0 | 自 v4.10 起，删除旧的 CPU 核测试平台 `tb_core_pipeline5.sv` |
| machine interrupt、TIMER32 与外部中断 | CPU 核 `core.sv` + SoC 平台 `rv32i_soc` | 已完成 | v5.0 | - |

---

## 环境依赖

- **RV32I 工具链**：`riscv64-unknown-elf-gcc` 等，将测试程序编译为 .elf 并提取二进制 .bin。
- **Verilator**：SystemVerilog 仿真器
- **Python 3**：运行 `bin2mem32.py`，编译出的裸二进制 .bin 转成每行一个 32-bit hex word 的 .mem 文件。

---

## 五级流水线核

### 涉及文件

**RTL：**
```
rtl/common/          # 核与 SoC 公共常量/枚举/类型（core_pkg、pipeline_pkg、soc_pkg）
rtl/core/            # 五级流水线核（IF/ID/EX/MEM/WB、forwarding、hazard、CSR、trap）
rtl/mem/             # memory 封装（simple_rom 指令 ROM、simple_ram 数据 RAM）
rtl/periph/          # MMIO 外设（mmio_gpio、mmio_uart、mmio_timer32）
rtl/soc/             # SoC 集成（data_subsystem 总线译码、rv32i_soc 顶层）
```

**Testbench：** 

- `tb/sv/tb_rv32i_soc.sv`：集成 MMIO 最小外设的 SoC 测试平台。

**汇编测试程序：**
```
# 基础 ISA 测试
sw/asm/0001_smoke.S                           # 最小冒烟
sw/asm/0101_branch.S                          # 分支指令
sw/asm/0102_alu_imm.S                         # ALU 立即数
sw/asm/0103_alu_reg.S                         # ALU 寄存器
sw/asm/0104_load_store.S                      # 访存指令
sw/asm/0105_jump.S                            # JAL/JALR
sw/asm/0106_u_type.S                          # LUI/AUIPC

# 流水线 data/control hazard 测试
sw/asm/0301_pipeline5_nofwd_noredirect.S      # 不依赖 forwarding/redirect 的基线冒烟
sw/asm/0302_pipeline5_fwd_noredirect.S        # data hazard 全覆盖
sw/asm/0303_pipeline5_fwd_redirect.S          # forwarding + control hazard 混合

# trap 测试
sw/asm/0501_trap_entry_smoke.S                # ECALL trap entry smoke
sw/asm/0502_exception_full.S                  # 全同步异常总测试（9 个 step）
sw/asm/0503_csr_instr_test.S                  # 6 个 CSR 指令读写 CSR 寄存器测试

# SoC/MMIO 测试
sw/asm/0601_soc_smoke.S                       # SoC 级别冒烟
sw/asm/0602_uart_tx.S                         # UART TX 发送字符
sw/asm/0603_gpio_rw.S                         # GPIO OUT/OE/IN 读写
sw/asm/0604_mmio_access_fault.S               # MMIO 未实现外设 access fault
sw/asm/0605_mmio_misaligned_priority.S        # misaligned MMIO 访问优先级
sw/asm/0606_wrong_path_mmio.S                 # wrong-path MMIO 不提交

# interrupt 测试
sw/asm/0705_interrupt_commit_precise.S        # CSR 写同拍中断精确提交
sw/asm/0706_mret_interrupt_reentry.S          # MRET 同拍中断重入
```

**C 测试程序：**
```
sw/c/0201_c_smoke.c                           # 最小冒烟
sw/c/0202_dmem_init.c                         # .data/.bss/.rodata 初始化
sw/c/0401_control_mix.c                       # 综合控制流 + 内存操作
sw/c/0551_trap_smoke.c                        # C 侧 trap handler smoke
sw/c/0651_soc_mmio_smoke.c                    # SoC MMIO 冒烟（GPIO/UART/access fault）
sw/c/0652_soc_mmio_gpio_uart.c                # SoC MMIO 综合测试（GPIO bit 操作/UART 多字符串）
sw/c/0751_timer_smoke.c                       # TIMER0 定时器中断 smoke（C trap handler + level pending 清除）
sw/c/0752_gpio_irq_basic.c                    # GPIO 外部中断基础行为（4 类触发、IRQ_EN/STATUS/PENDING、W1C）
sw/c/0753_uart_rx_irq.c                       # UART RX 中断（TB 注入、rx_irq_enable 门控、读清与 W1C 差异）
sw/c/0754_external_timer_priority.c           # MEIP/MTIP 优先级（同时 pending 优先进 MEIP，清后进 MTIP）
sw/c/0757_gpio_periodic_irq.c                 # TB 固定周期 GPIO 中断精确测量（TIMER0.MTIME + UART 报告）
```

**仿真脚本：** `sim/soc_asm/`、`sim/soc_c/`

当前共 **32 个 directed tests**（汇编 21 + C 11），覆盖 RV32I 指令集、五级流水线 hazard（6 种 RAW forward + load-use stall + redirect）、7 种同步异常、MMIO 外设访问与 access fault、machine timer/external interrupt（GPIO 4 类触发、UART RX、MEIP/MTIP 优先级、CSR 同拍中断、MRET 同拍重入）。

### 仿真命令

```bash
# —— SoC 汇编回归仿真 ——
sim/soc_asm/run_all.sh

# —— SoC C 回归仿真 ——
sim/soc_c/run_all.sh

# —— SoC 单个程序仿真 ——
sim/soc_asm/run_test.sh <n>               # n 表示 sw/asm 下 汇编程序前的四位编码
sim/soc_c/run_test.sh <m>                 # m 表示 sw/c 下 c 程序前的四位编码
```

汇编仿真详细流程见 [docs/simulation_flow_asm.md](docs/simulation_flow_asm.md)。C 仿真流程见 [docs/simulation_flow_c.md](docs/simulation_flow_c.md)。

---

## 编写新测试

在 `sw/asm/` 下创建 `.S` 文件，然后：

```bash
sim/soc_asm/run_test.sh <四位编号或完整basename>
```

在 `sw/c/` 下创建 `.c` 文件后运行：

```bash
sim/soc_c/run_test.sh <四位编号或完整basename>
```

汇编测试集分类见 [sw/asm/readme.md](sw/asm/readme.md)。

c 程序编写方法见 [sw/c/readme.md](sw/c/readme.md)。

MMIO 外设操作手册见 [rtl/periph/readme.md](rtl/periph/readme.md)。

MMIO 地址图镜像查阅见 [sw/linker/readme.md](sw/linker/readme.md)。
