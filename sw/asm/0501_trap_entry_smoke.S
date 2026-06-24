#include "platform.h"

#===============================================================================
# 0501_trap_entry_ecall.S - trap entry 最小 smoke test
#
# 目的：
#   - 用 ECALL 触发 environment call exception。
#   - 依赖 mtvec 复位值 0x00000080，确认 core 能重定向到 trap handler。
#   - handler 写 TEST_STATUS_ADDR，让 testbench 打印 trap_entry 后正常 PASS。
#
# 通过条件：
#   - 仿真日志出现 "this cycle happen trap_entry"。
#   - trap handler 写 DMEM_BASE+0x100 = 1，testbench 打印 PASS。
#   - wrong_path 的 store 被 trap kill，不会改写 dmem[DMEM_BASE+0x100]。
#
# 说明：
#   - 当前 simple_ram 内部 mem[64] 对应软件 byte 地址 DMEM_BASE+0x100。
#   - trap handler 使用 .text.trap section，由 linker 固定放到 IMEM_BASE+0x80。
#   - 本测试只检查 trap entry 和 mtvec direct 跳转，不执行 MRET。
#===============================================================================

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    # 前几条 nop 填充流水线，确保 ecall 前的普通指令都已提交完毕。
    nop
    nop
    nop
    addi  x0, x0, 2               # 写 x0 是合法操作，但不影响状态；确认 x0 写操作不被 trap 干扰。
    ecall                          # 触发 environment call exception。
                                   # PC 应重定向到 mtvec（复位值 = IMEM_BASE + 0x80）。
                                   # 同时 trap_ctrl 会 kill 流水线中年轻指令（即 ecall 之后的所有指令）。

wrong_path:
    # ecall 被接受后，这条路径的所有指令都会被 trap kill。
    # 如果 trap 机制失效，这里会写 DMEM 并无限循环，最终 timeout 或写 FAIL。
    lui   x10, %hi(DMEM_BASE)
    addi  x10, x10, %lo(DMEM_BASE)               # x10 = DMEM_BASE（wrong path，不应提交）
    addi  x11, x0, 2              # x11 = 2 = FAIL value（wrong path，不应提交）
    sw    x11, TEST_STATUS_OFFSET(x10)         # wrong path store：trap kill 正常时不应写入 memory
    jal   x0, wrong_path

.section .text.trap
trap_handler:
    # core 被 ecall 重定向到这里。当前 mcause=11（ECALL_M），mepc=ecall 指令 PC。
    # 本 handler 不执行 MRET，直接写 PASS 结束仿真。
    lui   x10, %hi(DMEM_BASE)
    addi  x10, x10, %lo(DMEM_BASE)               # x10 = DMEM_BASE
    addi  x11, x0, 1              # x11 = 1 = PASS value
    sw    x11, TEST_STATUS_OFFSET(x10)         # dmem[DMEM_BASE+0x100] = 1 → testbench 判 PASS

done:
    jal   x0, done
