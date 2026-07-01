/*
 * 0651_soc_mmio_smoke.c - SoC MMIO C smoke test.
 *
 * 目的：
 *   - 通过 platform.h 封装函数访问 GPIO/UART MMIO 寄存器。
 *   - 验证 GPIO OUT/OE 写后读正确性。
 *   - 验证 GPIO IN[29:0] 读回 testbench 默认固定驱动值 30'hA5A55A5A。
 *   - 验证 UART CTRL/STATUS 寄存器和 TX 数据通路。
 *
 * 关于 MMIO 访问方式：
 *   platform.h 提供 mmio_read32/mmio_write32，通过 volatile 指针
 *   直接访存。GPIO/UART 寄存器地址由 gpio_reg/uart_reg 计算，等价于
 *   手工构造 base + offset。所有操作在 C 中直接完成，无需内联汇编。
 *
 * 通过条件：
 *   - GPIO OUT 写 0x12345678 后读回匹配。
 *   - GPIO OE 写 0x0000ffff 后读回匹配。
 *   - GPIO IN[29:0] 读回 30'hA5A55A5A（即 0x25A55A5A）。
 *   - UART CTRL.enable 后 STATUS.ready 为 1。
 *   - uart_putc 发送 "SOC\n" 无异常。
 *
 * 失败返回码：
 *   1: GPIO OUT 读回值与写入值不匹配
 *   2: GPIO OE 读回值与写入值不匹配
 *   3: GPIO IN[29:0] 读回值不是 30'hA5A55A5A
 *   4: UART 使能后 STATUS.ready 仍为 0
 */

#include "platform.h"

int main(void)
{
    uint32_t value;

    // ---- GPIO OUT 写后读 ----
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), 0x12345678u);
    value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET));
    if (value != 0x12345678u) {     // OUT 寄存器应返回写入值
        return 1;
    }

    // ---- GPIO OE 写后读 ----
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET), 0x0000ffffu);
    value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET));
    if (value != 0x0000ffffu) {     // OE 寄存器应返回写入值
        return 2;
    }

    // ---- GPIO IN 只读验证 ----
    // IN[29:0] 由 testbench 默认驱动为 30'hA5A55A5A，bit[31:30] 为周期信号。
    value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IN_OFFSET));
    if ((value & 0x3fffffffu) != (0xa5a55a5au & 0x3fffffffu)) {
        return 3;
    }

    // ---- UART 使能与状态检查 ----
    uart_enable_tx(UART0_BASE);                             // 写 CTRL.enable = 1
    value = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((value & UART_STATUS_READY) == 0u) {             // 使能后 READY 应为 1
        return 4;
    }

    // ---- UART TX 发送 ----
    uart_putc(UART0_BASE, 'S');                         // uart_putc 内含忙等
    uart_putc(UART0_BASE, 'O');                         // 循环检查 STATUS.ready
    uart_putc(UART0_BASE, 'C');                         // 然后写 TXDATA 发送字符
    uart_putc(UART0_BASE, '\n');                        // SoC TB 会打印 UART TX event

    return 0;   // 全部通过 → crt0.S 写 PASS
}
