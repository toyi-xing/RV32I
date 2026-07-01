/*
 * 0757_gpio_periodic_irq.c — TB 固定周期 GPIO 输入中断精确测量。
 *
 * 目的：
 *   - 用 TIMER0.MTIME 精确测量 bit30/bit31 的边沿间隔。
 *   - 验证 bit30 双边沿间隔 ≈ 200 周期（TB_GPIO0_FAST_TOGGLE_CYCLES）。
 *   - 验证 bit31 双边沿间隔 ≈ 2000 周期（TB_GPIO0_SLOW_TOGGLE_CYCLES）。
 *   - 通过 UART TX 输出测量结果，便于观察实际值与目标值的偏差。
 *
 * TB 硬件驱动（tb_rv32i_soc.sv initial fork 线程）：
 *   - gpio0_in[30] 每 200 拍翻转一次（TB_GPIO0_FAST_TOGGLE_CYCLES）。
 *   - gpio0_in[31] 每 2000 拍翻转一次（TB_GPIO0_SLOW_TOGGLE_CYCLES）。
 *   - 双边沿触发 → 每次翻转产生一个 MEIP。
 *
 * 测量原理：
 *   - TIMER0 的 MTIME 在每个 clock cycle 自增 1（free-running counter）。
 *   - handler 记录每个 bit 的首次边沿 MTIME 和末次边沿 MTIME。
 *   - main 汇总后计算平均间隔：
 *       avg_bitN_interval = (bitN_last_mtime - bitN_first_mtime) / (bitN_count - 1)
 *   - 中断响应延迟在每次边沿中近似恒定，相减后延迟被抵消。
 *     测量值 = TB 翻转周期 + 噪声。噪声主要来自：
 *       (a) 被测指令流与 TB 翻转边沿的对齐抖动
 *       (b) handler 执行时间和 W1C 周期的微小波动
 *   - 噪声幅度通常 < 5 个周期，bit30（200 周期）的测量误差约 2.5%，
 *     bit31（2000 周期）的测量误差约 0.25%。
 *
 * 通过条件：
 *   - bit30_count >= 10：快周期采集足够样本。
 *   - bit31_count >= 6： 慢周期采集足够样本。
 *   - avg_bit30_interval ∈ [180, 220]：半周期 200 ±10%。
 *   - avg_bit31_interval ∈ [1800, 2200]：半周期 2000 ±10%。
 *
 * 失败场景：
 *   1: bit30_count < 10（中断未正常触发或 handler 未正确计数）
 *   2: bit31_count < 6
 *   3: avg_bit30_interval 超出 [180, 220]（快周期频率偏差）
 *   4: avg_bit31_interval 超出 [1800, 2200]（慢周期频率偏差）
 */
#include "platform.h"
#include "tb_rv32i_soc_test.h"

#define BIT30_MASK  (RV32I_U32_C(1) << 30)
#define BIT31_MASK  (RV32I_U32_C(1) << 31)
#define MIN_30_COUNT  RV32I_U32_C(10)
#define MIN_31_COUNT  RV32I_U32_C(6)

/* handler 统计数据 */
static volatile unsigned int irq_count;
static volatile unsigned int bit30_count;
static volatile unsigned int bit31_count;
static volatile unsigned int bit30_first_mtime;
static volatile unsigned int bit30_last_mtime;
static volatile unsigned int bit31_first_mtime;
static volatile unsigned int bit31_last_mtime;
static volatile unsigned int test_complete;

/* 软件除法 — RV32I 不含 DIV 指令 */
static unsigned int div_u32(unsigned int a, unsigned int b)
{
    unsigned int q = 0, r = 0;
    int i;
    if (b == 0u) return 0u;
    for (i = 31; i >= 0; i--) {
        r = (r << 1) | ((a >> (unsigned int)i) & 1u);
        if (r >= b) {
            r -= b;
            q |= (1u << (unsigned int)i);
        }
    }
    return q;
}

/* 带余数的除法，供十进制打印使用 */
static unsigned int divmod_u32(unsigned int a, unsigned int b, unsigned int *rem)
{
    unsigned int q = 0, r = 0;
    int i;
    if (b == 0u) { *rem = 0u; return 0u; }
    for (i = 31; i >= 0; i--) {
        r = (r << 1) | ((a >> (unsigned int)i) & 1u);
        if (r >= b) {
            r -= b;
            q |= (1u << (unsigned int)i);
        }
    }
    *rem = r;
    return q;
}

/* UART 输出辅助 */
static void uart_print_str(const char *s)
{
    while (*s) {
        uart_putc(UART0_BASE, *s++);
    }
}

static void uart_print_dec32(unsigned int val)
{
    char buf[12];
    int i = 0, j;
    unsigned int q, r;
    if (val == 0u) {
        uart_putc(UART0_BASE, '0');
        return;
    }
    q = val;
    while (q > 0u) {
        q = divmod_u32(q, 10u, &r);
        buf[i++] = (char)('0' + r);
    }
    for (j = i - 1; j >= 0; j--) {
        uart_putc(UART0_BASE, buf[j]);
    }
}

/*
 * __trap_handler_c — C trap handler。
 *
 * 累加 bit30/bit31 边沿计数并记录首末次 MTIME。
 * 所有 MMIO 读（MTIME / IRQ_STATUS）对外设寄存器直接读取，延迟固定。
 * W1C 清 pending 后返回 mepc，由 crt0.S 执行 mret。
 *
 * 注意：达到阈值后写 IRQ_EN=0 而非关 mstatus.MIE，
 * 因为 mret 会从 MPIE 恢复 MIE，写 MIE=0 无效。
 */
unsigned int __trap_handler_c(unsigned int mcause, unsigned int mepc, unsigned int mtval)
{
    unsigned int gpio_status;
    unsigned int now;

    (void)mtval;

    if (((mcause & MCAUSE_INTERRUPT_BIT) != 0u) &&
        ((mcause & MCAUSE_CODE_MASK) == 11u)) {

        irq_count++;
        now = mmio_read32(timer32_reg(TIMER0_BASE, TIMER32_MTIME_OFFSET));
        gpio_status = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));

        if (gpio_status & BIT30_MASK) {
            if (bit30_count == 0u) {
                bit30_first_mtime = now;
            }
            bit30_last_mtime = now;
            bit30_count++;
        }
        if (gpio_status & BIT31_MASK) {
            if (bit31_count == 0u) {
                bit31_first_mtime = now;
            }
            bit31_last_mtime = now;
            bit31_count++;
        }

        /* W1C — 清 IRQ_STATUS */
        mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), gpio_status);

        /* 达到阈值后关 IRQ_EN 阻止后续中断 */
        if (!test_complete && bit30_count >= MIN_30_COUNT && bit31_count >= MIN_31_COUNT) {
            test_complete = 1u;
            mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);
        }

        return mepc;
    }

    /* 非 MEIP 的中断/异常 → 挂起 */
    for (;;) {
    }
}

int main(void)
{
    unsigned int timeout;
    unsigned int avg30 = 0u, avg31 = 0u, ratio = 0u;

    /* ----------------------------------------------------------------
     * 关中断 + 初始化外设
     * ---------------------------------------------------------------- */

    csr_clear_mstatus(MSTATUS_MIE);
    csr_write_mie(0u);

    /* 初始化 UART TX — 用于输出测量报告 */
    uart_enable_tx(UART0_BASE);

    /* 清 GPIO 中断配置 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_RISE_EN_OFFSET), 0u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_FALL_EN_OFFSET), 0u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 0xFFFFFFFFu);

    /* 初始化 TIMER0 — MTIME 作为 free-running cycle counter */
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIME_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIMECMP_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), TIMER32_CTRL_ENABLE);

    /* 等几拍让 GPIO sync / TB 翻转稳下来 */
    for (volatile int i = 0; i < 100; i++) {
    }

    /* ----------------------------------------------------------------
     * 配置 bit[31:30] 双边沿触发
     * ---------------------------------------------------------------- */

    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_RISE_EN_OFFSET), BIT30_MASK | BIT31_MASK);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_FALL_EN_OFFSET), BIT30_MASK | BIT31_MASK);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), BIT30_MASK | BIT31_MASK);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), BIT30_MASK | BIT31_MASK);

    /* 开 MEIE + MIE */
    csr_write_mie(MIE_MEIE);
    csr_set_mstatus(MSTATUS_MIE);

    /* ----------------------------------------------------------------
     * 等待 handler 收集数据达到阈值
     * ---------------------------------------------------------------- */

    timeout = 100000u;
    while (!test_complete && timeout > 0u) {
        timeout--;
    }

    /* 关中断 */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_clear_mie(MIE_MEIE);

    /* ----------------------------------------------------------------
     * 计算平均间隔
     * ---------------------------------------------------------------- */

    if (bit30_count > 1u) {
        avg30 = div_u32(bit30_last_mtime - bit30_first_mtime, bit30_count - 1u);
    }
    if (bit31_count > 1u) {
        avg31 = div_u32(bit31_last_mtime - bit31_first_mtime, bit31_count - 1u);
    }
    if (avg30 > 0u) {
        ratio = div_u32(avg31, avg30);
    }

    /* ----------------------------------------------------------------
     * UART 输出测量报告
     * ---------------------------------------------------------------- */

    uart_print_str("\n--- GPIO PERIODIC IRQ ---\n");
    uart_print_str("B30 CNT=");
    uart_print_dec32(bit30_count);
    uart_print_str(" AVG=");
    uart_print_dec32(avg30);
    uart_print_str("\n");

    uart_print_str("B31 CNT=");
    uart_print_dec32(bit31_count);
    uart_print_str(" AVG=");
    uart_print_dec32(avg31);
    uart_print_str("\n");

    uart_print_str("RATIO(B31/B30)=");
    uart_print_dec32(ratio);
    uart_print_str(" (expect 10)\n");

    /* ----------------------------------------------------------------
     * 验证
     * ---------------------------------------------------------------- */
    // 该准确度要求仅适用于固定响应模型 0 wait-state，若未通过 tb mailbox 配置可能导致仿真 FAILED
    if (bit30_count < MIN_30_COUNT) {
        uart_print_str("FAIL: bit30 count too low\n");
        return 1;
    }
    if (bit31_count < MIN_31_COUNT) {
        uart_print_str("FAIL: bit31 count too low\n");
        return 2;
    }
    if (avg30 < 180u || avg30 > 220u) {
        uart_print_str("FAIL: bit30 avg interval out of range\n");
        return 3;
    }
    if (avg31 < 1800u || avg31 > 2200u) {
        uart_print_str("FAIL: bit31 avg interval out of range\n");
        return 4;
    }

    uart_print_str("PASS\n");
    return 0u;
}
