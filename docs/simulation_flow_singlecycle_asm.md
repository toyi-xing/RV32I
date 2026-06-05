# 单周期 Core 仿真流程

本文档按工作顺序说明从"写汇编测试"到"跑仿真看 PASS/FAIL"的完整路径，以及每个文件的角色、依赖关系和变更影响。

---

## 1. 六步总览：从 RTL 到跑通仿真

从写完 RTL 到看到 PASS，共 6 步：

| 步 | 做什么 | 关键产物 | 一句话说明 |
|----|--------|----------|-----------|
| 1 | 写 testbench | `tb/sv/tb_core_single_cycle.sv` | 产生 clk/rst、例化 core+ROM+RAM、打印 commit trace、检测 PASS |
| 2 | 写裸机汇编测试 | `sw/asm/<test>.S` | RV32I 汇编程序，最后往 `DMEM_BASE+0x100` 写 1 表示 PASS |
| 3 | 写汇编测试链接脚本 | `sw/linker/asm_test.ld` | 规定 `.text`→IMEM(0x0)、`.data`→DMEM(0x10000)、`_start` 入口 |
| 4 | 写格式转换脚本 | `scripts/bin2mem32.py` | 把 `.bin` 二进制转成每行一个 32-bit hex word 的 `.mem` |
| 5 | 编译软件生成 memory image | 运行 `05_build_mem.sh` | `.S`→`.elf`→`.dump`→`.bin`→`.mem` |
| 6 | 构建并运行仿真 | 运行 `06_run_sim.sh` | Verilator 编译脚本中列出的 .sv → `+imem=` 加载 .mem → 跑出 PASS/FAIL |

## 2. 文件总览（按工作顺序）

```
                      ┌─────────────────────┐
                      │  sw/asm/<test>.S    │  ← 你写的汇编测试
                      └────────┬────────────┘
                               │
                     riscv64-unknown-elf-gcc  +  sw/linker/asm_test.ld
                               │
                               ▼
                      ┌─────────────────────┐
                      │  build/<test>.elf    │  ← ELF（含符号/段信息）
                      └────────┬────────────┘
                               │
               ┌───────────────┼───────────────┐
               ▼               ▼               ▼
      ┌──────────────┐ ┌──────────────┐ ┌─────────────┐
      │ objdump -d   │ │ objcopy -O   │ │             │
      │              │ │ binary       │ │             │
      ▼              ▼                ▼               │
 ┌──────────┐ ┌──────────┐  ┌──────────┐              │
 │ .dump    │ │ .bin     │  │          │              │
 │ 反汇编    │ │ 二进制    │  │          │              │
 │ 供检查    │ │          │  │          │              │
 └──────────┘ └────┬─────┘  │          │              │
                   │        │          │              │
                   │  scripts/bin2mem32.py            │
                   ▼        │          │              │
             ┌──────────┐   │          │              │
             │ .mem     │◄──┘          │              │
             │ $readmemh│              │              │
             │ 每行word │               │              │
             └────┬─────┘              │              │
                  │                    │              │
                  ▼                    ▼              ▼
      ┌─────────────────────┐  ┌──────────────────────┐
      │  tb/sv/tb_core_     │  │  rtl/core/*.sv       │
      │  single_cycle.sv    │  │  rtl/mem/*.sv        │
      │  (+imem=build/      │  │  rtl/common/core_pkg │
      │   <test>.mem)       │  │                      │
      └──────────┬──────────┘  └──────────┬───────────┘
                 │                        │
                 ▼                        ▼
      ┌────────────────────────────────────────┐
      │  verilator -sv --binary --top-module   │
      │  tb_core_single_cycle                  │
      └────────────────┬───────────────────────┘
                       │
                       ▼
              ┌──────────────────┐
              │  ./obj_dir/      │
              │  Vtb_core_       │
              │  single_cycle    │  ← 编译好的仿真可执行文件
              └────────┬─────────┘
                       │
          Vtb_core_single_cycle +imem=build/<test>.mem
                       │
                       ▼
              ┌──────────────────┐
              │ stdout:          │
              │ [0] PC=...       │  ← commit trace
              │ PASS/FAIL/TIMEOUT│
              └──────────────────┘
```

---

## 3. 各文件角色

### 3.1 你手写的文件

| 文件 | 角色 | 说明 |
|------|------|------|
| `sw/asm/<test>.S` | 汇编测试程序 | RV32I 汇编，测试 core 功能。见第 4 节骨架 |
| `sw/linker/asm_test.ld` | 汇编测试链接脚本 | 定义 `.text`→IMEM(0x0)、`.data/.bss`→DMEM(0x10000) |
| `tb/sv/tb_core_single_cycle.sv` | testbench | 产生 clk/rst、例化 core+ROM+RAM、打印 commit trace、检测 PASS/FAIL |

### 3.2 RTL 源文件

| 文件 | 角色 |
|------|------|
| `rtl/common/core_pkg.sv` | 共享常量（XLEN, ILEN, IMEM_BASE, DMEM_BASE, opcode 枚举, ALU op 枚举等） |
| `rtl/core/pc_reg.sv` | PC 寄存器 |
| `rtl/core/if_stage.sv` | 取指阶段 |
| `rtl/core/id_stage.sv` | 译码阶段（例化 decoder + imm_gen） |
| `rtl/core/decoder.sv` | 指令译码器 |
| `rtl/core/imm_gen.sv` | 立即数生成 |
| `rtl/core/regfile.sv` | 通用寄存器堆 x0–x31 |
| `rtl/core/ex_stage.sv` | 执行阶段（例化 alu + branch_unit） |
| `rtl/core/alu.sv` | ALU 运算 |
| `rtl/core/branch_unit.sv` | 分支跳转判断 |
| `rtl/core/mem_stage.sv` | 访存阶段 |
| `rtl/core/wb_stage.sv` | 写回阶段 |
| `rtl/core/core_single_cycle.sv` | 单周期 core 顶层，连接上述所有模块 |
| `rtl/mem/simple_rom.sv` | 指令 ROM（`$readmemh` 通过 `+imem=<path>` 加载） |
| `rtl/mem/simple_ram.sv` | 数据 RAM（`$readmemh` 通过 `+dmem=<path>` 加载） |

### 3.3 脚本和中间产物

| 文件 | 角色 |
|------|------|
| `scripts/bin2mem32.py` | 把 `.bin` 转成每行一个 32-bit hex word 的 `.mem`，供 `$readmemh` 加载 |
| `sim/single_cycle_asm/05_build_mem.sh` | 一键编译汇编→`.elf`→`.dump`→`.bin`→`.mem` |
| `sim/single_cycle_asm/06_run_sim.sh` | 一键构建 Verilator 仿真 + 运行 |
| `build/<test>.elf` | ELF，含符号表和段信息 |
| `build/<test>.dump` | 反汇编结果，人工检查指令编码和地址 |
| `build/<test>.bin` | 裸二进制流 |
| `build/<test>.mem` | 每行一个 32-bit hex word，给 `$readmemh` |
| `obj_dir/Vtb_core_single_cycle` | 编译好的仿真可执行文件 |

---

## 4. 使用的工具

| 工具 | 来自 | 用途 |
|------|------|------|
| `riscv64-unknown-elf-gcc` | 工具链 (env.sh) | 编译/汇编/链接 .S → .elf |
| `riscv64-unknown-elf-objdump` | 同上 | 反汇编 .elf → .dump |
| `riscv64-unknown-elf-objcopy` | 同上 | .elf → .bin（提取裸二进制） |
| `scripts/bin2mem32.py` | 本仓库 | .bin → .mem |
| `verilator` | 系统安装 | SystemVerilog → C++ 仿真 |
| `Vtb_core_single_cycle` | verilator 生成 | 最终仿真可执行文件 |

---

## 5. 新建汇编测试（完整步骤）

### 5.1 写 .S 文件

在 `sw/asm/` 下新建 `<test>.S`，最小骨架：

```asm
.section .text.init
.globl _start

_start:
    # 在这里写测试指令

pass:
    lui   x30, 0x10          # x30 = DMEM_BASE
    addi  x31, x0, 1         # x31 = PASS value
    sw    x31, 0x100(x30)    # 写入 TEST_STATUS_ADDR

done:
    jal   x0, done           # 死循环

fail:
    lui   x30, 0x10
    addi  x31, x0, 2
    sw    x31, 0x100(x30)
    jal   x0, done
```

几点说明：

- **`.section .text.init`**：linker script 把 `.text.init` 放在普通 `.text` 前面，并放入 IMEM 起始地址（0x0），CPU 复位后第一条指令从这里取。
- **`jal x0, done`** 而非 `j done`：`j` 是伪指令。显式写 `jal x0` 可以让源码和反汇编更直接地对应到 RV32I 指令。
- **`pass` / `fail` 标签**：`x30`、`x31` 保留做测试结束状态，不用于普通数据验证。

### 5.2 生成 Memory Image

```bash
sim/single_cycle_asm/05_build_mem.sh <test>
```

执行流程：
1. `gcc` 汇编 + 链接（`-T sw/linker/asm_test.ld`）→ `.elf`
2. `objdump -d` → `.dump`（先检查这个文件确认指令编码正确）
3. `objcopy -O binary` → `.bin`
4. `bin2mem32.py` → `.mem`

输出全部在 `build/` 下。**每次修改 .S 后都要重新运行此脚本。**

### 5.3 运行仿真

```bash
sim/single_cycle_asm/06_run_sim.sh <test>
```

执行流程：
1. `verilator -sv --binary --timing --top-module tb_core_single_cycle` 编译 `06_run_sim.sh` 中列出的 .sv
2. 运行 `Vtb_core_single_cycle +imem=build/<test>.mem`

正常输出类似：

```
[1] @ 55: PC=0x00000000 Instr=0x02a00093   rd=x1 <= 0x0000002a
[2] @ 65: PC=0x00000004 Instr=0x00010537   rd=x10 <= 0x00010000
[3] @ 75: PC=0x00000008 Instr=0x00100593   rd=x11 <= 0x00000001
PASS after 4 cycles
DMEM access range: no program DMEM access
Stack max used:    SP not initialized to stack top
```

仿真结束时会打印 `DMEM access range` 和 `Stack max used`。汇编测试通常不初始化 `sp`，所以栈统计可能显示 `SP not initialized to stack top`；DMEM 范围已排除 `TEST_STATUS_ADDR` 的 PASS/FAIL 写入。详细口径见 `docs/08xx/0827 Testbench、commit trace与测试集组织.md`。

两脚本汇总为一个脚本：

```bash
sim/single_cycle_asm/run_test.sh <test>
```

7 个 asm 程序连续测试总脚本：

```bash
sim/single_cycle_asm/run_all.sh
```

### 5.4 PASS/FAIL 约定

```
TEST_STATUS_ADDR = DMEM_BASE + 0x100  (= 0x00010100)
PASS             = 写入 1
FAIL             = 写入任何非 1 值
TIMEOUT          = 超过 20010 周期未写入
```

---

## 6. 变更影响矩阵

修改什么 → 需要做什么：

| 你改了... | 重新生成 .mem？ | 重新构建仿真？ |
|-----------|-----------------|---------------|
| `sw/asm/<test>.S` | **是** (跑 05_build_mem.sh) | 否；重跑 `06_run_sim.sh` 时 Verilator 会按需增量构建 |
| `sw/linker/asm_test.ld` | **是** | 否 |
| `rtl/core/*.sv`（任意 RTL 模块） | 否 | **是**（重跑 06_run_sim.sh） |
| `rtl/mem/simple_rom.sv` / `simple_ram.sv` | 否 | **是** |
| `rtl/common/core_pkg.sv`（改 IMEM_BASE/DMEM_BASE 等） | **是**（同步检查 asm_test.ld 是否一致） | **是** |
| `tb/sv/tb_core_single_cycle.sv` | 否 | **是** |
| 新增 .sv 文件 | 否 | **是**，并且要加到 06_run_sim.sh 的 verilator 命令中 |
| `scripts/bin2mem32.py` | **是**（已有 .mem 是旧转换结果） | 否 |

**实际操作建议**：拿不准时就两条脚本都跑，反正 build_mem.sh 只要一两秒。

---

## 7. 调试指引

### 7.1 症状 → 原因

| 现象 | 最可能原因 |
|------|-----------|
| TIMEOUT | 程序没写 TEST_STATUS_ADDR，或分支跳错进了死循环 |
| FAIL: status=0x... | 测试主动写了非 1 值到 TEST_STATUS_ADDR |
| 第一条指令是 `00000000` | +imem 路径错 / .mem 没生成 / 加载失败 |
| 指令编码看起来字节反了 | .mem 格式不对；应用 bin2mem32.py 生成 |
| ILLEGAL | decoder 不支持该指令，或汇编生成的是伪指令展开后的非预期编码 |
| MISALIGN | load/store 地址不对齐访问宽度 |
| u_type.S / branch.S 等复合测试 FAIL | 先查该文件依赖的指令在对应定向测试中是否通过 |

### 7.2 标准检查清单

1. 检查 `build/<test>.dump`，确认 `_start` 在地址 `0x00000000`
2. 确认所有指令是 32-bit 编码（没有压缩指令 `c.*`）
3. 看 commit trace 定位第一条不符合预期的指令
4. 如果 store 没触发 PASS，检查写地址是不是 `0x00010100`

---

## 8. 后续添加测试建议

```text
sw/asm/alu_imm.S       — 全部 ALU 立即数指令
sw/asm/alu_reg.S       — 全部 ALU 寄存器指令
sw/asm/load_store.S    — LB/LH/LW/LBU/LHU + SB/SH/SW
sw/asm/branch.S        — BEQ/BNE/BLT/BGE/BLTU/BGEU
sw/asm/jump.S          — JAL/JALR
```

每文件覆盖少量指令，跑通后再扩展。小测试更容易从 commit trace 定位第一处错误。
