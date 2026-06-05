#===============================================================================
# pipeline5_fwd_redirect.S - RV32I pipeline forwarding + redirect 测试
#
# 目的：
#   - 专门覆盖 data hazard 和 control hazard 叠在一起时的行为。
#   - branch 比较操作数来自 EX/MEM、MEM/WB forwarding。
#   - load-use 后紧跟 branch，依赖 stall + forwarding 后再做 redirect。
#   - JAL/JALR taken redirect 后，wrong-path store/write 必须被 kill。
#   - JALR target base 来自上一条 ALU 指令，依赖 EX/MEM forwarding。
#
# 通过条件：
#   - 所有检查点累加到 x20，最终 x20 == 31。
#   - wrong-path store 没有改写 dmem[4]/dmem[8]/dmem[12]。
#   - 最后写 DMEM_BASE+0x100 = 1。
#===============================================================================

.section .text.init
.globl _start

_start:
    lui   x10, 0x10              # x10 = DMEM_BASE
    addi  x20, x0, 0             # 计分寄存器
    addi  x21, x0, 0             # wrong-path GPR 哨兵值
    addi  x22, x0, 99            # wrong-path store 污染值

    # -------------------------------------------------------------------------
    # 1. taken branch：rs1 来自 EX/MEM，rs2 来自 MEM/WB。
    #    I2 产生 x2，I1 产生 x1，branch 紧接着消费两者。
    # -------------------------------------------------------------------------
    addi  x1, x0, 7
    addi  x2, x1, 0              # x2 = 7，从 EX/MEM 消费 x1
    beq   x2, x1, br_fwd_taken   # x2 来自 EX/MEM，x1 来自 MEM/WB
    sw    x22, 0x004(x10)        # wrong path：必须被 kill
    addi  x21, x0, 99            # wrong path：必须被 kill
    jal   x0, fail

br_fwd_taken:
    addi  x20, x20, 1            # 计分 = 1
    bne   x21, x0, fail

    # -------------------------------------------------------------------------
    # 2. not-taken branch，操作数来自 forwarding。
    #    若 branch compare 或 redirect valid 错误，这里会落入 fail。
    # -------------------------------------------------------------------------
    addi  x3, x0, 4
    addi  x4, x3, 1              # x4 = 5，从 EX/MEM 消费 x3
    beq   x4, x3, fail           # x4 来自 EX/MEM，x3 来自 MEM/WB；not taken
    addi  x20, x20, 2            # 计分 = 3

    # -------------------------------------------------------------------------
    # 3. load-use branch。
    #    branch 必须在 ID stall，等 lw 数据可用后再 redirect。
    # -------------------------------------------------------------------------
    addi  x5, x0, 11
    sw    x5, 0x000(x10)
    lw    x6, 0x000(x10)
    beq   x6, x5, load_branch_taken
    sw    x22, 0x008(x10)        # wrong path：必须被 kill
    addi  x21, x0, 77            # wrong path：必须被 kill
    jal   x0, fail

load_branch_taken:
    addi  x20, x20, 4            # 计分 = 7
    bne   x21, x0, fail

    # -------------------------------------------------------------------------
    # 4. JAL link + redirect。
    #    target 的第一条指令立即检查 JAL rd = PC + 4。
    # -------------------------------------------------------------------------
.Ljal_link_ref_hi:
    auipc x7, %pcrel_hi(jal_after)
    addi  x7, x7, %pcrel_lo(.Ljal_link_ref_hi)
    jal   x8, jal_target
jal_after:
    sw    x22, 0x00c(x10)        # wrong path：必须被 kill
    addi  x21, x0, 66            # wrong path：必须被 kill
    jal   x0, fail

jal_target:
    bne   x8, x7, fail
    addi  x20, x20, 8            # 计分 = 15
    bne   x21, x0, fail

    # -------------------------------------------------------------------------
    # 5. JALR target base forwarding + bit0 清零。
    #    JALR 前一条指令把 x11 变为奇数。
    #    JALR 必须 forward x11、清掉 bit0，并跳转到 jalr_target。
    # -------------------------------------------------------------------------
.Ljalr_link_ref_hi:
    auipc x12, %pcrel_hi(jalr_after)
    addi  x12, x12, %pcrel_lo(.Ljalr_link_ref_hi)
.Ljalr_target_hi:
    auipc x11, %pcrel_hi(jalr_target)
    addi  x11, x11, %pcrel_lo(.Ljalr_target_hi)
    addi  x11, x11, 1            # 奇数 target base；JALR 必须清掉 bit0
    jalr  x13, x11, 0            # 从 EX/MEM 消费 x11
jalr_after:
    sw    x22, 0x010(x10)        # wrong path：必须被 kill
    addi  x21, x0, 55            # wrong path：必须被 kill
    jal   x0, fail

jalr_target:
    bne   x13, x12, fail
    addi  x20, x20, 16           # 计分 = 31
    bne   x21, x0, fail

    # -------------------------------------------------------------------------
    # 6. wrong-path store 检查和最终计分检查。
    # -------------------------------------------------------------------------
    lw    x14, 0x004(x10)
    bne   x14, x0, fail
    lw    x14, 0x008(x10)
    bne   x14, x0, fail
    lw    x14, 0x00c(x10)
    bne   x14, x0, fail
    lw    x14, 0x010(x10)
    bne   x14, x0, fail

    addi  x15, x0, 31
    bne   x20, x15, fail

pass:
    addi  x31, x0, 1
    sw    x31, 0x100(x10)

done:
    jal   x0, done

fail:
    addi  x31, x0, 2
    sw    x31, 0x100(x10)
    jal   x0, done
