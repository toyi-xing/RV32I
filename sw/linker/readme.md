# Linker 与内存分配说明

本文说明当前五级流水线核仿真使用的 IMEM/DMEM 地址图，以及 `asm_test.ld`、`c_baremetal.ld` 的分工。

## 当前地址图

RTL 中 `simple_rom` 和 `simple_ram` 都使用 32-bit word array。当前 `ADDR_WIDTH=16`，因此每块 memory 有 65536 words，即 256 KiB。

| 区域 | 起始地址 | 结束地址 | 大小 | 用途 |
|---|---:|---:|---:|---|
| IMEM | `0x0000_0000` | `0x0003_FFFF` | 256 KiB | 指令、trap handler、部分只读内容 |
| DMEM | `0x0004_0000` | `0x0007_FFFF` | 256 KiB | 数据、测试状态、C 栈 |

对应 RTL 常量在 `rtl/common/core_pkg.sv`：

```systemverilog
IMEM_BASE       = 32'h0000_0000;
DMEM_BASE       = 32'h0004_0000;
IMEM_SIZE_BYTES = 32'h0004_0000;
DMEM_SIZE_BYTES = 32'h0004_0000;
MTVEC_RESET     = IMEM_BASE + 32'h0000_0080;
```

## IMEM 布局

两个 linker script 都采用同一套 IMEM 入口约定：

| 地址/段 | 用途 |
|---|---|
| `0x0000_0000` / `.text.init` | reset 后第一段代码，必须包含 `_start` |
| `0x0000_0080` / `.text.trap` | M-mode direct trap 入口，对齐 `MTVEC_RESET` |
| `.text` | 普通程序代码，放在 `.text.trap` 之后 |

`.text.trap` 使用 `KEEP(*(.text.trap))`，并且即使当前程序没有 handler，也至少保留 4 bytes。这样普通 `.text` 不会占用 `mtvec` 默认入口；如果程序真的定义了 handler，也不会额外插入无意义占位字。

现有汇编和 C runtime 的 `_start` 都是短入口 stub：

```asm
.section .text.init
_start:
    jal x0, test_main

.section .text
test_main:
    ...
```

这种写法让 reset 入口固定在 `0x0`，同时把普通程序主体避开 `0x80` trap vector。需要 trap handler 的汇编程序应显式放到 `.text.trap`：

```asm
.section .text.trap
trap_handler:
    ...
```

## ASM 链接脚本

`asm_test.ld` 面向手写汇编测试。它的目标是尽量直接、透明：

| 段 | 放置区域 | 说明 |
|---|---|---|
| `.text.init` | IMEM | reset stub |
| `.text.trap` | IMEM `0x80` | trap handler |
| `.text` | IMEM | 普通代码 |
| `.rodata` | IMEM | 只读数据 |
| `.data` | DMEM | 已初始化数据 |
| `.bss` | DMEM | 未初始化数据 |

当前多数 `sw/asm/*.S` 测试不依赖 `.data/.bss`，而是直接用 `lui ..., 0x40` 构造 `DMEM_BASE=0x0004_0000`，再写 `DMEM_BASE+0x100` 作为 PASS/FAIL 状态。

## C 链接脚本

`c_baremetal.ld` 面向 C 裸机测试。C 测试使用两个 memory image：

| 镜像 | 来源段 | 加载目标 |
|---|---|---|
| `_imem.mem` | `.text.init/.text.trap/.text` | `simple_rom` |
| `_dmem.mem` | `.dmem_image` | `simple_ram` |

C 的 DMEM 布局：

| 地址范围 | 用途 |
|---|---|
| `0x0004_0000` - `0x0004_00FF` | 保留 |
| `0x0004_0100` - `0x0004_0103` | `TEST_STATUS_ADDR` |
| `0x0004_0104` - `0x0004_01FF` | 保留 |
| `0x0004_0200` 起 | `.rodata/.data` 初始镜像 |
| `.bss` | `NOLOAD`，由 `crt0.S` 进入 `main()` 前清零 |
| `0x0007_E000` - `0x0007_FFFF` | 预留 C 栈，当前 8 KiB |

关键符号：

| 符号 | 含义 |
|---|---|
| `__test_status_addr` | `DMEM_BASE + 0x100`，`crt0.S` 根据 `main()` 返回值写 PASS/FAIL |
| `__c_data_base` | `DMEM_BASE + 0x200`，C 数据初始镜像起点 |
| `__stack_top` | `DMEM_BASE + DMEM_SIZE_BYTES = 0x0008_0000` |
| `__stack_size` | 当前固定为 `0x2000` |
| `__stack_bottom` | `__stack_top - __stack_size = 0x0007_E000` |
| `__trap_vector` | `IMEM_BASE + 0x80` |

`crt0.S` 使用 linker symbol 设置 `sp`、清零 `.bss`，然后调用 `main()`。C 程序自身不应直接写 `TEST_STATUS_ADDR`；它只返回 0 或非 0，由 `crt0.S` 统一写状态字。

C runtime 还固定提供 `.text.trap` 入口。该入口保存寄存器、读取 `mcause/mepc/mtval`，调用弱符号 `__trap_handler_c`，再按 handler 返回值写 `mepc` 并执行 `mret`。普通 C 测试不触发 trap 时不会用到它；需要处理 trap 的测试提供同名强定义即可覆盖默认 FAIL handler。

## 修改地址图时要同步的地方

如果后续继续调整 IMEM/DMEM 大小或基址，需要一起检查：

- `rtl/common/core_pkg.sv` 的 `IMEM_*`、`DMEM_*` 常量。
- `rtl/mem/simple_rom.sv`、`rtl/mem/simple_ram.sv` 的默认 `ADDR_WIDTH` 是否仍引用公共常量。
- `sw/linker/asm_test.ld` 和 `sw/linker/c_baremetal.ld` 的 `MEMORY`、`__stack_top`、`__test_status_addr` 等符号。
- 手写汇编中构造 DMEM base 的 `lui ..., 0x40`。
- `tb/sv/tb_core_pipeline5.sv` 中 PASS/FAIL 地址和 DMEM/stack 统计。
- `docs/simulation_flow_pipeline_*.md` 中的命令示例和地址说明。
