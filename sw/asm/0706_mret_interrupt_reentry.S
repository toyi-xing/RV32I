# 0706_mret_interrupt_reentry.S — MRET 同拍 interrupt 重入语义
#
# 目的：
#   - handler 第一次进入时不清除 external/GPIO 中断源，mret 时 MPIE 使能中断。
#   - MRET 返回边界立即再次接受 interrupt（MRET+interrupt）。
#   - 第二次 handler 清除中断源后正常 mret，回到主流程。
#   - 验证 mcause/mepc/mstatus.MIE/MPIE 符合"先 MRET，再 interrupt entry"。
#
# 通过条件：
#   - handler 共进入 2 次。
#   - 两次 mepc 都等于指令 CSRRS 之后的 after_enable。
#   - 两次 mcause 都是 MEIP。
#   - 第二次 handler entry 时 mstatus.MIE=0 且 MPIE=1，符合 MRET+interrupt entry。
#   - 最终正常 mret 回主流程后 mstatus.MIE=1 且 MPIE=1。
#
# 错误码（DMEM_BASE+0x104）：
#   1: handler 进入次数 != 2
#   2: 第一次 mepc 不是 after_enable
#   3: 第二次 mepc 不是 after_enable
#   4: 第一次 mcause 不是 MEIP
#   5: 第二次 mcause 不是 MEIP
#   6: handler 收到非 MEIP trap
#   7: 第二次 entry 的 mstatus 不符合 MRET+interrupt entry 语义
#   8: 最终 mret 回主流程后的 mstatus 不符合普通 MRET 语义

#include "platform.h"
#include "tb_rv32i_soc_test.h"

.equ HANDLER_COUNT_OFFSET,  0x200
.equ FIRST_MEPC_OFFSET,     0x204
.equ SECOND_MEPC_OFFSET,    0x208
.equ FIRST_MCAUSE_OFFSET,   0x20c
.equ SECOND_MCAUSE_OFFSET,  0x210
.equ FIRST_MSTATUS_OFFSET,  0x214
.equ SECOND_MSTATUS_OFFSET, 0x218
.equ FINAL_MSTATUS_OFFSET,  0x21c

.section .text.init
.globl _start

_start:
    jal x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)                  # x20 = DMEM_BASE

    # ------------------------------------------------------------------
    # 初始化
    # ------------------------------------------------------------------
    csrw  mie, x0
    csrrc x0, mstatus, MSTATUS_MIE

    lui   x5, %hi(GPIO0_BASE)
    addi  x5, x5, %lo(GPIO0_BASE)
    sw    x0, GPIO_IRQ_EN_OFFSET(x5)
    sw    x0, GPIO_IRQ_RISE_EN_OFFSET(x5)
    sw    x0, GPIO_IRQ_PENDING_OFFSET(x5)

    sw    x0, HANDLER_COUNT_OFFSET(x20)
    sw    x0, FIRST_MSTATUS_OFFSET(x20)
    sw    x0, SECOND_MSTATUS_OFFSET(x20)
    sw    x0, FINAL_MSTATUS_OFFSET(x20)

    # 确保 GPIO bit 0 初始为低
    lui   x5, %hi(TB_GPIO0_CLR_MASK_ADDR)
    addi  x5, x5, %lo(TB_GPIO0_CLR_MASK_ADDR)
    addi  x6, x0, 1
    sw    x6, 0(x5)
    nop; nop; nop; nop; nop
    nop; nop; nop; nop; nop

    # ==================================================================
    # Step 1: 配置 rising edge，使能 MEIE，开 MIE → 触发中断链
    # ==================================================================

    # 配置上升沿触发 bit 0
    lui   x5, %hi(GPIO0_BASE)
    addi  x5, x5, %lo(GPIO0_BASE)
    addi  x6, x0, 1
    sw    x6, GPIO_IRQ_EN_OFFSET(x5)                 # IRQ_EN[0] = 1
    sw    x6, GPIO_IRQ_RISE_EN_OFFSET(x5)            # RISE_EN[0] = 1
    sw    x6, GPIO_IRQ_PENDING_OFFSET(x5)            # 清残留

    li    x5, MIE_MEIE
    csrw  mie, x5                                    # 使能 MEIE

    # 上升沿：TB 置位 bit 0
    lui   x5, %hi(TB_GPIO0_SET_MASK_ADDR)
    addi  x5, x5, %lo(TB_GPIO0_SET_MASK_ADDR)
    addi  x6, x0, 1
    sw    x6, 0(x5)

    # 等待 pending 置位
    nop; nop; nop; nop; nop
    nop; nop; nop; nop; nop

    # ==================================================================
    # CSRRS 同拍触发第一次中断
    # ==================================================================
    # MEIE=1, MIE=0, MEIP=1 → CSRRS 提交后 MIE=1，
    # trap_ctrl 同拍接受 interrupt，mepc = after_enable。
    # 触发过程与 0705 完全相同（见 0705 对应位置的注释）。
    # ==================================================================
    csrrs x0, mstatus, MSTATUS_MIE

after_enable:
    # 期望：handler 第一次进入时不消 pending → MRET 时立刻重入
    # handler 第二次进入时消 pending → mret 回到此处

    # 验证 handler 共进入 2 次
    lw    x5, HANDLER_COUNT_OFFSET(x20)
    addi  x6, x0, 2
    bne   x5, x6, fail_count

    # 验证第一次 mepc = after_enable
    lw    x5, FIRST_MEPC_OFFSET(x20)
    la    x6, after_enable
    bne   x5, x6, fail_first_mepc

    # 验证第二次 mepc = after_enable（MRET+interrupt 不改变 mepc）
    lw    x5, SECOND_MEPC_OFFSET(x20)
    la    x6, after_enable
    bne   x5, x6, fail_second_mepc

    # 验证第一次 mcause 是 MEIP
    lw    x5, FIRST_MCAUSE_OFFSET(x20)
    li    x6, MCAUSE_INTERRUPT_BIT
    and   x5, x5, x6
    beq   x5, x0, fail_first_cause
    lw    x5, FIRST_MCAUSE_OFFSET(x20)
    li    x6, MCAUSE_CODE_MASK
    and   x5, x5, x6
    addi  x6, x0, 11
    bne   x5, x6, fail_first_cause

    # 验证第二次 mcause 是 MEIP
    lw    x5, SECOND_MCAUSE_OFFSET(x20)
    li    x6, MCAUSE_INTERRUPT_BIT
    and   x5, x5, x6
    beq   x5, x0, fail_second_cause
    lw    x5, SECOND_MCAUSE_OFFSET(x20)
    li    x6, MCAUSE_CODE_MASK
    and   x5, x5, x6
    addi  x6, x0, 11
    bne   x5, x6, fail_second_cause

    # 第二次 entry 是 MRET+interrupt 的 interrupt entry 结果：
    # MIE 应被 interrupt entry 清 0，MPIE 保持 old MPIE=1。
    lw    x5, SECOND_MSTATUS_OFFSET(x20)
    li    x6, MSTATUS_MIE
    and   x7, x5, x6
    bne   x7, x0, fail_second_mstatus
    li    x6, MSTATUS_MPIE
    and   x7, x5, x6
    beq   x7, x0, fail_second_mstatus

    # 第二次 handler 清 pending 后普通 mret 回主流程：
    # MIE <= MPIE = 1, MPIE <= 1。
    csrr  x5, mstatus
    sw    x5, FINAL_MSTATUS_OFFSET(x20)
    li    x6, MSTATUS_MIE
    and   x7, x5, x6
    beq   x7, x0, fail_final_mstatus
    li    x6, MSTATUS_MPIE
    and   x7, x5, x6
    beq   x7, x0, fail_final_mstatus

pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

fail_count:
    addi  x5, x0, 1
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    jal   x0, fail
fail_first_mepc:
    addi  x5, x0, 2
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    jal   x0, fail
fail_second_mepc:
    addi  x5, x0, 3
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    jal   x0, fail
fail_first_cause:
    addi  x5, x0, 4
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    jal   x0, fail
fail_second_cause:
    addi  x5, x0, 5
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    jal   x0, fail
fail_second_mstatus:
    addi  x5, x0, 7
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    jal   x0, fail
fail_final_mstatus:
    addi  x5, x0, 8
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
fail:
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFFSET(x20)
    jal   x0, done

# ====================================================================
# Trap handler — 两次进入，第一次不清 pending，第二次清
# ====================================================================
.section .text.trap
trap_handler:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)

    # 递增 handler 进入次数
    lw    x5, HANDLER_COUNT_OFFSET(x20)
    addi  x5, x5, 1
    sw    x5, HANDLER_COUNT_OFFSET(x20)

    # 验证 mcause 是 MEIP；其他 trap 视为未预期
    csrr  x6, mcause
    csrr  x12, mstatus
    li    x7, MCAUSE_INTERRUPT_BIT
    and   x8, x6, x7
    beq   x8, x0, unexpected_trap                       # 非 interrupt
    li    x7, MCAUSE_CODE_MASK
    and   x8, x6, x7
    addi  x7, x0, 11
    bne   x8, x7, unexpected_trap                       # 非 MEIP

    csrr  x7, mepc

    lw    x5, HANDLER_COUNT_OFFSET(x20)
    addi  x9, x0, 1
    beq   x5, x9, first_entry                            # 第一次跳转

    # ---- 第二次进入 ----
    sw    x6, SECOND_MCAUSE_OFFSET(x20)
    sw    x7, SECOND_MEPC_OFFSET(x20)
    sw    x12, SECOND_MSTATUS_OFFSET(x20)

    # 清 GPIO pending
    lui   x10, %hi(GPIO0_BASE)
    addi  x10, x10, %lo(GPIO0_BASE)
    lw    x11, GPIO_IRQ_PENDING_OFFSET(x10)
    sw    x11, GPIO_IRQ_PENDING_OFFSET(x10)
    # 清 TB 驱动力
    lui   x10, %hi(TB_GPIO0_CLR_MASK_ADDR)
    addi  x10, x10, %lo(TB_GPIO0_CLR_MASK_ADDR)
    addi  x11, x0, 1
    sw    x11, 0(x10)

    mret

    # ---- 第一次进入：不清 pending，直接 mret → MRET+interrupt ----
    #
    # 此时 mstatus.MIE=0, MPIE=1（第一次中断 entry 时保存的旧 MIE 值）。
    # GPIO pending 未被清除，因此 MEIP 仍为 1。
    #
    # mret 进入 MEM 提交阶段时，MRET 硬件自动：
    #   1. mstatus.MIE <= MPIE = 1（恢复旧 MIE，即开中断）。
    #   2. 同拍 trap_ctrl 检测到 mret_accept == 1 且
    #      MRET 后的 MIE=1, MEIE=1, MEIP=1 → mret_irq_request 成立。
    #   3. 同一拍同时接受 MRET 提交 + interrupt trap entry
    #      （即 "MRET+interrupt" 语义）。
    #   4. mepc 保持当前值（仍是第一次中断的返回地址 after_enable），
    #      不更新——因为 MRET+interrupt 的 mepc 是 MRET 要返回的位置，
    #      也是本次中断结束后应回去的位置。
    #   5. mstatus.MIE <= 0（中断 entry 关全局中断）。
    #   6. mstatus.MPIE <= 旧 MPIE（即 1，等价于"先 MRET 再 interrupt
    #      entry"的语义：MRET 恢复 MIE，interrupt entry 再关掉它，
    #      但 MPIE 保留 MRET 恢复前的值）。
    #   7. Kill IF/ID, ID/EX, EX/MEM, MEM/WB（MRET 的 WB 被 killed）。
    #   8. Redirect 到 mtvec（0x80），进入第二次 trap_handler。
    #
    # 从软件视角来看，MRET 之后没有执行任何一条用户指令，
    # 流水线直接重定向回 mtvec，因此表现为"MRET 返回边界立即重入中断"。
    # ==================================================================
first_entry:
    sw    x6, FIRST_MCAUSE_OFFSET(x20)
    sw    x7, FIRST_MEPC_OFFSET(x20)
    sw    x12, FIRST_MSTATUS_OFFSET(x20)
    mret

unexpected_trap:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    addi  x5, x0, 6
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFFSET(x20)
    jal   x0, done
