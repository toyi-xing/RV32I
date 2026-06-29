/*==============================================================================
 * 0501_fpga_smoke — UART 打印 + GPIO 软件延时交替闪烁
 *
 * FPGA 表现：
 *   上电后通过 UART0 输出 "RV\n"（可在串口终端看到两个字符和一个换行）。
 *   随后 LED0 与 LED1 以软件延时交替闪烁（与 0500 相同，但延时更长）。
 *   使用中断：纯轮询。
 *============================================================================*/

#include "platform.h"

static void delay(volatile uint32_t cycles)
{
    while (cycles != 0u) {
        cycles--;
    }
}

int main(void)
{
    uint32_t pattern = 1u;

    uart_enable_tx(UART0_BASE);
    uart_putc(UART0_BASE, 'R');
    uart_putc(UART0_BASE, 'V');
    uart_putc(UART0_BASE, '\n');

    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET), 0x00000003u);

    for (;;) {
        mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), pattern);
        pattern ^= 0x00000003u;
        delay(2000000u);
    }

    return 0;
}
