/*==============================================================================
 * 0505_fpga_key_led_uart — KEY / LED / UART 综合演示（三中断）
 *
 * FPGA 表现：
 *   · KEY0（边沿）— 每按一次，LED0 切换闪烁档位
 *         档位：0.2s → 0.5s → 1s → 2s → 5s（循环），同时串口发 '0'
 *   · KEY1（电平）— LED1 跟随按键，按下亮、松开灭，按下时串口发 '1'
 *   · UART RX    — 收到字符后 echo 回发，并将字符值映射到 GPIO[9:2]
 *        并行输出保持到下一个 RX 才改变
 *   · 按键带 20ms 软件消抖，TIMER0 提供 1ms 时基
 *   · 使用 TIMER0、GPIO、UART 三个外设的中断
 *============================================================================*/

#include "platform.h"

/* 时钟与定时 */
#define CLK_HZ              50000000u
#define TICK_CYCLES         50000u          /* 50M ÷ 1000 = 50k → 1ms 滴答 */
#define DEBOUNCE_MS         20u

/* GPIO bit 定义 */
#define KEY0_MASK           GPIO_BIT(0)
#define KEY1_MASK           GPIO_BIT(1)
#define KEY_MASK            (KEY0_MASK | KEY1_MASK)

#define LED0_MASK           GPIO_BIT(0)
#define LED1_MASK           GPIO_BIT(1)
#define RX_PARALLEL_MASK    0x000003fcu     /* GPIO[9:2] */

#define KEY_ACTIVE_LOW      1u

/* LED0 闪烁档位（翻转间隔，单位 ms） */
static const uint32_t g_blink_periods[] = { 200, 500, 1000, 2000, 5000 };
#define BLINK_MODE_COUNT    (sizeof(g_blink_periods) / sizeof(g_blink_periods[0]))

/* 全局状态 */
static volatile uint32_t g_ms_ticks;            /* 1ms 递增的系统滴答 */
static volatile uint32_t g_blink_mode;          /* 当前闪烁档位索引 */
static volatile uint32_t g_blink_elapsed;       /* 当前档位已流逝的 ms */
static volatile uint32_t g_led0_state;          /* LED0 当前亮灭 */

static volatile uint32_t g_gpio_out_shadow;     /* GPIO_OUT 影子寄存器 */

/* 按键消抖 */
static volatile uint32_t g_key_raw;             /* 边沿中断捕获的原始值 */
static volatile uint32_t g_key_stable;          /* 消抖确认后的稳态值 */
static volatile uint32_t g_key_debounce_active; /* 消抖进行中 */
static volatile uint32_t g_key_debounce_deadline;

/*----------------------------------------------------------------------------
 * 寄存器地址辅助（节省 typing）
 *----------------------------------------------------------------------------*/
static inline uint32_t reg_gpio(uint32_t off)  { return GPIO0_BASE + off; }
static inline uint32_t reg_timer(uint32_t off) { return TIMER0_BASE + off; }
static inline uint32_t reg_uart(uint32_t off)  { return UART0_BASE + off; }

/*----------------------------------------------------------------------------
 * 提交 GPIO_OUT 影子到硬件
 *----------------------------------------------------------------------------*/
static inline void gpio_commit(void)
{
    mmio_write32(reg_gpio(GPIO_OUT_OFFSET), g_gpio_out_shadow);
}

/*----------------------------------------------------------------------------
 * 读取按键原始电平（取反后按下=1）
 *----------------------------------------------------------------------------*/
static uint32_t read_keys(void)
{
    uint32_t v = mmio_read32(reg_gpio(GPIO_IN_OFFSET));
#if KEY_ACTIVE_LOW
    v = (~v) & KEY_MASK;
#else
    v &= KEY_MASK;
#endif
    return v;
}

/*----------------------------------------------------------------------------
 * UART 发送一个字节（忙等待 TX ready）
 *----------------------------------------------------------------------------*/
static void uart_send_byte(uint32_t byte)
{
    while ((mmio_read32(reg_uart(UART_STATUS_OFFSET)) & UART_STATUS_TX_READY) == 0u) { }
    mmio_write32(reg_uart(UART_TXDATA_OFFSET), byte & 0xffu);
}

/*----------------------------------------------------------------------------
 * 消抖确认后的按键动作处理
 *----------------------------------------------------------------------------*/
static void apply_key_action(uint32_t new_stable)
{
    uint32_t changed = g_key_stable ^ new_stable;
    uint32_t pressed = changed & new_stable;        /* 0 → 1 的边沿 */

    g_key_stable = new_stable;

    /* KEY1 电平模式：LED1 直接跟随按键电平 */
    if ((new_stable & KEY1_MASK) != 0u) {
        g_gpio_out_shadow |= LED1_MASK;
    } else {
        g_gpio_out_shadow &= ~LED1_MASK;
    }

    /* KEY0 边沿模式：按下时切换闪烁档位 */
    if ((pressed & KEY0_MASK) != 0u) {
        g_blink_mode++;
        if (g_blink_mode >= BLINK_MODE_COUNT) {
            g_blink_mode = 0u;
        }
        g_blink_elapsed = 0u;
        g_led0_state = LED0_MASK;   /* 换档时强制点亮，直观反馈 */
        uart_send_byte((uint32_t)'0');
    }

    /* KEY1 按下边沿发 '1'（仅边沿，不是每 tick 都发） */
    if ((pressed & KEY1_MASK) != 0u) {
        uart_send_byte((uint32_t)'1');
    }

    gpio_commit();
}

/*----------------------------------------------------------------------------
 * UART 中断处理 — RX 数据到达
 *----------------------------------------------------------------------------*/
static void handle_uart_irq(void)
{
    uint32_t status = mmio_read32(reg_uart(UART_STATUS_OFFSET));

    if ((status & UART_STATUS_IRQ_PENDING) != 0u) {
        uint32_t rx = mmio_read32(reg_uart(UART_RXDATA_OFFSET)) & 0xffu;

        /* 回环发送 */
        uart_send_byte(rx);

        /* 并行输出到 GPIO[9:2]；保持到下一个 RX 才改变 */
        g_gpio_out_shadow = (g_gpio_out_shadow & ~RX_PARALLEL_MASK) | (rx << 2);
        gpio_commit();
    }
}

/*----------------------------------------------------------------------------
 * GPIO 中断处理 — 按键边沿 → 捕获电平 → 启动消抖
 *----------------------------------------------------------------------------*/
static void handle_gpio_irq(void)
{
    uint32_t pending = mmio_read32(reg_gpio(GPIO_IRQ_PENDING_OFFSET)) & KEY_MASK;

    if (pending != 0u) {
        mmio_write32(reg_gpio(GPIO_IRQ_PENDING_OFFSET), pending);   /* W1C 清除 */

        g_key_raw = read_keys();
        g_key_debounce_deadline = g_ms_ticks + DEBOUNCE_MS;
        g_key_debounce_active = 1u;
    }
}

/*----------------------------------------------------------------------------
 * TIMER0 中断处理 — 1ms 时基：消抖轮询 + LED0 闪烁
 *----------------------------------------------------------------------------*/
static void handle_timer_irq(void)
{
    /* MTIME 归零；MTIMECMP 固定为 TICK_CYCLES，无需改写 */
    mmio_write32(reg_timer(TIMER32_MTIME_OFFSET), 0u);

    g_ms_ticks++;

    /*------------------------------------------------------
     * 按键消抖轮询
     *------------------------------------------------------*/
    if (g_key_debounce_active) {
        if (g_ms_ticks >= g_key_debounce_deadline) {
            uint32_t raw = read_keys();

            if (raw == g_key_raw) {
                /* 两次采样一致 → 消抖完成 */
                g_key_debounce_active = 0u;
                apply_key_action(raw);
            } else {
                /* 不一致 → 更新候选值，重新计时 */
                g_key_raw = raw;
                g_key_debounce_deadline = g_ms_ticks + DEBOUNCE_MS;
            }
        }
    }

    /*------------------------------------------------------
     * LED0 闪烁
     *------------------------------------------------------*/
    g_blink_elapsed++;
    if (g_blink_elapsed >= g_blink_periods[g_blink_mode]) {
        g_blink_elapsed = 0u;
        g_led0_state ^= LED0_MASK;
        g_gpio_out_shadow = (g_gpio_out_shadow & ~LED0_MASK) | g_led0_state;
        gpio_commit();
    }
}

/*----------------------------------------------------------------------------
 * C 级 trap 入口（覆盖 crt0.S 弱符号）
 *----------------------------------------------------------------------------*/
uint32_t __trap_handler_c(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    uint32_t code = mcause & MCAUSE_CODE_MASK;
    (void)mtval;

    /* 异常：不处理，直接返回（测试时若触发会在 crt0 写 FAIL） */
    if ((mcause & MCAUSE_INTERRUPT_BIT) == 0u) {
        return mepc;
    }

    if (code == 7u) {           /* Machine Timer Interrupt */
        handle_timer_irq();
    } else if (code == 11u) {   /* Machine External Interrupt */
        handle_uart_irq();
        handle_gpio_irq();
    }

    return mepc;
}

/*----------------------------------------------------------------------------
 * main
 *----------------------------------------------------------------------------*/
int main(void)
{
    /*---------- GPIO 初始化 ----------*/
    g_gpio_out_shadow = 0u;
    g_key_stable = read_keys();
    if ((g_key_stable & KEY1_MASK) != 0u) {
        g_gpio_out_shadow |= LED1_MASK;
    }

    mmio_write32(reg_gpio(GPIO_OE_OFFSET),
                 LED0_MASK | LED1_MASK | RX_PARALLEL_MASK);
    gpio_commit();

    /* GPIO 中断：双边沿触发 */
    mmio_write32(reg_gpio(GPIO_IRQ_EN_OFFSET), 0u);
    mmio_write32(reg_gpio(GPIO_IRQ_RISE_EN_OFFSET), KEY_MASK);
    mmio_write32(reg_gpio(GPIO_IRQ_FALL_EN_OFFSET), KEY_MASK);
    mmio_write32(reg_gpio(GPIO_IRQ_HIGH_EN_OFFSET), 0u);
    mmio_write32(reg_gpio(GPIO_IRQ_LOW_EN_OFFSET), 0u);
    mmio_write32(reg_gpio(GPIO_IRQ_PENDING_OFFSET), 0xffffffffu);
    mmio_write32(reg_gpio(GPIO_IRQ_EN_OFFSET), KEY_MASK);

    /*---------- UART 初始化 ----------*/
    mmio_write32(reg_uart(UART_CTRL_OFFSET),
                 UART_CTRL_TX_ENABLE | UART_CTRL_RX_IRQ_ENABLE);
    (void)mmio_read32(reg_uart(UART_RXDATA_OFFSET));   /* 清残留 RX */
    mmio_write32(reg_uart(UART_IRQ_PENDING_OFFSET), UART_IRQ_PENDING_RX);

    /*---------- TIMER0 初始化（1ms 滴答） ----------*/
    mmio_write32(reg_timer(TIMER32_CTRL_OFFSET), 0u);
    mmio_write32(reg_timer(TIMER32_MTIME_OFFSET), 0u);
    mmio_write32(reg_timer(TIMER32_MTIMECMP_OFFSET), TICK_CYCLES);
    mmio_write32(reg_timer(TIMER32_CTRL_OFFSET), TIMER32_CTRL_ENABLE);

    /*---------- 开中断 ----------*/
    csr_set_mie(MIE_MTIE | MIE_MEIE);  /* 定时器 + 外部中断 */
    csr_set_mstatus(MSTATUS_MIE);      /* 全局中断使能 */

    /*---------- 主循环 ----------*/
    for (;;) {
        __asm__ volatile ("wfi");
    }
}
