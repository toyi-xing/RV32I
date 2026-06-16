# 五级流水线 C 仿真流程

本文档说明当前五级流水线 core 的 C 裸机测试如何编译、生成 IMEM/DMEM 镜像并通过 Verilator 运行。

---

## 1. 仿真命令

```bash
# 编译 C 测试 → imem.mem + dmem.mem
sim/pipeline5_c/05_build_mem.sh <test>

# 构建 Verilator 仿真 + 运行
sim/pipeline5_c/06_run_sim.sh <test>

# 两步合一
sim/pipeline5_c/run_test.sh <test>
```

`<test>` 可以是四位编号或完整 basename，例如：

```bash
sim/pipeline5_c/run_test.sh 0401
sim/pipeline5_c/run_test.sh 0401_control_mix
```

## 2. 与流水线汇编测试的差异

### 2.1 测试程序结构不同

| | 汇编测试 | C 测试 |
|--|---------|--------|
| 程序入口 | `sw/asm/<test>.S`，手写 `_start` | `sw/c/<test>.c`，搭配 `sw/c_runtime/crt0.S` |
| 链接脚本 | `sw/linker/asm_test.ld` | `sw/linker/c_baremetal.ld` |
| 内存镜像 | 单文件 `.mem`（只含 imem） | 双文件 `_imem.mem` + `_dmem.mem`（`.dmem_image` 段初始数据） |
| dmem 初始化 | 否（RAM 默认全 0） | 是（C 全局变量初始值通过 dmem 镜像加载） |

### 2.2 仿真命令区别

流水线 C 仿真同时加载 imem 和 dmem：
```bash
Vtb_core_pipeline5 "+imem=build/pipeline5_c/<test>_imem.mem" "+dmem=build/pipeline5_c/<test>_dmem.mem"
```

## 3. 可用的 C 测试文件

| 文件 | 描述 |
|------|------|
| `sw/c/0201_c_smoke.c` | 最小冒烟：1+2=3 自检，通过返回 0 |
| `sw/c/0401_control_mix.c` | 稍复杂 C 程序：.data/.bss/.rodata、嵌套循环冒泡排序、函数调用栈、byte/halfword 访存、分支密集路径 |

## 4. 新建 C 测试

### 4.1 写 .c 文件

在 `sw/c/` 下新建 `<test>.c`，最小骨架：

```c
int main(void)
{
    // 在这里写测试代码

    return 0;  // 0 表示 PASS；非 0 返回值由 crt0.S 转成 FAIL
}
```

几点说明：

- **入口约定**：`crt0.S` 负责初始化栈指针、清零 `.bss`、加载 `.dmem_image` 到 DMEM 基址，然后调用 `main()`。
- **全局变量初始化**：若 C 测试需要在 DMEM 中预置数据，定义全局变量并赋初值即可。链接脚本会将这些初始值收集到 `.dmem_image` 段，仿真启动时 `simple_ram` 通过 `$readmemh` 加载。
- **PASS/FAIL 约定**：C 测试由 `crt0.S` 统一写 `DMEM_BASE + 0x100`（即 `0x00010100`）。`main()` 返回 0 时写 1 表示 PASS，返回非 0 时写 2 表示 FAIL。超时（20010 周期）自动判 TIMEOUT。

### 4.2 生成 Memory Image

```bash
sim/pipeline5_c/05_build_mem.sh <test>
```

执行流程：

1. `gcc` 编译 + 链接（`-T sw/linker/c_baremetal.ld`）→ `.elf`
2. `objdump -d` → `.dump`
3. `objcopy -j .text` → `_imem.bin` → `_imem.mem`
4. `objcopy -j .dmem_image` → `_dmem.bin` → `_dmem.mem`

输出全部在 `build/pipeline5_c/` 下。**每次修改 .c 后都需重新运行此脚本。**

### 4.3 运行仿真

```bash
sim/pipeline5_c/06_run_sim.sh <test>
```

正常输出类似：

```
[0] @ 55: PC=0x00000000 Instr=0x00000537   rd=x10 <= 0x00010000
...
PASS after N cycles
DMEM access range: 0x00010200 - 0x00010ffc
Stack max used:    80 bytes
```

`DMEM access range` 统计仿真期间程序实际发起过 load/store 的最小和最大 DMEM 地址，已排除 `TEST_STATUS_ADDR` 的 PASS/FAIL 写入。`Stack max used` 通过 `min(sp)` 估算最大栈深，C 测试由 `crt0.S` 初始化 `sp`，因此这个值通常比 `.mem` 文件大小更能反映运行时栈压力。DMEM 地址范围不等价于真实 RAM 占用，因为中间地址未必都被访问；详细口径见 `docs/08xx/0827 Testbench、commit trace与测试集组织.md`。

## 5. 调试注意事项

- C 测试的 commit trace 比汇编更晚出现，因为 `crt0.S` 在进入 `main()` 前做了栈和 bss 初始化。
- `sw/linker/c_baremetal.ld` 中 `_stack_end` 的值和栈指针初始化代码（`crt0.S`）必须一致，否则 `main()` 内的函数调用会异常。
- 全局变量的 dmem 地址可通过 `.map` 文件或 `.dump` 中的符号地址确认。
- RTL 文件由 `sim/pipeline5_c/06_run_sim.sh` 按 `rtl/common/*.sv`、`rtl/core/*.sv`、`rtl/mem/*.sv` 收集；testbench 仍固定为 `tb/sv/tb_core_pipeline5.sv`。
