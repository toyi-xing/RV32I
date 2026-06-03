#===============================================================================
# alu_reg.S — RV32I R-type ALU directed test skeleton
#
# 计划覆盖：
#   ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
#
# 建议测试点：
#   - ADD/SUB 的普通结果和溢出截断结果
#   - SLT 与 SLTU 在同一组操作数上的差异
#   - SRL 与 SRA 对负数的差异
#   - SLL/SRL/SRA 的 shift amount 来自 rs2[4:0]
#
# 约定：
#   - x30 = DMEM_BASE，用于写 PASS/FAIL 状态
#   - x31 = status value，1 表示 PASS，2 表示 FAIL
#   - 每个检查点可用 bne 跳到 fail
#===============================================================================

.section .text.init
.globl _start

_start:
    # ADD / SUB：加减法
    #
    # 0 + 0 = 0
    add   x1, x0, x0
    bne   x1, x0, fail

    # 0 + 1 = 1
    addi  x1, x0, 1          # x1 = 1
    add   x2, x0, x1         # x2 = 0 + 1 = 1
    bne   x1, x2, fail

    # 正 + 正 = 正
    addi  x1, x0, 42
    addi  x2, x0, 100
    add   x3, x1, x2         # x3 = 142
    addi  x4, x0, 142
    bne   x3, x4, fail

    # 正 - 正 = 正
    sub   x3, x2, x1         # x3 = 100 - 42 = 58
    addi  x4, x0, 58
    bne   x3, x4, fail

    # 正 - 正 = 负
    sub   x3, x1, x2         # x3 = 42 - 100 = -58
    addi  x4, x0, -58
    bne   x3, x4, fail

    # 0 - n = -n
    sub   x3, x0, x1         # x3 = 0 - 42 = -42
    addi  x4, x0, -42
    bne   x3, x4, fail

    # 加法溢出绕回：0x7fffffff + 1 = 0x80000000
    lui   x1, 0x80000
    addi  x1, x1, -1         # x1 = 0x7fffffff
    addi  x2, x0, 1
    add   x3, x1, x2         # x3 = 0x7fffffff + 1
    lui   x4, 0x80000
    bne   x3, x4, fail

    # 减法借位绕回：0x80000000 - 1 = 0x7fffffff
    lui   x5, 0x80000
    sub   x6, x5, x2         # x6 = 0x80000000 - 1
    lui   x7, 0x80000
    addi  x7, x7, -1         # x7 = 0x7fffffff
    bne   x6, x7, fail

    # rd=x0：写入应被丢弃
    add   x0, x1, x2         # 尝试写 x0
    add   x3, x0, x0         # x3 = 0（验证 x0 仍为 0）
    bne   x3, x0, fail

    # SLT / SLTU：有符号 / 无符号 小于比较
    #
    # 0 < 1 → 1（两者相同）
    addi  x1, x0, 1
    slt   x2, x0, x1         # x2 = (0 < 1) = 1
    bne   x1, x2, fail
    sltu  x2, x0, x1         # x2 = (0 < 1) unsigned = 1
    bne   x1, x2, fail

    # 相等：不小于自己 → 0
    slt   x2, x1, x1
    bne   x2, x0, fail
    sltu  x2, x1, x1
    bne   x2, x0, fail

    # 关键差异：0x80000000 vs 1
    # SLT（有符号）：-2^31 < 1 → 1
    # SLTU（无符号）：2^31 < 1 → 0
    lui   x1, 0x80000        # x1 = 0x80000000
    addi  x2, x0, 1
    slt   x3, x1, x2         # x3 = 1
    addi  x4, x0, 1
    bne   x3, x4, fail
    sltu  x3, x1, x2         # x3 = 0
    bne   x3, x0, fail

    # 负数比较：-2 < -3 ? 假（-2 更大）
    addi  x1, x0, -2
    addi  x2, x0, -3
    slt   x3, x1, x2         # x3 = 0
    bne   x3, x0, fail
    slt   x3, x2, x1         # x3 = 1
    addi  x4, x0, 1
    bne   x3, x4, fail

    # SLTU：-1 是无符号最大值
    addi  x1, x0, -1         # x1 = 0xFFFFFFFF
    addi  x2, x0, 2
    sltu  x3, x1, x2         # x3 = (0xFFFFFFFF < 2) = 0
    bne   x3, x0, fail
    sltu  x3, x2, x1         # x3 = (2 < 0xFFFFFFFF) = 1
    addi  x4, x0, 1
    bne   x3, x4, fail

    # XOR / OR / AND：按位逻辑
    #
    # 0 ^ X = X, 0 | X = X, 0 & X = 0
    addi  x1, x0, 0x555
    xor   x2, x0, x1         # x2 = 0 ^ 0x555 = 0x555
    bne   x1, x2, fail
    or    x2, x0, x1         # x2 = 0 | 0x555 = 0x555
    bne   x1, x2, fail
    and   x2, x0, x1         # x2 = 0 & 0x555 = 0
    bne   x2, x0, fail

    # X ^ X = 0, X | X = X, X & X = X
    xor   x2, x1, x1
    bne   x2, x0, fail
    or    x2, x1, x1
    bne   x1, x2, fail
    and   x2, x1, x1
    bne   x1, x2, fail

    # 全 1 掩码运算
    addi  x1, x0, -1         # x1 = 0xFFFFFFFF
    xor   x2, x1, x0         # x2 = 0xFFFFFFFF ^ 0 = 0xFFFFFFFF
    bne   x1, x2, fail
    xor   x2, x1, x1         # x2 = 0xFFFFFFFF ^ 0xFFFFFFFF = 0
    bne   x2, x0, fail
    or    x2, x1, x0         # x2 = 0xFFFFFFFF | 0 = 0xFFFFFFFF
    bne   x1, x2, fail
    and   x2, x1, x0         # x2 = 0xFFFFFFFF & 0 = 0
    bne   x2, x0, fail

    # 交替位图：0x55555555 ^ 0xAAAAAAAA = 0xFFFFFFFF
    lui   x1, 0x55555
    addi  x1, x1, 0x555      # x1 = 0x55555555
    lui   x2, 0xAAAAA
    addi  x2, x2, 0x555      # x2 = 0xAAAAA555
    addi  x2, x2, 0x555      # x2 = 0xAAAAAAAA
    xor   x3, x1, x2         # x3 = 0x55555555 ^ 0xAAAAAAAA = 0xFFFFFFFF
    addi  x4, x0, -1
    bne   x3, x4, fail
    and   x3, x1, x2         # x3 = 0x55555555 & 0xAAAAAAAA = 0
    bne   x3, x0, fail
    or    x3, x1, x2         # x3 = 0x55555555 | 0xAAAAAAAA = 0xFFFFFFFF
    addi  x4, x0, -1
    bne   x3, x4, fail

    # SLL / SRL / SRA：移位
    #
    # SLL：左移 0 / 4 / 31 位
    addi  x1, x0, 1
    addi  x2, x0, 0
    sll   x3, x1, x2         # 1 << 0 = 1
    addi  x4, x0, 1
    bne   x3, x4, fail

    addi  x2, x0, 4
    sll   x3, x1, x2         # 1 << 4 = 16
    addi  x4, x0, 16
    bne   x3, x4, fail

    addi  x2, x0, 31
    sll   x3, x1, x2         # 1 << 31 = 0x80000000
    lui   x4, 0x80000
    bne   x3, x4, fail

    # SRL：逻辑右移 0x80000000 >> 31 = 1
    lui   x1, 0x80000
    addi  x2, x0, 31
    srl   x3, x1, x2
    addi  x4, x0, 1
    bne   x3, x4, fail

    # SRA vs SRL：0x80000000 >> 1 的差异
    addi  x2, x0, 1
    srl   x3, x1, x2         # x3 = 0x40000000（补 0）
    lui   x4, 0x40000
    bne   x3, x4, fail
    sra   x3, x1, x2         # x3 = 0xC0000000（补符号位 1）
    lui   x4, 0xC0000
    bne   x3, x4, fail

    # -1 右移 31 位：SRL = 1, SRA = -1
    addi  x1, x0, -1
    addi  x2, x0, 31
    srl   x3, x1, x2         # x3 = 1
    addi  x4, x0, 1
    bne   x3, x4, fail
    sra   x3, x1, x2         # x3 = 0xFFFFFFFF
    bne   x3, x1, fail

    # shamt 只取 [4:0]：移位 32 → shamt=0，移位 33 → shamt=1
    addi  x1, x0, 1
    addi  x2, x0, 32
    sll   x3, x1, x2         # x3 = 1 << 0 = 1
    addi  x4, x0, 1
    bne   x3, x4, fail

    addi  x2, x0, 33
    sll   x3, x1, x2         # x3 = 1 << 1 = 2
    addi  x4, x0, 2
    bne   x3, x4, fail

    # 正数：SRL == SRA
    addi  x1, x0, 0x7ff
    addi  x2, x0, 2
    srl   x3, x1, x2         # x3 = 0x1ff
    sra   x4, x1, x2         # x4 = 0x1ff
    bne   x3, x4, fail
    addi  x5, x0, 0x1ff
    bne   x3, x5, fail

pass:
    lui   x30, 0x10
    addi  x31, x0, 1
    sw    x31, 0x100(x30)

done:
    jal   x0, done

fail:
    lui   x30, 0x10
    addi  x31, x0, 2
    sw    x31, 0x100(x30)
    jal   x0, done
