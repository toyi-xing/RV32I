# 0705_interrupt_commit_precise.S — CSR 写同拍 interrupt 精确提交语义
#
# 目的：
#   - pending 已存在时，CSR 指令打开 mstatus.MIE 后中断在提交边界触发。
#   - 当前 CSR 指令必须先完成提交，再接受 interrupt。
#   - interrupt 的 mepc 指向 CSR 指令之后的返回 PC。
#   - CSR 写 mtvec 同拍接受 interrupt 时，redirect 使用新 mtvec。
#   - 已经提交的 older 指令（store 等）不被 interrupt 错误 kill。
#
# 通过条件：
#   - handler 收到 MEIP（mcause 低 5 位 = 11）。
#   - handler 记录的 mepc == after_mie_enable 的地址。
#   - mtvec 写同拍 interrupt 进入 alt_trap_handler。
#   - alt_trap_handler 记录的 mepc == after_mtvec_write 的地址。
#   - after_mie_enable 之前 store 的 DMEM 值（0xA5A5/0x5A5A）未被破坏。
#
# 错误码（0x40104）：
#   1: mepc 不是 after_mie_enable
#   2: store 值被中断破坏
#   3: score 不等于 2
#   4: handler 收到非 MEIP 中断
#   5: Stage2 提前进入旧 mtvec handler
#   6: mtvec 写同拍 interrupt 没有进入 alt_trap_handler
#   7: mtvec 写同拍 interrupt 的 mepc 不匹配

#include "platform.h"
#include "tb_rv32i_soc_test.h"

.equ SAVED_MEPC_OFFSET,  0x300
.equ SAVED_VAL1_OFFSET,  0x310
.equ SAVED_VAL2_OFFSET,  0x320
.equ CURRENT_STAGE_OFFSET, 0x330
.equ ALT_MEPC_OFFSET,    0x334
.equ ALT_HIT_OFFSET,     0x338
.equ SCORE_OFFSET,       0x108

.section .text.init
.globl _start

_start:
    jal x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    addi  x21, x0, 0
    sw    x0, CURRENT_STAGE_OFFSET(x20)
    sw    x0, ALT_MEPC_OFFSET(x20)
    sw    x0, ALT_HIT_OFFSET(x20)

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

    lui   x5, %hi(TB_GPIO0_CLR_MASK_ADDR)
    addi  x5, x5, %lo(TB_GPIO0_CLR_MASK_ADDR)
    addi  x6, x0, 1
    sw    x6, 0(x5)
    nop; nop; nop; nop; nop; nop; nop; nop; nop; nop

    # ==================================================================
    # Step 1: CSRRS 使能 MIE → 中断在提交后触发
    # ==================================================================

    # 配置上升沿触发 bit 0
    lui   x5, %hi(GPIO0_BASE)
    addi  x5, x5, %lo(GPIO0_BASE)
    addi  x6, x0, 1
    sw    x6, GPIO_IRQ_EN_OFFSET(x5)
    sw    x6, GPIO_IRQ_RISE_EN_OFFSET(x5)
    sw    x6, GPIO_IRQ_PENDING_OFFSET(x5)

    li    x5, MIE_MEIE
    csrw  mie, x5

    # TB 上升沿
    lui   x5, %hi(TB_GPIO0_SET_MASK_ADDR)
    addi  x5, x5, %lo(TB_GPIO0_SET_MASK_ADDR)
    addi  x6, x0, 1
    sw    x6, 0(x5)
    nop; nop; nop; nop; nop; nop; nop; nop; nop; nop

    # Store 测试值到 DMEM
    li    x5, 0xA5A5
    sw    x5, SAVED_VAL1_OFFSET(x20)
    li    x5, 0x5A5A
    sw    x5, SAVED_VAL2_OFFSET(x20)

    # 读回确认（CSRRS 之前）
    lw    x5, SAVED_VAL1_OFFSET(x20)
    li    x6, 0xA5A5
    bne   x5, x6, stage_fail_store

    # 记期望 mepc
    la    x5, after_mie_enable
    sw    x5, SAVED_MEPC_OFFSET(x20)
    addi  x5, x0, 1
    sw    x5, CURRENT_STAGE_OFFSET(x20)

    # ==================================================================
    # CSRRS 同拍触发中断
    # ==================================================================
    # 此时：MEIE=1, MIE=0, MEIP=1（GPIO pending 已置位）。
    # MIE=0 屏蔽了全局中断，但 MEIP 信号一直为高。
    #
    # csrrs x0, mstatus, MSTATUS_MIE 进入 MEM 提交阶段：
    #   1. CSR 写提交 → mstatus.MIE = 1（全局中断打开）。
    #   2. trap_ctrl 在同一提交边界检测到：
    #      MIE=1, MEIE=1, MEIP=1 → interrupt request 成立。
    #   3. 同一拍同时接受 CSR 写提交 + interrupt trap entry。
    #      （即 "CSR写+interrupt" 语义）
    #   4. 硬件写 mepc = mem_interrupt_return_pc_i
    #      = ex_mem_data_q.next_pc = csrrs 指令的下一条 PC
    #      = after_mie_enable 的地址。
    #   5. Kill IF/ID, ID/EX, EX/MEM（年轻指令），
    #      不 kill MEM/WB（CSR 写已提交）。
    #   6. Redirect 到 mtvec（0x80），进入 trap_handler。
    #
    # CSR 提交与中断接受在硬件上发生在同一个 MEM 周期：
    #   csr_file 先完成 mstatus.MIE=1 的普通 CSR 写，
    #   再用同拍后续的 trap entry 赋值覆盖 mepc/mcause/mstatus。
    #   最终效果等价于 "CSR 写先提交，然后立即中断 entry"。
    # ==================================================================
    csrrs x0, mstatus, MSTATUS_MIE

after_mie_enable:
    # handler mret 回到此处
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)

    # 验证 mepc == after_mie_enable
    lw    x5, SAVED_MEPC_OFFSET(x20)
    la    x6, after_mie_enable
    bne   x5, x6, stage_fail_mepc

    # 验证 store 值未被中断破坏
    lw    x5, SAVED_VAL1_OFFSET(x20)
    li    x6, 0xA5A5
    bne   x5, x6, stage_fail_store
    lw    x5, SAVED_VAL2_OFFSET(x20)
    li    x6, 0x5A5A
    bne   x5, x6, stage_fail_store

    addi  x21, x21, 1

    # ==================================================================
    # Step 2: CSRW mtvec 同拍触发中断，redirect 必须使用新 mtvec
    # ==================================================================
    # 先关全局中断，复位 GPIO 输入为低并清 pending。
    csrrc x0, mstatus, MSTATUS_MIE
    sw    x0, ALT_MEPC_OFFSET(x20)
    sw    x0, ALT_HIT_OFFSET(x20)
    addi  x5, x0, 2
    sw    x5, CURRENT_STAGE_OFFSET(x20)

    lui   x5, %hi(GPIO0_BASE)
    addi  x5, x5, %lo(GPIO0_BASE)
    addi  x6, x0, 1
    sw    x6, GPIO_IRQ_PENDING_OFFSET(x5)

    lui   x5, %hi(TB_GPIO0_CLR_MASK_ADDR)
    addi  x5, x5, %lo(TB_GPIO0_CLR_MASK_ADDR)
    addi  x6, x0, 1
    sw    x6, 0(x5)
    nop; nop; nop; nop; nop; nop; nop; nop; nop; nop

    # 提前准备新 mtvec 地址。后面 GPIO pending 可能随时到来，
    # 因此不能把可中断的 la 伪指令放在 csrw mtvec 前面。
    la    x7, alt_trap_handler

    # 保持 MEIE=1，并重新打开 MIE。此时还没有 pending，因此不会提前进中断。
    li    x5, MIE_MEIE
    csrw  mie, x5
    csrrs x0, mstatus, MSTATUS_MIE

    # 触发 GPIO 上升沿。GPIO 经过 TB 驱动和两级同步后才置 pending。
    # 下面 3 个 nop 让 pending 在 csrw mtvec 提交边界前稳定为 1；
    # 若 pending 过早，会进入旧 mtvec handler 并 fail；
    # 若 pending 过晚，alt handler 记录的 mepc 会不等于 after_mtvec_write。
    lui   x5, %hi(TB_GPIO0_SET_MASK_ADDR)
    addi  x5, x5, %lo(TB_GPIO0_SET_MASK_ADDR)
    addi  x6, x0, 1
    sw    x6, 0(x5)
    nop
    nop
    nop

    csrw  mtvec, x7
after_mtvec_write:
    nop
    nop
    nop
    nop

    lw    x5, ALT_HIT_OFFSET(x20)
    addi  x6, x0, 1
    bne   x5, x6, stage_fail_alt_not_hit

    lw    x5, ALT_MEPC_OFFSET(x20)
    la    x6, after_mtvec_write
    bne   x5, x6, stage_fail_alt_mepc

    addi  x21, x21, 1
    addi  x5, x0, 2
    bne   x21, x5, fail_score

pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

stage_fail_mepc:
    addi  x5, x0, 1
    sw    x5, 0x104(x20)
    jal   x0, fail
stage_fail_store:
    sw    x5, 0x108(x20)                    # 实际值供排查
    addi  x5, x0, 2
    sw    x5, 0x104(x20)
    jal   x0, fail
fail_score:
    addi  x5, x0, 3
    sw    x5, 0x104(x20)
    jal   x0, fail
stage_fail_old_mtvec:
    addi  x5, x0, 5
    sw    x5, 0x104(x20)
    jal   x0, fail
stage_fail_alt_not_hit:
    addi  x5, x0, 6
    sw    x5, 0x104(x20)
    jal   x0, fail
stage_fail_alt_mepc:
    addi  x5, x0, 7
    sw    x5, 0x104(x20)
fail:
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFFSET(x20)
    jal   x0, done

# ====================================================================
# Trap handler
# ====================================================================
.section .text.trap
trap_handler:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)

    # Stage2 不应再进入旧 mtvec handler；若进入，说明 interrupt 早于
    # csrw mtvec 提交边界被接受，或 redirect 没有使用新 mtvec。
    lw    x5, CURRENT_STAGE_OFFSET(x20)
    addi  x6, x0, 2
    beq   x5, x6, stage_fail_old_mtvec

    csrr  x5, mcause
    li    x6, MCAUSE_INTERRUPT_BIT
    and   x7, x5, x6
    beq   x7, x0, unexpected
    li    x6, MCAUSE_CODE_MASK
    and   x7, x5, x6
    addi  x6, x0, 11
    bne   x7, x6, unexpected

    # 记录 mepc
    csrr  x5, mepc
    sw    x5, SAVED_MEPC_OFFSET(x20)

    # 清 GPIO pending
    lui   x5, %hi(GPIO0_BASE)
    addi  x5, x5, %lo(GPIO0_BASE)
    lw    x6, GPIO_IRQ_PENDING_OFFSET(x5)
    sw    x6, GPIO_IRQ_PENDING_OFFSET(x5)

    mret

unexpected:
    addi  x5, x0, 4
    sw    x5, 0x104(x20)
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFFSET(x20)
    jal   x0, done

    .align 2
alt_trap_handler:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)

    csrr  x5, mcause
    li    x6, MCAUSE_INTERRUPT_BIT
    and   x7, x5, x6
    beq   x7, x0, unexpected
    li    x6, MCAUSE_CODE_MASK
    and   x7, x5, x6
    addi  x6, x0, 11
    bne   x7, x6, unexpected

    csrr  x5, mepc
    sw    x5, ALT_MEPC_OFFSET(x20)
    addi  x5, x0, 1
    sw    x5, ALT_HIT_OFFSET(x20)

    # 清 GPIO pending 和 TB 驱动，避免返回后再次触发。
    lui   x5, %hi(GPIO0_BASE)
    addi  x5, x5, %lo(GPIO0_BASE)
    lw    x6, GPIO_IRQ_PENDING_OFFSET(x5)
    sw    x6, GPIO_IRQ_PENDING_OFFSET(x5)

    lui   x5, %hi(TB_GPIO0_CLR_MASK_ADDR)
    addi  x5, x5, %lo(TB_GPIO0_CLR_MASK_ADDR)
    addi  x6, x0, 1
    sw    x6, 0(x5)

    mret
