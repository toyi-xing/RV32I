# RV32I Teaching Core

本仓库是一个 RV32I 教学核实现仓库，当前维护对象是五级流水线顶层 `core.sv`，已完成最小 M-mode CSR/trap 支持。

工程架构说明见 `docs/08xx/` 下的 082x 系列文档。支持的指令见 `docs/08xx/0821 RV32I最小教学核指令集、编码与译码参考.md`。CSR/trap 设计见 `docs/08xx/0831 最小M-mode CSR与trap规划.md`。

---

## 目录结构

| 目录 | 说明 |
|------|------|
| `rtl/` | RTL 源码（core_pkg、pipeline_pkg、core 各阶段模块、memory 封装） |
| `tb/` | testbench（当前维护五级流水线 testbench） |
| `sim/` | 编译和仿真脚本（按汇编/C 分目录） |
| `sw/` | 汇编和 C 裸机测试程序 |
| `scripts/` | 辅助脚本（bin2mem32 等） |
| `build/` | 编译产物（.elf、.dump、.bin、.mem） |
| `docs/` | 说明文档 |

---

## 项目时间戳

| 核 | 顶层 | 状态 | release 版本 | 备注 |
|---|------|------|------|------|
| 单周期 RV32I | `core_single_cycle.sv` | 历史版本已完成，当前不再维护 | v1.0 | 最终兼容版本为 v2.0，自 v2.10 起删除该文件 |
| 五级流水线 RV32I（data hazard + control hazard） | `core_pipeline5.sv` | 已完成 | v2.0 | 后续开发持续在该文件上累积 |
| 五级流水线 RV32I（CSR/exception trap） | `core_pipeline5.sv` | 已完成 | v3.0 | 自 v3.4 起，将 `core_pipeline5.sv` 改名为 `core.sv` |

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
rtl/common/core_pkg.sv               # ISA/CSR/trap 常量与枚举
rtl/common/pipeline_pkg.sv           # 流水线寄存器 struct 和 forwarding 类型
rtl/core/core.sv                     # 五级流水顶层
rtl/core/pipe_reg.sv                 # 四组流水线寄存器
rtl/core/forwarding_unit.sv          # RAW 数据前递
rtl/core/hazard_unit.sv              # load-use/CSR-use stall + EX redirect 控制
rtl/core/csr_file.sv                 # 最小 M-mode CSR 文件
rtl/core/trap_ctrl.sv                # trap/MRET 接受、重定向和 kill 控制
rtl/core/*_stage.sv                  # IF/ID/EX/MEM/WB 阶段组合逻辑
rtl/mem/simple_rom.sv                # 指令 ROM
rtl/mem/simple_ram.sv                # 数据 RAM
```

**Testbench：** `tb/sv/tb_core_pipeline5.sv`

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

# trap 测试（手动运行）
sw/asm/0501_trap_entry_smoke.S                # ECALL trap entry smoke
sw/asm/0502_exception_full.S                  # 全同步异常总测试（9 个 step）
sw/asm/0503_csr_instr_test.S                  # 6 个 CSR 指令读写 CSR 寄存器测试
```

**C 测试程序：**
```
sw/c/0201_c_smoke.c                           # 最小冒烟
sw/c/0202_dmem_init.c                         # .data/.bss/.rodata 初始化
sw/c/0401_control_mix.c                       # 综合控制流 + 内存操作
sw/c/0551_trap_smoke.c                        # C 侧 trap handler smoke
```

**仿真脚本：** `sim/pipeline5_asm/`、`sim/pipeline5_c/`

### 当前特性

- **37 条 RV32I 指令**：完整 ALU、分支、跳转、访存、LUI/AUIPC。
- **五级流水线**：IF/ID/EX/MEM/WB。
- **数据 hazard**：forwarding（EX/MEM、MEM/WB）+ load-use stall。
- **控制 hazard**：branch/JAL/JALR redirect flush + wrong-path kill。
- **CSR**：6 条 Zicsr 指令（CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI），最小 M-mode CSR（mstatus/mtvec/mscratch/mepc/mcause/mtval + 只读 CSR）。
- **同步异常**：instruction address misaligned、illegal instruction、breakpoint、load/store address misaligned、ECALL/EBREAK from M-mode。
- **MRET**：trap handler 返回。
- **trap 精确提交**：在 MEM 边界接受，kill 年轻指令，不影响 older instruction。

### 仿真命令

```bash
# —— 所有汇编程序回归仿真 ——
sim/pipeline5_asm/run_all.sh

# —— C 仿真 ——
sim/pipeline5_c/run_test.sh <n>            # n 表示 sw/c 下 c 程序前的四位编码

# —— 汇编仿真 ——
sim/pipeline5_asm/run_test.sh <m>          # m 表示 sw/asm 下 汇编程序前的四位编码
```

汇编仿真详细流程见 [docs/simulation_flow_pipeline_asm.md](docs/simulation_flow_pipeline_asm.md)。C 仿真流程见 [docs/simulation_flow_pipeline_c.md](docs/simulation_flow_pipeline_c.md)。

---

## 编写新测试

在 `sw/asm/` 下创建 `.S` 文件，然后：

```bash
sim/pipeline5_asm/run_test.sh <四位编号或完整basename>
```

在 `sw/c/` 下创建 `.c` 文件后运行：

```bash
sim/pipeline5_c/run_test.sh <四位编号或完整basename>
```

汇编测试编写规范见 `sw/asm/readme.md`。

c 程序编写方法见 `sw/c/readme.md`。
