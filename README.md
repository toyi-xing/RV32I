# RV32I Teaching Core

本仓库是一个 RV32I 教学核实现仓库，包含**单周期**和**五级流水线**两套顶层，均通过 Verilator 仿真验证。

工程架构说明见 `docs/08xx/` 下的 082x 系列文档。支持的指令见 `docs/08xx/0821 RV32I最小教学核指令集、编码与译码参考.md`。

---

## 目录结构

| 目录 | 说明 |
|------|------|
| `rtl/` | RTL 源码（core_pkg、pipeline_pkg、core 各阶段模块、memory 封装） |
| `tb/` | testbench（单周期 + 流水线各一套） |
| `sim/` | 编译和仿真脚本（按单周期/流水线、汇编/C 分目录） |
| `sw/` | 汇编和 C 裸机测试程序 |
| `scripts/` | 辅助脚本（bin2mem32 等） |
| `build/` | 编译产物（.elf、.dump、.bin、.mem） |
| `docs/` | 说明文档 |

---

## 当前状态

| 核 | 顶层 | 状态 | git 历史版本 |
|---|------|------|------|
| 单周期 RV32I | `core_single_cycle.sv` | 已完成 | v1.0 |
| 五级流水线 RV32I（data hazard + control hazard） | `core_pipeline5.sv` | 已完成 | v2.0 |

---

## 环境依赖

- **RV32I 工具链**：`riscv64-unknown-elf-gcc` 等，将测试程序编译为 .elf 并提取二进制 .bin。
- **Verilator**：SystemVerilog 仿真器
- **Python 3**：运行 `bin2mem32.py`，编译出的裸二进制 .bin 转成每行一个 32-bit hex word 的 .mem 文件。

---

## 单周期核

### 涉及文件

**RTL（15 个文件）：**
```
rtl/common/core_pkg.sv           # ISA 常量与枚举
rtl/core/pc_reg.sv               # PC 寄存器
rtl/core/if_stage.sv             # 取指
rtl/core/id_stage.sv             # 译码
rtl/core/decoder.sv              # 指令译码器
rtl/core/imm_gen.sv              # 立即数生成
rtl/core/regfile.sv              # 通用寄存器堆
rtl/core/ex_stage.sv             # 执行
rtl/core/alu.sv                  # ALU 运算
rtl/core/branch_unit.sv          # 分支跳转判断
rtl/core/mem_stage.sv            # 访存
rtl/core/wb_stage.sv             # 写回
rtl/core/core_single_cycle.sv    # 单周期顶层
rtl/mem/simple_rom.sv            # 指令 ROM
rtl/mem/simple_ram.sv            # 数据 RAM
```

**Testbench：** `tb/sv/tb_core_single_cycle.sv`

**汇编测试程序：** (sw/asm/) `smoke.S`、`alu_imm.S`、`alu_reg.S`、`load_store.S`、`branch.S`、`jump.S`、`u_type.S`，须搭配 asm 链接程序 `sw/linker/asm_test.ld`

**c测试程序：** (sw/c) `c_smoke.c`、`dmem_init.c`，须搭配 c 启动程序 `sw/c_runtime/crt0.S` 和 c 链接程序 `sw/linker/c_baremetal.ld`

**仿真脚本：** `sim/single_cycle_asm/`，`sim/single_cycle_c/`

### 仿真命令

```bash
# 跑全部单周期汇编测试
sim/single_cycle_asm/run_all.sh

# 跑单个测试
sim/single_cycle_asm/run_test.sh alu_imm

# C 测试
sim/single_cycle_c/run_test.sh c_smoke
```

汇编仿真详细流程见 [docs/simulation_flow_singlecycle_asm.md](docs/simulation_flow_singlecycle_asm.md)。

---

## 五级流水线核

### 涉及文件

单周期的 RTL 全部共用，额外增加以下文件：

**RTL 新增（5 个文件）：**
```
rtl/common/pipeline_pkg.sv           # 流水线专用类型（struct、fwd_sel 枚举）
rtl/core/core_pipeline5.sv           # 五级流水顶层（代替 core_single_cycle）
rtl/core/pipe_reg.sv                 # 四组流水线寄存器
rtl/core/forwarding_unit.sv          # RAW 数据前递
rtl/core/hazard_unit.sv              # load-use stall + redirect flush/kill 控制
```

**Testbench：** `tb/sv/tb_core_pipeline5.sv`

**测试程序：**
```
sw/asm/pipeline5_nofwd_noredirect.S      # 无 forwarding/redirect 基线冒烟
sw/asm/pipeline5_fwd_noredirect.S        # data hazard 全覆盖
sw/asm/pipeline5_fwd_redirect.S          # forwarding + control hazard 混合
```

**C 测试程序：**
```
sw/c/c_smoke.c                           # 最小冒烟
sw/c/control_mix.c                       # 综合控制流 + 内存操作
```

**仿真脚本：** `sim/pipeline5_asm/`、`sim/pipeline5_c/`

### 仿真命令

```bash
# 跑流水线测试
sim/pipeline5_asm/run_test.sh pipeline5_nofwd_noredirect
sim/pipeline5_asm/run_test.sh pipeline5_fwd_noredirect
sim/pipeline5_asm/run_test.sh pipeline5_fwd_redirect
sim/pipeline5_c/run_test.sh control_mix
```

---

## 编写新测试

### 单周期

在 `sw/asm/` 下创建 `.S` 文件，然后：

```bash
sim/single_cycle_asm/run_test.sh <test>
```

流水线同理：

```bash
sim/pipeline5_asm/run_test.sh <test>
```

汇编测试编写规范见 `sw/asm/readme.md`。
