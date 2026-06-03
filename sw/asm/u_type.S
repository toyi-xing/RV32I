#===============================================================================
# u_type.S — RV32I U-type 定向测试
#
# 覆盖指令：
#   LUI, AUIPC
#
# 测试点：
#   - LUI 将 imm[31:12] 放到高 20 位，低 12 位为 0
#   - LUI bit31 只是结果位，不做符号扩展
#   - AUIPC 返回 pc + imm
#   - AUIPC 使用当前 PC，而非 PC+4
#   - rd=x0 时写入被丢弃
#
# 约定：
#   - x30 = DMEM_BASE，用于写 PASS/FAIL 状态
#   - x31 = status value，1 表示 PASS，2 表示 FAIL
#   - 每个检查点用 bne 跳到 fail
#===============================================================================

.section .text.init
.globl _start

_start:
    # LUI imm=0：结果应为 0
    lui   x1, 0x0
    bne   x1, x0, fail

    # LUI 正数：0x00001 << 12 = 0x00001000
    lui   x1, 0x1
    addi  x2, x0, 1
    slli  x2, x2, 12
    bne   x1, x2, fail

    # LUI bit31 置位（0xfffff << 12 = 0xfffff000）
    lui   x1, 0xfffff
    addi  x2, x0, -1
    slli  x2, x2, 12
    bne   x1, x2, fail

    # AUIPC imm=0（PC = 0x00000028）：结果应为当前 PC
    auipc x3, 0x0
    addi  x4, x0, 0x28
    bne   x3, x4, fail

    # AUIPC 正数（PC = 0x00000034）：
    # 结果 = 0x00000034 + 0x00001000 = 0x00001034
    auipc x5, 0x1
    lui   x6, 0x1
    addi  x6, x6, 0x34
    bne   x5, x6, fail

    # AUIPC bit31 置位（PC = 0x00000044）：
    # 结果 = 0x00000044 + 0xfffff000 = 0xfffff044
    auipc x7, 0xfffff
    lui   x8, 0xfffff
    addi  x8, x8, 0x44
    bne   x7, x8, fail

    # rd=x0 写入应被丢弃：LUI 写 x0 不影响其他寄存器
    lui   x5, 0x1           # x5 = 0x1000
    lui   x0, 0x2           # 尝试写入 x0，regfile 应丢弃
    addi  x6, x0, 1         # x6 = 1（验证 x0 仍为 0）
    slli  x6, x6, 12        # x6 = 0x1000
    bne   x5, x6, fail      # x5 与 x6 应相等

    # rd=x0 写入应被丢弃：AUIPC 写 x0 不影响其他寄存器
    lui   x5, 0x0           # x5 = 0
    auipc x0, 0x1           # 尝试写入 x0，regfile 应丢弃
    bne   x5, x0, fail      # x5 = x0 = 0，应相等

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
