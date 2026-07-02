# 0802_dmem_wait_forwarding.S — DMEM wait 下 forwarding 与 consumer 正确性
#
# 目的：
#   - 验证 MEM wait 期间 MEM/WB 作为 forwarding source 能正确供应数据。
#   - 覆盖 delayed load 后立即被 ALU 运算、addi 立即数、store data 使用。
#   - 验证 load-use stall + MEM wait 组合场景。
#
# 延迟配置：
#   - DMEM resp_delay = 4（固定），确保每次 load 都经历 wait-state。
#
# 通过条件：
#   - 各阶段运算/转发/写回结果与预期一致。
#   - CHECK_EQ 按位或汇总到 x24，最终 x24 == 0。
#
# 错误码（0x104）：
#   x24 bit[0] (0x01): delayed load + addi 结果不匹配（load-use stall）
#   x24 bit[1] (0x02): (预留，不用)
#   x24 bit[2] (0x04): (预留，不用)
#   x24 bit[4] (0x08): load + store data forwarding 不匹配
#   x24 bit[5] (0x10): 第二组 load + ALU 运算不匹配
#   x24 bit[6] (0x20): 连续 load 后链式加不匹配

#include "tb_rv32i_soc_test.h"

.macro CHECK_EQ rs1, rs2, mask
    beq   \rs1, \rs2, 1f
    li    x31, \mask
    or    x24, x24, x31
1:
.endm

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    addi  x24, x0, 0
    # DMEM resp_delay = 4（固定延迟）
    lui   x21, %hi(TB_RESP_DELAY_CFG0_ADDR)
    addi  x21, x21, %lo(TB_RESP_DELAY_CFG0_ADDR)
    addi  x5, x0, 4
    sw    x5, 0(x21)

    addi  x22, x20, 0x240

    # ------------------------------------------------------------------
    # 1. delayed load + addi（load-use stall → forwarding）
    #    lw  x6, 0(x22)       # DMEM wait, 4 拍后得到 41
    #    addi x7, x6, 1        # stall 等待 x6 就绪 → 42
    # ------------------------------------------------------------------
    addi  x5, x0, 41
    sw    x5, 0(x22)
    lw    x6, 0(x22)
    addi  x7, x6, 1
    addi  x8, x0, 42
    CHECK_EQ x7, x8, 0x00000001

    # ------------------------------------------------------------------
    # 2. delayed load + 直接 forwarding（无 stall，同拍 forwarding）
    #    lw  x6, 4(x22)       # DMEM wait, 4 拍后得到 5
    #    addi x7, x6, 7        # x6 来自 MEM/WB forwarding → 12
    # ------------------------------------------------------------------
    addi  x5, x0, 5
    sw    x5, 4(x22)
    lw    x6, 4(x22)
    beq   x6, x5, 1f
    li    x31, 0x00000002
    or    x24, x24, x31
1:
    addi  x7, x6, 7
    addi  x8, x0, 12
    CHECK_EQ x7, x8, 0x00000004

    # ------------------------------------------------------------------
    # 3. delayed load → store data forwarding（store 使用 load 结果）
    #    lw  x6, 8(x22)
    #    sw  x6, 12(x22)       # store data 来自 MEM/WB forwarding
    #    lw  x7, 12(x22)       # 再读回验证
    # ------------------------------------------------------------------
    li    x5, 0x13579bdf
    sw    x5, 8(x22)
    lw    x6, 8(x22)
    sw    x6, 12(x22)
    lw    x7, 12(x22)
    CHECK_EQ x6, x7, 0x00000008

    # ------------------------------------------------------------------
    # 4. delayed load 后较长依赖链
    #    lw  x5, 16(x22)
    #    addi x10, x0, 3      # 不依赖 load 的独立指令
    #    addi x11, x10, 4
    #    addi x12, x11, 5
    #    addi x13, x12, 6
    #    add  x14, x13, x5    # 最终使用 x5（来自 MEM/WB forwarding）
    # ------------------------------------------------------------------
    li    x9, 0x2468ace0
    sw    x9, 16(x22)
    lw    x5, 16(x22)
    addi  x10, x0, 3
    addi  x11, x10, 4
    addi  x12, x11, 5
    addi  x13, x12, 6
    add   x14, x13, x5
    li    x15, 0x2468acf2
    CHECK_EQ x14, x15, 0x00000010

    # ------------------------------------------------------------------
    # 5. 连续 load 后结果加法
    #    lw  x6, 20(x22)      # DMEM wait
    #    add x7, x6, x6        # forwarding x6 → 2*x6
    # ------------------------------------------------------------------
    li    x5, 0x11223344
    sw    x5, 20(x22)
    lw    x6, 20(x22)
    add   x7, x6, x6
    li    x8, 0x22446688
    CHECK_EQ x7, x8, 0x00000020

    bne   x24, x0, fail
pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

fail:
    sw    x24, TEST_ERROR_CODE_OFFSET(x20)
    addi  x5, x0, 2
    sw    x5, TEST_STATUS_OFFSET(x20)
    jal   x0, done
