/*==============================================================================
 * c_baremetal.ld — RV32I 教学 core C 裸机程序链接脚本
 *
 * 内存布局：
 *   IMEM (0x00000000) : .text
 *   DMEM (0x00040000) : reserved / TEST_STATUS / .rodata / .data / .bss / stack
 *
 * simple_rom/simple_ram 当前容量均为 256 KiB。C 程序的数据段从 DMEM+0x200
 * 开始，避开 TEST_STATUS_ADDR = DMEM+0x100，防止正常全局变量/栈使用状态字。
 *
 * .data/.rodata 的初始值通过 dmem.mem 加载到 simple_ram。
 * .bss 由 sw/c_runtime/crt0.S 在进入 main 前清零。
 *============================================================================*/

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 256K
    DMEM (rw) : ORIGIN = 0x00040000, LENGTH = 256K
}

__dmem_base        = ORIGIN(DMEM);
__test_status_addr = ORIGIN(DMEM) + 0x100;
__c_data_base      = ORIGIN(DMEM) + 0x200;
__stack_top        = ORIGIN(DMEM) + LENGTH(DMEM);
__stack_size       = 0x2000;
__stack_bottom     = __stack_top - __stack_size;
__trap_vector      = ORIGIN(IMEM) + 0x80;

SECTIONS
{
    /*----------------------------------------------------------------------
     * .text.init — reset 后执行的入口 stub，必须位于 IMEM 起始地址。
     *--------------------------------------------------------------------*/
    .text.init : ALIGN(4)
    {
        KEEP(*(.text.init))    /* reset 入口 _start 必须位于 IMEM 起始处 */
    } > IMEM

    ASSERT(. <= __trap_vector, ".text.init overlaps trap vector")

    /*----------------------------------------------------------------------
     * .text.trap — M-mode direct trap 入口，和 core_pkg::MTVEC_RESET 对齐。
     *--------------------------------------------------------------------*/
    .text.trap __trap_vector : ALIGN(4)
    {
        __trap_section_start = .;
        KEEP(*(.text.trap))
        . = MAX(., __trap_section_start + 4);
    } > IMEM

    /*----------------------------------------------------------------------
     * .text — C 函数代码，放在 trap vector 之后。
     *--------------------------------------------------------------------*/
    .text : ALIGN(4)
    {
        *(.text)
        *(.text.*)
    } > IMEM

    /*----------------------------------------------------------------------
     * .dmem_image — 会被 objcopy 生成 dmem.mem 并加载到 simple_ram。
     *
     * 本节从 DMEM_BASE 开始，先保留 0x200 字节：
     *   0x00040000-0x000400ff : 保留
     *   0x00040100-0x00040103 : TEST_STATUS_ADDR
     *   0x00040104-0x000401ff : 保留
     *
     * C 可正常访问的数据从 0x00040200 开始。
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
