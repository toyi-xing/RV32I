/*
 * 0856_wait_mixed_random_smoke.c — AXI-Lite DMEM 与 APB MMIO 混合访问 smoke
 *
 * 目的：
 *   - 交替执行 DMEM 运算、GPIO 中断模拟、UART RX 和 TIMER0 操作。
 *   - 验证 AXI-Lite router 能在外部 DMEM 与内部 APB 外设路径之间正确切换，
 *     且外设副作用不重复、PASS/FAIL 自检机制正常工作。
 *
 * 注意：
 *   本测试不检查固定周期统计。各外设操作只验证语义正确性（值匹配、
 *   中断标志位、读清行为等），不依赖精确周期计数。
 *
 * 测试步骤：
 *   1. DMEM: buf 数组的 store/load/运算/异或。
 *   2. GPIO0: 写 OUT，读回确认；模拟 GPIO 中断并检查 STATUS。
 *   3. UART0: 注入 RX 字节后读 STATUS/RXDATA。
 *   4. TIMER0: 配置 MTIMECMP，等待 MTIP 后关 timer。
 *
 * 通过条件：
 *   所有检查通过后 errors == 0，return 0。
 *   若 errors != 0，按 bit 位定位具体哪一项检查失败。
 *
 * 错误码：
 *   bit[0]: DMEM buf[2] = buf[0] + buf[1] 不匹配
 *   bit[1]: DMEM buf[3] = buf[2] ^ mask 不匹配
 *   bit[2]: GPIO OUT 回读不匹配
 *   bit[3]: GPIO IRQ_STATUS 未置位
 *   bit[4]: UART RX_VALID 未置位
 *   bit[5]: UART RXDATA 值不匹配
 *   bit[6]: TIMER0 MTIP 未置位
 */

#include "platform.h"
#include "tb_rv32i_soc_test.h"

static volatile uint32_t buf[4];

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
     * DMEM 运算：AXI-Lite 路径上的 store/load/加减/异或
     * ================================================================== */
    buf[0] = 0x11112222u;
    buf[1] = 0x33334444u;
    buf[2] = buf[0] + buf[1];
    if (buf[2] != 0x44446666u) {
        errors |= (1u << 0);
    }
    buf[3] = buf[2] ^ 0x00ff00ffu;
    if (buf[3] != 0x44bb6699u) {
        errors |= (1u << 1);
    }

    /* ==================================================================
     * GPIO0 基本读写 + 中断 STATUS
     * ================================================================== */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), 0x00aa5500u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET));
    if (val != 0x00aa5500u) {
        errors |= (1u << 2);
    }
    tb_gpio0_clear_mask(2u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 2u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_RISE_EN_OFFSET), 2u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 2u);
    tb_gpio0_set_mask(2u);
    wait_cycles(30u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 2u) == 0u) {
        errors |= (1u << 3);
    }
    tb_gpio0_clear_mask(2u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 2u);

    /* ==================================================================
     * UART0 RX
     * ================================================================== */
    tb_uart0_rx((uint8_t)'Z');
    wait_cycles(20u);
    val = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((val & UART_STATUS_RX_VALID) == 0u) {
        errors |= (1u << 4);
    }
    val = mmio_read32(uart_reg(UART0_BASE, UART_RXDATA_OFFSET));
    if (val != (uint32_t)'Z') {
        errors |= (1u << 5);
    }

    /* ==================================================================
     * TIMER0 基本定时
     * ================================================================== */
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIMECMP_OFFSET), 6u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIME_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), TIMER32_CTRL_ENABLE);
    wait_cycles(50u);
    val = mmio_read32(timer32_reg(TIMER0_BASE, TIMER32_STATUS_OFFSET));
    if ((val & TIMER32_STATUS_MTIP) == 0u) {
        errors |= (1u << 6);
    }
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);

    if (errors != 0u) {
        mmio_write32(DMEM_BASE + TEST_ERROR_CODE_OFFSET, errors);
        return 1;
    }
    return 0;
}
