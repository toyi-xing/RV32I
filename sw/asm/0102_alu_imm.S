#===============================================================================
# 0102_alu_imm.S — RV32I I-type ALU directed test skeleton
#
# 计划覆盖：
#   ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
#
# 建议测试点：
#   - 正数、负数、0、-1 的运算结果
#   - 有符号比较和无符号比较的差异
#   - 逻辑右移和算术右移的差异
#   - shift amount 只取 shamt[4:0]
#
# 约定：
#   - x30 = DMEM_BASE，用于写 PASS/FAIL 状态
#   - x31 = status value，1 表示 PASS，2 表示 FAIL
#   - 每个检查点可用 bne 跳到 fail
#===============================================================================

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    # ADDI 正数加、链式累加
    addi  x1, x0, 1
    addi  x1, x1, 2
    addi  x2, x0, 3
    bne   x1, x2, fail

    # ADDI 负数立即数（符号扩展）
    addi  x3, x0, -1
    addi  x4, x0, -2048
    addi  x5, x4, 2047
    bne   x5, x3, fail
    addi  x6, x5, 4
    bne   x6, x2, fail

    # ADDI 正立即数导致 32-bit 回绕
    # 0x7fffffff + 1 = 0x80000000
    lui   x7, 0x80000
    addi  x7, x7, -1
    addi  x8, x7, 1
    lui   x9, 0x80000
    bne   x8, x9, fail

    # SLTI / SLTIU：有符号 / 无符号 小于比较
    #
    # SLTI  0, -1 → 0（有符号：0 不小于 -1）
    # SLTIU 0, -1 → 1（无符号：0 < 0xFFFFFFFF）
    slti  x1, x0, 1          # x1 = (0 < 1) = 1
    addi  x2, x0, 1
    bne   x1, x2, fail

    slti  x1, x0, -1         # x1 = (0 < -1) = 0
    bne   x1, x0, fail

    sltiu x1, x0, -1         # x1 = (0 < 0xFFFFFFFF) = 1    SLTIU指令：rd = (rs1 < unsigned(sign_ext(immI))) ? 1 : 0
    addi  x2, x0, 1
    bne   x1, x2, fail

    slti  x1, x0, 0          # x1 = (0 < 0) = 0
    bne   x1, x0, fail

    # 负数 rs1 的有符号比较
    addi  x1, x0, -2         # x1 = -2
    slti  x2, x1, -1         # x2 = (-2 < -1) = 1
    addi  x3, x0, 1
    bne   x2, x3, fail
    slti  x2, x1, -2         # x2 = (-2 < -2) = 0
    bne   x2, x0, fail
    slti  x2, x1, -3         # x2 = (-2 < -3) = 0
    bne   x2, x0, fail

    # SLTIU：负数按无符号比较是最大值，不会"小于"小正数
    addi  x1, x0, -1         # x1 = 0xFFFFFFFF
    sltiu x2, x1, 2          # x2 = (0xFFFFFFFF < 2) = 0
    bne   x2, x0, fail
    sltiu x2, x0, 2          # x2 = (0 < 2) = 1
    addi  x3, x0, 1
    bne   x2, x3, fail

    # XORI / ORI / ANDI：与或非 立即数
    #
    # 0 ^ X = X, 0 | X = X, 0 & X = 0
    addi  x1, x0, 0x555      # x1 = 0x555
    xori  x2, x0, 0x555      # x2 = 0 ^ 0x555 = 0x555
    bne   x1, x2, fail
    ori   x2, x0, 0x555      # x2 = 0 | 0x555 = 0x555
    bne   x1, x2, fail
    andi  x2, x1, 0x000      # x2 = 0x555 & 0 = 0
    bne   x2, x0, fail

    # X ^ X = 0, X | X = X, X & X = X
    xori  x2, x1, 0x555      # x2 = 0x555 ^ 0x555 = 0
    bne   x2, x0, fail
    ori   x2, x1, 0x555      # x2 = 0x555 | 0x555 = 0x555
    bne   x1, x2, fail
    andi  x2, x1, 0x555      # x2 = 0x555 & 0x555 = 0x555
    bne   x1, x2, fail

    # 负数立即数（符号扩展为 0xFFFFFFFF）
    addi  x1, x0, -1         # x1 = 0xFFFFFFFF
    xori  x2, x1, -1         # x2 = 0xFFFFFFFF ^ 0xFFFFFFFF = 0
    bne   x2, x0, fail
    ori   x2, x1, -1         # x2 = 0xFFFFFFFF | 0xFFFFFFFF = 0xFFFFFFFF
    bne   x1, x2, fail
    andi  x2, x0, -1         # x2 = 0 & 0xFFFFFFFF = 0
    bne   x2, x0, fail

    # 负数立即数边界：-2048 的 12-bit I-immediate 应符号扩展为 0xFFFFF800
    addi  x1, x0, -1         # x1 = 0xFFFFFFFF，用于测试 ANDI 掩码
    addi  x3, x0, -2048      # x3 = 0xFFFFF800，作为期望值
    xori  x2, x0, -2048      # x2 = 0 ^ 0xFFFFF800 = 0xFFFFF800
    bne   x2, x3, fail
    ori   x2, x0, -2048      # x2 = 0 | 0xFFFFF800 = 0xFFFFF800
    bne   x2, x3, fail
    andi  x2, x1, -2048      # x2 = 0xFFFFFFFF & 0xFFFFF800 = 0xFFFFF800
    bne   x2, x3, fail

    # 混合位图：0x55555555 ^ 0x555 = 0x55555000
    lui   x1, 0x55555
    addi  x1, x1, 0x555      # x1 = 0x55555555
    xori  x2, x1, 0x555      # x2 = 0x55555555 ^ 0x555 = 0x55555000
    lui   x3, 0x55555
    bne   x2, x3, fail

    # SLLI / SRLI / SRAI：左移 / 逻辑右移 / 算术右移
    #
    # SLLI：左移
    addi  x1, x0, 1
    slli  x1, x1, 0          # 移 0 位不变
    addi  x2, x0, 1
    bne   x1, x2, fail

    slli  x1, x1, 4          # 1 << 4 = 16
    addi  x2, x0, 16
    bne   x1, x2, fail

    slli  x1, x1, 1          # 16 << 1 = 32
    addi  x2, x0, 32
    bne   x1, x2, fail

    addi  x1, x0, 1
    slli  x1, x1, 31         # 1 << 31 = 0x80000000
    lui   x2, 0x80000
    bne   x1, x2, fail

    # SRLI：逻辑右移补 0
    lui   x1, 0x80000        # x1 = 0x80000000
    srli  x1, x1, 31         # 逻辑右移 31 → 1
    addi  x2, x0, 1
    bne   x1, x2, fail

    # SRAI vs SRLI：负数高位右移差异
    lui   x1, 0x80000        # x1 = 0x80000000（符号位 = 1）
    srli  x2, x1, 1          # x2 = 0x40000000（补 0）
    lui   x3, 0x40000
    bne   x2, x3, fail
    srai  x2, x1, 1          # x2 = 0xC0000000（补符号位 1）
    lui   x3, 0xC0000
    bne   x2, x3, fail

    # -1 右移 31 位：SRLI 只补 0 得到 1，SRAI 补符号位仍保持 -1
    addi  x1, x0, -1         # x1 = 0xFFFFFFFF
    srli  x2, x1, 31         # x2 = 0x00000001
    addi  x3, x0, 1
    bne   x2, x3, fail
    srai  x2, x1, 31         # x2 = 0xFFFFFFFF
    bne   x2, x1, fail

    # 正数高位为 0：SRLI == SRAI
    addi  x1, x0, 0x7ff      # x1 = 0x7ff（正数）
    srli  x2, x1, 2          # x2 = 0x1ff
    srai  x3, x1, 2          # x3 = 0x1ff（正数时相同）
    bne   x2, x3, fail
    addi  x4, x0, 0x1ff
    bne   x2, x4, fail

pass:
    lui   x30, 0x40
    addi  x31, x0, 1
    sw    x31, 0x100(x30)

done:
    jal   x0, done

fail:
    lui   x30, 0x40
    addi  x31, x0, 2
    sw    x31, 0x100(x30)
    jal   x0, done
