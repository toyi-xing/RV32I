# 五级流水线汇编仿真流程

本文档说明当前五级流水线 core 的汇编测试如何编译、生成 IMEM 镜像并通过 Verilator 运行。

---

## 1. 仿真命令

```bash
# 编译汇编 → .mem
sim/pipeline5_asm/05_build_mem.sh <test>

# 构建 Verilator 仿真 + 运行
sim/pipeline5_asm/06_run_sim.sh <test>

# 两步合一
sim/pipeline5_asm/run_test.sh <test>

# 回归全部汇编测试（10 个：分指令类型 7 个 + 流水线 3 个）
sim/pipeline5_asm/run_all.sh
```

`<test>` 可以是四位编号或完整 basename，例如：

```bash
sim/pipeline5_asm/run_test.sh 0303
sim/pipeline5_asm/run_test.sh 0303_pipeline5_fwd_redirect
```

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
  ↓ Verilator tb_core_pipeline5 + simple_rom/simple_ram
PASS / FAIL / TIMEOUT
```

`05_build_mem.sh` 会使用 `sw/linker/asm_test.ld`，把 `.text.init` 放到复位入口附近，并生成：

| 文件 | 说明 |
|---|---|
| `build/<test>.elf` | 链接后的 ELF |
| `build/<test>.dump` | 反汇编，debug 时优先看它 |
| `build/<test>.bin` | 裸二进制 |
| `build/<test>.mem` | `$readmemh` 使用的 32-bit word 镜像 |

`06_run_sim.sh` 会构建 `tb_core_pipeline5`，RTL 文件按目录收集：

```bash
rtl/common/*.sv
rtl/core/*.sv
rtl/mem/*.sv
```

testbench 仍显式只编译 `tb/sv/tb_core_pipeline5.sv`，不会自动把其他 testbench 一起加入。

## 3. 汇编测试分组

### 3.1 测试关注点不同

| 分组 | 文件 | 关注点 |
|---|---|---|
| `00xx` | `0001_smoke.S` | 最小取指、执行、访存、PASS/FAIL |
| `01xx` | `0101`～`0106` | 基础 RV32I 指令语义 |
| `03xx` | `0301`～`0303` | data/control hazard |
| `05xx` | `0501_trap_entry_smoke.S` | trap entry smoke，当前手动运行 |

### 3.2 branch/JAL/JALR 已支持

control hazard flush（redirect 时清空 IF/ID、ID/EX）已在 v2.0 实现。branch/JAL/JALR 可在流水线测试中正常使用。

### 3.3 可用的测试文件

| 文件 | 前置条件 | 描述 |
|------|---------|------|
| `0001_smoke.S` | 基础数据通路 | 最小冒烟 |
| `0101_branch.S`～`0106_u_type.S` | 基础 RV32I | 分组覆盖 branch/ALU/load-store/jump/U-type |
| `0301_pipeline5_nofwd_noredirect.S` | 空壳数据通路 | 手工 3 NOP 隔离 RAW，验证 pipeline 基础通路 |
| `0302_pipeline5_fwd_noredirect.S` | forwarding + load-use stall | 所有 data hazard 由硬件解决，无需 RAW 隔离 NOP |
| `0303_pipeline5_fwd_redirect.S` | forwarding + control hazard | forwarding + redirect 混合：分支操作数前递、load-use 后紧跟分支、JAL/JALR wrong-path kill、JALR bit0 清零 |
| `0501_trap_entry_smoke.S` | CSR/trap RTL 已集成 | ECALL 触发 trap entry，handler 写 PASS；当前不放入 `run_all.sh` |

## 4. 调试注意事项

- 加新 .sv 文件到 `rtl/common/`、`rtl/core/`、`rtl/mem/` 后，pipeline5 脚本会自动纳入 Verilator 输入；新增 testbench 仍需手动选择。
- 流水线的 commit trace 有固定流水线延迟，第一条正常提交指令通常在复位释放后的数拍之后出现。
- 如果看到非法指令提交，先检查 redirect flush 是否没有正确清掉错误路径指令，或测试程序是否跳到了未初始化 ROM 区域。
- 仿真结束时会打印 `DMEM access range` 和 `Stack max used`。汇编测试通常不初始化 `sp`，所以栈统计可能显示 `SP not initialized to stack top`；DMEM 范围已排除 `TEST_STATUS_ADDR` 的 PASS/FAIL 写入。
