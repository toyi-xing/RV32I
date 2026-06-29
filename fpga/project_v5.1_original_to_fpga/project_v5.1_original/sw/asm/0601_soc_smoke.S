#include "platform.h"

#===============================================================================
# 0601_soc_smoke.S - SoC wrapper 最小冒烟测试
#
# 目的：
#   - 通过 rv32i_soc 跑通最小取指、执行、DMEM 写入和 PASS/FAIL 通路。
#   - 不访问 MMIO，先确认 SoC wrapper/data_subsystem 未破坏 core 主路径。
#
# PASS 条件：
#   - testbench 检测到 DMEM_BASE+0x100 写入 1 后打印 PASS。
#===============================================================================

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    # =========================================================================
    # ALU 冒烟 — 两个立即数相加，验证基本取指/译码/执行通路
    # =========================================================================
    addi  x1, x0, 7
    addi  x2, x0, 5
    add   x3, x1, x2          # x3 = 12
    addi  x4, x0, 12
    bne   x3, x4, fail

    # =========================================================================
    # DMEM 访存 — 通过 SoC data_subsystem 写/读 DMEM，验证主线访存通路
    # =========================================================================
    lui   x10, %hi(DMEM_BASE)
    addi  x10, x10, %lo(DMEM_BASE)           # x10 = DMEM_BASE = 0x00040000
    sw    x3, 0x000(x10)
    lw    x5, 0x000(x10)         # 读回 DMEM[0]，验证 data_subsystem DMEM 通路
    bne   x5, x4, fail

    # =========================================================================
    # PASS/FAIL — 写 TEST_STATUS 结束仿真
    # =========================================================================
pass:
    addi  x11, x0, 1
    sw    x11, TEST_STATUS_OFFSET(x10)

done:
    jal   x0, done

fail:
    lui   x10, %hi(DMEM_BASE)
    addi  x10, x10, %lo(DMEM_BASE)
    addi  x11, x0, 2
    sw    x11, TEST_STATUS_OFFSET(x10)
    jal   x0, fail
