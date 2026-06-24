/*
 * 0652_soc_mmio_gpio_uart.c - SoC MMIO 外设综合测试（GPIO + UART）
 *
 * 目的：
 *   - GPIO 寄存器 bit 级独立验证（OUT/OE 互不影响，IN 只读）。
 *   - UART 多字符串发送，验证 TX 数据通路稳定性。
 *   - GPIO 与 UART 的组合使用场景。
 *
 * 关于 MMIO 访问方式：
 *   platform.h 提供 mmio_read32/mmio_write32，通过 volatile 指针
 *   直接访存。GPIO/UART 寄存器地址由 gpio_reg/uart_reg 计算。
 *
 * 通过条件：
 *   - Stage1: OUT 写 0xAAAAAAAA 和 0x55555555 后读回均匹配。
 *   - Stage2: OE 写 0x0000FFFF 和 0xFFFF0000 后读回均匹配。
 *   - Stage3: OUT=0xAAAAAAAA 时写 OE=0x0000FFFF，读 OUT 仍为 0xAAAAAAAA。
 *   - Stage4: OE=0x0000FFFF 时写 OUT=0x55555555，读 OE 仍为 0x0000FFFF。
 *   - Stage5: 写 IN 偏移地址后读回仍为 TB 固定值 0xA5A55A5A。
 *   - Stage6: UART TX"0652: GPIO OUT/OE OK\n"等 3 个字符串无异常。
 *
 * 失败返回码：
 *   1: Stage1 OUT 位翻转测试失败
 *   2: Stage2 OE 位翻转测试失败
 *   3: Stage3 OUT 受 OE 写入影响（不独立）
 *   4: Stage4 OE 受 OUT 写入影响（不独立）
 *   5: Stage5 IN 被写入值改变（不是只读）
 *   6: Stage6 UART 发送序列异常
 */

#include "platform.h"

/* 测试中使用的 GPIO 数据常量 */
#define GPIO_PATTERN_A   0xAAAAAAAAu
#define GPIO_PATTERN_5   0x55555555u
#define GPIO_OE_LOW      0x0000FFFFu
#define GPIO_OE_HIGH     0xFFFF0000u

/* MMIO 未映射地址 —— GPIO 和 UART 之间的预留空间，访问会触发 access fault。
 * 0611_mmio_access_fault.S 在汇编侧做了完整测试，这里只用来演示 C 侧
 * MMIO 访问可能触发异常（但不捕获，仅供阅读参考）。 */
// #define UNMAPPED_MMIO    0x00081000u

/*
 * uart_puts — 通过 uart_putc 发送字符串
 * 需要 UART 已经 enable。
 */
static void uart_puts(uint32_t uart_base, const char *str)
{
    while (*str != '\0') {
        uart_putc(uart_base, *str);
        str++;
    }
}

/*
 * gpio_write_out — 写 GPIO OUT 并读回验证
 * 返回 0 表示匹配，非 0 表示 expected 值。
 */
static uint32_t gpio_write_out(uint32_t gpio_base, uint32_t value)
{
    mmio_write32(gpio_reg(gpio_base, GPIO_OUT_OFFSET), value);
    return mmio_read32(gpio_reg(gpio_base, GPIO_OUT_OFFSET)) != value;
}

/*
 * gpio_write_oe — 写 GPIO OE 并读回验证
 * 返回 0 表示匹配，非 0 表示失败。
 */
static uint32_t gpio_write_oe(uint32_t gpio_base, uint32_t value)
{
    mmio_write32(gpio_reg(gpio_base, GPIO_OE_OFFSET), value);
    return mmio_read32(gpio_reg(gpio_base, GPIO_OE_OFFSET)) != value;
}

int main(void)
{
    uint32_t value;

    /* ---- Stage1: GPIO OUT 位翻转测试 ---- */
    /* 写全 0xA pattern → 读回应一致 */
    if (gpio_write_out(GPIO0_BASE, GPIO_PATTERN_A) != 0u) {
        return 1;
    }
    /* 写全 0x5 pattern → 读回应一致（覆盖全部 bit） */
    if (gpio_write_out(GPIO0_BASE, GPIO_PATTERN_5) != 0u) {
        return 1;
    }

    /* ---- Stage2: GPIO OE 位翻转测试 ---- */
    if (gpio_write_oe(GPIO0_BASE, GPIO_OE_LOW) != 0u) {
        return 2;
    }
    if (gpio_write_oe(GPIO0_BASE, GPIO_OE_HIGH) != 0u) {
        return 2;
    }

    /* ---- Stage3: OUT 不受 OE 写入影响 ---- */
    /* 设置 OUT=A，再写 OE=LOW，读 OUT 仍应为 A */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), GPIO_PATTERN_A);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET),  GPIO_OE_LOW);
    value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET));
    if (value != GPIO_PATTERN_A) {
        return 3;
    }

    /* ---- Stage4: OE 不受 OUT 写入影响 ---- */
    /* OE=LOW 在前一 stage 已设置；写 OUT=5，读 OE 仍应为 LOW */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_OUT_OFFSET), GPIO_PATTERN_5);
    value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_OE_OFFSET));
    if (value != GPIO_OE_LOW) {
        return 4;
    }

    /* ---- Stage5: IN 只读验证 ---- */
    /* 写 IN 偏移地址应是空操作或 access fault；无论如何读回不应为写入值 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IN_OFFSET), 0xDEADBEEFu);
    value = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IN_OFFSET));
    if (value != 0xA5A55A5Au) {
        return 5;
    }

    /* ---- Stage6: UART 多字符串发送 ---- */
    uart_enable_tx(UART0_BASE);
    value = mmio_read32(uart_reg(UART0_BASE, UART_STATUS_OFFSET));
    if ((value & UART_STATUS_READY) == 0u) {
        return 6;
    }

    /* 连续发送 3 个字符串，验证 TX 通路稳定 */
    uart_puts(UART0_BASE, "0652: GPIO OUT/OE OK\n");
    uart_puts(UART0_BASE, "0652: GPIO IN readonly OK\n");
    uart_puts(UART0_BASE, "0652: ALL TESTS PASSED\n");

    return 0;   /* 全部通过 → crt0.S 写 PASS */
}
