# 0804_mmio_wait_access_fault.S — MMIO wait-state access fault 精确语义
#
# 目的：
#   - 验证 GPIO0/UART0/TIMER0 窗口内未定义 offset 的 load/store 在
#     配置非 0 delay 时，delayed response error 能在 MEM completion 边界
#     转成精确 load/store access fault。
#   - 验证 faulting store 不产生外设副作用（写未定义 offset 不应改变
#     已知寄存器的值）。
#   - 验证 fault 后 wrong-path store 被正确 kill。
#
# 延迟配置：
#   - GPIO0/UART0/TIMER0 resp_delay = 3（固定延迟）。
#   - DMEM 默认 0 delay，不影响 fault 响应。
#
# 测试方法：
#   每个 step 使用 SET_EXPECT 宏设置预期 cause/mepc/tval 和恢复 PC，
#   然后执行一次对外设窗口内未定义 offset 的 load/store。预期触发 access
#   fault trap，trap_handler 自动校验各字段后跳转到恢复 PC。
#   check_step 子例程确认 trap_seen=1、wrong_path=0 后累加 score。
#
# 6 个 step 顺序：
#   1. GPIO0 窗口内未定义 offset load  → LOAD_ACCESS_FAULT
#   2. GPIO0 窗口内未定义 offset store → STORE_ACCESS_FAULT
#   3. UART0 窗口内未定义 offset load  → LOAD_ACCESS_FAULT
#   4. UART0 窗口内未定义 offset store → STORE_ACCESS_FAULT
#   5. TIMER0 窗口内未定义 offset load  → LOAD_ACCESS_FAULT
#   6. TIMER0 窗口内未定义 offset store → STORE_ACCESS_FAULT
#
# 通过条件：
#   所有 6 个 step 的 trap cause/mepc/tval/wrong_path 检查通过，
#   score == TOTAL_STEPS。
#
# 错误码（0x104）：
#   101-106: step N 未触发 trap（N=1..6）
#   201-206: step N trap_seen 标志未置位
#   301-306: step N wrong_path 被写入（fault 后继续执行了 wrong-path store）
#   401-406: step N 预期 cause 不匹配
#   501-506: step N 预期 mepc 不匹配
#   601-606: step N 预期 tval 不匹配
#   900: score != TOTAL_STEPS

#include "tb_rv32i_soc_test.h"

.equ TOTAL_STEPS, 6

.macro LOAD_LABEL reg, label
    lui   \reg, %hi(\label)
    addi  \reg, \reg, %lo(\label)
.endm

.macro SET_EXPECT cause, fault_label, tval_reg, resume_label, step_id
    addi  x5, x0, \cause
    sw    x5, TEST_EXPECT_CAUSE_OFFSET(x20)
    LOAD_LABEL x5, \fault_label
    sw    x5, TEST_EXPECT_MEPC_OFFSET(x20)
    sw    \tval_reg, TEST_EXPECT_TVAL_OFFSET(x20)
    LOAD_LABEL x5, \resume_label
    sw    x5, TEST_RESUME_PC_OFFSET(x20)
    sw    x0, TEST_TRAP_SEEN_OFFSET(x20)
    sw    x0, TEST_WRONG_PATH_OFFSET(x20)
    addi  x5, x0, \step_id
    sw    x5, TEST_STEP_ID_OFFSET(x20)
.endm

.macro WRONG_PATH_STORE
    addi  x5, x0, 0x55
    sw    x5, TEST_WRONG_PATH_OFFSET(x20)
    jal   x0, fail_no_trap
.endm

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    lui   x21, %hi(TB_RESP_DELAY_CFG0_ADDR)
    addi  x21, x21, %lo(TB_RESP_DELAY_CFG0_ADDR)
    # GPIO0/UART0/TIMER0 resp_delay = 3（固定延迟），DMEM = 0
    li    x5, 0x03030300
    sw    x5, 0(x21)

    sw    x0, TEST_ERROR_CODE_OFFSET(x20)
    sw    x0, TEST_SCORE_OFFSET(x20)
    sw    x0, TEST_WRONG_PATH_OFFSET(x20)

    # ==================================================================
    # Step 1: GPIO0 未定义 offset load → LOAD_ACCESS_FAULT
    # ==================================================================
    lui   x21, %hi(GPIO0_BASE)
    addi  x21, x21, %lo(GPIO0_BASE)
    addi  x21, x21, 0x028
    SET_EXPECT EXCEPTION_CAUSE_LOAD_ACCESS_FAULT, step1_fault, x21, step1_resume, 1
step1_fault:
    lw    x7, 0(x21)
    WRONG_PATH_STORE
step1_resume:
    jal   x1, check_step

    # ==================================================================
    # Step 2: GPIO0 未定义 offset store → STORE_ACCESS_FAULT
    # ==================================================================
    SET_EXPECT EXCEPTION_CAUSE_STORE_ACCESS_FAULT, step2_fault, x21, step2_resume, 2
    addi  x7, x0, 0x5a
step2_fault:
    sw    x7, 0(x21)
    WRONG_PATH_STORE
step2_resume:
    jal   x1, check_step

    # ==================================================================
    # Step 3: UART0 未定义 offset load → LOAD_ACCESS_FAULT
    # ==================================================================
    lui   x21, %hi(UART0_BASE)
    addi  x21, x21, %lo(UART0_BASE)
    addi  x21, x21, 0x014
    SET_EXPECT EXCEPTION_CAUSE_LOAD_ACCESS_FAULT, step3_fault, x21, step3_resume, 3
step3_fault:
    lw    x7, 0(x21)
    WRONG_PATH_STORE
step3_resume:
    jal   x1, check_step

    # ==================================================================
    # Step 4: UART0 未定义 offset store → STORE_ACCESS_FAULT
    # ==================================================================
    SET_EXPECT EXCEPTION_CAUSE_STORE_ACCESS_FAULT, step4_fault, x21, step4_resume, 4
    addi  x7, x0, 0x6b
step4_fault:
    sw    x7, 0(x21)
    WRONG_PATH_STORE
step4_resume:
    jal   x1, check_step

    # ==================================================================
    # Step 5: TIMER0 未定义 offset load → LOAD_ACCESS_FAULT
    # ==================================================================
    lui   x21, %hi(TIMER0_BASE)
    addi  x21, x21, %lo(TIMER0_BASE)
    addi  x21, x21, 0x010
    SET_EXPECT EXCEPTION_CAUSE_LOAD_ACCESS_FAULT, step5_fault, x21, step5_resume, 5
step5_fault:
    lw    x7, 0(x21)
    WRONG_PATH_STORE
step5_resume:
    jal   x1, check_step

    # ==================================================================
    # Step 6: TIMER0 未定义 offset store → STORE_ACCESS_FAULT
    # ==================================================================
    SET_EXPECT EXCEPTION_CAUSE_STORE_ACCESS_FAULT, step6_fault, x21, step6_resume, 6
    addi  x7, x0, 0x7c
step6_fault:
    sw    x7, 0(x21)
    WRONG_PATH_STORE
step6_resume:
    jal   x1, check_step

    lw    x5, TEST_SCORE_OFFSET(x20)
    addi  x6, x0, TOTAL_STEPS
    bne   x5, x6, fail_score

pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

check_step:
    lw    x5, TEST_TRAP_SEEN_OFFSET(x20)
    addi  x6, x0, 1
    bne   x5, x6, fail_trap_seen
    lw    x5, TEST_WRONG_PATH_OFFSET(x20)
    bne   x5, x0, fail_wrong_path
    lw    x5, TEST_SCORE_OFFSET(x20)
    addi  x5, x5, 1
    sw    x5, TEST_SCORE_OFFSET(x20)
    jalr  x0, 0(x1)

fail_no_trap:
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 100
    jal   x0, fail_with_x5
fail_trap_seen:
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 200
    jal   x0, fail_with_x5
fail_wrong_path:
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 300
    jal   x0, fail_with_x5
fail_score:
    addi  x5, x0, 900
    jal   x0, fail_with_x5
fail_with_x5:
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFFSET(x20)
fail_loop:
    jal   x0, fail_loop

.section .text.trap
trap_handler:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    csrr  x5, mcause
    csrr  x6, mepc
    csrr  x7, mtval
    lw    x8, TEST_EXPECT_CAUSE_OFFSET(x20)
    bne   x5, x8, fail_cause
    lw    x8, TEST_EXPECT_MEPC_OFFSET(x20)
    bne   x6, x8, fail_mepc
    lw    x8, TEST_EXPECT_TVAL_OFFSET(x20)
    bne   x7, x8, fail_mtval
    addi  x8, x0, 1
    sw    x8, TEST_TRAP_SEEN_OFFSET(x20)
    lw    x9, TEST_RESUME_PC_OFFSET(x20)
    csrw  mepc, x9
    mret

fail_cause:
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 400
    jal   x0, fail_with_x5
fail_mepc:
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 500
    jal   x0, fail_with_x5
fail_mtval:
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 600
    jal   x0, fail_with_x5
