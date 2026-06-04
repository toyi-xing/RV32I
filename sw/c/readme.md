# C 裸机测试计划

## smoke 测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `c_smoke.c` | C 入口、栈、函数调用、局部变量 — 最小 C 冒烟 |

测试逻辑：定义一个 `main()`，做简单加法后返回 0。如果 core 能正确执行 `crt0.S` → `main()` → 返回 → `crt0.S` 写 PASS 的完整流程，说明 C runtime 和 core 的基本配合正常。

## dmem 初始化测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `dmem_init.c` | `.rodata` 只读表初始化、`.data` 全局变量初始值和写回、`.bss` 清零、局部数组的栈上 load/store、函数调用传参和返回值 |

### 错误码对照

`dmem_init.c` 每个检查点返回不同错误码，FAIL 时可根据返回值定位错误：

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

## C 与汇编测试的分工

汇编测试逐个覆盖 37 条 RV32I 指令的边缘情况。C 测试不追求指令覆盖，而是验证 **C 编译器生成的正常指令流** 在 core 上能正确运行：

| | 汇编测试 | C 测试 |
|--|---------|--------|
| 关注点 | 每条指令的编码和结果 | C runtime + 编译器生成代码的整体正确性 |
| 指令流 | 手写，精确控制 | gcc 编译生成，含栈帧/传参/地址加载等 |
| 数据初始化 | 手动构造 | `.rodata`/`.data`/`.bss` 由 linker + crt0 处理 |
| PASS/FAIL | 内联写 DMEM | `crt0.S` 统一根据 `main()` 返回值写 |
| 排错方式 | 看 dump 对比预期 | 先用错误码缩小范围，再看 dump |

**关键区别**：汇编测试通过 `bne x5, x6, fail` 自检，结果由程序自己判断。C 测试只写 `return N`，由 `crt0.S` 统一判断 `x10/a0` 后写 `TEST_STATUS_ADDR`。

### crt0.S 启动流程

```
_start
  │
  ├─ 设置 sp = __stack_top
  ├─ 清零 .bss 段 (__bss_start ~ __bss_end)
  ├─ jal x1, main
  │       │
  │       └─ main() 返回 0 → 写 1 (PASS)
  │                   返回非0 → 写 2 (FAIL)
  └─ 无限 loop
```

C 程序永远不直接写 `TEST_STATUS_ADDR(0x00010100)`。

## 依赖关系

```
c_smoke.c
  └─→ dmem_init.c  (依赖 crt0 + .data/.bss 通路正常)
```

两个测试都依赖同一个 `crt0.S` 和 `c_baremetal.ld`。如果两个都 FAIL，优先检查：
1. `crt0.S` 是否正常执行到 `main()`（dump 确认 PC 路径）
2. `+dmem=` 是否加载（FAIL 且错误码为 1，说明 `.data` 没初始化）
3. linker 的 `__bss_start`/`__bss_end` 符号是否与 `.bss` 段匹配（`readelf -S` 检查）

## C 裸机约束

- 不使用标准库、`printf`、`malloc`、系统调用、CSR、异常或中断。
- 不使用乘除法（RV32I 不含 M 扩展）。
- 不主动、故意写地址 `0x00010100`。
- 全局变量可以使用；`.rodata`/`.data` 通过 `dmem.mem` 初始化，`.bss` 由 `crt0.S` 进入 `main` 前清零。
