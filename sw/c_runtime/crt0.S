/*------------------------------------------------------------------------------
 * crt0.S — RV32I C 裸机程序最小启动代码。
 *
 * 作用：
 *   1. 设置 x2/sp 到 linker 定义的 __stack_top。
 *   2. 清零 .bss，满足 C 语言对未初始化全局变量的要求。
 *   3. 调用 main()。
 *   4. 根据 main 返回值写 TEST_STATUS_ADDR：
 *        main 返回 0  -> PASS，写 1
 *        main 返回非0 -> FAIL，写 2
 *------------------------------------------------------------------------------*/

.section .text.init
.globl _start

_start:
    # x2 是 sp。栈从 DMEM 顶部向下生长，__stack_top 在 c_baremetal.ld 中定义。
    lui   x2, %hi(__stack_top)
    addi  x2, x2, %lo(__stack_top)

    # 清零 .bss：x5 指向当前地址，x6 指向结束地址。
    lui   x5, %hi(__bss_start)
    addi  x5, x5, %lo(__bss_start)
    lui   x6, %hi(__bss_end)
    addi  x6, x6, %lo(__bss_end)

clear_bss:
    beq   x5, x6, bss_done
    sw    x0, 0(x5)
    addi  x5, x5, 4
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
    addi  x6, x0, 2
    sw    x6, 0(x5)
    jal   x0, done

pass:
    addi  x6, x0, 1
    sw    x6, 0(x5)

done:
    jal   x0, done

