/*==============================================================================
 * 0503_fpga_timer_blink — 定时器轮询控制 LED0 以 1s 间隔闪烁
 *
 * FPGA 表现：
 *   LED0 每隔 1 秒翻转一次状态（亮 1s → 灭 1s → 亮 1s → ...）。
 *   50MHz 晶振驱动 TIMER0，软件轮询 MTIME 寄存器判断 50M 周期。
 *   无中断，无串口，无按键响应。
 *============================================================================*/

#include "platform.h"

#define CLK_HZ          50000000u
#define BLINK_CYCLES    CLK_HZ  /* 50M ticks = 1s */

#define LED0_MASK       GPIO_BIT(0)

int main(void)
{
    uint32_t next;
    uint32_t led = 0u;

    /* LED0 输出 */
    mmio_write32(GPIO0_BASE + GPIO_OE_OFFSET, LED0_MASK);
    mmio_write32(GPIO0_BASE + GPIO_OUT_OFFSET, 0u);

    /* TIMER0 从 0 开始计数 */
    mmio_write32(TIMER0_BASE + TIMER32_MTIME_OFFSET, 0u);
    mmio_write32(TIMER0_BASE + TIMER32_CTRL_OFFSET, TIMER32_CTRL_ENABLE);

    next = BLINK_CYCLES;

    for (;;) {
        uint32_t now = mmio_read32(TIMER0_BASE + TIMER32_MTIME_OFFSET);

        if (now >= next) {
            led ^= LED0_MASK;
            mmio_write32(GPIO0_BASE + GPIO_OUT_OFFSET, led);
            next += BLINK_CYCLES;
        }
    }
}
