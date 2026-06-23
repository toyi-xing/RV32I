# 1 C 裸机测试计划

## 1.1 smoke 测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `0201_c_smoke.c` | C 入口、栈、函数调用、局部变量 — 最小 C 冒烟 |

测试逻辑：定义一个 `main()`，做简单加法后返回 0。如果 core 能正确执行 `crt0.S` → `main()` → 返回 → `crt0.S` 写 PASS 的完整流程，说明 C runtime 和 core 的基本配合正常。

## 1.2 dmem 初始化测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `0202_dmem_init.c` | `.rodata` 只读表初始化、`.data` 全局变量初始值和写回、`.bss` 清零、局部数组的栈上 load/store、函数调用传参和返回值 |

### 错误码对照

`0202_dmem_init.c` 每个检查点返回不同错误码，FAIL 时可根据返回值定位错误：

| 返回值 | 阶段 | 可能原因 |
|--------|------|----------|
| 1 | `.data` 初始值 | `+dmem=` 未加载或 `.data` 段顺序异常，`g_data` 不是 7 |
| 2 | `.bss` 清零 | `crt0.S` 的清零循环出错或未执行 |
| 3 | `.rodata` 读表 | `k_table` 初始值错乱，大概率 `+dmem=` 加载路径或格式问题 |
| 4 | `.data` 写回 | 全局变量 store 后 load 不对，检查 core 的 store 通路 |
| 5 | `.bss` 写回 | `.bss` 区域的 store 后 load 不对 |
| 6 | 栈上局部数组 | 栈帧分配或 sp 设置问题，`crt0.S` 的 sp 初始化是否正常 |
| 7 | 函数调用 + ABI | `main()` 调 `add3()` 传入参数或取回返回值有误 |

---

## 1.3 跳过

## 1.4 综合控制流测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `0401_control_mix.c` | .data/.bss/.rodata、嵌套循环冒泡排序、函数调用栈、byte/halfword 访存、分支密集路径 |

### 错误码对照

`0401_control_mix.c` 错误码从 1~10 逐步收敛：

| 返回值 | 阶段 | 可能原因 |
|--------|------|----------|
| 1 | `.bss` 检查 | `g_sink` 非零 — `.bss` 未清零 |
| 2~4 | 全局 Work/Bytes/Halves 初始化 | `.bss` 清零未覆盖到对应数组 |
| 5 | 冒泡排序正确性 | 排序结果无序 — 存/取或分支跳转有误 |
| 6 | `fold_step` 累加结果 | 函数调用或运算逻辑出错 |
| 7 | Byte 操作 | `g_bytes` 的 byte store/load 通路 |
| 8 | Halfword 操作 | `g_halves` 的 halfword store/load 通路 |
| 9 | `branch_mix` 三次调用 | 分支密集函数的返回值 |
| 10 | `g_sink` 写回验证 | .data 段的 store 后 load |

---

## 1.5 trap smoke 测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `0551_trap_smoke.c` | 共享 C trap 入口、ECALL、`mcause/mepc/mtval` 读取、C handler 返回后 `mret` 回主流程 |

`crt0.S` 固定提供 `.text.trap` 入口，并定义弱符号 `__trap_handler_c`。普通 C 测试不需要关心它；需要处理 trap 的测试提供同名强定义即可覆盖默认 handler。

`0551_trap_smoke.c` 的 handler 记录 `mcause/mepc/mtval`，对 ECALL 返回 `mepc + 4`。`main()` 在 `ecall` 后继续执行并检查记录值，全部正确时返回 0。

---

## 1.6 SoC MMIO 测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `0651_soc_mmio_smoke.c` | 通过 `platform.h` 封装函数访问 GPIO/UART MMIO，验证 GPIO OUT/OE 写后读、GPIO IN 只读、UART 使能/状态查询/TX 发送 |
| `0652_soc_mmio_gpio_uart.c` | GPIO bit 级独立验证（OUT/OE 互不影响、IN 只读）、UART 多字符串发送 |

SoC 平台提供 `sw/include/platform.h`，封装了 `mmio_read32`/`mmio_write32` 等 MMIO 访问原语。C 程序直接调用这些函数操作外设寄存器，无需内联汇编。

`0651_soc_mmio_smoke.c` 的测试顺序：GPIO OUT 写 0x12345678 → 读回验证 → GPIO OE 写 0x0000ffff → 读回验证 → GPIO IN 读回 0xA5A55A5A → UART 使能 → 读 STATUS.ready → 通过 uart_putc 发送 "SOC\n"。全部正确时返回 0。

`0652_soc_mmio_gpio_uart.c` 在 0651 基础上进一步验证外设寄存器独立性：Stage1~2 做 GPIO 全 bit 翻转（`0xAAAAAAAA` / `0x55555555` 覆盖 OUT，`0x0000FFFF` / `0xFFFF0000` 覆盖 OE）；Stage3~4 验证 OUT 和 OE 互不影响；Stage5 写 IN 地址后读回确认仍为 0xA5A55A5A；Stage6 连续发送 3 个字符串验证 UART TX 稳定性。全部正确时返回 0。

---

## 1.7 timer interrupt 测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `0751_timer_smoke.c` | 最小 timer interrupt — 配置 TIMER0、开中断、handler 关定时器清 pending、main 检测 flag 后 return 0 |

用 `platform.h` 封装的 CSR 访问函数（`csr_write_mie`、`csr_set_mstatus` 等），不再在测试 .c 内重复定义内联汇编。

测试顺序：关全局中断 → 清 `mie` → 配置 `MTIMECMP=16`、`MTIME=0` → 写 `mie.MTIE` → 开启 timer → 开全局中断 → 等待 handler 置 flag。handler 写 `CTRL=0` 停 timer（`MTIP` 随 `CTRL.enable=0` 变为 0），完成 level pending 清除。

# 2 C 与汇编测试的分工

汇编测试逐个覆盖 RISC-V ISA 的边缘情况。C 测试不追求指令覆盖，而是验证 **C 编译器生成的正常指令流** 在 core 上能正确运行：

| | 汇编测试 | C 测试 |
|--|---------|--------|
| 关注点 | 每条指令的编码和结果 | C runtime + 编译器生成代码的整体正确性 |
| 指令流 | 手写，精确控制 | gcc 编译生成，含栈帧/传参/地址加载等 |
| 数据初始化 | 手动构造 | `.rodata`/`.data`/`.bss` 由 linker + crt0 处理 |
| PASS/FAIL | 内联写 DMEM | `crt0.S` 统一根据 `main()` 返回值写 |
| 排错方式 | 看 dump 对比预期 | 先用错误码缩小范围，再看 dump |

**关键区别**：汇编测试通过 `bne x5, x6, fail` 自检，结果由程序自己判断。C 测试只写 `return N`，由 `crt0.S` 统一判断 `x10/a0` 后写 `TEST_STATUS_ADDR`。

# 3 crt0.S 启动流程

```
_start
  │
  ├─ .text.trap 固定提供 trap entry
  │       └─ trap 时保存寄存器，调用 __trap_handler_c，写 mepc，mret
  ├─ 设置 sp = __stack_top
  ├─ 清零 .bss 段 (__bss_start ~ __bss_end)
  ├─ jal x1, main
  │       │
  │       └─ main() 返回 0 → 写 1 (PASS)
  │                   返回非0 → 写 2 (FAIL)
  └─ 无限 loop
```

C 程序永远不直接写 `TEST_STATUS_ADDR(0x00040100)`。（但不是硬件保护，野指针等可能导致被写入）

默认 `__trap_handler_c` 会写 FAIL 并停住，表示普通 C 程序不期望发生 trap。专门的 trap 测试可以实现自己的 `__trap_handler_c(unsigned int mcause, unsigned int mepc, unsigned int mtval)`，返回值会被 `crt0.S` 写入 `mepc`，随后执行 `mret`。

## 3.1 依赖关系

```
0201_c_smoke.c
  └─→ 0202_dmem_init.c  (依赖 crt0 + .data/.bss 通路正常)
```

两个测试都依赖同一个 `crt0.S` 和 `c_baremetal.ld`。如果两个都 FAIL，优先检查：
1. `crt0.S` 是否正常执行到 `main()`（dump 确认 PC 路径）
2. `+dmem=` 是否加载（FAIL 且错误码为 1，说明 `.data` 没初始化）
3. linker 的 `__bss_start`/`__bss_end` 符号是否与 `.bss` 段匹配（`readelf -S` 检查）

## 3.2 编写 C trap handler 测试

crt0.S 已提供完整的 trap 入口，C 测试只需提供 `__trap_handler_c` 强定义即可接管异常。

### 函数原型

```c
unsigned int __trap_handler_c(unsigned int mcause,
                              unsigned int mepc,
                              unsigned int mtval);
```

- `mcause`：`csrr mcause` 的值（异常原因编码）。
- `mepc`：`csrr mepc` 的值（fault 指令 PC）。
- `mtval`：`csrr mtval` 的值（异常附加信息）。
- **返回值**：写入 `mepc` 的值，随后 crt0.S 执行 `mret`。通常传入 `mepc + 4` 跳过 fault 指令，或传入 `resume_pc` 继续执行。

注意：handler 运行在 machine mode，返回后自动 `mret`。crt0.S 的 `.text.trap` 入口已保存/恢复全部 GPR，handler 内读写全局变量安全。

### 参考步骤

以 `0551_trap_smoke.c` 为例，编写一个 C trap handler 测试的流程：

1. **定义全局变量**保存 handler 读到的 CSR 值：
   ```c
   static volatile unsigned int trap_seen;      // 调用计数
   static volatile unsigned int trap_mcause;    // mcause 记录值
   ```

2. **提供 `__trap_handler_c` 强定义**：
   ```c
   unsigned int __trap_handler_c(unsigned int mcause, unsigned int mepc, unsigned int mtval)
   {
       trap_seen = trap_seen + 1u;
       trap_mcause = mcause;
       return mepc + 4u;   // 跳过 ecall，继续执行
   }
   ```

3. **在 `main()` 中触发异常**。fault 指令会打断 C 的正常控制流，需用内联汇编精确嵌入：
   ```c
   __asm__ volatile (
       "1:\n"
       "ecall\n"
       : : : "memory"
   );
   ```
   若需要获取 fault 指令的 PC 以验证 `mepc`，参见 `0551_trap_smoke.c` 中局部 label + `%hi/%lo` 的手法。

4. **在 `main()` 中检查 handler 记录的值**，参考 `0551_trap_smoke.c` 逐项检查、不同错误返回不同 error_code 的模式。

### 内联汇编注意事项

- ecall/ebreak 后面的 C 代码能否执行到，取决于 `__trap_handler_c` 返回的 mepc。
- `"memory"` clobber 保证 `trap_seen` 等全局变量在读检查前被重新加载。
- trap 测试的全局变量必须用 `volatile` 声明，防止编译器优化掉跨 ecall 的读写。

### 运行方式

```bash
sim/soc_c/run_test.sh 0551
```

### 日志预期

```
[..] @ ..: PC=0x800000.. Instr=0x00000073 INSTR_ECALL   noWB
^^^^^^^^^^ this cycle happen trap_entry  ^^^^^^^^^^
...
PASS after N cycles
```

### 实现示例

| 文件 | 验证内容 |
|------|----------|
| `0551_trap_smoke.c` | ECALL 触发 → handler 检查 mcause/mepc/mtval → mret 回 main → 逐项检查 |

## 3.3 编写 C MMIO 测试

SoC 平台提供 `sw/include/platform.h`，封装了 GPIO/UART/TIMER32 的 MMIO 地址、offset、bit mask 和基础读写函数。

### MMIO 辅助 API

所有操作通过 `volatile` 指针直接访存，无需 trap handler：

```c
// 核心读写函数
uint32_t mmio_read32(uint32_t addr);
void     mmio_write32(uint32_t addr, uint32_t value);

// GPIO 寄存器地址计算
uint32_t gpio_reg(uint32_t base, uint32_t offset);   // base + offset
// GPIO_OUT_OFFSET = 0x000, GPIO_IN_OFFSET = 0x004, GPIO_OE_OFFSET = 0x008

// UART 寄存器地址计算
uint32_t uart_reg(uint32_t base, uint32_t offset);
// UART_TXDATA_OFFSET = 0x000, UART_STATUS_OFFSET = 0x004, UART_CTRL_OFFSET = 0x008,
// UART_RXDATA_OFFSET = 0x00c, UART_IRQ_PENDING_OFFSET = 0x010

// UART 便捷函数
void uart_enable(uint32_t base);   // 写 UART_CTRL_ENABLE
void uart_putc(uint32_t base, char ch);  // 忙等 READY 后发字符
```

### 参考步骤

以 `0651_soc_mmio_smoke.c` 为例，编写一个 C MMIO 测试的流程：

1. **包含头文件**：
   ```c
   #include "platform.h"
   ```

2. **GPIO OUT/OE 写后读验证**：
   ```c
   mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), 0x12345678u);
   value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET));
   if (value != 0x12345678u) return 1;
   ```
   写 `GPIO_OUT` 寄存器，读回确认。不同的检查点返回不同错误码。

3. **GPIO IN 只读验证**（由 testbench 驱动固定值）：
   ```c
   value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IN_OFFSET));
   if (value != 0xa5a55a5au) return 3;
   ```

4. **UART 使能与状态检查**：
   ```c
   uart_enable(UART0_BASE);                                     // 写 CTRL
   value = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
   if ((value & UART_STATUS_READY) == 0u) return 4;             // 检查 READY
   ```

5. **UART TX 发送字符**（SoC testbench 会打印到终端）：
   ```c
   uart_putc(UART0_BASE, 'S');
   uart_putc(UART0_BASE, 'O');
   uart_putc(UART0_BASE, 'C');
   uart_putc(UART0_BASE, '\n');
   ```

### 运行方式

```bash
# SoC 仿真（含 MMIO 外设）
sim/soc_c/run_test.sh 0651
```

### 日志预期

```
...
[..]*******[UART_TX_EVENT] uart0_tx_data:0x53('S')*******
[..]*******[UART_TX_EVENT] uart0_tx_data:0x4f('O')*******
[..]*******[UART_TX_EVENT] uart0_tx_data:0x43('C')*******
[..]*******[UART_TX_EVENT] uart0_tx_data:0x0a('
')*******
...
PASS after N cycles
```

### 注意事项

- 当前所有 C 测试统一使用 SoC 仿真入口（`sim/soc_c/`）。旧 core-only 仿真入口已删除。
- MMIO 寄存器是固定响应模型（无等待），`mmio_read32` 直接返回结果，不需等待状态。
- `GPIO_IN` 的值由 testbench 驱动，C 程序只能读不能写。
- UART 的 `uart_putc` 包含忙等循环，测试的是 UART STATUS 寄存器的正确性。

### 实现示例

| 文件 | 验证内容 |
|------|----------|
| `0651_soc_mmio_smoke.c` | GPIO OUT/OE 写后读、GPIO IN 只读验证、UART 使能/状态查询/TX 发送 |
| `0652_soc_mmio_gpio_uart.c` | GPIO bit 级操作、OUT/OE 独立验证、IN 只读确认、UART 多字符串发送 |

# 4 C 裸机约束

- 不使用标准库、`printf`、`malloc`、系统调用。
- 普通 C 测试不主动触发异常或访问 CSR；专门的 trap/CSR 测试除外。
- 不使用乘除法（RV32I 不含 M 扩展）。
- 不主动、故意写地址 `0x00040100`。
- 全局变量可以使用；`.rodata`/`.data` 通过 `dmem.mem` 初始化，`.bss` 由 `crt0.S` 进入 `main` 前清零。
