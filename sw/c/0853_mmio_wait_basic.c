/*
 * 0853_mmio_wait_basic.c — APB GPIO/UART/TIMER 基本读写与副作用检查
 *
 * 目的：
 *   - 验证经 AXI-Lite 到 APB 转换后的 MMIO 读写只产生一次外设副作用
 *     （W1C 不重复清、UART TX 不重复发送、UART RXDATA 读清只发生一次、
 *     TIMER32 写寄存器语义不变）。
 *   - 验证固定 PREADY 响应下的软件可见寄存器行为。
 *
 * 测试步骤：
 *   1. GPIO0: 写 OUT/OE，读回确认；模拟 GPIO 中断 PENDING/W1C 语义。
 *   2. UART0: 使能 TX 并写 TXDATA，检查 TX_READY；注入 RX 字节后读
 *      STATUS/RXDATA 确认 RX_VALID/IRQ_PENDING 和读清行为。
 *   3. TIMER0: 配置 MTIMECMP 后等待 MTIP，关 timer 后确认 MTIP 清除。
 *
 * 通过条件：
 *   所有检查通过后 errors == 0，return 0。
 *   若 errors != 0，按 bit 位定位具体哪一项检查失败。
 *
 * 错误码：
 *   bit[0]:  GPIO OUT 回读不匹配
 *   bit[1]:  GPIO OE 回读不匹配
 *   bit[2]:  GPIO PENDING 置位后读回为 0
 *   bit[3]:  GPIO STATUS 读回为 0
 *   bit[4]:  W1C 清除后 PENDING 未清零
 *   bit[5]:  UART TX 未就绪（TX_READY=0）
 *   bit[6]:  UART RX_VALID 未置位
 *   bit[7]:  UART IRQ_PENDING 未置位
 *   bit[8]:  UART RX_VALID 在 read 之前消失
 *   bit[9]:  UART IRQ_PENDING W1C 未清除
 *   bit[10]: UART RXDATA 值不匹配
 *   bit[11]: UART RXDATA 读清后 RX_VALID 未清零
 *   bit[12]: TIMER0 MTIP 未置位
 *   bit[13]: TIMER0 关使能后 MTIP 未清除
 */

#include "platform.h"
#include "tb_rv32i_soc_test.h"

static void wait_cycles(unsigned int n)
{
    volatile unsigned int i;
    for (i = 0u; i < n; i++) {
    }
}

int main(void)
{
    uint32_t val;
    uint32_t errors = 0u;

    csr_clear_mstatus(MSTATUS_MIE);
    csr_write_mie(0u);

    /* ==================================================================
     * GPIO0 基本读写 + 中断 PENDING 与 W1C
     * ================================================================== */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), 0x13579bdfu);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET));
    if (val != 0x13579bdfu) {
        errors |= (1u << 0);
    }
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET), 0x0000ffffu);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET));
    if (val != 0x0000ffffu) {
        errors |= (1u << 1);
    }

    /* 模拟 GPIO 中断：TB 驱动输入上升沿 → PENDING 置位 */
    tb_gpio0_clear_mask(1u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 1u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_RISE_EN_OFFSET), 1u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 1u);
    tb_gpio0_set_mask(1u);
    wait_cycles(30u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET));
    if ((val & 1u) == 0u) {
        errors |= (1u << 2);
    }
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 1u) == 0u) {
        errors |= (1u << 3);
    }
    /* W1C：写 1 到 PENDING，完成 APB 写传输后确认清除 */
    tb_gpio0_clear_mask(1u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 1u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET));
    if ((val & 1u) != 0u) {
        errors |= (1u << 4);
    }

    /* ==================================================================
     * UART0 TX/RX 基本操作
     * ================================================================== */
    uart_enable_tx(UART0_BASE);
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_TX_READY) == 0u) {
        errors |= (1u << 5);
    }
    mmio_write32(uart_reg(UART0_BASE, UART_TXDATA_OFFSET), (uint32_t)'W');

    /* TB 注入 RX 字节后检查 STATUS 和读清语义 */
    tb_uart0_rx((uint8_t)'R');
    wait_cycles(20u);
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) == 0u) {
        errors |= (1u << 6);
    }
    if ((val & UART_STATUS_IRQ_PENDING) == 0u) {
        errors |= (1u << 7);
    }
    /* IRQ_PENDING W1C */
    mmio_write32(uart_reg(UART0_BASE, UART_IRQ_PENDING_OFFSET), UART_IRQ_PENDING_RX);
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) == 0u) {
        errors |= (1u << 8);
    }
    if ((val & UART_STATUS_IRQ_PENDING) != 0u) {
        errors |= (1u << 9);
    }
    /* 读 RXDATA 确认值 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_RXDATA_OFFSET));
    if (val != (uint32_t)'R') {
        errors |= (1u << 10);
    }
    /* RXDATA 读清后确认 RX_VALID 为 0 */
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) != 0u) {
        errors |= (1u << 11);
    }

    /* ==================================================================
     * TIMER0 基本读写 + MTIP 置位/清除
     * ================================================================== */
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIMECMP_OFFSET), 5u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIME_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), TIMER32_CTRL_ENABLE);
    wait_cycles(40u);
    val = mmio_read32(timer32_reg(TIMER0_BASE, TIMER32_STATUS_OFFSET));
    if ((val & TIMER32_STATUS_MTIP) == 0u) {
        errors |= (1u << 12);
    }
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);
    val = mmio_read32(timer32_reg(TIMER0_BASE, TIMER32_STATUS_OFFSET));
    if ((val & TIMER32_STATUS_MTIP) != 0u) {
        errors |= (1u << 13);
    }

    if (errors != 0u) {
        mmio_write32(DMEM_BASE + TEST_ERROR_CODE_OFFSET, errors);
        return 1;
    }
    return 0;
}
