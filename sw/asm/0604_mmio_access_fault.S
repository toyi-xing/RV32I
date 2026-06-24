#include "platform.h"

#===============================================================================
# 0604_mmio_access_fault.S - MMIO access fault smoke test
#
# 目的：
#   - 访问未映射 MMIO 保留区，检查 load/store access fault。
#   - handler 校验 mcause/mepc/mtval，并用 mret 返回主流程。
#
# PASS 条件：
#   - load access fault 和 store access fault 都被正确捕获。
#   - faulting store 不产生 GPIO/UART/DMEM 副作用。
#
# 说明：
#   - 使用 SET_EXPECT 宏配置每个 step 的预期异常参数。
#   - fault 指令后立即跟 WRONG_PATH_STORE；若 store 被提交说明 fault
#     未 kill 年轻指令，测试将 FAIL。
#   - check_step 子程序检查 trap_seen 和 wrong_path 标记，累加得分。
#===============================================================================


.equ TOTAL_STEPS,                  2

# 将 label 的绝对地址加载到寄存器（RISC-V 没有直接取 PC + label 的伪指令）
.macro LOAD_LABEL reg, label
    lui   \reg, %hi(\label)
    addi  \reg, \reg, %lo(\label)
.endm

# 设置预期的异常参数并存到 DMEM。
# cause：期望的 mcause 值
# fault_label：fault 指令的 label（期望 mepc = 该 label 的地址）
# tval_reg：期望 mtval 值所在的寄存器
# resume_label：trap 返回后应继续执行的 label
# step_id：当前 step 编号
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

# 在 fault 指令后立即执行。如果这条 store 被执行，说明 core 的 trap
# 机制未正确 kill 年轻指令，直接跳转到 fail_no_trap。
.macro WRONG_PATH_STORE
    addi  x5, x0, 0x55
    sw    x5, TEST_WRONG_PATH_OFFSET(x20)   # 写标记，main 最后检查
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
    lui   x21, %hi(TEST_UNMAPPED_MMIO_BASE)
    addi  x21, x21, %lo(TEST_UNMAPPED_MMIO_BASE)

    sw    x0, TEST_ERROR_CODE_OFFSET(x20)
    sw    x0, TEST_SCORE_OFFSET(x20)
    sw    x0, TEST_WRONG_PATH_OFFSET(x20)

    # =========================================================================
    # Step 1: load access fault — 读未实现 MMIO 地址 0x00083000
    #         预期 mcause=5, mepc=step1_fault, mtval=fault_addr
    # =========================================================================
    SET_EXPECT EXCEPTION_CAUSE_LOAD_ACCESS_FAULT, step1_fault, x21, step1_resume, 1
step1_fault:
    lw    x7, 0(x21)
    WRONG_PATH_STORE
step1_resume:
    jal   x1, check_step

    # =========================================================================
    # Step 2: store access fault — 写未实现 MMIO 地址 0x00083004
    #         预期 mcause=7, mepc=step2_fault, mtval=fault_addr
    # =========================================================================
    addi  x6, x21, 4
    SET_EXPECT EXCEPTION_CAUSE_STORE_ACCESS_FAULT, step2_fault, x6, step2_resume, 2
    addi  x7, x0, 0x5a
step2_fault:
    sw    x7, 4(x21)
    WRONG_PATH_STORE
step2_resume:
    jal   x1, check_step

    lw    x5, TEST_SCORE_OFFSET(x20)
    addi  x6, x0, TOTAL_STEPS
    bne   x5, x6, fail_score

pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

# check_step — 验证 trap 是否按预期触发：
#   - TRAP_SEEN 应为 1（handler 已被调用）
#   - WRONG_PATH 应为 0（fault 后的年轻指令未被执行）
#   通过后得分加 1，返回调用者。
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
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
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
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    sw    x5, TEST_ERROR_CODE_OFFSET(x20)
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFFSET(x20)
fail_loop:
    jal   x0, fail_loop

# =============================================================================
# 共享 trap handler — 校验异常参数后 mret 返回主流程
# =============================================================================
.section .text.trap
trap_handler:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)

    csrr  x5, mcause                       # 读异常原因
    csrr  x6, mepc                         # 读 fault 指令 PC
    csrr  x7, mtval                        # 读 fault 地址/附加信息

    lw    x8, TEST_EXPECT_CAUSE_OFFSET(x20)        # 检查 mcause
    bne   x5, x8, fail_cause
    lw    x8, TEST_EXPECT_MEPC_OFFSET(x20)         # 检查 mepc
    bne   x6, x8, fail_mepc
    lw    x8, TEST_EXPECT_TVAL_OFFSET(x20)         # 检查 mtval
    bne   x7, x8, fail_mtval

    addi  x8, x0, 1
    sw    x8, TEST_TRAP_SEEN_OFFSET(x20)           # 标记 trap 已触发
    lw    x9, TEST_RESUME_PC_OFFSET(x20)           # 加载跳过后应继续的地址
    csrw  mepc, x9                         # 写入 mepc，mret 后从这里继续
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
