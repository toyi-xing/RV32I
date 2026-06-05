# 汇编测试计划

## 1. smoke 测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `smoke.S` | 取指、执行、访存、写回、PASS/FAIL 通路 — 最小冒烟 |

## 2. RV32I 指令集测试 `已通过`

| 文件 | 覆盖指令 |
|------|----------|
| `alu_imm.S` | ADDI / SLTI / SLTIU / XORI / ORI / ANDI / SLLI / SRLI / SRAI |
| `alu_reg.S` | ADD / SUB / SLL / SLT / SLTU / XOR / SRL / SRA / OR / AND |
| `load_store.S` | LB / LH / LW / LBU / LHU / SB / SH / SW |
| `branch.S` | BEQ / BNE / BLT / BGE / BLTU / BGEU |
| `jump.S` | JAL / JALR |
| `u_type.S` | LUI / AUIPC |

### 2.1 为什么先用汇编，不用 C？

验证 37 条 RV32I 指令阶段，汇编能精确控制每条指令编码、寄存器选择、访存地址和跳转路径。

C 会引入 ABI 约定、栈帧、函数调用、启动代码、`.data`/`.bss` 初始化、编译器额外生成的指令等变量。出错时很难确定是 core 的问题还是编译/链接引入的问题。

### 2.2 先测 BEQ / BNE，再测其他

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

### 2.3 依赖链与交叉验证

每个 .S 文件并非只测自己的指令，也依赖前面已验证的指令甚至是**尚未验证过的指令**来构造测试场景和预期值：

```
smoke (addi / lui / sw / jal)
  └─→ branch.S (beq / bne)
        └─→ u_type.S / alu_imm.S / alu_reg.S / jump.S / load_store.S
```

这种嵌套关系意味着**测试之间在互相验证**：只要全部 PASS，说明整条依赖链上的指令都正确，不需要区分谁是"被测"谁是"辅助"。

**出错了怎么查：**

如果某个测试 FAIL，不要急着怀疑它本身的测试逻辑。先确认它依赖的指令在对应的定向测试中是否通过。例如 u_type.S 用了 SLLI，如果它 FAIL 了，先跑 alu_imm.S 看 SLLI 是否正常。如果 alu_imm.S 也 FAIL，那问题在 alu_imm.S 而非 u_type.S；如果 alu_imm.S 通过，再回头排查 u_type.S 的测试逻辑本身。

### 2.4 立即数书写规范

| 立即数类型 | 进制 | 适用指令/场景 | 示例 |
|-----------|------|-------------|------|
| LUI immediate | 16 进制 | `lui` | `lui x1, 0x10000` |
| 地址/掩码/位图 | 16 进制 | `addi` 构造地址、`xori`/`ori`/`andi` 掩码、比较时使用的位图 | `addi x1, x0, 0xFF`, `xori x2, x1, 0x555` |
| 普通小正整数 | 10 进制 | `addi` 做简单加法、构造小值 | `addi x1, x0, 42` |
| 负立即数 / 符号扩展边界 | 10 进制负数 | `addi` 或 xori/ori/andi 做符号扩展测试 | `addi x1, x0, -1`, `addi x1, x0, -2048` |
| Shift amount | 10 进制 | `slli`/`srli`/`srai` | `slli x1, x1, 4` |
| 比较结果 | 10 进制 | `bne` 与预期值比较 | `bne x1, x2, fail` / `bne x1, x0, fail`（x0 即 0） |

## 3. 五级流水线数据通路测试 `已通过`

| 文件 | 验证内容 |
|------|----------|
| `pipeline5_nofwd_noredirect.S` | 无 forwarding/redirect 基线冒烟（手插 3 NOP 隔离 RAW） |
| `pipeline5_fwd_noredirect.S` | data hazard 全覆盖：EX/MEM→EX、MEM/WB→EX、WB_IMM、store data、load-use rs1+rs2 |

### 3.1 与单周期测试的差异

**单周期**的汇编测试不需要考虑指令间的数据依赖——每条指令在一个周期内完成读寄存器、运算、写回，下一条指令读到的一定是正确值。

**五级流水**则不同：RAW hazard 需要硬件（forwarding + stall）来解决。因此流水线测试的关注点从"指令语义是否正确"转向"数据依赖是否正确处理"：

- `pipeline5_nofwd_noredirect.S` 在最早期空壳阶段使用，手动在 producer/consumer 之间插 3 条 NOP 来绕过尚未实现的 forwarding。它验证的是**流水线的基础数据通路**——指令能否正确流过 5 级，commit 能否正确输出。
- `pipeline5_fwd_noredirect.S` 在 forwarding + stall 实现后使用，**不插入任何用于隔离 RAW 的 NOP**。所有依赖全部靠硬件解决。采用**累加链**设计：每个 forwarding/load-use 场景的结果累加到同一寄存器，最终减固定常数得 1。任意路径出错都会导致最终结果 ≠ 1。

### 3.2 流水线测试特有的注意事项

- **不使用 branch/JAL/JALR**：control hazard flush 尚未实现，redirect 后的错误路径指令会干扰测试结果。
- **nop 指令的使用**：`nop` 是 `addi x0, x0, 0` 的伪指令。在流水线测试中，nop 不再是"做无害操作"的填充，而是**有意控制流水线距离**的手段（例如在无 forwarding 时拉开 producer/consumer 间距）。在 `pipeline5_fwd_noredirect.S` 中，测试全程不用 nop 隔离 RAW，但收尾仍保留若干 nop 作为合法指令填充，防止 testbench 取到空 ROM 产生误报。
- **测试结果相互独立**：每个测试场景使用不同的寄存器组，避免前一个测试对后一个测试产生 RAW 干扰。
