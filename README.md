# RV32I Teaching Core

本仓库是一个 RV32I 教学核实现仓库，历史上包含**单周期**和**五级流水线**两套顶层；当前维护对象是五级流水线顶层 `core_pipeline5.sv`。

工程架构说明见 `docs/08xx/` 下的 082x 系列文档。支持的指令见 `docs/08xx/0821 RV32I最小教学核指令集、编码与译码参考.md`。

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
| 五级流水线 RV32I（data hazard + control hazard） | `core_pipeline5.sv` | 当前维护 | v2.0 | 后续开发持续在该文件上累积 |

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
rtl/core/core_pipeline5.sv           # 五级流水顶层
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

**测试程序：**
```
sw/asm/0301_pipeline5_nofwd_noredirect.S      # 不依赖 forwarding/redirect 的基线冒烟
sw/asm/0302_pipeline5_fwd_noredirect.S        # data hazard 全覆盖
sw/asm/0303_pipeline5_fwd_redirect.S          # forwarding + control hazard 混合
sw/asm/0501_trap_entry_smoke.S                # trap entry smoke，手动运行
```

**C 测试程序：**
```
sw/c/0201_c_smoke.c                           # 最小冒烟
sw/c/0401_control_mix.c                       # 综合控制流 + 内存操作
```

**仿真脚本：** `sim/pipeline5_asm/`、`sim/pipeline5_c/`

### 仿真命令

```bash
# 跑单个流水线汇编测试
sim/pipeline5_asm/run_test.sh 0102
sim/pipeline5_asm/run_test.sh 0301
sim/pipeline5_asm/run_test.sh 0302
sim/pipeline5_asm/run_test.sh 0303

# 跑当前汇编回归列表
sim/pipeline5_asm/run_all.sh

# 跑 C 测试
sim/pipeline5_c/run_test.sh 0201
sim/pipeline5_c/run_test.sh 0401
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
