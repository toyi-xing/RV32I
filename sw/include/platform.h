#ifndef RV32I_PLATFORM_H
#define RV32I_PLATFORM_H

/*
 * .S 汇编测试由 gcc 先预处理再汇编；gcc 在该模式下会自动定义
 * __ASSEMBLER__。借此让同一个头文件同时服务 C 和汇编：汇编只看到常量，
 * C 额外看到 stdint.h 和 inline helper。
 */
#ifdef __ASSEMBLER__
#define RV32I_U32_C(value) value
#else
        #include <stdint.h>
        #define RV32I_U32_C(value) UINT32_C(value)
    #endif

    #define IMEM_BASE       RV32I_U32_C(0x00000000)  /* 指令存储器基地址。 */
    #define IMEM_SIZE_BYTES RV32I_U32_C(0x00040000)  /* 指令存储器大小（256 KB）。 */
    #define DMEM_BASE       RV32I_U32_C(0x00040000)  /* 数据存储器基地址。 */
    #define DMEM_SIZE_BYTES RV32I_U32_C(0x00040000)  /* 数据存储器大小（256 KB）。 */
    #define MMIO_BASE       RV32I_U32_C(0x00080000)  /* MMIO 外设区域基地址。 */
    #define MMIO_SIZE_BYTES RV32I_U32_C(0x00010000)  /* MMIO 区域大小（64 KB）。 */

    #define TEST_STATUS_OFFSET      RV32I_U32_C(0x100)  /* 测试状态字在 DMEM 中的偏移。 */
    #define TEST_STATUS_ADDR        (DMEM_BASE + TEST_STATUS_OFFSET)  /* 测试状态字绝对地址（crt0.S 写入）。 */
    #define TEST_PASS_VALUE         RV32I_U32_C(0x00000001)  /* crt0.S 写此值表示 PASS。 */
    #define TEST_FAIL_VALUE         RV32I_U32_C(0x00000002)  /* crt0.S 写此值表示 FAIL。 */

    /* DMEM 低地址保留区内的定向测试临时数据偏移。 */
    #define TEST_ERROR_CODE_OFFSET   RV32I_U32_C(0x104)  /* 错误码。 */
    #define TEST_SCORE_OFFSET        RV32I_U32_C(0x108)  /* 测试分数。 */
    #define TEST_EXPECT_CAUSE_OFFSET RV32I_U32_C(0x10c)  /* 预期 mcause。 */
    #define TEST_EXPECT_MEPC_OFFSET  RV32I_U32_C(0x110)  /* 预期 mepc。 */
    #define TEST_EXPECT_TVAL_OFFSET  RV32I_U32_C(0x114)  /* 预期 mtval。 */
    #define TEST_RESUME_PC_OFFSET    RV32I_U32_C(0x118)  /* 中断/异常恢复 PC。 */
    #define TEST_TRAP_SEEN_OFFSET    RV32I_U32_C(0x11c)  /* trap 发生标志。 */
    #define TEST_WRONG_PATH_OFFSET   RV32I_U32_C(0x120)  /* 错误路径标志。 */
    #define TEST_STEP_ID_OFFSET      RV32I_U32_C(0x124)  /* 步骤 ID。 */

    /* 当前 SoC 定向测试用此保留 MMIO 地址作 unmapped 访问目标。 */
    #define TEST_UNMAPPED_MMIO_BASE  (MMIO_BASE + RV32I_U32_C(0x00003000))

    #define GPIO0_BASE              RV32I_U32_C(0x00080000)  /* GPIO0 基地址。 */
    #define GPIO_OUT_OFFSET         RV32I_U32_C(0x000)  /* 输出寄存器偏移。 */
    #define GPIO_IN_OFFSET          RV32I_U32_C(0x004)  /* 输入寄存器偏移（只读）。 */
    #define GPIO_OE_OFFSET          RV32I_U32_C(0x008)  /* 输出使能寄存器偏移。 */
    #define GPIO_IRQ_EN_OFFSET      RV32I_U32_C(0x00c)  /* 中断使能寄存器偏移。 */
    #define GPIO_IRQ_RISE_EN_OFFSET RV32I_U32_C(0x010)  /* 上升沿中断使能偏移。 */
    #define GPIO_IRQ_FALL_EN_OFFSET RV32I_U32_C(0x014)  /* 下降沿中断使能偏移。 */
    #define GPIO_IRQ_HIGH_EN_OFFSET RV32I_U32_C(0x018)  /* 高电平中断使能偏移。 */
    #define GPIO_IRQ_LOW_EN_OFFSET  RV32I_U32_C(0x01c)  /* 低电平中断使能偏移。 */
    #define GPIO_IRQ_PENDING_OFFSET RV32I_U32_C(0x020)  /* 中断待处理寄存器偏移（W1C）。 */
    #define GPIO_IRQ_STATUS_OFFSET  RV32I_U32_C(0x024)  /* 中断状态寄存器偏移（只读）。 */
    #define GPIO_BIT(bit)           (RV32I_U32_C(1) << (bit))  /* GPIO bit mask 辅助宏。 */
    #define GPIO_IRQ_BIT(bit)       GPIO_BIT(bit)  /* GPIO 中断 bit mask 辅助宏。 */

    #define TIMER0_BASE                 RV32I_U32_C(0x00081000)  /* TIMER0 基地址。 */
    #define TIMER32_MTIME_OFFSET        RV32I_U32_C(0x000)  /* MTIME 计数器偏移。 */
    #define TIMER32_MTIMECMP_OFFSET     RV32I_U32_C(0x004)  /* MTIMECMP 比较值偏移。 */
    #define TIMER32_CTRL_OFFSET         RV32I_U32_C(0x008)  /* 控制寄存器偏移。 */
    #define TIMER32_STATUS_OFFSET       RV32I_U32_C(0x00c)  /* 状态寄存器偏移。 */
    #define TIMER32_CTRL_ENABLE         RV32I_U32_C(0x00000001)  /* CTRL.enable 位掩码。 */
    #define TIMER32_STATUS_MTIP         RV32I_U32_C(0x00000001)  /* STATUS.mtip 位掩码。 */

    #define UART0_BASE                  RV32I_U32_C(0x00082000)  /* UART0 基地址。 */
    #define UART_TXDATA_OFFSET          RV32I_U32_C(0x000)  /* TX 数据寄存器偏移（WO）。 */
    #define UART_STATUS_OFFSET          RV32I_U32_C(0x004)  /* 状态寄存器偏移（RO）。 */
    #define UART_CTRL_OFFSET            RV32I_U32_C(0x008)  /* 控制寄存器偏移。 */
    #define UART_RXDATA_OFFSET          RV32I_U32_C(0x00c)  /* RX 数据寄存器偏移（读清）。 */
    #define UART_IRQ_PENDING_OFFSET     RV32I_U32_C(0x010)  /* 中断待处理寄存器偏移（W1C）。 */

    #define UART_CTRL_TX_ENABLE         RV32I_U32_C(0x00000001)  /* CTRL.tx_enable。 */
    #define UART_CTRL_RX_IRQ_ENABLE     RV32I_U32_C(0x00000002)  /* CTRL.rx_irq_enable。 */
    #define UART_STATUS_TX_READY        RV32I_U32_C(0x00000001)  /* STATUS.tx_ready。 */
    #define UART_STATUS_RX_VALID        RV32I_U32_C(0x00000002)  /* STATUS.rx_valid。 */
    #define UART_STATUS_IRQ_PENDING     RV32I_U32_C(0x00000004)  /* STATUS.irq_pending。 */
    #define UART_IRQ_PENDING_RX         RV32I_U32_C(0x00000001)  /* IRQ_PENDING.rx 位。 */

    #define UART_CTRL_ENABLE            UART_CTRL_TX_ENABLE  /* 使能 UART TX（旧名称兼容）。 */
    #define UART_STATUS_READY           UART_STATUS_TX_READY  /* UART TX 就绪标志（旧名称兼容）。 */

    #define MSTATUS_MIE                 RV32I_U32_C(0x00000008)  /* MSTATUS.MIE（全局中断使能）。 */
    #define MSTATUS_MPIE                RV32I_U32_C(0x00000080)  /* MSTATUS.MPIE（trap 前全局中断使能备份）。 */
    #define MIE_MTIE                    RV32I_U32_C(0x00000080)  /* MIE.MTIE（定时器中断使能）。 */
    #define MIE_MEIE                    RV32I_U32_C(0x00000800)  /* MIE.MEIE（外部中断使能）。 */
    /* 本教学平台不实现 MIE_MSIE（软件中断）。 */
    #define MIP_MTIP                    RV32I_U32_C(0x00000080)  /* MIP.MTIP（定时器中断待处理）。 */
    #define MIP_MEIP                    RV32I_U32_C(0x00000800)  /* MIP.MEIP（外部中断待处理）。 */
    /* 本教学平台不实现 MIP_MSIP（软件中断）。 */
    #define MCAUSE_INTERRUPT_BIT        RV32I_U32_C(0x80000000)  /* mcause[31]：1 = 中断，0 = 异常。 */
    #define MCAUSE_CODE_MASK            RV32I_U32_C(0x0000001f)  /* mcause 低 5 bit cause code 掩码。 */

    #define EXCEPTION_CAUSE_INST_ADDR_MISALIGNED   RV32I_U32_C(0)   /* 指令地址未对齐。 */
    #define EXCEPTION_CAUSE_ILLEGAL_INSTR          RV32I_U32_C(2)   /* 非法指令。 */
    #define EXCEPTION_CAUSE_BREAKPOINT             RV32I_U32_C(3)   /* 断点（ebreak）。 */
    #define EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED   RV32I_U32_C(4)   /* Load 地址未对齐。 */
    #define EXCEPTION_CAUSE_LOAD_ACCESS_FAULT      RV32I_U32_C(5)   /* Load access fault。 */
    #define EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED  RV32I_U32_C(6)   /* Store 地址未对齐。 */
    #define EXCEPTION_CAUSE_STORE_ACCESS_FAULT     RV32I_U32_C(7)   /* Store access fault。 */
    #define EXCEPTION_CAUSE_ECALL_M                RV32I_U32_C(11)  /* ECALL from M-mode。 */

    #define CSR_ADDR_MSCRATCH           RV32I_U32_C(0x340)  /* mscratch CSR 地址。 */

    #ifndef __ASSEMBLER__

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
        static inline void uart_enable_tx(uint32_t base)
        {
            mmio_write32(uart_reg(base, UART_CTRL_OFFSET), UART_CTRL_ENABLE);
        }

        // 使能 UART RX 中断（读 CTRL → 置 rx_irq_enable → 写回）。不影响 tx_enable。
        static inline void uart_enable_rx_irq(uint32_t base)
        {
            uint32_t ctrl = mmio_read32(uart_reg(base, UART_CTRL_OFFSET));
            mmio_write32(uart_reg(base, UART_CTRL_OFFSET), ctrl | UART_CTRL_RX_IRQ_ENABLE);
        }

        // 忙等待 UART TX ready 后发送一个字符。
        static inline void uart_putc(uint32_t base, char ch)
        {
            while ((mmio_read32(uart_reg(base, UART_STATUS_OFFSET)) & UART_STATUS_READY) == RV32I_U32_C(0)) {
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

        // 读 mip（查看中断待处理状态）。
        static inline uint32_t csr_read_mip(void)
        {
            uint32_t v;
            __asm__ volatile ("csrr %0, mip" : "=r"(v));
            return v;
        }

        // 读 mtval（查看异常附加信息，如 fault 地址或指令编码）。
        static inline uint32_t csr_read_mtval(void)
        {
            uint32_t v;
            __asm__ volatile ("csrr %0, mtval" : "=r"(v));
            return v;
        }

        // 写 mie（使能或禁用特定中断源，建议先读后改）。
        static inline void csr_write_mie(uint32_t value)
        {
            __asm__ volatile ("csrw mie, %0" :: "r"(value));
        }

        // 置位 mie 中指定位（开特定中断源，不影响其他位）。
        static inline void csr_set_mie(uint32_t mask)
        {
            __asm__ volatile ("csrs mie, %0" :: "r"(mask));
        }

        // 清除 mie 中指定位（关特定中断源，不影响其他位）。
        static inline void csr_clear_mie(uint32_t mask)
        {
            __asm__ volatile ("csrc mie, %0" :: "r"(mask));
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

    #endif  // __ASSEMBLER__

#endif
