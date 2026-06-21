# 汇编仿真流程

本文档说明 RV32I 教学核的汇编测试如何编译、生成 IMEM 镜像并通过 Verilator 运行。

---

## 1. 仿真命令

### 1.1 core-only 仿真（不含 MMIO）

```bash
# 编译汇编 → .mem
sim/pipeline5_asm/05_build_mem.sh <test>

# 构建 Verilator 仿真 + 运行
sim/pipeline5_asm/06_run_sim.sh <test>

# 两步合一
sim/pipeline5_asm/run_test.sh <test>

# 回归全部 core-only 汇编测试
sim/pipeline5_asm/run_all.sh
```

`<test>` 可以是四位编号或完整 basename，例如：

```bash
sim/pipeline5_asm/run_test.sh 0303
sim/pipeline5_asm/run_test.sh 0303_pipeline5_fwd_redirect
```

### 1.2 SoC 仿真（含 MMIO 外设）

```bash
sim/soc_asm/run_test.sh <test>
sim/soc_asm/run_all.sh
```

SoC 测试（06xx）必须使用 `sim/soc_asm/`，因为 MMIO 译码和外设在 core-only 环境下不存在。

## 2. 仿真流程

单测试脚本分两步：

```text
sw/asm/<test>.S
  ↓ riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32
build/<test>.elf
  ↓ objdump
build/<test>.dump
  ↓ objcopy + scripts/bin2mem32.py
build/<test>.mem
  ↓ Verilator tb_core_pipeline5 / tb_rv32i_soc + simple_rom/simple_ram
PASS / FAIL / TIMEOUT
```

`05_build_mem.sh` 会使用 `sw/linker/asm_test.ld`，把 `.text.init` 放到复位入口附近，并生成：

| 文件 | 说明 |
|---|---|
| `build/<test>.elf` | 链接后的 ELF |
| `build/<test>.dump` | 反汇编，debug 时优先看它 |
| `build/<test>.bin` | 裸二进制 |
| `build/<test>.mem` | `$readmemh` 使用的 32-bit word 镜像 |

仿真脚本按平台收集 RTL 文件：

**core-only（sim/pipeline5_asm/）：**
```
rtl/common/*.sv
rtl/core/*.sv
rtl/mem/*.sv
```

**SoC（sim/soc_asm/）：**
```
rtl/common/*.sv
rtl/core/*.sv
rtl/mem/*.sv
rtl/periph/*.sv
rtl/soc/*.sv
```

## 3. 汇编测试分组

### 3.1 测试分组总览

| 分组 | 编号 | 关注点 | 仿真平台 |
|------|------|--------|---------|
| `00xx` | `0001_smoke.S` | 最小取指、执行、访存、PASS/FAIL | core-only |
| `01xx` | `0101`～`0106` | 基础 RV32I 指令语义 | core-only |
| `03xx` | `0301`～`0303` | data/control hazard | core-only |
| `05xx` | `0501`～`0503` | trap entry、全异常、CSR 指令 | core-only |
| `06xx` | `0601`～`0606` | SoC 冒烟、UART、GPIO、MMIO fault/优先级/wrong-path | SoC |

### 3.2 branch/JAL/JALR 已支持

control hazard flush（redirect 时清空 IF/ID、ID/EX）已在 v2.0 实现。branch/JAL/JALR 可在流水线测试中正常使用。

## 4. 调试注意事项

- 加新 .sv 文件到 `rtl/` 下后，对应平台的仿真脚本会自动纳入 Verilator 输入；新增 testbench 仍需手动选择。
- 流水线的 commit trace 有固定流水线延迟，第一条正常提交指令通常在复位释放后的数拍之后出现。
- 如果看到非法指令提交，先检查 redirect flush 是否没有正确清掉错误路径指令，或测试程序是否跳到了未初始化 ROM 区域。
- 仿真结束时会打印 `DMEM access range` 和 `Stack max used`。汇编测试通常不初始化 `sp`，所以栈统计可能显示 `SP not initialized to stack top`；DMEM 范围已排除 `TEST_STATUS_ADDR` 的 PASS/FAIL 写入。
