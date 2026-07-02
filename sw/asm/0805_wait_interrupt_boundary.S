# 0805_wait_interrupt_boundary.S — MEM wait 期间 interrupt 不越过 older 指令
#
# 目的：
#   - 验证在 older 的 DMEM load 等待 response 期间，timer interrupt 不
#     越过该 older 指令提前进入 trap，确保精确中断语义。
#   - response completion 后 core 回到正常提交边界，此时才接受 interrupt。
#   - 检查 older load 的结果在 interrupt handler 返回后仍可用。
#
# 延迟配置：
#   - DMEM resp_delay = 7（固定），保证 older load 经历多个 wait 周期。
#   - TIMER0 配置 MTIMECMP=2，确保 load wait 期间 MTIP 置位。
#
# 测试流程：
#   1. 配置 timer 在 2 拍后触发 MTIP。
#   2. 对 DMEM 执行 load（resp_delay=7），该 load 进入 MEM wait。
#   3. 在 wait 期间 MTIP 置位，但 core 不应立即 trap。
#   4. load response 返回后，core 继续提交，在提交边界接受 timer interrupt。
#   5. handler 记录 mepc，关 timer，mret 继续。
#   6. main 检查 interrupt handler 的 mepc == after_wait_load。
#
# 通过条件：
#   - handler 记录的 mepc 地址 == after_wait_load。
#   - older load 的值（0x13572468）在 interrupt 前后保持一致。
#
# 错误码（0x104）：
#   0x01: older load 回读值不匹配
#   0x02: mepc != after_wait_load
#   0x100: exception trap（非 interrupt）
#   0x200: 非 timer interrupt（mcause 不匹配）

#include "tb_rv32i_soc_test.h"

.equ SAVED_MEPC_OFFSET, 0x300
.equ IRQ_SEEN_OFFSET,   0x304
.equ LOAD_VALUE_OFFSET, 0x308
.equ SAVED_X6_OFFSET,   0x30c

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    addi  x24, x0, 0

    # 关中断，安全初始化
    csrw  mie, x0
    csrrc x0, mstatus, MSTATUS_MIE

    # DMEM resp_delay = 7（固定延迟）
    lui   x21, %hi(TB_RESP_DELAY_CFG0_ADDR)
    addi  x21, x21, %lo(TB_RESP_DELAY_CFG0_ADDR)
    addi  x5, x0, 7
    sw    x5, 0(x21)

    # 初始化 DMEM 数据区
    li    x5, 0x13572468
    sw    x5, LOAD_VALUE_OFFSET(x20)
    sw    x0, TEST_ERROR_CODE_OFFSET(x20)
    sw    x0, SAVED_MEPC_OFFSET(x20)
    sw    x0, IRQ_SEEN_OFFSET(x20)

    # 配置 TIMER0：MTIMECMP=2，使能后在 2 拍后触发 MTIP
    lui   x21, %hi(TIMER0_BASE)
    addi  x21, x21, %lo(TIMER0_BASE)
    sw    x0, TIMER32_CTRL_OFFSET(x21)
    addi  x5, x0, 2
    sw    x5, TIMER32_MTIMECMP_OFFSET(x21)
    sw    x0, TIMER32_MTIME_OFFSET(x21)

    # 开 timer 中断和全局中断
    li    x5, MIE_MTIE
    csrw  mie, x5
    csrrs x0, mstatus, MSTATUS_MIE
    addi  x5, x0, TIMER32_CTRL_ENABLE
    sw    x5, TIMER32_CTRL_OFFSET(x21)

    # ==================================================================
    # 执行 older DMEM load（resp_delay=7），进入 MEM wait。
    # 在 wait 期间 MTIP 应已置位，但 core 不应立即 trap。
    # load response 返回后，在 after_wait_load 边界 core 接受 interrupt。
    # ==================================================================
wait_load:
    lw    x6, LOAD_VALUE_OFFSET(x20)
after_wait_load:
    # 验证 load 结果正确（interrupt 前后数据不被破坏）
    li    x7, 0x13572468
    beq   x6, x7, 1f
    addi  x24, x24, 1
1:

    # 等待 interrupt handler 置 IRQ_SEEN
wait_irq:
    lw    x5, IRQ_SEEN_OFFSET(x20)
    beq   x5, x0, wait_irq

    # 检查 mepc == after_wait_load
    lw    x5, SAVED_MEPC_OFFSET(x20)
    la    x6, after_wait_load
    beq   x5, x6, 1f
    addi  x24, x24, 2
1:

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

.section .text.trap
trap_handler:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    sw    x6, SAVED_X6_OFFSET(x20)
    csrr  x5, mcause
    # 必须是 interrupt
    li    x6, MCAUSE_INTERRUPT_BIT
    and   x7, x5, x6
    bne   x7, x0, 1f
    addi  x24, x0, 0x100
    jal   x0, fail
1:
    # 必须是 timer interrupt（cause code = 7）
    li    x6, MCAUSE_CODE_MASK
    and   x7, x5, x6
    addi  x6, x0, 7
    beq   x7, x6, 1f
    addi  x24, x0, 0x200
    jal   x0, fail
1:
    # 记录 mepc 并关 timer
    csrr  x5, mepc
    sw    x5, SAVED_MEPC_OFFSET(x20)
    lui   x5, %hi(TIMER0_BASE)
    addi  x5, x5, %lo(TIMER0_BASE)
    sw    x0, TIMER32_CTRL_OFFSET(x5)
    addi  x6, x0, 1
    sw    x6, IRQ_SEEN_OFFSET(x20)
    lw    x6, SAVED_X6_OFFSET(x20)
    mret
