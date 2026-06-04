/*==============================================================================
 * c_baremetal.ld — RV32I 教学 core C 裸机程序链接脚本
 *
 * 内存布局：
 *   IMEM (0x00000000) : .text
 *   DMEM (0x00010000) : reserved / TEST_STATUS / .rodata / .data / .bss / stack
 *
 * simple_rom/simple_ram 当前容量均为 4 KiB。C 程序的数据段从 DMEM+0x200
 * 开始，避开 TEST_STATUS_ADDR = DMEM+0x100，防止正常全局变量/栈使用状态字。
 *
 * .data/.rodata 的初始值通过 dmem.mem 加载到 simple_ram。
 * .bss 由 sw/c_runtime/crt0.S 在进入 main 前清零。
 *============================================================================*/

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rw) : ORIGIN = 0x00010000, LENGTH = 4K
}

__dmem_base        = ORIGIN(DMEM);
__test_status_addr = ORIGIN(DMEM) + 0x100;
__c_data_base      = ORIGIN(DMEM) + 0x200;
__stack_bottom     = ORIGIN(DMEM) + 0x0e00;
__stack_top        = ORIGIN(DMEM) + LENGTH(DMEM);

SECTIONS
{
    /*----------------------------------------------------------------------
     * .text — C runtime 和 C 函数代码，放入 IMEM。
     *--------------------------------------------------------------------*/
    .text : ALIGN(4)
    {
        KEEP(*(.text.init))    /* reset 入口 _start 必须位于 IMEM 起始处 */
        *(.text)
        *(.text.*)
    } > IMEM

    /*----------------------------------------------------------------------
     * .dmem_image — 会被 objcopy 生成 dmem.mem 并加载到 simple_ram。
     *
     * 本节从 DMEM_BASE 开始，先保留 0x200 字节：
     *   0x00010000-0x000100ff : 保留
     *   0x00010100-0x00010103 : TEST_STATUS_ADDR
     *   0x00010104-0x000101ff : 保留
     *
     * C 可正常访问的数据从 0x00010200 开始。
     *--------------------------------------------------------------------*/
    .dmem_image ORIGIN(DMEM) : ALIGN(4)
    {
        . += 0x200;

        __rodata_start = .;
        *(.srodata)
        *(.srodata.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
        __rodata_end = .;

        __data_start = .;
        *(.sdata)
        *(.sdata.*)
        *(.data)
        *(.data.*)
        . = ALIGN(4);
        __data_end = .;
    } > DMEM

    /*----------------------------------------------------------------------
     * .bss — 不进入 dmem.mem；启动代码进入 main 前清零。
     *--------------------------------------------------------------------*/
    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.sbss)
        *(.sbss.*)
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}

ASSERT(__bss_end <= __stack_bottom, "C data/bss overlaps reserved stack area")
ASSERT(__test_status_addr + 4 <= __c_data_base, "TEST_STATUS overlaps C data area")
