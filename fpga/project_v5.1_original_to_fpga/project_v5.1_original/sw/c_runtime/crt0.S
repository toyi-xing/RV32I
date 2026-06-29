/*------------------------------------------------------------------------------
 * crt0.S — RV32I C 裸机程序最小启动代码。
 *
 * 作用：
 *   1. 提供固定 .text.trap 入口，供 C 程序通过 __trap_handler_c 接管 trap。
 *   2. 设置 x2/sp 到 linker 定义的 __stack_top。
 *   3. 清零 .bss，满足 C 语言对未初始化全局变量的要求。
 *   4. 调用 main()。
 *   5. 根据 main 返回值写 TEST_STATUS_ADDR：
 *        main 返回 0  -> PASS，写 1
 *        main 返回非0 -> FAIL，写 2
 *
 * 说明：
 *   - __trap_handler_c 是弱定义。普通 C 程序不触发 trap 时无需关心。
 *   - 需要处理 trap 的 C 测试可自行提供强定义：
 *       unsigned int __trap_handler_c(unsigned int mcause,
 *                                    unsigned int mepc,
 *                                    unsigned int mtval);
 *     返回值会写入 mepc，随后由本入口执行 mret。
 *------------------------------------------------------------------------------*/

.section .text.init
.globl _start

_start:
    jal   x0, test_main           # 跳过 trap_vector 区域，跳转到真正的 .text 入口

.section .text.trap
.globl __trap_entry

__trap_entry:
    # trap 可能打断任意 C 指令流。进入 C handler 前要把全部被 caller 有可能使用
    # 的 GPR 保存到栈上，返回前再恢复。r2/sp 也保存到自己的 ABI slot。
    # 栈帧布局：x2(sp) 处不存数据，x2+4 开始依次存 x1/x3~x31，共 31 word = 124 bytes，
    # 再加 x2 自身，总共 128 bytes。保持 sp 16 字节对齐。
    addi  x2, x2, -128            # 分配栈帧
    sw    x1, 4(x2)               # 保存 ra
    sw    x3, 12(x2)              # 保存 gp（当前未使用，但保留）
    sw    x4, 16(x2)              # 保存 tp（当前未使用，但保留）
    sw    x5, 20(x2)              # 保存 t0
    sw    x6, 24(x2)              # 保存 t1
    sw    x7, 28(x2)              # 保存 t2
    sw    x8, 32(x2)              # 保存 s0/fp
    sw    x9, 36(x2)              # 保存 s1
    sw    x10, 40(x2)             # 保存 a0
    sw    x11, 44(x2)             # 保存 a1
    sw    x12, 48(x2)             # 保存 a2
    sw    x13, 52(x2)             # 保存 a3
    sw    x14, 56(x2)             # 保存 a4
    sw    x15, 60(x2)             # 保存 a5
    sw    x16, 64(x2)             # 保存 a6
    sw    x17, 68(x2)             # 保存 a7
    sw    x18, 72(x2)             # 保存 s2
    sw    x19, 76(x2)             # 保存 s3
    sw    x20, 80(x2)             # 保存 s4
    sw    x21, 84(x2)             # 保存 s5
    sw    x22, 88(x2)             # 保存 s6
    sw    x23, 92(x2)             # 保存 s7
    sw    x24, 96(x2)             # 保存 s8
    sw    x25, 100(x2)            # 保存 s9
    sw    x26, 104(x2)            # 保存 s10
    sw    x27, 108(x2)            # 保存 s11
    sw    x28, 112(x2)            # 保存 t3
    sw    x29, 116(x2)            # 保存 t4
    sw    x30, 120(x2)            # 保存 t5
    sw    x31, 124(x2)            # 保存 t6
    addi  x5, x2, 128             # x5 = 保存前的原始 sp
    sw    x5, 8(x2)               # 把原始 sp 存到 x2 的 ABI slot

    # C handler 参数：a0=mcause, a1=mepc, a2=mtval。
    csrr  x10, mcause
    csrr  x11, mepc
    csrr  x12, mtval
    jal   x1, __trap_handler_c    # 调用 C handler；返回值 x10 = 新的 mepc 值
    csrw  mepc, x10               # 用 handler 返回值更新 mepc（mret 时跳转至此地址）

    # 恢复全部 GPR（和保存顺序对称）
    lw    x1, 4(x2)
    lw    x3, 12(x2)
    lw    x4, 16(x2)
    lw    x5, 20(x2)
    lw    x6, 24(x2)
    lw    x7, 28(x2)
    lw    x8, 32(x2)
    lw    x9, 36(x2)
    lw    x10, 40(x2)
    lw    x11, 44(x2)
    lw    x12, 48(x2)
    lw    x13, 52(x2)
    lw    x14, 56(x2)
    lw    x15, 60(x2)
    lw    x16, 64(x2)
    lw    x17, 68(x2)
    lw    x18, 72(x2)
    lw    x19, 76(x2)
    lw    x20, 80(x2)
    lw    x21, 84(x2)
    lw    x22, 88(x2)
    lw    x23, 92(x2)
    lw    x24, 96(x2)
    lw    x25, 100(x2)
    lw    x26, 104(x2)
    lw    x27, 108(x2)
    lw    x28, 112(x2)
    lw    x29, 116(x2)
    lw    x30, 120(x2)
    lw    x31, 124(x2)
    lw    x2, 8(x2)               # 恢复 sp（从保存的原始 sp 中加载）
    mret                           # 返回被打断的 C 代码流

.section .text
test_main:
    # x2 是 sp。栈从 DMEM 顶部向下生长，__stack_top 在 c_baremetal.ld 中定义。
    lui   x2, %hi(__stack_top)
    addi  x2, x2, %lo(__stack_top)

    # 清零 .bss：x5 指向当前地址，x6 指向结束地址。
    lui   x5, %hi(__bss_start)
    addi  x5, x5, %lo(__bss_start)
    lui   x6, %hi(__bss_end)
    addi  x6, x6, %lo(__bss_end)

clear_bss:
    beq   x5, x6, bss_done         # x5 == x6 表示 .bss 已清零完毕
    sw    x0, 0(x5)                # 写 0
    addi  x5, x5, 4                # 前进一个 word
    jal   x0, clear_bss

bss_done:
    # 调用 C 的 main()。按 RISC-V ABI，返回值放在 x10/a0。
    jal   x1, main

    # 构造 TEST_STATUS_ADDR，后续只由 crt0 统一写 PASS/FAIL。
    lui   x5, %hi(__test_status_addr)
    addi  x5, x5, %lo(__test_status_addr)

    # main 返回 0 表示通过，非 0 表示失败。
    beq   x10, x0, pass

fail:
    addi  x6, x0, 2               # x6 = 2（FAIL value）
    sw    x6, 0(x5)               # 写 TEST_STATUS_ADDR = 2
    jal   x0, done

pass:
    addi  x6, x0, 1               # x6 = 1（PASS value）
    sw    x6, 0(x5)               # 写 TEST_STATUS_ADDR = 1

done:
    jal   x0, done                # 无限循环终止

.weak __trap_handler_c
.type __trap_handler_c, @function
__trap_handler_c:
    # 默认 handler 表示"普通 C 程序不期望发生 trap"。
    # 若触发，直接写 FAIL，便于 testbench 结束。
    lui   x5, %hi(__test_status_addr)
    addi  x5, x5, %lo(__test_status_addr)
    addi  x6, x0, 2               # x6 = 2（FAIL value）
    sw    x6, 0(x5)               # 写 TEST_STATUS_ADDR = 2
default_trap_loop:
    jal   x0, default_trap_loop
