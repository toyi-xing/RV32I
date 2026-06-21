#ifndef RV32I_PLATFORM_H
#define RV32I_PLATFORM_H

#include <stdint.h>

#define IMEM_BASE       0x00000000u
#define IMEM_SIZE_BYTES 0x00040000u
#define DMEM_BASE       0x00040000u
#define DMEM_SIZE_BYTES 0x00040000u
#define MMIO_BASE       0x00080000u
#define MMIO_SIZE_BYTES 0x00010000u

#define GPIO0_BASE      0x00080000u
#define GPIO_OUT_OFFSET 0x000u
#define GPIO_IN_OFFSET  0x004u
#define GPIO_OE_OFFSET  0x008u

#define UART0_BASE        0x00082000u
#define UART_TXDATA_OFFSET 0x000u
#define UART_STATUS_OFFSET 0x004u
#define UART_CTRL_OFFSET   0x008u

#define UART_CTRL_ENABLE  0x00000001u
#define UART_STATUS_READY 0x00000001u

static inline volatile uint32_t *mmio_ptr(uint32_t addr)
{
    return (volatile uint32_t *)addr;
}

static inline uint32_t mmio_read32(uint32_t addr)
{
    return *mmio_ptr(addr);
}

static inline void mmio_write32(uint32_t addr, uint32_t value)
{
    *mmio_ptr(addr) = value;
}

static inline uint32_t gpio_reg(uint32_t base, uint32_t offset)
{
    return base + offset;
}

static inline uint32_t uart_reg(uint32_t base, uint32_t offset)
{
    return base + offset;
}

static inline void uart_enable(uint32_t base)
{
    mmio_write32(uart_reg(base, UART_CTRL_OFFSET), UART_CTRL_ENABLE);
}

static inline void uart_putc(uint32_t base, char ch)
{
    while ((mmio_read32(uart_reg(base, UART_STATUS_OFFSET)) & UART_STATUS_READY) == 0u) {
    }
    mmio_write32(uart_reg(base, UART_TXDATA_OFFSET), (uint32_t)(uint8_t)ch);
}

#endif
