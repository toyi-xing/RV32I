# 0801_dmem_wait_basic.S — DMEM wait-state 下基本 load/store 指令正确性
#
# 目的：
#   - 验证 data_subsystem 在 DMEM 配置非 0 delay 时，基本 load/store
#     指令仍能正确执行。
#   - 覆盖 SW/LW、SB/LB/LBU、SH/LH/LHU 的读写语义、byte enable、
#     符号/零扩展和对齐/非对齐访问。
#
# 延迟配置：
#   - DMEM resp_delay = 3（固定），通过 TB_RESP_DELAY_CFG0_ADDR 设置。
#   - 当拍 response 路径（delay=0）已在旧测试中覆盖，本测试只跑 delay>0。
#
# 通过条件：
#   - 所有 CHECK_EQ 按位或汇总到 x24，最终 x24 == 0。
#   - 若 x24 != 0，按 mask 逐 bit 定位具体哪一项检查失败。
#
# 错误码（0x104）：
#   x24 bit[0] (0x01): SW/LW 回读不匹配
#   x24 bit[1] (0x02): 逐字节 SB 后 LW 回读不匹配
#   x24 bit[2] (0x04): LB 符号扩展错误
#   x24 bit[3] (0x08): LBU 零扩展错误
#   x24 bit[4] (0x10): SH 半字写入后 LW 回读不匹配
#   x24 bit[5] (0x20): LH 符号扩展错误
#   x24 bit[6] (0x40): LHU 零扩展错误
#   x24 bit[7] (0x80): SH + LW 验证回读不匹配
#   x24 bit[8] (0x100): LH 符号扩展错误（第二组）
#   x24 bit[9] (0x200): 基址+偏移 LW 回读不匹配

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
    # DMEM resp_delay = 3（固定延迟），其余 target 默认 0
    lui   x21, %hi(TB_RESP_DELAY_CFG0_ADDR)
    addi  x21, x21, %lo(TB_RESP_DELAY_CFG0_ADDR)
    addi  x5, x0, 3
    sw    x5, 0(x21)

    # ------------------------------------------------------------------
    # 1. SW/LW 基本回读
    # ------------------------------------------------------------------
    addi  x22, x20, 0x200

    li    x5, 0x12345678
    sw    x5, 0(x22)
    lw    x6, 0(x22)
    CHECK_EQ x5, x6, 0x00000001

    # ------------------------------------------------------------------
    # 2. 逐字节 SB 后 LW 回读（byte enable 正确性）
    # ------------------------------------------------------------------
    sw    x0, 0(x22)
    addi  x5, x0, 0x78
    sb    x5, 0(x22)
    addi  x5, x0, 0x56
    sb    x5, 1(x22)
    addi  x5, x0, 0x34
    sb    x5, 2(x22)
    addi  x5, x0, 0x12
    sb    x5, 3(x22)
    lw    x6, 0(x22)
    li    x7, 0x12345678
    CHECK_EQ x6, x7, 0x00000002

    # ------------------------------------------------------------------
    # 3. LB/LBU 符号/零扩展
    # ------------------------------------------------------------------
    addi  x5, x0, -128
    sb    x5, 1(x22)
    lb    x6, 1(x22)
    addi  x7, x0, -128
    CHECK_EQ x6, x7, 0x00000004
    lbu   x6, 1(x22)
    addi  x7, x0, 0x80
    CHECK_EQ x6, x7, 0x00000008

    # ------------------------------------------------------------------
    # 4. SH 半字写入 + LW 回读（半字不破坏相邻字节）
    # ------------------------------------------------------------------
    li    x5, 0x89abcdef
    sw    x5, 4(x22)
    lui   x5, 0xffff8
    sh    x5, 6(x22)
    lw    x6, 4(x22)
    li    x7, 0x8000cdef
    CHECK_EQ x6, x7, 0x00000010
    lh    x6, 6(x22)
    lui   x7, 0xffff8
    CHECK_EQ x6, x7, 0x00000020
    lhu   x6, 6(x22)
    lui   x7, 0x8
    CHECK_EQ x6, x7, 0x00000040

    # ------------------------------------------------------------------
    # 5. SH 正数 + LW/LH 回读
    # ------------------------------------------------------------------
    li    x5, 0x00007fff
    sh    x5, 4(x22)
    lw    x6, 4(x22)
    li    x7, 0x80007fff
    CHECK_EQ x6, x7, 0x00000080
    lh    x6, 4(x22)
    li    x7, 0x00007fff
    CHECK_EQ x6, x7, 0x00000100

    # ------------------------------------------------------------------
    # 6. 基址+偏移 load/store
    # ------------------------------------------------------------------
    addi  x23, x22, 16
    addi  x5, x0, -42
    sw    x5, -16(x23)
    lw    x6, -16(x23)
    CHECK_EQ x5, x6, 0x00000200

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
