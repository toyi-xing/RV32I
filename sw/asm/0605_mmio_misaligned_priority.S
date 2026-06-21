#===============================================================================
# 0605_mmio_misaligned_priority.S - MMIO misaligned priority test
#
# 目的：
#   - 对未映射 MMIO 地址执行不对齐 load/store。
#   - 检查优先报 address misaligned，而不是 access fault。
#   - 检查 tval 为 faulting address。
#
# 说明：
#   - 与 0604 共享同一套 SET_EXPECT/WRONG_PATH_STORE/check_step 框架。
#   - 区别在于 fault 地址不对齐（0x83001、0x83002），预期异常为
#     misaligned（mcause=4/6）而非 access fault（mcause=5/7）。
#   - 验证 MMIO 窗口上的异常优先级：misaligned > access fault。
#===============================================================================

.equ CAUSE_LOAD_ADDR_MISALIGNED,    4
.equ CAUSE_STORE_ADDR_MISALIGNED,   6

.equ DMEM_BASE_HI,                  0x40
.equ BAD_MMIO_BASE_HI,              0x83
.equ TEST_STATUS_OFF,               0x100
.equ ERROR_CODE_OFF,                0x104
.equ SCORE_OFF,                     0x108
.equ EXPECT_CAUSE_OFF,              0x10c
.equ EXPECT_MEPC_OFF,               0x110
.equ EXPECT_TVAL_OFF,               0x114
.equ RESUME_PC_OFF,                 0x118
.equ TRAP_SEEN_OFF,                 0x11c
.equ WRONG_PATH_OFF,                0x120
.equ STEP_ID_OFF,                   0x124
.equ TOTAL_STEPS,                   2

# 将 label 的绝对地址加载到寄存器
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
    sw    x5, EXPECT_CAUSE_OFF(x20)
    LOAD_LABEL x5, \fault_label
    sw    x5, EXPECT_MEPC_OFF(x20)
    sw    \tval_reg, EXPECT_TVAL_OFF(x20)
    LOAD_LABEL x5, \resume_label
    sw    x5, RESUME_PC_OFF(x20)
    sw    x0, TRAP_SEEN_OFF(x20)
    sw    x0, WRONG_PATH_OFF(x20)
    addi  x5, x0, \step_id
    sw    x5, STEP_ID_OFF(x20)
.endm

# 在 fault 指令后立即执行。如果被执行说明 trap kill 未生效。
.macro WRONG_PATH_STORE
    addi  x5, x0, 0x55
    sw    x5, WRONG_PATH_OFF(x20)   # 写标记，main 最后检查
    jal   x0, fail_no_trap
.endm

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, DMEM_BASE_HI
    lui   x21, BAD_MMIO_BASE_HI

    sw    x0, ERROR_CODE_OFF(x20)
    sw    x0, SCORE_OFF(x20)
    sw    x0, WRONG_PATH_OFF(x20)

    # =========================================================================
    # Step 1: misaligned load — 在未映射 MMIO 地址 0x83001 执行 lw
    #         优先报 load address misaligned (mcause=4)，而非 access fault
    # =========================================================================
    addi  x6, x21, 1
    SET_EXPECT CAUSE_LOAD_ADDR_MISALIGNED, step1_fault, x6, step1_resume, 1
step1_fault:
    lw    x7, 1(x21)
    WRONG_PATH_STORE
step1_resume:
    jal   x1, check_step

    # =========================================================================
    # Step 2: misaligned store — 在未映射 MMIO 地址 0x83002 执行 sw
    #         优先报 store address misaligned (mcause=6)，而非 access fault
    # =========================================================================
    addi  x6, x21, 2
    SET_EXPECT CAUSE_STORE_ADDR_MISALIGNED, step2_fault, x6, step2_resume, 2
    addi  x7, x0, 0x66
step2_fault:
    sw    x7, 2(x21)
    WRONG_PATH_STORE
step2_resume:
    jal   x1, check_step

    lw    x5, SCORE_OFF(x20)
    addi  x6, x0, TOTAL_STEPS
    bne   x5, x6, fail_score

pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFF(x20)
done:
    jal   x0, done

# check_step — 验证 trap 是否按预期触发（同 0604 框架）
check_step:
    lw    x5, TRAP_SEEN_OFF(x20)
    addi  x6, x0, 1
    bne   x5, x6, fail_trap_seen

    lw    x5, WRONG_PATH_OFF(x20)
    bne   x5, x0, fail_wrong_path

    lw    x5, SCORE_OFF(x20)
    addi  x5, x5, 1
    sw    x5, SCORE_OFF(x20)
    jalr  x0, 0(x1)

fail_no_trap:
    lui   x20, DMEM_BASE_HI
    lw    x5, STEP_ID_OFF(x20)
    addi  x5, x5, 100
    jal   x0, fail_with_x5

fail_trap_seen:
    lw    x5, STEP_ID_OFF(x20)
    addi  x5, x5, 200
    jal   x0, fail_with_x5

fail_wrong_path:
    lw    x5, STEP_ID_OFF(x20)
    addi  x5, x5, 300
    jal   x0, fail_with_x5

fail_score:
    addi  x5, x0, 900
    jal   x0, fail_with_x5

fail_with_x5:
    lui   x20, DMEM_BASE_HI
    sw    x5, ERROR_CODE_OFF(x20)
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFF(x20)
fail_loop:
    jal   x0, fail_loop

# =============================================================================
# 共享 trap handler — 校验 mcause/mepc/mtval 后 mret 返回主流程
# =============================================================================
.section .text.trap
trap_handler:
    lui   x20, DMEM_BASE_HI

    csrr  x5, mcause                       # 读异常原因
    csrr  x6, mepc                         # 读 fault 指令 PC
    csrr  x7, mtval                        # 读 fault 地址

    lw    x8, EXPECT_CAUSE_OFF(x20)        # 检查 mcause
    bne   x5, x8, fail_cause
    lw    x8, EXPECT_MEPC_OFF(x20)         # 检查 mepc
    bne   x6, x8, fail_mepc
    lw    x8, EXPECT_TVAL_OFF(x20)         # 检查 mtval
    bne   x7, x8, fail_mtval

    addi  x8, x0, 1
    sw    x8, TRAP_SEEN_OFF(x20)           # 标记 trap 已触发
    lw    x9, RESUME_PC_OFF(x20)           # 加载跳过后应继续的地址
    csrw  mepc, x9                         # 写入 mepc，mret 后从这里继续
    mret

fail_cause:
    lw    x5, STEP_ID_OFF(x20)
    addi  x5, x5, 400
    jal   x0, fail_with_x5

fail_mepc:
    lw    x5, STEP_ID_OFF(x20)
    addi  x5, x5, 500
    jal   x0, fail_with_x5

fail_mtval:
    lw    x5, STEP_ID_OFF(x20)
    addi  x5, x5, 600
    jal   x0, fail_with_x5
