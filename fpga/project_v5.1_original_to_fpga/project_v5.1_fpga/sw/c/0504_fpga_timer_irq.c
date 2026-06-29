/*==============================================================================
 * 0504_fpga_timer_irq — 定时器中断控制 LED0 以 1s 间隔闪烁
 *
 * FPGA 表现：
 *   LED0 每隔 1 秒翻转一次状态（与 0503 视觉效果相同）。
 *   区别在于翻转由 TIMER0 中断驱动，主循环空闲（wfi）等待。
 *   50MHz 晶振驱动 TIMER0，每次中断将 MTIME 归零，MTIMECMP 固定为 50M。
 *   无串口，无按键响应。
 * 
 * debug 结果：
 *   一开始 rtl\fpga\fpga_dmem.sv:22 :        .clock0  (clk_i), 存在 __trap_handler_c 出不去的情况
 *   问题大概率出在第一次中断之后：
 *    - crt0.S 的 __trap_entry 会把 x1~x31 全部 sw 到栈，再调用 C handler，返回前又一堆 lw 从栈恢复。
 *    - FPGA DMEM wrapper 现在用的是 altsyncram M9K，读行为很可能是同步读/一拍读，而 CPU 核原本按“组合/同周期 DMEM 读”来设计。
 *    - 仿真器里用的 RAM 和 FPGA M9K 行为不一样，所以仿真 PC 看着正常，上板却可能在 trap 恢复寄存器、恢复 sp 或读取全局变量 led 时拿到旧数据。
 *    - 一旦 sp 或寄存器恢复错，第一次 LED 点亮后，后续可能卡死、反复 trap、或者返回到了不对的状态。
 *   改为 .clock0(~clk_i) 也就是让 DMEM M9K 在下降沿读写。这样 CPU 在上升沿进入 MEM 阶段后，地址/写使能/写数据稳定，下降沿 M9K 完成访问，下一次上升沿 CPU 正好能采到 load 数据。
 *   问题就修复了，然后0505也能跑了。
 *============================================================================*/

#include "platform.h"

#define CLK_HZ          50000000u
#define BLINK_CYCLES    CLK_HZ

#define LED0_MASK       GPIO_BIT(0)

static volatile uint32_t led = 0u;

/* 强定义覆盖 crt0.S 的弱符号 —— 所有 trap 都由这里处理 */
uint32_t __trap_handler_c(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    uint32_t code = mcause & MCAUSE_CODE_MASK;
    (void)mtval;

    /* 定时器中断 (mcause[31]=1, code=7) */
    if ((mcause & MCAUSE_INTERRUPT_BIT) && code == 7u) {
        led ^= LED0_MASK;
        mmio_write32(GPIO0_BASE + GPIO_OUT_OFFSET, led);

        /* 安排下一个 1s 中断 */
        mmio_write32(TIMER0_BASE + TIMER32_MTIME_OFFSET, 0u);
    }

    return mepc;    /* 返回原 mepc，继续执行被打断的代码 */
}

int main(void)
{
    /* LED0 输出 */
    mmio_write32(GPIO0_BASE + GPIO_OE_OFFSET, LED0_MASK);
    mmio_write32(GPIO0_BASE + GPIO_OUT_OFFSET, 0u);

    /* TIMER0：清零，设首次比较值，启动 */
    mmio_write32(TIMER0_BASE + TIMER32_MTIME_OFFSET, 0u);
    mmio_write32(TIMER0_BASE + TIMER32_MTIMECMP_OFFSET, BLINK_CYCLES);
    mmio_write32(TIMER0_BASE + TIMER32_CTRL_OFFSET, TIMER32_CTRL_ENABLE);

    /* 开中断：定时器中断 + 全局 MIE */
    csr_set_mie(MIE_MTIE);
    csr_set_mstatus(MSTATUS_MIE);

    for (;;) {

    }

    led ^= LED0_MASK;
    mmio_write32(GPIO0_BASE + GPIO_OUT_OFFSET, led);
}
