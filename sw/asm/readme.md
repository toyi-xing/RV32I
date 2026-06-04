# 汇编测试计划

## smoke 测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `smoke.S` | 取指、执行、访存、写回、PASS/FAIL 通路 — 最小冒烟 |

## RV32I 指令集测试 `已通过`

| 文件 | 覆盖指令 |
|------|----------|
| `alu_imm.S` | ADDI / SLTI / SLTIU / XORI / ORI / ANDI / SLLI / SRLI / SRAI |
| `alu_reg.S` | ADD / SUB / SLL / SLT / SLTU / XOR / SRL / SRA / OR / AND |
| `load_store.S` | LB / LH / LW / LBU / LHU / SB / SH / SW |
| `branch.S` | BEQ / BNE / BLT / BGE / BLTU / BGEU |
| `jump.S` | JAL / JALR |
| `u_type.S` | LUI / AUIPC |

### 为什么先用汇编，不用 C？

验证 37 条 RV32I 指令阶段，汇编能精确控制每条指令编码、寄存器选择、访存地址和跳转路径。

C 会引入 ABI 约定、栈帧、函数调用、启动代码、`.data`/`.bss` 初始化、编译器额外生成的指令等变量。出错时很难确定是 core 的问题还是编译/链接引入的问题。

### 先测 BEQ / BNE，再测其他

TB 的判断逻辑很简单：检测到 `TEST_STATUS_ADDR` 被写入 1 就 PASS，写其他值就 FAIL。如果测试程序自己不会判断对错，那 TB 只能知道"程序跑完了"，无法知道"每条指令的结果对不对"。

**策略分三步走：**

1. **先测 BEQ / BNE 的 taken / not-taken** — 确认这两条分支指令工作正常。
2. **后续测试用 `bne` 自检** — 算出结果后和预期值比较，不等就跳 `fail`：

   ```asm
   # 算出结果到 x5，预期值到 x6
   bne x5, x6, fail    # 不符就跳 fail
   # 符合则继续下一个测试
   ```

   这样每条指令的正确性由程序自己保证，TB 只负责"走到最后就是 PASS"，信息量比单纯看 commit trace 高得多。
3. **最后回来补全 branch.S** — 等所有测试都用上自检后，再回过来把剩下的 BLT / BGE / BLTU / BGEU 测完。

### 依赖链与交叉验证

每个 .S 文件并非只测自己的指令，也依赖前面已验证的指令甚至是**尚未验证过的指令**来构造测试场景和预期值：

```
smoke (addi / lui / sw / jal)
  └─→ branch.S (beq / bne)
        └─→ u_type.S / alu_imm.S / alu_reg.S / jump.S / load_store.S
```

这种嵌套关系意味着**测试之间在互相验证**：只要全部 PASS，说明整条依赖链上的指令都正确，不需要区分谁是"被测"谁是"辅助"。

**出错了怎么查：**

如果某个测试 FAIL，不要急着怀疑它本身的测试逻辑。先确认它依赖的指令在对应的定向测试中是否通过。例如 u_type.S 用了 SLLI，如果它 FAIL 了，先跑 alu_imm.S 看 SLLI 是否正常。如果 alu_imm.S 也 FAIL，那问题在 alu_imm.S 而非 u_type.S；如果 alu_imm.S 通过，再回头排查 u_type.S 的测试逻辑本身。

### 立即数书写规范

| 立即数类型 | 进制 | 适用指令/场景 | 示例 |
|-----------|------|-------------|------|
| LUI immediate | 16 进制 | `lui` | `lui x1, 0x10000` |
| 地址/掩码/位图 | 16 进制 | `addi` 构造地址、`xori`/`ori`/`andi` 掩码、比较时使用的位图 | `addi x1, x0, 0xFF`, `xori x2, x1, 0x555` |
| 普通小正整数 | 10 进制 | `addi` 做简单加法、构造小值 | `addi x1, x0, 42` |
| 负立即数 / 符号扩展边界 | 10 进制负数 | `addi` 或 xori/ori/andi 做符号扩展测试 | `addi x1, x0, -1`, `addi x1, x0, -2048` |
| Shift amount | 10 进制 | `slli`/`srli`/`srai` | `slli x1, x1, 4` |
| 比较结果 | 10 进制 | `bne` 与预期值比较 | `bne x1, x2, fail` / `bne x1, x0, fail`（x0 即 0） |