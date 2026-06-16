#===============================================================================
# 0105_jump.S — RV32I jump directed test skeleton
#
# 计划覆盖：
#   JAL, JALR
#
# 建议测试点：
#   - JAL 跳转到正确 target
#   - JAL 写回 rd = pc + 4
#   - JALR target = (rs1 + imm) & ~1
#   - JALR 写回 rd = pc + 4
#   - rd = x0 时不写回
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
    # JAL forward（rd=x0）
    jal   x0, 1f
    jal   x0, fail
1:
    # JAL link（rd!=x0）：验证回写地址 = PC+4
    auipc x1, 0x0
    addi  x1, x1, 12        # x1 = auipc_PC + 12 = JAL_PC + 4
    jal   x2, 2f
    jal   x0, fail
2:
    bne   x1, x2, fail

    # JAL 后跳：验证 J-type 负偏移
    beq   x0, x0, 1f          # 前跳进测试体
    jal   x0, fail
jal_bwd:                      # 后跳目标
    beq   x0, x0, 2f          # 走到后续测试
1:
    jal   x0, jal_bwd         # 后跳（应 taken）
    jal   x0, fail            # 没后跳 → fail
2:

    # JALR link（rd!=x0）：验证回写地址
    auipc x3, 0x0
    addi  x3, x3, 16        # x3 = target
    jalr  x4, x3, 0         # x4 = JALR_PC + 4, jump to target
    jal   x0, fail
    # target:
    auipc x5, 0x0
    addi  x5, x5, -8        # x5 = target_PC - 8 = JALR_PC
    addi  x5, x5, 4         # x5 = JALR_PC + 4 = 预期回写地址
    bne   x4, x5, fail

    # JALR rd=x0：不回写
    auipc x6, 0x0
    addi  x6, x6, 16        # x6 = target
    jalr  x0, x6, 0         # 仅跳转，不回写
    jal   x0, fail
    # target:
    add   x8, x0, x0        # x8 = 0
    bne   x8, x0, fail      # 验证 x0 未被 JALR 写入

    # JALR 正偏移（imm=8）
    auipc x9, 0x0
    addi  x9, x9, 12        # x9 = target_forward
    jalr  x0, x9, 8         # target = (x9 + 8) & ~1
    jal   x0, fail          # 未跳 → fail
    jal   x0, fail          # 未跳 → fail

    # JALR LSB clearing：bit0 应被强制为 0
    auipc x7, 0x0
    addi  x7, x7, 17        # x7 = PC + 17（奇数）
    jalr  x0, x7, 0         # target = (PC+17) & ~1 = PC+16
    jal   x0, fail

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
