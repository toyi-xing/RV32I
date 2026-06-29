#include "platform.h"

#===============================================================================
# 0602_uart_tx.S - UART0 TX MMIO smoke test
#
# 目的：
#   - 软件写 UART0 CTRL.enable。
#   - 读取 UART0 STATUS.ready。
#   - 连续写 TXDATA，testbench 应观察到 UART TX event。
#
# PASS 条件：
#   - UART0 STATUS bit0 为 1。
#   - 写 TXDATA 后程序最终写 DMEM_BASE+0x100 = 1。
#===============================================================================


.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)       # x20 = DMEM_BASE
    lui   x21, %hi(UART0_BASE)
    addi  x21, x21, %lo(UART0_BASE)      # x21 = UART0_BASE = 0x00082000

    # =========================================================================
    # UART 使能 — 写 UART_CTRL.enable = 1
    # =========================================================================
    addi  x5, x0, 1
    sw    x5, UART_CTRL_OFFSET(x21)  # UART0_CTRL = 1 → 使能 TX

    # =========================================================================
    # STATUS 轮询 — 检查 UART_STATUS.ready 是否为 1
    # =========================================================================
    lw    x6, UART_STATUS_OFFSET(x21)   # 读 STATUS
    andi  x6, x6, 1                  # 只保留 bit0 (ready)
    beq   x6, x0, fail               # ready=0 → 外设未就绪，FAIL

    # =========================================================================
    # TX 发送 — 连续发送 "UART\n" 字符串
    # =========================================================================
    addi  x5, x0, 'U'
    sw    x5, UART_TXDATA_OFFSET(x21)   # TX 'U'
    addi  x5, x0, 'A'
    sw    x5, UART_TXDATA_OFFSET(x21)   # TX 'A'
    addi  x5, x0, 'R'
    sw    x5, UART_TXDATA_OFFSET(x21)   # TX 'R'
    addi  x5, x0, 'T'
    sw    x5, UART_TXDATA_OFFSET(x21)   # TX 'T'
    addi  x5, x0, 10
    sw    x5, UART_TXDATA_OFFSET(x21)   # TX '\n'

    # =========================================================================
    # PASS/FAIL — 写 TEST_STATUS 结束仿真
    # =========================================================================
pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

fail:
    addi  x5, x0, 2
    sw    x5, TEST_STATUS_OFFSET(x20)
    jal   x0, done
