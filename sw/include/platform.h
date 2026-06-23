#ifndef RV32I_PLATFORM_H
#define RV32I_PLATFORM_H

#include <stdint.h>

#define IMEM_BASE       0x00000000u
#define IMEM_SIZE_BYTES 0x00040000u
#define DMEM_BASE       0x00040000u
#define DMEM_SIZE_BYTES 0x00040000u
#define MMIO_BASE       0x00080000u
#define MMIO_SIZE_BYTES 0x00010000u

#define GPIO0_BASE              0x00080000u
#define GPIO_OUT_OFFSET         0x000u
#define GPIO_IN_OFFSET          0x004u
#define GPIO_OE_OFFSET          0x008u
#define GPIO_IRQ_EN_OFFSET      0x00cu
#define GPIO_IRQ_RISE_EN_OFFSET 0x010u
#define GPIO_IRQ_FALL_EN_OFFSET 0x014u
#define GPIO_IRQ_HIGH_EN_OFFSET 0x018u
#define GPIO_IRQ_LOW_EN_OFFSET  0x01cu
#define GPIO_IRQ_PENDING_OFFSET 0x020u
#define GPIO_IRQ_STATUS_OFFSET  0x024u
#define GPIO_BIT(bit)           (1u << (bit))
#define GPIO_IRQ_BIT(bit)       GPIO_BIT(bit)

#define TIMER0_BASE                 0x00081000u
#define TIMER32_MTIME_OFFSET        0x000u
#define TIMER32_MTIMECMP_OFFSET     0x004u
#define TIMER32_CTRL_OFFSET         0x008u
#define TIMER32_STATUS_OFFSET       0x00cu
#define TIMER32_CTRL_ENABLE         0x00000001u
#define TIMER32_STATUS_MTIP         0x00000001u

#define UART0_BASE                  0x00082000u
#define UART_TXDATA_OFFSET          0x000u
#define UART_STATUS_OFFSET          0x004u
#define UART_CTRL_OFFSET            0x008u
#define UART_RXDATA_OFFSET          0x00cu
#define UART_IRQ_PENDING_OFFSET     0x010u

#define UART_CTRL_TX_ENABLE         0x00000001u
#define UART_CTRL_RX_IRQ_ENABLE     0x00000002u
#define UART_STATUS_TX_READY        0x00000001u
#define UART_STATUS_RX_VALID        0x00000002u
#define UART_STATUS_IRQ_PENDING     0x00000004u
#define UART_IRQ_PENDING_RX         0x00000001u

#define UART_CTRL_ENABLE            UART_CTRL_TX_ENABLE
#define UART_STATUS_READY           UART_STATUS_TX_READY

#define MSTATUS_MIE                 0x00000008u
#define MIE_MTIE                    0x00000080u
#define MIE_MEIE                    0x00000800u
/* MIE_MSIE is intentionally not implemented in this teaching platform. */
#define MIP_MTIP                    0x00000080u
#define MIP_MEIP                    0x00000800u
/* MIP_MSIP is intentionally not implemented in this teaching platform. */
#define MCAUSE_INTERRUPT_BIT        0x80000000u
#define MCAUSE_CODE_MASK            0x0000001fu

// 将 MMIO 地址转换为 volatile 指针，供 read/write 使用。
static inline volatile uint32_t *mmio_ptr(uint32_t addr)
{
    return (volatile uint32_t *)addr;
}

// 读 32-bit MMIO 寄存器。
static inline uint32_t mmio_read32(uint32_t addr)
{
    return *mmio_ptr(addr);
}

// 写 32-bit MMIO 寄存器。
static inline void mmio_write32(uint32_t addr, uint32_t value)
{
    *mmio_ptr(addr) = value;
}

// GPIO 寄存器 byte address = base + offset。
static inline uint32_t gpio_reg(uint32_t base, uint32_t offset)
{
    return base + offset;
}

// UART 寄存器 byte address = base + offset。
static inline uint32_t uart_reg(uint32_t base, uint32_t offset)
{
    return base + offset;
}

// TIMER32 寄存器 byte address = base + offset。
static inline uint32_t timer32_reg(uint32_t base, uint32_t offset)
{
    return base + offset;
}

// 使能 UART TX（写 CTRL.tx_enable = 1）。
static inline void uart_enable(uint32_t base)
{
    mmio_write32(uart_reg(base, UART_CTRL_OFFSET), UART_CTRL_ENABLE);
}

// 使能 UART TX 和 RX 中断（写 CTRL.tx_enable=1, rx_irq_enable=1）。
static inline void uart_enable_rx_irq(uint32_t base)
{
    mmio_write32(uart_reg(base, UART_CTRL_OFFSET), UART_CTRL_TX_ENABLE | UART_CTRL_RX_IRQ_ENABLE);
}

// 忙等待 UART TX ready 后发送一个字符。
static inline void uart_putc(uint32_t base, char ch)
{
    while ((mmio_read32(uart_reg(base, UART_STATUS_OFFSET)) & UART_STATUS_READY) == 0u) {
    }
    mmio_write32(uart_reg(base, UART_TXDATA_OFFSET), (uint32_t)(uint8_t)ch);
}

//--------------------------------------------------------------------------
// CSR 访问
//--------------------------------------------------------------------------
// 只封装当前阶段软件确实需要的 CSR 访问。以下原则：
//   - mtvec/mcause/mepc/mtval 复位后已由硬件和链接脚本定好，软件只读不写。除非你明确知道为什么写他们。
//   - mie 和 mstatus 是正常开关中断需求，提供读写。
//   - mscratch 是 handler 暂存专用，提供读写。

// 读 mstatus。
static inline uint32_t csr_read_mstatus(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mstatus" : "=r"(v));
    return v;
}

// 读 mie。
static inline uint32_t csr_read_mie(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mie" : "=r"(v));
    return v;
}

// 读 mscratch。
static inline uint32_t csr_read_mscratch(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mscratch" : "=r"(v));
    return v;
}

// 读 mepc（由硬件写入，软件读取以判断返回地址）。
static inline uint32_t csr_read_mepc(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mepc" : "=r"(v));
    return v;
}

// 读 mcause（由硬件写入，软件读取以区分异常/中断和 cause code）。
static inline uint32_t csr_read_mcause(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mcause" : "=r"(v));
    return v;
}

// 写 mie（使能或禁用特定中断源，建议先读后改）。
static inline void csr_write_mie(uint32_t value)
{
    __asm__ volatile ("csrw mie, %0" :: "r"(value));
}

// 写 mscratch（handler 用作暂存寄存器）。
static inline void csr_write_mscratch(uint32_t value)
{
    __asm__ volatile ("csrw mscratch, %0" :: "r"(value));
}

// 置位 mstatus 中指定的位（如 MSTATUS_MIE 开全局中断）。
static inline void csr_set_mstatus(uint32_t mask)
{
    __asm__ volatile ("csrs mstatus, %0" :: "r"(mask));
}

// 清除 mstatus 中指定的位（如 MSTATUS_MIE 关全局中断）。
static inline void csr_clear_mstatus(uint32_t mask)
{
    __asm__ volatile ("csrc mstatus, %0" :: "r"(mask));
}

#endif
