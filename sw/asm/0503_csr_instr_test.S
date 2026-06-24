#include "platform.h"

#===============================================================================
# 0503_csr_inst.S - 6 条 Zicsr 指令独立测试
#
# 目的：
#   - 以 mscratch(0x340) 为测试 CSR，逐条验证 CSRRW/CSRRS/CSRRC/
#     CSRRWI/CSRRSI/CSRRCI 的读写正确性。
#   - 验证 CSRRW 在 rd=x0 时不写 rd、rs1=x0 时仍写 CSR；CSRRS/CSRRC
#     在 rs1=x0 时不修改 CSR 的语义。
#
# 通过条件：
#   - 所有 step 计分累加到 x21，最终 x21 == 10。
#   - 写 DMEM_BASE+0x100 = 1。
#
# 说明：
#   - 使用 mscratch 作为测试 CSR，该地址无 WARL 副作用，可自由读写任意值。
#   - 所有 li x5, 0x... 由汇编器自动展开为 lui + addi 序列。
#===============================================================================


.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x20, %hi(DMEM_BASE)
    addi  x20, x20, %lo(DMEM_BASE)              # x20 = DMEM_BASE
    addi  x21, x0, 0             # x21 = 计分寄存器

    # =========================================================================
    # Step 1: CSRRW — 写入 0xa5a5a5a5，然后纯读验证
    # =========================================================================
    li    x5, 0xa5a5a5a5
    csrrw x0, CSR_ADDR_MSCRATCH, x5   # mscratch = 0xa5a5a5a5（rd=x0 不捕获旧值）
    csrr  x6, CSR_ADDR_MSCRATCH       # x6 = mscratch（csrr 是 csrrs rd, CSR, x0 伪指令）
    bne   x6, x5, fail
    addi  x21, x21, 1            # score = 1

    # =========================================================================
    # Step 2: CSRRW — 原子交换，验证旧值返回和新值写入
    # =========================================================================
    li    x5, 0x5a5a5a5a
    csrrw x6, CSR_ADDR_MSCRATCH, x5   # x6 = 旧值(=0xa5a5a5a5), mscratch = 0x5a5a5a5a
    li    x7, 0xa5a5a5a5
    bne   x6, x7, fail           # 返回的旧值应为 0xa5a5a5a5
    csrr  x6, CSR_ADDR_MSCRATCH       # 再读一次确认新值已写入
    li    x7, 0x5a5a5a5a
    bne   x6, x7, fail
    addi  x21, x21, 1            # score = 2

    # =========================================================================
    # Step 3: CSRRS — 置位测试
    #         mscratch = 0x5a5a5a5a，用 CSRRS 只置位低 8 位
    # =========================================================================
    addi  x5, x0, 0x0ff          # x5 = 0x000000ff（mask：低 8 位置位）
    csrrs x6, CSR_ADDR_MSCRATCH, x5   # x6 = 旧值(=0x5a5a5a5a), mscratch |= 0xff
    li    x7, 0x5a5a5a5a
    bne   x6, x7, fail           # 返回的旧值应仍为 0x5a5a5a5a
    csrr  x6, CSR_ADDR_MSCRATCH       # 读新值
    li    x7, 0x5a5a5aff
    bne   x6, x7, fail           # 新值应为 0x5a5a5aff（低 8 位置位）
    addi  x21, x21, 1            # score = 3

    # =========================================================================
    # Step 4: CSRRC — 清除测试
    #         mscratch = 0x5a5a5aff，清除低 8 位
    # =========================================================================
    addi  x5, x0, 0x0ff          # x5 = 0x000000ff（mask：低 8 位清除）
    csrrc x6, CSR_ADDR_MSCRATCH, x5   # x6 = 旧值(=0x5a5a5aff), mscratch &= ~0xff
    li    x7, 0x5a5a5aff
    bne   x6, x7, fail           # 旧值应不变
    csrr  x6, CSR_ADDR_MSCRATCH       # 读新值
    li    x7, 0x5a5a5a00
    bne   x6, x7, fail           # 新值应为 0x5a5a5a00（低 8 位清零）
    addi  x21, x21, 1            # score = 4

    # =========================================================================
    # Step 5: CSRRWI — 立即数写入
    #         写入 uimm=0x5a（5 位无符号立即数），零扩展到 32 位 = 0x5a
    # =========================================================================
    csrrwi x6, CSR_ADDR_MSCRATCH, 0x1a  # x6 = 旧值(=0x5a5a5a00), mscratch = 0x1a
    li    x7, 0x5a5a5a00
    bne   x6, x7, fail              # 旧值应不变
    csrr  x6, CSR_ADDR_MSCRATCH
    addi  x7, x0, 0x1a
    bne   x6, x7, fail              # 新值应为 0x1a（uimm 零扩展）
    addi  x21, x21, 1               # score = 5

    # =========================================================================
    # Step 6: CSRRSI — 立即数置位
    #         mscratch = 0x1a，用 uimm=0x0a 置位
    # =========================================================================
    csrrsi x6, CSR_ADDR_MSCRATCH, 0x0a  # x6 = 旧值, mscratch |= 0x0a
    addi  x7, x0, 0x1a
    bne   x6, x7, fail             # 旧值应为 0x1a
    csrr  x6, CSR_ADDR_MSCRATCH
    addi  x7, x0, 0x1a             # 0x1a | 0x0a = 0x1a（0x1a 已包含 0x0a 的位）
    bne   x6, x7, fail
    addi  x21, x21, 1              # score = 6

    # =========================================================================
    # Step 7: CSRRCI — 立即数清除
    #         mscratch = 0x1a，用 uimm=0x08 清除 bit3
    # =========================================================================
    csrrci x6, CSR_ADDR_MSCRATCH, 0x08  # x6 = 旧值, mscratch &= ~0x08
    addi  x7, x0, 0x1a
    bne   x6, x7, fail             # 旧值应为 0x1a
    csrr  x6, CSR_ADDR_MSCRATCH
    addi  x7, x0, 0x12             # 0x1a & ~0x08 = 0x12
    bne   x6, x7, fail
    addi  x21, x21, 1              # score = 7

    # =========================================================================
    # Step 8: CSRRS rs1=x0 — 不应修改 CSR
    #         mscratch = 0x12，csrrs x0, CSR_ADDR_MSCRATCH, x0 → 只读不变
    # =========================================================================
    csrrs x0, CSR_ADDR_MSCRATCH, x0     # 只读操作，不修改 CSR
    csrr  x6, CSR_ADDR_MSCRATCH
    addi  x7, x0, 0x12
    bne   x6, x7, fail             # mscratch 应仍为 0x12
    addi  x21, x21, 1              # score = 8

    # =========================================================================
    # Step 9: CSRRC rs1=x0 — 不应修改 CSR
    #         mscratch = 0x12，csrrc x0, CSR_ADDR_MSCRATCH, x0 → 只读不变
    # =========================================================================
    csrrc x0, CSR_ADDR_MSCRATCH, x0     # 只读操作，不修改 CSR
    csrr  x6, CSR_ADDR_MSCRATCH
    addi  x7, x0, 0x12
    bne   x6, x7, fail             # mscratch 应仍为 0x12
    addi  x21, x21, 1              # score = 9

    # =========================================================================
    # Step 10: CSRRWI uimm=0 — 写入 0
    #          mscratch = 0x12，csrrwi 写入 uimm=0 → mscratch 清 0
    # =========================================================================
    csrrwi x6, CSR_ADDR_MSCRATCH, 0     # x6 = 旧值(=0x12), mscratch = 0
    addi  x7, x0, 0x12
    bne   x6, x7, fail             # 旧值应为 0x12
    csrr  x6, CSR_ADDR_MSCRATCH
    bne   x6, x0, fail             # 新值应为 0
    addi  x21, x21, 1              # score = 10

    # =========================================================================
    # 最终计分检查
    # =========================================================================
    addi  x5, x0, 10
    bne   x21, x5, fail

pass:
    addi  x5, x0, 1
    sw    x5, TEST_STATUS_OFFSET(x20)
done:
    jal   x0, done

fail:
    addi  x5, x0, 2
    sw    x5, TEST_STATUS_OFFSET(x20)
    jal   x0, done
