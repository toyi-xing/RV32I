#===============================================================================
# 0101_branch.S — RV32I branch directed test skeleton
#
# 计划覆盖：
#   BEQ, BNE, BLT, BGE, BLTU, BGEU
#
# 建议测试点：
#   - 每条 branch 都测 taken 和 not-taken
#   - BLT/BGE 使用正数、负数混合测试有符号比较
#   - BLTU/BGEU 使用同一组操作数测试无符号比较
#   - branch target 前后跳转都可覆盖，先从向前跳转开始
#
# 约定：
#   - x30 = DMEM_BASE，用于写 PASS/FAIL 状态
#   - x31 = status value，1 表示 PASS，2 表示 FAIL
#   - 对于应该 taken 的分支，落空路径直接跳 fail
#   - 对于应该 not-taken 的分支，taken target 直接跳 fail
#===============================================================================

.section .text.init
.globl _start

_start:
    # BEQ 应该成立
    lui   x1, 0x1
    beq   x1, x1, beq_notaken
    jal   x0, fail

    # BEQ 不应该成立
beq_notaken:
    beq   x1, x0, fail

    # BNE 应该成立
bne_taken:
    bne   x1, x0, bne_notaken
    jal   x0, fail

    # BNE 不应该成立
bne_notaken:
    lui   x2, 0x1
    bne   x1, x2, fail

    # BLT（有符号小于）

    # 正 < 正：1 < 2 → taken
    addi  x3, x0, 1
    addi  x4, x0, 2
    blt   x3, x4, blt1
    jal   x0, fail
blt1:
    # 相等：1 < 1 → not-taken
    blt   x3, x3, fail

    # 负 < 正：-1 < 1 → taken
    addi  x5, x0, -1
    addi  x6, x0, 1
    blt   x5, x6, blt2
    jal   x0, fail
blt2:
    # 正 < 负：1 < -1 → not-taken
    addi  x5, x0, 1
    addi  x6, x0, -1
    blt   x5, x6, fail

    # 负 < 负：-2 < -1 → taken
    addi  x5, x0, -2
    addi  x6, x0, -1
    blt   x5, x6, blt3
    jal   x0, fail
blt3:

    # BGE（有符号大于等于）

    # 正 >= 正：2 >= 1 → taken
    addi  x3, x0, 2
    addi  x4, x0, 1
    bge   x3, x4, bge1
    jal   x0, fail
bge1:
    # 相等：1 >= 1 → taken
    addi  x3, x0, 1
    bge   x3, x3, bge2
    jal   x0, fail
bge2:
    # 负 >= 正：-1 >= 1 → not-taken
    addi  x5, x0, -1
    addi  x6, x0, 1
    bge   x5, x6, fail

    # 负 >= 负：-1 >= -2 → taken
    addi  x5, x0, -1
    addi  x6, x0, -2
    bge   x5, x6, bge3
    jal   x0, fail
bge3:

    # BLTU（无符号小于）

    # 正 < 正：1 < 2 → taken
    addi  x3, x0, 1
    addi  x4, x0, 2
    bltu  x3, x4, bltu1
    jal   x0, fail
bltu1:
    # 关键差异：-1（0xFFFFFFFF）是无符号最大值，不应小于 1
    addi  x3, x0, -1
    addi  x4, x0, 1
    bltu  x3, x4, fail      # 0xFFFFFFFF < 1 → false
    bltu  x4, x3, bltu2     # 1 < 0xFFFFFFFF → true
    jal   x0, fail
bltu2:
    # 相等：1 < 1 → not-taken
    addi  x3, x0, 1
    bltu  x3, x3, fail

    # BGEU（无符号大于等于）

    # 相等：5 >= 5 → taken
    addi  x3, x0, 5
    bgeu  x3, x3, bgeu1
    jal   x0, fail
bgeu1:
    # 无符号：1 >= 0xFFFFFFFF → not-taken
    addi  x3, x0, 1
    addi  x4, x0, -1
    bgeu  x3, x4, fail

    # 无符号：0xFFFFFFFF >= 0xFFFFFFFF → taken
    bgeu  x4, x4, bgeu2
    jal   x0, fail
bgeu2:

    # 后跳：验证 B-type 负偏移编码
    beq   x0, x0, bwd_body     # 前跳进测试体
    jal   x0, fail
bwd_dst:                       # 后跳目标
    beq   x0, x0, pass         # 从后跳到达 → 走到 pass
bwd_body:
    addi  x3, x0, 1
    addi  x4, x0, 1
    beq   x3, x4, bwd_dst      # 后跳（应 taken）
    jal   x0, fail             # 没后跳 → fail

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
