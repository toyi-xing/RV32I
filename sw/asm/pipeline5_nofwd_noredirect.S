#===============================================================================
# pipeline5_nofwd_noredirect.S - RV32I five-stage pipeline smoke test without hazards
#
# 目的：
#   - 单周期和搭建五级流水空壳冒烟测试。
#   - 当前 rtl 无 data hazard （无 forewording,不支持 RAW ）与 control hazard （ pc redirect 后的指令 kill ）。
#   1. 只使用顺序流，不使用 branch/JAL/JALR，避免当前尚未实现的 flush/kill。
#   2. 在 producer/consumer 之间插入 3 条 nop，避免当前尚未实现的 forwarding/stall。
#   3. 通过 ALU 计算出 1，写入 RAM，再 load 回来，最后写 TEST_STATUS_ADDR。
#
# PASS 条件：
#   testbench 检测到 DMEM_BASE+0x100 写入 1 后打印 PASS。
#===============================================================================

.section .text.init
.globl _start

_start:
    addi  x1, x0, 7           # x1 = 7

    addi  x2, x0, 6           # x2 = 6
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0

    sub   x3, x1, x2          # x3 = 1

    lui   x10, 0x10           # x10 = DMEM_BASE = 0x00010000
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0

    sw    x3, 0x000(x10)      # dmem[DMEM_BASE+0x000] = 1

    lw    x4, 0x000(x10)      # x4 = 1
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0

    addi  x5, x4, 0           # x5 = loaded pass value
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0

    sw    x5, 0x100(x10)      # dmem[DMEM_BASE+0x100] = 1, notify testbench

    # 不跳转收尾，避免触发当前尚未实现的 redirect flush。
    # 留出若干合法 nop，保证 testbench 在取到空 ROM 之前结束。
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
