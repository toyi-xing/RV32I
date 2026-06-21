#===============================================================================
# 0603_gpio_rw.S - GPIO0 MMIO read/write smoke test
#
# 目的：
#   - 写 GPIO0 OUT/OE 并读回验证。
#   - 读取 GPIO0 IN，确认来自 testbench 固定输入 0xA5A55A5A。
#
# PASS 条件：
#   - OUT/OE 读回值正确。
#   - IN 读回值等于 0xA5A55A5A。
#===============================================================================

.equ DMEM_BASE_HI,       0x40
.equ GPIO0_BASE_HI,      0x80
.equ TEST_STATUS_OFF,    0x100
.equ GPIO_OUT_OFF,       0x000
.equ GPIO_IN_OFF,        0x004
.equ GPIO_OE_OFF,        0x008

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, DMEM_BASE_HI       # x20 = DMEM_BASE
    lui   x21, GPIO0_BASE_HI      # x21 = GPIO0_BASE = 0x00080000

    # =========================================================================
    # GPIO OUT — 写 0x13579246，读回验证
    # =========================================================================
    lui   x5, 0x13579
    addi  x5, x5, 0x246          # x5 = 0x13579246
    sw    x5, GPIO_OUT_OFF(x21)  # GPIO0_OUT = 0x13579246
    lw    x6, GPIO_OUT_OFF(x21)  # 读回
    bne   x6, x5, fail

    # =========================================================================
    # GPIO OE — 写 0x0000ffff，读回验证
    # =========================================================================
    lui   x5, 0x00010
    addi  x5, x5, -1             # x5 = 0x0000ffff
    sw    x5, GPIO_OE_OFF(x21)   # GPIO0_OE = 0x0000ffff
    lw    x6, GPIO_OE_OFF(x21)   # 读回
    bne   x6, x5, fail

    # =========================================================================
    # GPIO IN — 读回 testbench 固定驱动值 0xA5A55A5A
    #           构造方式：lui 0xa5a55 → 0xa5a55000, 逐次 addi 得到 0xa5a55a5a
    # =========================================================================
    lui   x5, 0xa5a55
    addi  x5, x5, 0x5a           # x5 = 0xa5a5505a
    addi  x5, x5, 0x500          # x5 = 0xa5a5555a
    addi  x5, x5, 0x500          # x5 = 0xa5a55a5a
    lw    x6, GPIO_IN_OFF(x21)   # 读 GPIO0_IN
    bne   x6, x5, fail            # IN 应等于 TB 驱动的 0xa5a55a5a

    # =========================================================================
    # PASS/FAIL — 写 TEST_STATUS 结束仿真
    # =========================================================================
pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFF(x20)
done:
    jal   x0, done

fail:
    addi  x5, x0, 2
    sw    x5, TEST_STATUS_OFF(x20)
    jal   x0, done
