# 单周期 Core C 裸机仿真流程

本文档说明 C 测试如何在当前单周期 RV32I core 上编译、生成 IMEM/DMEM 镜像并跑出 PASS/FAIL。

## 1. 一条命令运行

在仓库根目录执行：

```bash
sim/single_cycle_c/run_test.sh c_smoke
```

期望输出中出现：

```text
PASS after ... cycles
DMEM access range: ...
Stack max used:    ...
```

`DMEM access range` 统计仿真期间程序实际 load/store 过的最小和最大 DMEM 地址，已排除 `TEST_STATUS_ADDR` 的 PASS/FAIL 写入。`Stack max used` 通过 `min(sp)` 估算最大栈深；DMEM 地址范围不等价于真实 RAM 占用，因为中间地址未必都被访问。详细口径见 `docs/08xx/0827 Testbench、commit trace与测试集组织.md`。

## 2. C 流程总览

```text
sw/c_runtime/crt0.S + sw/c/<test>.c
        │
        ▼
riscv64-unknown-elf-gcc + sw/linker/c_baremetal.ld
        │
        ▼
build/single_cycle_c/<test>.elf
        │
        ├─ objdump -d
        │     └─ build/single_cycle_c/<test>.dump
        │
        ├─ objcopy -j .text
        │     └─ <test>_imem.bin -> <test>_imem.mem
        │
        └─ objcopy -j .dmem_image
              └─ <test>_dmem.bin -> <test>_dmem.mem
        │
        ▼
Vtb_core_single_cycle +imem=<test>_imem.mem +dmem=<test>_dmem.mem
```

## 3. 新增文件角色

| 文件 | 角色 |
|------|------|
| `sw/c/c_smoke.c` | C 冒烟测试 |
| `sw/c/dmem_init.c` |检查栈、函数调用、局部变量、全局变量、`.rodata/.data/.bss` |
| `sw/c_runtime/crt0.S` | C 启动代码，设置 `sp`、清零 `.bss`、调用 `main()`、统一写 PASS/FAIL |
| `sw/linker/c_baremetal.ld` | C 裸机链接脚本，定义 IMEM/DMEM 布局和保留状态地址 |
| `sim/single_cycle_c/05_build_mem.sh` | 编译 C 测试并生成 IMEM/DMEM 两份 `.mem` |
| `sim/single_cycle_c/06_run_sim.sh` | 构建 Verilator 仿真并加载两份 memory image |
| `sim/single_cycle_c/run_test.sh` | 一键执行 C 编译和仿真 |

## 4. PASS/FAIL 约定

testbench 仍复用当前汇编测试的检测逻辑：

```text
TEST_STATUS_ADDR = DMEM_BASE + 0x100 = 0x00010100
PASS             = 写入 1
FAIL             = 写入任何非 1 值
```

C 程序本身不直接写 `0x00010100`。`main()` 返回值由 `crt0.S` 判断：

```text
main() 返回 0    -> crt0.S 写 1
main() 返回非 0 -> crt0.S 写 2
```

按 RISC-V ABI，`int main(void)` 的返回值位于 `x10/a0`，所以 `crt0.S` 在 `jal x1, main` 返回后检查 `x10`。

## 5. C DMEM 布局

当前 C linker 保留了低地址状态区，并把 C 数据放到更后面：

```text
0x00010000 - 0x000100ff   保留
0x00010100 - 0x00010103   TEST_STATUS_ADDR
0x00010104 - 0x000101ff   保留
0x00010200 - ...          .rodata / .data / .bss
0x00010e00 - 0x00010fff   C stack
```

正常链接出来的 C 全局变量、静态变量和栈不会占用 `mem[64]`。这不是硬件保护；野指针或手写固定地址仍然可能写到状态地址。

## 6. `.rodata/.data/.bss` 如何生效

- `.rodata` 和 `.data` 放在 linker 的 `.dmem_image` section 中。
- `05_build_mem.sh` 使用 `objcopy -j .dmem_image` 生成 `dmem.mem`。
- `06_run_sim.sh` 用 `+dmem=<path>` 加载 simple_ram 初始内容。
- `.bss` 不进入 `dmem.mem`，由 `crt0.S` 在进入 `main()` 前逐 word 清零。

因此 C 程序可以使用初始化全局变量、未初始化全局变量和只读表，但仍不要使用标准库和系统调用。

## 7. 主要编译参数

```bash
-march=rv32i
-mabi=ilp32
-mno-relax
-msmall-data-limit=0
-nostdlib
-nostartfiles
-ffreestanding
-O0
```

其中 `-msmall-data-limit=0` 用来避免编译器生成依赖 `gp` 初始化的小数据访问；当前 `crt0.S` 不设置 `gp`。

## 8. 变更影响矩阵

修改什么 -> 需要做什么：

| 你改了... | 重新生成 IMEM/DMEM？ | 重新构建仿真？ | 推荐命令 |
|-----------|----------------------|----------------|----------|
| `sw/c/<test>.c` | **是** | 否；重跑仿真脚本时 Verilator 会按需增量构建 | `sim/single_cycle_c/run_test.sh <test>` |
| 新增 `sw/c/<new_test>.c` | **是** | 否；除非 RTL/TB 也改了 | `sim/single_cycle_c/run_test.sh <new_test>` |
| `sw/c_runtime/crt0.S` | **是** | 否 | `sim/single_cycle_c/run_test.sh c_smoke` |
| `sw/linker/c_baremetal.ld` | **是** | 否 | `sim/single_cycle_c/run_test.sh c_smoke` |
| `sim/single_cycle_c/05_build_mem.sh` | **是** | 否 | `sim/single_cycle_c/run_test.sh c_smoke` |
| `sim/single_cycle_c/06_run_sim.sh` | 否 | **是**，脚本会重新调用 Verilator | `sim/single_cycle_c/06_run_sim.sh c_smoke` |
| `rtl/core/*.sv`（任意 RTL 模块） | 否 | **是** | `sim/single_cycle_c/run_test.sh c_smoke` |
| `rtl/mem/simple_rom.sv` / `rtl/mem/simple_ram.sv` | 否 | **是** | `sim/single_cycle_c/run_test.sh c_smoke` |
| `rtl/common/core_pkg.sv`（改 IMEM_BASE/DMEM_BASE 等） | **是**（同步检查 `c_baremetal.ld`） | **是** | `sim/single_cycle_c/run_test.sh c_smoke` |
| `tb/sv/tb_core_single_cycle.sv` | 否 | **是** | `sim/single_cycle_c/run_test.sh c_smoke` |
| 新增 .sv 文件 | 否 | **是**，并且要加到 `06_run_sim.sh` 的 verilator 命令中 | `sim/single_cycle_c/run_test.sh c_smoke` |
| `scripts/bin2mem32.py` | **是**（已有 `.mem` 是旧转换结果） | 否 | `sim/single_cycle_c/run_test.sh c_smoke` |

单独拆开运行时：

```bash
sim/single_cycle_c/05_build_mem.sh c_smoke   # 只重新编译 C 并生成 _imem.mem/_dmem.mem
sim/single_cycle_c/06_run_sim.sh c_smoke     # 只使用已有镜像跑仿真
```

如果 C 测试文件不是 `c_smoke.c`，命令参数要跟文件名去掉 `.c` 后一致。例如：

```text
sw/c/c_loop.c
```

对应命令是：

```bash
sim/single_cycle_c/run_test.sh <test>
```

**实际操作建议**：拿不准时直接跑 `sim/single_cycle_c/run_test.sh <test>`。它会先重新生成两份 memory image，再构建/运行仿真，最不容易漏步骤。

## 9. 出错时先看什么

| 现象 | 优先检查 |
|------|----------|
| 第一条指令为 `00000000` | `+imem=` 路径或 `_imem.mem` 是否生成 |
| 全局变量初始值错误 | `+dmem=` 是否加载、`_dmem.mem` 是否生成 |
| `.bss` 不是 0 | `crt0.S` 的 `__bss_start/__bss_end` 清零路径 |
| TIMEOUT | `main()` 没返回、`crt0.S` 没写状态地址、或程序跑飞 |
| FAIL | 查看 `build/single_cycle_c/<test>.dump` 和 commit trace，定位 `main()` 返回非 0 的原因 |
