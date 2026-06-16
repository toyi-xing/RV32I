#===============================================================================
# 0301_pipeline5_nofwd_noredirect.S - RV32I five-stage pipeline smoke test without hazards
#
# 目的：
#   - 早期搭建五级流水空壳时的冒烟测试，也可作为当前基础数据通路回归。
#   - 该测试刻意不依赖 data hazard/control hazard 处理能力。
#   1. 只使用顺序流，不使用 branch/JAL/JALR。
#   2. 在 producer/consumer 之间插入 3 条 nop，避免 RAW 依赖需要 forwarding/stall。
#   3. 通过 ALU 计算出 1，写入 RAM，再 load 回来，最后写 TEST_STATUS_ADDR。
#
# PASS 条件：
#   testbench 检测到 DMEM_BASE+0x100 写入 1 后打印 PASS。
#===============================================================================

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    addi  x1, x0, 7           # x1 = 7

    addi  x2, x0, 6           # x2 = 6
    nop
    nop
    nop

    sub   x3, x1, x2          # x3 = 1

    lui   x10, 0x40           # x10 = DMEM_BASE = 0x00040000
    nop
    nop
    nop

    sw    x3, 0x000(x10)      # dmem[DMEM_BASE+0x000] = 1

    lw    x4, 0x000(x10)      # x4 = 1
    nop
    nop
    nop

    addi  x5, x4, 0           # x5 = loaded pass value
    nop
    nop
    nop

    sw    x5, 0x100(x10)      # dmem[DMEM_BASE+0x100] = 1, notify testbench

    # 不跳转收尾，避免触发当前尚未实现的 redirect flush。
    # 留出若干合法 nop，保证 testbench 在取到空 ROM 之前结束。
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
