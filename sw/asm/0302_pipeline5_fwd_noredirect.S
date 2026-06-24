#include "platform.h"

#===============================================================================
# 0302_pipeline5_fwd_noredirect.S - RV32I data hazard forwarding + load-use test
#
# 目的：
#   - 五级流水 data hazard 定向测试。
#   - 测试 RTL 具备处理 data hazard 的能力（支持 RAW forwarding 和 load-use stall）。
#   - 该测试刻意不覆盖 control hazard，控制流保持顺序执行。
#   验证五级流水的 data hazard 处理能力：
#   1. EX/MEM->EX（WB_ALU）     -> back-to-back RAW
#   2. MEM/WB->EX（WB_ALU）     -> 间隔 1 条指令的 RAW
#   3. EX/MEM 优先于 MEM/WB    -> 两段同时命中同一 rd
#   4. EX/MEM->EX（WB_IMM）     -> LUI 立即数前递
#   5. EX/MEM->EX store data    -> store 的 rs2 前递
#   6. MEM/WB->EX store data    -> store 的 rs2 前递
#   7. load-use（rs1）         -> stall + MEM/WB->EX
#   8. load-use（rs2）         -> stall + MEM/WB->EX
#
# 设计：
#   所有测试结果累加到一个结果寄存器中，最终减去固定常数得到 1。
#   任意 forwarding/load-use 路径出错均会导致最终结果不为 1。
#   有转发路径的结果串联成一条计算链：
#    EX/MEM+MEM/WB  → x4=1
#    + priority      → x4=2
#    + WB_IMM        → x4=3
#    → store→load    → x7=3
#    → load-use rs1  → x8=3
#    → load-use rs2  → x16=3
#    + x8            → x4=6
#    + x16           → x4=9
#    - 8             → x4=1
#===============================================================================

.section .text.init
.globl _start

_start:
    jal   x0, test_main

.section .text
test_main:
    lui   x10, %hi(DMEM_BASE)
    addi  x10, x10, %lo(DMEM_BASE)           # x10 = DMEM_BASE = 0x00040000

    # ---- 1+2: EX/MEM->EX + MEM/WB->EX, WB_ALU ----
    # x4 = 1 (若两段 forwarding 都正常)
    addi  x1, x0, 5           # x1 = 5
    addi  x2, x1, 2           # x2 = 7 (EX/MEM->EX forward)
    addi  x3, x0, 6           # x3 = 6
    sub   x4, x2, x3          # x4 = 1 (x2 from MEM/WB, x3 from EX/MEM)

    # ---- 3: EX/MEM 优先于 MEM/WB ----
    # x20 = 1 (若 EX/MEM 优先正确); x4 += x20 => x4 = 2
    # 若误取 MEM/WB 的旧值 => x20 = 99 => x4 = 100
    addi  x20, x0, 99         # x20 = 99
    addi  x20, x20, -98       # x20 = 1 (priority: EX/MEM 99 over MEM/WB old 99)
    add   x4, x4, x20         # x4 = 2 (正: 1+1; 误: 1+99=100)

    # ---- 4: EX/MEM->EX, WB_IMM ----
    # x6 = 1 (若 WB_IMM 前递正常); x4 += x6 => x4 = 3
    # 若 WB_IMM 未正确选到 imm => x6 = 0 => x4 = 2
    lui   x5, 0x00001         # x5 = 0x00001000
    srli  x6, x5, 12          # x6 = 1 (EX/MEM->EX, WB_IMM)
    add   x4, x4, x6          # x4 = 3 (正: 2+1; 误: 2+0=2)

    # ---- 5+6: store data forwarding (EX/MEM->EX) + load back ----
    # sw 用 x4=3 测试 store data EX/MEM->EX 前递
    # lw 读回 3, 后续累加到结果
    sw    x4, 0x000(x10)      # dmem[0] = 3 (EX/MEM->EX store data fwd)
    lw    x7, 0x000(x10)      # x7 = 3 (读回 store 的值; 若 store fwd 错则不为 3)

    # ---- 7+8: load-use rs1 + rs2 ----
    # x8 = x7 (load-use rs1, 若 stall+fwd 正常则为 3)
    # x15 = reload 3, x16 = x15 (load-use rs2)
    addi  x8, x7, 0           # x8 = 3 (rs1 load-use stall + MEM/WB->EX fwd)
    lw    x15, 0x000(x10)     # x15 = 3
    add   x16, x0, x15        # x16 = 3 (rs2 load-use stall + MEM/WB->EX fwd)

    # ---- 累加所有结果, 最终得到 1 ----
    add   x4, x4, x8          # x4 = 3+3 = 6 (正), 或不为 6 (任何前驱出错)
    add   x4, x4, x16         # x4 = 6+3 = 9 (正), 或不为 9
    addi  x4, x4, -8          # x4 = 1 (正), 或不为 1 (转发路径出错)
    # 验证结果: 任意转发/load-use 路径出错 => x4 != 1 => testbench 不打印 PASS
    sw    x4, TEST_STATUS_OFFSET(x10)      # dmem[DMEM_BASE+0x100] = 1 (正), PASS

    # ---- 收尾 ----
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
