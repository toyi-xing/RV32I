#include "platform.h"

#===============================================================================
# 0502_exception_full.S - 当前最小 M-mode trap 异常总测试
#
# 目的：
#   - 在一个汇编程序内覆盖当前 core 支持的主要同步异常路径。
#   - handler 检查 mcause/mepc/mtval，并用 mret 返回主流程。
#   - 主流程逐 step 计分，最终 score == TOTAL_STEPS 才写 PASS。
#
# 覆盖的异常类型：
#   1. ECALL（environment call from M-mode）
#   2. EBREAK（breakpoint）
#   3. 全 0 编码非法指令（illegal instruction）
#   4. 不支持的 M 扩展 MUL 编码（illegal instruction）
#   5. 写只读 CSR mvendorid（CSR 文件在 MEM 判非法 → illegal instruction）
#   6. 读未实现 CSR 地址（CSR 文件在 MEM 判非法 → illegal instruction）
#   7. load address misaligned（lw 地址不是 4 字节对齐）
#   8. store address misaligned（sw 地址不是 4 字节对齐，且 faulting store 不应写 memory）
#   9. JALR target bit1=1（instruction address misaligned）
#
# 失败定位（DMEM_BASE+0x104 保存 error_code）：
#   100+step：该 step 根本没有进入 trap（wrong-path store 没有被 trap kill）。
#   200+step：resume 后 handler 未把 TEST_TRAP_SEEN_OFFSET 置位。
#   300+step：resume 后 wrong-path 的标记值意外写入了 DMEM（trap kill 机制失效）。
#   400+step：handler 读到的 mcause 不等于预先写入 TEST_EXPECT_CAUSE_OFFSET 的期望值。
#   500+step：handler 读到的 mepc 不等于预先写入 TEST_EXPECT_MEPC_OFFSET 的期望值。
#   600+step：handler 读到的 mtval 不等于预先写入 TEST_EXPECT_TVAL_OFFSET 的期望值。
#   700+step：store misaligned 错误地产生了写副作用（DMEM_BASE word 被污染）。
#   800+step：JALR misaligned 未 trap 而跳到了错误目标（step9_bad_target 被执行）。
#   900：最终 score 不等于 TOTAL_STEPS。
#
# 传递条件：
#   - 所有 step 全部通过，score == TOTAL_STEPS，写 DMEM_BASE+0x100 = 1。
#===============================================================================


.equ TOTAL_STEPS,                  9

# DMEM 偏移量（基于 x20 = DMEM_BASE）

#-------------------------------------------------------------------------------
# LOAD_LABEL reg, label — 汇编宏（编译期文本替换），不是函数调用。
# 展开成两条指令，将 label 的绝对地址加载到 reg。
# 后续的 sw 指令再用 reg 把该地址写入 DMEM。
#-------------------------------------------------------------------------------
.macro LOAD_LABEL reg, label
    lui   \reg, %hi(\label)
    addi  \reg, \reg, %lo(\label)
.endm

#-------------------------------------------------------------------------------
# SET_EXPACE cause, fault_label, tval_reg, resume_label, step_id — 汇编宏。
#
# 功能：在每个 step 的 fault 指令执行前，把"期望值"写入 DMEM 固定偏移位置。
#       当 trap handler 被触发时，它会去读这些期望值，和自己从 CSR 读到的
#       mcause/mepc/mtval 逐一比对。
#
# 参数说明：
#   cause        — 期望的 mcause 值（汇编数字常量，如 EXCEPTION_CAUSE_ECALL_M=11）
#   fault_label  — fault 指令所在的 label 名；LOAD_LABEL 取其绝对地址作为期望 mepc
#   tval_reg     — 期望的 mtval 值所在的寄存器（如 x0 表示期望 mtval=0）
#   resume_label — 主流程中 resume 地址的 label；handler 会把它写入 mepc 后 mret
#   step_id      — step 编号（1~9），用于出错时计算 error_code 定位
#
# 写入的 DMEM 偏移（基于 x20=DMEM_BASE）：
#   TEST_EXPECT_CAUSE_OFFSET(0x10c) ← cause
#   TEST_EXPECT_MEPC_OFFSET(0x110)  ← fault_label 的绝对地址
#   TEST_EXPECT_TVAL_OFFSET(0x114)  ← tval_reg 的值
#   TEST_RESUME_PC_OFFSET(0x118)    ← resume_label 的绝对地址
#   TEST_TRAP_SEEN_OFFSET(0x11c)    ← 0（由 handler 置 1）
#   TEST_WRONG_PATH_OFFSET(0x120)   ← 0（wrong path 若执行会改写此值）
#   TEST_STEP_ID_OFFSET(0x124)      ← step_id
#
# 具体流程示例（Step 1 展开后）：
#   SET_EXPECT EXCEPTION_CAUSE_ECALL_M, step1_fault, x0, step1_resume, 1
#     ↓ 展开为
#   addi x5, x0, 11          # x5 = 11 (ECALL_M)
#   sw   x5, 0x10c(x20)      # DMEM → EXPECT_CAUSE = 11
#   lui  x5, %hi(step1_fault) # 取 step1_fault 的高 20 bit 地址
#   addi x5, x5, %lo(step1_fault) # 加上低 12 bit
#   sw   x5, 0x110(x20)      # DMEM → EXPECT_MEPC = fault 指令地址
#   sw   x0, 0x114(x20)      # DMEM → EXPECT_TVAL = 0（来自 x0）
#   lui  x5, %hi(step1_resume)
#   addi x5, x5, %lo(step1_resume)
#   sw   x5, 0x118(x20)      # DMEM → RESUME_PC = trap 返回地址
#   sw   x0, 0x11c(x20)      # DMEM → TRAP_SEEN = 0（待 handler 置 1）
#   sw   x0, 0x120(x20)      # DMEM → WRONG_PATH = 0（wrong path 若执行会写 0x55）
#   addi x5, x0, 1
#   sw   x5, 0x124(x20)      # DMEM → STEP_ID = 1
#-------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------
# WRONG_PATH_STORE — 汇编宏，不是函数调用。
#
# 位置：紧跟在 fault 指令之后。如果 trap 没有发生（即 fault 指令被 CPU 当成
#       正常指令执行了），流水线会继续执行到 WRONG_PATH_STORE。
#       它会写 TEST_WRONG_PATH_OFFSET=0x55 并跳转到 fail_no_trap。
#
# 如果 trap 正常触发，trap_ctrl 会 kill 流水线中年轻指令，WRONG_PATH_STORE
#       就不会被执行。check_step 验证 TEST_WRONG_PATH_OFFSET 仍为 0。
#
# 所以 WRONG_PATH_STORE 是一个"哨兵"：
# - 它被执行 → trap 机制有 bug（fault 指令未被 trap kill）
# - 它没被执行 → trap 正常工作
#-------------------------------------------------------------------------------
.macro WRONG_PATH_STORE
    addi  x5, x0, 0x55
    sw    x5, TEST_WRONG_PATH_OFFSET(x20)  # 写标记：如果 trap kill 正常，此行永远不应提交
    jal   x0, fail_no_trap         # 跳转到"未进入 trap"的失败处理
.endm

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)              # x20 = DMEM_BASE，全局地址基址寄存器

    # 初始化 DMEM 检查区域
    sw    x0, TEST_ERROR_CODE_OFFSET(x20)
    sw    x0, TEST_SCORE_OFFSET(x20)
    sw    x0, 0(x20)             # 清 dmem[0]，供 step8 检测 store misaligned 副作用

    # -------------------------------------------------------------------------
    # Step 1: ECALL → mcause=11, mepc=ecall 指令 PC, mtval=0
    # -------------------------------------------------------------------------
    SET_EXPECT EXCEPTION_CAUSE_ECALL_M, step1_fault, x0, step1_resume, 1
step1_fault:
    ecall
    WRONG_PATH_STORE
step1_resume:
    jal   x1, check_step

    # -------------------------------------------------------------------------
    # Step 2: EBREAK → mcause=3, mepc=ebreak 指令 PC, mtval=0
    # -------------------------------------------------------------------------
    SET_EXPECT EXCEPTION_CAUSE_BREAKPOINT, step2_fault, x0, step2_resume, 2
step2_fault:
    ebreak
    WRONG_PATH_STORE
step2_resume:
    jal   x1, check_step

    # -------------------------------------------------------------------------
    # Step 3: 全 0 编码非法指令 → mcause=2, mepc=该指令 PC, mtval=该指令编码(0)
    # -------------------------------------------------------------------------
    SET_EXPECT EXCEPTION_CAUSE_ILLEGAL_INSTR, step3_fault, x0, step3_resume, 3
step3_fault:
    .word 0x00000000             # 非法指令：全 0 编码，无对应指令
    WRONG_PATH_STORE
step3_resume:
    jal   x1, check_step

    # -------------------------------------------------------------------------
    # Step 4: 不支持的 M 扩展 MUL 编码 → mcause=2, mepc=该指令 PC, mtval=该指令编码
    #         当前 RV32I 核不实现 M 扩展，MUL 指令的编码应被 decoder 判非法。
    # -------------------------------------------------------------------------
    lui   x6, 0x02208
    addi  x6, x6, 0x1b3         # x6 = 0x022081b3（MUL 的 machine encoding）
    SET_EXPECT EXCEPTION_CAUSE_ILLEGAL_INSTR, step4_fault, x6, step4_resume, 4
step4_fault:
    .word 0x022081b3             # 非法指令：MUL x3, x17, x2
    WRONG_PATH_STORE
step4_resume:
    jal   x1, check_step

    # -------------------------------------------------------------------------
    # Step 5: 写只读 CSR mvendorid → mcause=2, mepc=该指令 PC, mtval=指令编码
    #         mvendorid(0xF11) 是只读 CSR，CSR 文件在 MEM 阶段判非法访问。
    # -------------------------------------------------------------------------
    lui   x6, 0xf1101
    addi  x6, x6, 0x073         # x6 = 0xf1101073（CSRRW x0, mvendorid, x0）
    SET_EXPECT EXCEPTION_CAUSE_ILLEGAL_INSTR, step5_fault, x6, step5_resume, 5
step5_fault:
    .word 0xf1101073             # 非法指令：写入只读 CSR
    WRONG_PATH_STORE
step5_resume:
    jal   x1, check_step

    # -------------------------------------------------------------------------
    # Step 6: 读未实现 CSR 0x7c0 → mcause=2, mepc=该指令 PC, mtval=指令编码
    #         0x7c0 不在当前 CSR 文件实现的地址范围内，判非法访问。
    # -------------------------------------------------------------------------
    lui   x6, 0x7c002
    addi  x6, x6, 0x073         # x6 = 0x7c002073（CSRRS x0, 0x7c0, x0）
    SET_EXPECT EXCEPTION_CAUSE_ILLEGAL_INSTR, step6_fault, x6, step6_resume, 6
step6_fault:
    .word 0x7c002073             # 非法指令：访问不存在的 CSR 地址
    WRONG_PATH_STORE
step6_resume:
    jal   x1, check_step

    # -------------------------------------------------------------------------
    # Step 7: lw 地址不对齐 → mcause=4, mepc=lw 指令 PC, mtval=fault 地址
    #         DMEM_BASE+1 不是 word 对齐地址。
    # -------------------------------------------------------------------------
    addi  x6, x20, 1             # x6 = DMEM_BASE + 1（非 word 对齐地址）
    SET_EXPECT EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED, step7_fault, x6, step7_resume, 7
step7_fault:
    lw    x7, 1(x20)             # load 地址不对齐，触发 exception
    WRONG_PATH_STORE
step7_resume:
    jal   x1, check_step

    # -------------------------------------------------------------------------
    # Step 8: sw 地址不对齐 → mcause=6, mepc=sw 指令 PC, mtval=fault 地址
    #         写入 DMEM_BASE+2 是 halfword 对齐但非 word 对齐。
    #         faulting store 不应写入 DMEM_BASE word，通过检查 dmem[0] 验证。
    # -------------------------------------------------------------------------
    sw    x0, 0(x20)             # 先清 dmem[0]，便于后续检测 store 副作用
    addi  x6, x20, 2             # x6 = DMEM_BASE + 2（非 word 对齐地址）
    SET_EXPECT EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED, step8_fault, x6, step8_resume, 8
    addi  x7, x0, 0x5a           # x7 = 0x5a，用于验证 faulting store 不应写 memory
step8_fault:
    sw    x7, 2(x20)             # store 地址不对齐，触发 exception；正常时不会写 dmem
    WRONG_PATH_STORE
step8_resume:
    jal   x1, check_step
    lw    x5, 0(x20)             # 检查 dmem[0] 是否被 store 污染
    bne   x5, x0, fail_store_side_effect

    # -------------------------------------------------------------------------
    # Step 9: JALR target bit1=1 → mcause=0, mepc=JALR 指令 PC, mtval=错误 target
    #         JALR 的目标地址低位被清零后仍然 bit1=1，EX 阶段判 instruction
    #         address misaligned，不发出 redirect，改为 exception。
    # -------------------------------------------------------------------------
    LOAD_LABEL x6, step9_bad_target
    addi  x6, x6, 2              # x6 = step9_bad_target + 2（非 4 字节对齐）
    SET_EXPECT EXCEPTION_CAUSE_INST_ADDR_MISALIGNED, step9_fault, x6, step9_resume, 9
    addi  x7, x6, 0              # x7 = 同 x6，JR 消费 forwarding 后的 x7
step9_fault:
    jalr  x0, 0(x7)              # 跳转到非对齐地址，触发 exception
    WRONG_PATH_STORE
step9_resume:
    jal   x1, check_step

    # 所有 step 完成，检查最终计分
    lw    x5, TEST_SCORE_OFFSET(x20)
    addi  x6, x0, TOTAL_STEPS
    bne   x5, x6, fail_score

pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

    .align 2
step9_bad_target:
    # 若 JALR misaligned 未正确 trap，core 会跳到此 label 执行。
    # 这里打一个 fail 标记，防止误 PAS。
    jal   x0, fail_bad_jalr_target

#-------------------------------------------------------------------------------
# check_step：resume 后检查 handler 是否运行、wrong-path store 是否被 trap kill。
#   x1 传入返回地址（由 jal x1, check_step 设置）。
#   若所有检查通过，score++ 后通过 x1 返回主流程。
#-------------------------------------------------------------------------------
check_step:
    lw    x5, TEST_TRAP_SEEN_OFFSET(x20)        # handler 应已置位此标记
    addi  x6, x0, 1
    bne   x5, x6, fail_trap_seen

    lw    x5, TEST_WRONG_PATH_OFFSET(x20)       # wrong-path 标记应保持 0
    bne   x5, x0, fail_wrong_path

    lw    x5, TEST_SCORE_OFFSET(x20)
    addi  x5, x5, 1
    sw    x5, TEST_SCORE_OFFSET(x20)
    jalr  x0, 0(x1)                     # 正常返回主流程

# 失败处理函数。每个函数读取 TEST_STEP_ID_OFFSET 后加上对应偏移作为 error_code。
# error_code = STEP_ID + offset：
#   100 = 未进入 trap（wrong-path 没有被 kill 而直接跳到了 fail_no_trap）
#   200 = TRAP_SEEN 未置位
#   300 = wrong-path store 未被 kill
#   700 = store misaligned 产生了写副作用
#   800 = JALR misaligned 未 trap，跳到了错误目标
#   900 = 最终 score ≠ TOTAL_STEPS
#   400/500/600 = handler 内 mcause/mepc/mtval 不匹配（见 trap_handler）

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

fail_store_side_effect:
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 700
    jal   x0, fail_with_x5

fail_bad_jalr_target:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)
    lw    x5, TEST_STEP_ID_OFFSET(x20)
    addi  x5, x5, 800
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

#===============================================================================
# trap handler：统一异常入口
#
# 入口条件：
#   - mtvec = IMEM_BASE + 0x80（复位默认值，或由软件写入的 __trap_vector）。
#   - 发生同步异常时 core 自动跳转至此。
#   - mcause/mepc/mtval 已由硬件写入。
#
# 处理流程：
#   1. 读 mcause/mepc/mtval。
#   2. 依次和 TEST_EXPECT_CAUSE_OFFSET/TEST_EXPECT_MEPC_OFFSET/TEST_EXPECT_TVAL_OFFSET 比较。
#   3. 若全部匹配，置位 TEST_TRAP_SEEN_OFFSET，读 TEST_RESUME_PC_OFFSET 写入 mepc。
#   4. mret 返回主流程。
#   5. 若不匹配，跳转到对应 fail_* 函数。
#===============================================================================
.section .text.trap
trap_handler:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)              # x20 = DMEM_BASE

    csrr  x5, mcause
    csrr  x6, mepc
    csrr  x7, mtval

    lw    x8, TEST_EXPECT_CAUSE_OFFSET(x20)
    bne   x5, x8, fail_cause     # mcause != 期望值

    lw    x8, TEST_EXPECT_MEPC_OFFSET(x20)
    bne   x6, x8, fail_mepc      # mepc != 期望值

    lw    x8, TEST_EXPECT_TVAL_OFFSET(x20)
    bne   x7, x8, fail_mtval     # mtval != 期望值

    # 全部匹配：置位 TRAP_SEEN，修改 mepc 指向 resume 地址，mret 返回
    addi  x8, x0, 1
    sw    x8, TEST_TRAP_SEEN_OFFSET(x20)

    lw    x9, TEST_RESUME_PC_OFFSET(x20)
    csrw  mepc, x9
    mret

# handler 内各检查点失败处理
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
