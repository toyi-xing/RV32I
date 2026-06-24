/*
 * 0753_uart_rx_irq.c — UART0 RX 中断基础行为测试。
 *
 * 目的：
 *   - TB 注入 RX 字节后 RXDATA/STATUS/IRQ_PENDING 的变化。
 *   - CTRL.rx_irq_enable 对 uart_irq → MEIP 的门控。
 *   - 读 RXDATA 同时清 rx_valid 和 rx_irq_pending。
 *   - 写 IRQ_PENDING[0]=1 只清 pending，不消费 RXDATA。
 *   - UART interrupt 以 machine external interrupt 进入 core。
 *
 * 通过条件：
 *   Stage1: TB 注入 → RXDATA 保存、状态位置位。
 *   Stage2: rx_irq_enable=0 时不产生中断，=1 后中断触发。
 *   Stage3: W1C 清 pending 保留 RXDATA，读 RXDATA 清 pending。
 *
 * 失败场景：
 *   - timeout：中断未按预期发生。
 *   - 错误 mcause：handler 收到非 MEIP 的中断。
 *   - RX 清除语义错误（读 RXDATA 不清理、W1C 错误等）。
 */

#include "platform.h"
#include "tb_rv32i_soc_test.h"

/* handler 记录 */
static volatile unsigned int irq_count;
static volatile unsigned int irq_mcause;
static volatile unsigned int irq_rx_data;

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
    volatile unsigned int dummy;

    (void)mtval;

    /* 仅接受 MEIP（machine external interrupt） */
    if (((mcause & MCAUSE_INTERRUPT_BIT) != 0u) &&
        ((mcause & MCAUSE_CODE_MASK) == 11u)) {

        irq_count++;
        irq_mcause = mcause;

        /* 读 RXDATA 同时清 pending；编译器可能优化掉读取结果，
         * 用 volatile dummy 保证读操作不被删除。 */
        dummy = mmio_read32(uart_reg(UART0_BASE, UART_RXDATA_OFFSET));
        (void)dummy;
        irq_rx_data = dummy;

        return mepc;
    }

    for (;;) {
    }
}

int main(void)
{
    unsigned int val;

    /* 确保 GPIO 中断全部关闭，不影响 MEIP 判断 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);

    /* ----------------------------------------------------------------
     * Stage1: TB 注入 RX 字节，观测寄存器（无全局中断）
     * ---------------------------------------------------------------- */

    /* 1a: TB 注入字节 'U'（0x55） */
    tb_uart0_rx((uint8_t)'U');
    wait_cycles(20u);

    /* 1b: 读 STATUS — rx_valid + irq_pending 都应置位 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) == 0u) {
        return 1;
    }
    if ((val & UART_STATUS_IRQ_PENDING) == 0u) {
        return 2;
    }

    /* 1c: 读 IRQ_PENDING — bit0 应置位 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_IRQ_PENDING_OFFSET));
    if ((val & UART_IRQ_PENDING_RX) == 0u) {
        return 3;
    }

    /* 1d: 读 RXDATA — 应为 'U'，且读后自动清 rx_valid 和 pending */
    val = mmio_read32(uart_reg(UART0_BASE, UART_RXDATA_OFFSET));
    if (val != (unsigned int)'U') {
        return 4;
    }
    /* 读后 pending 和 rx_valid 都应已清除 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) != 0u) {
        return 5;
    }
    if ((val & UART_STATUS_IRQ_PENDING) != 0u) {
        return 6;
    }

    /* ----------------------------------------------------------------
     * Stage2: rx_irq_enable 门控中断
     * ---------------------------------------------------------------- */
    irq_count = 0u;

    /* 2a: TB 注入字节 'A'（此时 rx_irq_enable 应为 0） */
    tb_uart0_rx((uint8_t)'A');
    wait_cycles(20u);

    /* 确认 pending 已置位 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_IRQ_PENDING_OFFSET));
    if ((val & UART_IRQ_PENDING_RX) == 0u) {
        return 11;
    }

    /* 2b: 开全局中断和 MEIE，但 rx_irq_enable 仍为 0 */
    csr_set_mie(MIE_MEIE);
    csr_set_mstatus(MSTATUS_MIE);
    wait_cycles(100u);

    /* rx_irq_enable=0 → uart_irq=0 → MEIP=0，不应有中断 */
    if (irq_count != 0u) {
        return 12;  /* 产生了不应出现的中断 */
    }

    /* 2c: 使能 rx_irq_enable → 中断应触发 */
    uart_enable_rx_irq(UART0_BASE);
    if (wait_for_irq(1u, 5000u) != 0u) {
        return 13;  /* timeout */
    }

    /* 2d: 验证 handler 记录 */
    val = irq_mcause;
    if ((val & MCAUSE_INTERRUPT_BIT) == 0u) {
        return 14;
    }
    if ((val & MCAUSE_CODE_MASK) != 11u) {
        return 15;
    }
    if (irq_rx_data != (unsigned int)'A') {
        return 16;
    }

    /* 2e: 清理 */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_clear_mie(MIE_MEIE);

    /* ----------------------------------------------------------------
     * Stage3: W1C 清 pending vs RXDATA 读清语义差异
     * ---------------------------------------------------------------- */
    irq_count = 0u;

    /* 3a: TB 注入字节 'C' */
    tb_uart0_rx((uint8_t)'C');
    wait_cycles(20u);

    /* 3b: 确认 pending 已置位 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_IRQ_PENDING_OFFSET));
    if ((val & UART_IRQ_PENDING_RX) == 0u) {
        return 21;
    }

    /* 3c: W1C — 写 1 清 IRQ_PENDING，但不清 rx_valid */
    mmio_write32(uart_reg(UART0_BASE, UART_IRQ_PENDING_OFFSET), UART_IRQ_PENDING_RX);
    val = mmio_read32(uart_reg(UART0_BASE, UART_IRQ_PENDING_OFFSET));
    if ((val & UART_IRQ_PENDING_RX) != 0u) {
        return 22;  /* W1C 后 pending 应为 0 */
    }

    /* 3d: rx_valid 应保留（W1C 不清 rx_valid） */
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) == 0u) {
        return 23;  /* W1C 不应清除 rx_valid */
    }
    if ((val & UART_STATUS_IRQ_PENDING) != 0u) {
        return 24;  /* IRQ_PENDING 已清，STATUS.irq_pending 应为 0 */
    }

    /* 3e: 读 RXDATA 应返回 'C'（未被 W1C 消费），且读后 rx_valid 清 0 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_RXDATA_OFFSET));
    if (val != (unsigned int)'C') {
        return 25;  /* RXDATA 应保留 'C' */
    }
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) != 0u) {
        return 26;  /* 读 RXDATA 清 rx_valid */
    }

    /* ----------------------------------------------------------------
     * 全部通过
     * ---------------------------------------------------------------- */
    return 0u;
}
