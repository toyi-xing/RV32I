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
#
# 说明：
#   - 当前 simple_ram 内部 mem[64] 对应软件 byte 地址 DMEM_BASE+0x100。
#   - 本测试只检查 trap entry 和 mtvec direct 跳转，不执行 MRET。
#===============================================================================

.section .text.init
.globl _start

_start:
    nop
    nop
    nop
    addi  x0, x0, 2
    ecall                       # 触发 trap，PC 应重定向到 mtvec = 0x80

wrong_path:
    lui   x10, 0x10
    addi  x11, x0, 2
    sw    x11, 0x100(x10)       # wrong path：trap kill 正常时不应提交
    jal   x0, wrong_path

    # 当前 core_pkg::MTVEC_RESET = IMEM_BASE + 0x80。
    # .text.init 位于 IMEM 起始处，因此用 .org 把 handler 放到 0x80。
    .org 0x80

trap_handler:
    lui   x10, 0x10             # x10 = DMEM_BASE
    addi  x11, x0, 1            # PASS value
    sw    x11, 0x100(x10)       # dmem[DMEM_BASE+0x100] = 1

done:
    jal   x0, done
