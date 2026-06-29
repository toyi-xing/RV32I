/*==============================================================================
 * 0500_fpga_led_spark — GPIO 软件延时交替闪烁
 *
 * FPGA 表现：
 *   LED0(LEDR0) 与 LED1(LEDR1) 以软件延时交替闪烁。
 *   观察到两灯轮流亮灭，周期约 500k × 2 条指令 ≈ 数毫秒（取决于 CPU 频率）。
 *   无串口输出，无中断。
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

    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET), 0x00000003u);

    for (;;) {
        mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), pattern);
        pattern ^= 0x00000003u;
        delay(800000u);
    }

    return 0;
}
