/*
 * 0754_external_timer_priority.c — MEIP/MTIP 优先级与汇总测试。
 *
 * 目的：
 *   - 同时制造 external interrupt（GPIO 上升沿）和 timer interrupt。
 *   - 同时打开 MIE_MEIE | MIE_MTIE，验证 MEIP > MTIP 优先级。
 *   - 第一拍 handler 进入 machine external interrupt，清外设 pending。
 *   - 第二拍 handler 进入 machine timer interrupt。
 *   - 验证 mip.MEIP 与 GPIO IRQ_STATUS 一致。
 *
 * 通过条件：
 *   - 第一次 interrupt：mcause = 0x8000000B (MEIP)
 *   - 第二次 interrupt：mcause = 0x80000007 (MTIP)
 *   - 第一次 handler 入口时 mip.MEIP 和 mip.MTIP 同时为 1。
 *   - MEIP handler 清除 GPIO 后 mip.MEIP = 0，mip.MTIP 仍为 1。
 *
 * 失败场景：
 *   - timeout：某一级中断未发生。
 *   - 顺序错误：第一次不是 MEIP 或第二次不是 MTIP。
 *   - handler 清除外设 pending 后 mip.MEIP 仍不为 0，或 MTIP 被错误清掉。
 *
 * main 返回码：
 *   0 : PASS
 *   1 : GPIO pending 未置位
 *   2 : timer pending 未置位
 *   11: 第一次中断 timeout
 *   12: 第一次 trap 不是 interrupt
 *   13: 第一次 interrupt 不是 MEIP
 *   14: 第一次 handler 入口时 mip.MEIP 未置位
 *   15: 第一次 handler 入口时 mip.MTIP 未置位
 *   16: 第一次 handler 入口时 GPIO IRQ_STATUS 未置位
 *   17: 清 GPIO pending 后 mip.MEIP 仍置位
 *   18: 清 GPIO pending 后 GPIO IRQ_STATUS 仍置位
 *   19: 清 GPIO pending 后 mip.MTIP 被错误清除
 *   21: 第二次中断 timeout
 *   22: 第二次 trap 不是 interrupt
 *   23: 第二次 interrupt 不是 MTIP
 *   24: handler 进入次数不是 2
 */

#include "platform.h"
#include "tb_rv32i_soc_test.h"

/* handler 记录 */
static volatile unsigned int irq_count;
static volatile unsigned int irq_first_mcause;
static volatile unsigned int irq_second_mcause;
static volatile unsigned int irq_mip_at_first_entry;
static volatile unsigned int irq_gpio_status_at_first_entry;
static volatile unsigned int irq_mip_after_meip_clear;
static volatile unsigned int irq_gpio_status_after_meip_clear;

static void wait_cycles(unsigned int n)
{
    volatile unsigned int i;
    for (i = 0u; i < n; i++) {
    }
}

static unsigned int wait_for_irq(unsigned int expected, unsigned int timeout)
{
    while (irq_count < expected && timeout > 0u) {
        timeout--;
    }
    return (irq_count >= expected) ? 0u : 1u;
}

unsigned int __trap_handler_c(unsigned int mcause, unsigned int mepc, unsigned int mtval)
{
    unsigned int code;

    (void)mtval;

    /* 非 interrupt trap → 无限循环 */
    if ((mcause & MCAUSE_INTERRUPT_BIT) == 0u) {
        for (;;) {
        }
    }

    code = mcause & MCAUSE_CODE_MASK;

    /* 记录 first/second */
    if (irq_count == 0u) {
        irq_first_mcause = mcause;
        irq_mip_at_first_entry = csr_read_mip();
        irq_gpio_status_at_first_entry = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    } else if (irq_count == 1u) {
        irq_second_mcause = mcause;
    } else {
        for (;;) {  /* 超过 2 次非预期中断 */
        }
    }
    irq_count++;

    if (code == 11u) {
        /* MEIP — 清 GPIO pending（上升沿触发，W1C 即可） */
        mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET),
            mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET)));
        irq_gpio_status_after_meip_clear = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
        irq_mip_after_meip_clear = csr_read_mip();
    } else if (code == 7u) {
        /* MTIP — 停定时器 */
        mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);
    }

    return mepc;
}

int main(void)
{
    unsigned int val;

    /* ----------------------------------------------------------------
     * 配置 GPIO 上升沿触发（bit 1）和 TIMER0
     * ---------------------------------------------------------------- */

    /* 关全局中断 */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_write_mie(0u);

    /* 确保 bit 1 为低 */
    tb_gpio0_clear_mask(2u);
    wait_cycles(20u);

    /* 配置 GPIO：上升沿触发 bit 1 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 2u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_RISE_EN_OFFSET), 2u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 2u);  /* 清残留 pending */

    /* 配置 TIMER0：MTIMECMP = 1。先启动并等待 MTIP 置位，但保持
     * mstatus.MIE=0，因此不会提前进入 handler。 */
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIME_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIMECMP_OFFSET), 1u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), TIMER32_CTRL_ENABLE);
    wait_cycles(20u);
    val = csr_read_mip();
    if ((val & MIP_MTIP) == 0u) {
        return 2;  /* timer pending 未置位 */
    }

    /* 制造 GPIO 上升沿（bit 1 低→高），pending 置位 */
    tb_gpio0_set_mask(2u);
    wait_cycles(20u);

    /* 确认 pending */
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET));
    if ((val & 2u) == 0u) {
        return 1;  /* GPIO pending 未置位 */
    }

    /* 开中断：同时使能 MEIP 和 MTIP */
    csr_write_mie(MIE_MEIE | MIE_MTIE);
    csr_set_mstatus(MSTATUS_MIE);

    /* 现在 MEIP=1（GPIO pending），MTIP=1（timer pending），应选择 MEIP。 */

    /* ----------------------------------------------------------------
     * 等待第一次中断 — 应为 MEIP（MEIP > MTIP）
     * ---------------------------------------------------------------- */
    if (wait_for_irq(1u, 5000u) != 0u) {
        return 11;  /* timeout — 第一次中断未发生 */
    }

    /* 验证第一次中断是 MEIP */
    val = irq_first_mcause;
    if ((val & MCAUSE_INTERRUPT_BIT) == 0u) {
        return 12;  /* 不是 interrupt */
    }
    if ((val & MCAUSE_CODE_MASK) != 11u) {
        return 13;  /* 不是 MEIP（应优先选择 external） */
    }

    /* 验证第一次进入时 mip.MEIP = 1 且 mip.MTIP = 1。 */
    val = irq_mip_at_first_entry;
    if ((val & MIP_MEIP) == 0u) {
        return 14;  /* 进入 MEIP handler 时 mip.MEIP 应为 1 */
    }
    if ((val & MIP_MTIP) == 0u) {
        return 15;  /* 严格优先级测试要求第一次 entry 时 MTIP 也已经 pending */
    }
    if ((irq_gpio_status_at_first_entry & 2u) == 0u) {
        return 16;  /* GPIO IRQ_STATUS 应与 mip.MEIP 对应 */
    }
    if ((irq_mip_after_meip_clear & MIP_MEIP) != 0u) {
        return 17;  /* 清 GPIO pending 后 mip.MEIP 应为 0 */
    }
    if ((irq_gpio_status_after_meip_clear & 2u) != 0u) {
        return 18;  /* 清 GPIO pending 后 IRQ_STATUS 应为 0 */
    }
    if ((irq_mip_after_meip_clear & MIP_MTIP) == 0u) {
        return 19;  /* 清 external 不应清 timer pending */
    }

    /* ----------------------------------------------------------------
     * 等待第二次中断 — 应为 MTIP
     * ---------------------------------------------------------------- */
    if (wait_for_irq(2u, 10000u) != 0u) {
        return 21;  /* timeout — 第二次中断未发生 */
    }

    /* 验证第二次中断是 MTIP */
    val = irq_second_mcause;
    if ((val & MCAUSE_INTERRUPT_BIT) == 0u) {
        return 22;
    }
    if ((val & MCAUSE_CODE_MASK) != 7u) {
        return 23;  /* 不是 MTIP */
    }

    /* 验证 exact 顺序：第一次=MEIP, 第二次=MTIP */
    if (irq_count != 2u) {
        return 24;  /* 不应有额外的中断 */
    }

    /* ----------------------------------------------------------------
     * 全部通过
     * ---------------------------------------------------------------- */
    return 0u;
}
