#===============================================================================
# 0606_wrong_path_mmio.S - wrong-path MMIO side-effect test
#
# 目的：
#   - taken branch 的 wrong-path store 不应触发 GPIO/UART 副作用。
#   - trap entry 后的 wrong-path store 不应触发 GPIO/UART/DMEM 副作用。
#   - handler 使用 mret 返回主流程，最终检查 GPIO OUT 仍为 0。
#
# PASS 条件：
#   - wrong-path DMEM 标记保持 0。
#   - GPIO OUT 保持 0。
#   - 仿真日志不应出现本测试的 UART TX event。
#
# 说明：
#   - 测试 wrong-path 指令被 flush/kill 后，其对 MMIO 的访问是否真正
#     被取消（不提交），而非仅抑制了寄存器写回。
#   - Case 1：taken branch 后的顺序路径指令。
#   - Case 2：trap entry 后比 ecall 年轻的指令。
#===============================================================================

.equ CAUSE_ECALL_M,       11

.equ DMEM_BASE_HI,        0x40
.equ GPIO0_BASE_HI,       0x80
.equ UART0_BASE_HI,       0x82
.equ TEST_STATUS_OFF,     0x100
.equ ERROR_CODE_OFF,      0x104
.equ WRONG_PATH_OFF,      0x120
.equ EXPECT_MEPC_OFF,     0x110
.equ RESUME_PC_OFF,       0x118
.equ TRAP_SEEN_OFF,       0x11c
.equ GPIO_OUT_OFF,        0x000
.equ UART_TXDATA_OFF,     0x000
.equ UART_CTRL_OFF,       0x008

.macro LOAD_LABEL reg, label
    lui   \reg, %hi(\label)
    addi  \reg, \reg, %lo(\label)
.endm

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, DMEM_BASE_HI
    lui   x21, GPIO0_BASE_HI
    lui   x22, UART0_BASE_HI

    sw    x0, ERROR_CODE_OFF(x20)
    sw    x0, WRONG_PATH_OFF(x20)
    sw    x0, TRAP_SEEN_OFF(x20)
    sw    x0, GPIO_OUT_OFF(x21)

    # 先使能 UART。后续 wrong-path 写 TXDATA 若提交，TB 会打印 UART event
    # 且测试 FAIL。通过观察日志中是否有 UART TX event 可快速判断。
    addi  x5, x0, 1
    sw    x5, UART_CTRL_OFF(x22)        # UART0_CTRL = 1 → 使能 TX

    # =========================================================================
    # Case 1: branch taken 后 wrong-path flush
    #         beq 必然 taken，顺序路径上的 GPIO/UART/DMEM store 应被 flush，
    #         不产生任何副作用。
    # =========================================================================
    addi  x5, x0, 1
    addi  x6, x0, 1
    beq   x5, x6, branch_target        # 必然 taken，顺序路径被 flush
    # === wrong path start ===
    addi  x7, x0, 0x33
    sw    x7, GPIO_OUT_OFF(x21)       # wrong path — 对 GPIO 的 store 应被 kill
    sw    x7, UART_TXDATA_OFF(x22)    # wrong path — 不应触发 UART TX event
    sw    x7, WRONG_PATH_OFF(x20)     # wrong path — 不应写 DMEM 标记
    # === wrong path end ===

branch_target:
    # 验证 Case 1：wrong-path DMEM/GPIO 标记必须为 0
    lw    x5, WRONG_PATH_OFF(x20)
    bne   x5, x0, fail_branch_side_effect   # DMEM 标记不应被写
    lw    x5, GPIO_OUT_OFF(x21)
    bne   x5, x0, fail_branch_side_effect   # GPIO OUT 不应被写

    # =========================================================================
    # Case 2: trap entry 后 wrong-path kill
    #         ecall 触发 trap，ecall 之后的 GPIO/UART/DMEM store 是年轻指令，
    #         应在 trap entry 时被 kill，不产生任何副作用。
    # =========================================================================
    LOAD_LABEL x5, trap_fault
    sw    x5, EXPECT_MEPC_OFF(x20)
    LOAD_LABEL x5, trap_resume
    sw    x5, RESUME_PC_OFF(x20)
    sw    x0, TRAP_SEEN_OFF(x20)
    sw    x0, WRONG_PATH_OFF(x20)
trap_fault:
    ecall                                  # ECALL → trap entry
    # === wrong path start (ecall 后的年轻指令) ===
    addi  x7, x0, 0x44
    sw    x7, GPIO_OUT_OFF(x21)       # wrong path — 对 GPIO 的 store 应被 kill
    sw    x7, UART_TXDATA_OFF(x22)    # wrong path — 不应触发 UART TX event
    sw    x7, WRONG_PATH_OFF(x20)     # wrong path — 不应写 DMEM 标记
    # === wrong path end ===
    jal   x0, fail_no_trap

trap_resume:
    # 验证 Case 2：trap 必须被触发，wrong-path DMEM/GPIO 标记必须为 0
    lw    x5, TRAP_SEEN_OFF(x20)
    addi  x6, x0, 1
    bne   x5, x6, fail_trap_seen
    lw    x5, WRONG_PATH_OFF(x20)
    bne   x5, x0, fail_trap_side_effect
    lw    x5, GPIO_OUT_OFF(x21)
    bne   x5, x0, fail_trap_side_effect

    # =========================================================================
    # PASS/FAIL — 写 TEST_STATUS 结束仿真
    # =========================================================================
pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFF(x20)
done:
    jal   x0, done

fail_branch_side_effect:
    addi  x5, x0, 101
    jal   x0, fail_with_x5

fail_no_trap:
    addi  x5, x0, 102
    jal   x0, fail_with_x5

fail_trap_seen:
    addi  x5, x0, 103
    jal   x0, fail_with_x5

fail_trap_side_effect:
    addi  x5, x0, 104
    jal   x0, fail_with_x5

fail_with_x5:
    lui   x20, DMEM_BASE_HI
    sw    x5, ERROR_CODE_OFF(x20)
    addi  x6, x0, 2
    sw    x6, TEST_STATUS_OFF(x20)
fail_loop:
    jal   x0, fail_loop

# =============================================================================
# trap handler — 校验 mcause=ECALL_M, mepc=预期值，mret 到 resume
# =============================================================================
.section .text.trap
trap_handler:
    lui   x20, DMEM_BASE_HI

    csrr  x5, mcause
    addi  x6, x0, CAUSE_ECALL_M
    bne   x5, x6, fail_cause                    # mcause 应为 ECALL from M-mode

    csrr  x5, mepc
    lw    x6, EXPECT_MEPC_OFF(x20)
    bne   x5, x6, fail_mepc                     # mepc 应为 ecall 指令地址

    addi  x5, x0, 1
    sw    x5, TRAP_SEEN_OFF(x20)                # 标记 trap 已触发
    lw    x6, RESUME_PC_OFF(x20)                # 加载跳过后应继续的地址
    csrw  mepc, x6                              # 写入 mepc，mret 后从那里继续
    mret

fail_cause:
    addi  x5, x0, 201
    jal   x0, fail_with_x5

fail_mepc:
    addi  x5, x0, 202
    jal   x0, fail_with_x5
