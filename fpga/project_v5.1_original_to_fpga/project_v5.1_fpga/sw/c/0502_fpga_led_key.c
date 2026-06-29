/*==============================================================================
 * 0502_fpga_led_key — GPIO 直通：按键直接驱动 LED
 *
 * FPGA 表现：
 *   无中断，无串口，纯 GPIO 轮询。
 *   KEY0 按下 → LED0 亮，松开 → LED0 灭。
 *   KEY1 按下 → LED1 亮，松开 → LED1 灭。
 *   若灯与按键对应关系相反，说明板子物理走线与代码 bit 假设不一致。
 *============================================================================*/

#include "platform.h"

#define KEY0_MASK           GPIO_BIT(0)
#define KEY1_MASK           GPIO_BIT(1)
#define KEY_MASK            (KEY0_MASK | KEY1_MASK)

#define LED0_MASK           GPIO_BIT(0)
#define LED1_MASK           GPIO_BIT(1)
#define GPIO_OUTPUT_MASK    (LED0_MASK | LED1_MASK)

#ifndef KEY_ACTIVE_LOW
#define KEY_ACTIVE_LOW      1u
#endif

int main(void)
{
    uint32_t keys;

    /* 配置 LED0(bit0) LED1(bit1) 为输出 */
    mmio_write32(GPIO0_BASE + GPIO_OE_OFFSET, LED0_MASK | LED1_MASK);

    for (;;) {
        /* 读按键（低电平有效 → 取反使按下=1） */
        keys = mmio_read32(GPIO0_BASE + GPIO_IN_OFFSET);
#if KEY_ACTIVE_LOW
        keys = ~keys;
#endif
        keys &= KEY0_MASK | KEY1_MASK;

        /* KEY0 → LED0，KEY1 → LED1 */
        mmio_write32(GPIO0_BASE + GPIO_OUT_OFFSET, keys);
    }

    return 0;
}
