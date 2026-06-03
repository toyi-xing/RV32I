#===============================================================================
# load_store.S — RV32I load/store directed test skeleton
#
# 计划覆盖：
#   LB, LH, LW, LBU, LHU, SB, SH, SW
#
# 建议测试点：
#   - SB/SH/SW 的 byte enable 和写数据 lane 对齐
#   - LB/LH 的符号扩展
#   - LBU/LHU 的零扩展
#   - 同一个 word 内不同 byte/halfword offset 的读写
#
# 当前 demo 约束：
#   - 只测试合法、对齐访问；不对齐访问后续异常/trap 阶段再系统测试
#
# 约定：
#   - x29 = DMEM_BASE，用于测试数据区
#   - x30 = DMEM_BASE，用于写 PASS/FAIL 状态
#   - x31 = status value，1 表示 PASS，2 表示 FAIL
#   - 每个检查点可用 bne 跳到 fail
#===============================================================================

.section .text.init
.globl _start

_start:
    lui   x29, 0x10

    # SW / LW：字读写
    #
    # 写小正数再读回
    addi  x1, x0, 42
    sw    x1, 0x000(x29)
    lw    x2, 0x000(x29)
    bne   x1, x2, fail

    # 写全 1 再读回
    addi  x1, x0, -1
    sw    x1, 0x000(x29)
    lw    x2, 0x000(x29)
    bne   x1, x2, fail

    # 写复杂位图再读回
    lui   x1, 0x12345
    addi  x1, x1, 0x678      # x1 = 0x12345678
    sw    x1, 0x000(x29)
    lw    x2, 0x000(x29)
    bne   x1, x2, fail

    # SB / LB / LBU：全 lane 字节写入 + 符号/零扩展
    #
    # 4 个 byte lane 逐一写入后 LW 全 word 验证
    sw    x0, 0x000(x29)         # DMEM_BASE[0] = 0x00000000
    addi  x2, x0, 0x12
    sb    x2, 0x003(x29)         # offset 3 → be=1000
    addi  x2, x0, 0x34
    sb    x2, 0x002(x29)         # offset 2 → be=0100
    addi  x2, x0, 0x56
    sb    x2, 0x001(x29)         # offset 1 → be=0010
    addi  x2, x0, 0x78
    sb    x2, 0x000(x29)         # offset 0 → be=0001
    lw    x3, 0x000(x29)
    lui   x4, 0x12345
    addi  x4, x4, 0x678          # 预期 0x12345678
    bne   x3, x4, fail

    # LB 符号扩展：写 0x80 → LB = 0xFFFFFF80
    addi  x2, x0, -128
    sb    x2, 0x001(x29)
    lb    x3, 0x001(x29)
    addi  x4, x0, -128
    bne   x3, x4, fail

    # LBU 零扩展：写 0x80 → LBU = 0x80
    lbu   x3, 0x001(x29)
    addi  x4, x0, 0x80
    bne   x3, x4, fail

    # LB 符号扩展：写 0xFF → LB = 0xFFFFFFFF（-1）
    addi  x2, x0, -1
    sb    x2, 0x000(x29)
    lb    x3, 0x000(x29)
    addi  x4, x0, -1
    bne   x3, x4, fail

    # LBU 零扩展：写 0xFF → LBU = 0xFF
    lbu   x3, 0x000(x29)
    addi  x4, x0, 0xFF
    bne   x3, x4, fail

    # SH / LH / LHU：半字写入与符号/零扩展
    #
    # 先恢复 word 为 0x12345678
    lui   x1, 0x12345
    addi  x1, x1, 0x678
    sw    x1, 0x000(x29)

    # 在 offset 2 写 0x8000（高半字替换）
    lui   x2, 0xFFFF8        # x2 = 0xFFFF8000
    sh    x2, 0x002(x29)     # DMEM_BASE+2 = 0x8000
    # 预期 full word = 0x80005678
    lw    x3, 0x000(x29)
    lui   x4, 0x80005
    addi  x4, x4, 0x678      # x4 = 0x80005678
    bne   x3, x4, fail

    # LH 符号扩展：读 offset 2 → 0x8000 → LH = 0xFFFF8000
    lh    x3, 0x002(x29)
    lui   x4, 0xFFFF8
    bne   x3, x4, fail

    # LHU 零扩展：读 offset 2 → 0x8000 → LHU = 0x00008000
    lhu   x3, 0x002(x29)
    lui   x4, 0x8            # x4 = 0x00008000
    bne   x3, x4, fail

    # 在 offset 0 写 0x7FFF（低半字替换）
    lui   x2, 0x8
    addi  x2, x2, -1         # x2 = 0x7FFF
    sh    x2, 0x000(x29)     # DMEM_BASE+0 = 0x7FFF
    # 预期 full word = 0x80007FFF
    lw    x3, 0x000(x29)
    lui   x4, 0x80008
    addi  x4, x4, -1         # x4 = 0x80008000 - 1 = 0x80007FFF
    bne   x3, x4, fail

    # LH：0x7FFF → 正数，符号扩展后仍是 0x00007FFF
    lh    x3, 0x000(x29)
    lui   x4, 0x8
    addi  x4, x4, -1         # x4 = 0x00007FFF
    bne   x3, x4, fail

    # 负偏移：load/store immediate 符号扩展
    addi  x28, x29, 16        # x28 = DMEM_BASE + 16
    addi  x1, x0, -42         # x1 = -42
    sw    x1, -16(x28)        # 用负偏移 SW：写入 DMEM_BASE+0
    lw    x2, -16(x28)        # 用负偏移 LW：从 DMEM_BASE+0 读回
    addi  x3, x0, -42
    bne   x2, x3, fail

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
