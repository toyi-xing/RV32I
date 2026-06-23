/*
 * 0751_timer_smoke.c - TIMER0 machine timer interrupt smoke test.
 *
 * 目的：
 *   - 配置 TIMER0，MTIME 计数 16 拍后触发 MTIP。
 *   - 打开 mie.MTIE 和 mstatus.MIE，验证 core 能进入 C trap handler。
 *   - handler 检查 mcause 确认是 timer interrupt 后，停定时器清 level
 *     pending，mret 回 main。
 *   - main 检测 timer_irq_seen 后 return 0 → crt0.S 写 RAM[64] → PASS。
 *
 * 关于 CSR 访问：
 *   platform.h 提供 csr_write_mie、csr_set_mstatus 等函数，通过
 *   csrw/csrs/csrc 指令操作 CSR。本文件不再定义内联汇编。
 *
 * 关于 handler 的 mcause 检查：
 *   handler 先判断 mcause[31]（interrupt bit）和低 5 bit（cause code）。
 *   仅当确认是 machine timer interrupt（code 7）时才处理；非预期的
 *   trap 进入无限循环，导致仿真 timeout → FAIL。这样能及时发现硬件
 *   产生了错误类型的 trap。
 *
 * 通过条件：
 *   - MTIME 从 0 计数到 15（共 16 拍）后 MTIP 置位，core 进入 handler。
 *   - handler 关 timer 后 MTIP 电平自动变低，不会 mret 后再次中断。
 *   - main 检测到 timer_irq_seen，return 0。
 *
 * 失败场景：
 *   - timeout：timer interrupt 未发生（mie.MTIE 或 mstatus.MIE 未正确设置、
 *     TIMER0 地址或使能有误、mtvec 未指向 trap 入口）。
 *   - 非预期 trap：handler 进入无限循环 → timeout，说明硬件产生了非 timer
 *     的异常或中断（如 MMIO access fault、unmapped interrupt 等）。
 */

#include "platform.h"

/* MTIMECMP = 16：MTIME 从 0 计到 15 共 16 拍后触发 MTIP。
 * 选择 16 的原因是：足够短到仿真快速通过，又足够长到确保 timer 配置
 * 和中断使能流程在 MTIP 到来前全部完成。 */
#define TIMER_COMPARE_VALUE     16u

/* timer_irq_seen — handler 置位、main 轮询的中断已发生标志。
 * volatile 防止编译器优化掉 while 轮询。 */
static volatile uint32_t timer_irq_seen;

/*
 * __trap_handler_c — C trap handler 强定义。
 *
 * 参数由 crt0.S 的 .text.trap 入口保存并传入：
 *   mcause — 触发 trap 的原因（中断位 + cause code）。
 *   mepc   — 被 trap 打断的指令 PC，handler 返回后从这里继续执行。
 *   mtval  — 异常附加信息（本测试不使用）。
 *
 * 返回值被 crt0.S 写入 mepc，随后执行 mret。
 * 本 handler 返回原 mepc（从 while 循环被打断处恢复）。
 *
 * 检查逻辑：
 *   1. mcause[31] = 1 → 是 interrupt，不是 exception。
 *   2. mcause[6:0] = 7 → 是 machine timer interrupt。
 *   同时满足才处理；否则进入无限循环 → timeout → FAIL。
 */
unsigned int __trap_handler_c(unsigned int mcause, unsigned int mepc, unsigned int mtval)
{
    uint32_t cause_code;

    (void)mtval;

    cause_code = mcause & MCAUSE_CODE_MASK;
    if (((mcause & MCAUSE_INTERRUPT_BIT) != 0u) &&
        (cause_code == 7u)) {

        /* 关 timer → CTRL.enable = 0 → mtip_o 变 0。
         * TIMER 是 level pending，没有单独的 pending 寄存器需要
         * acknowledge。关闭使能后比较条件不成立，中断自动清除。 */
        mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);

        /* 通知 main 中断已发生。 */
        timer_irq_seen = 1u;

        return mepc;
    }

    /* 非预期的 trap：无限循环等待 timeout。 */
    for (;;) {
    }
}

/*
 * main — 配置 TIMER0 并等待 timer interrupt。
 *
 * 步骤：
 *   1. 关全局中断并清 mie（安全初始化）。
 *   2. 停 timer，配置 MTIMECMP 和 MTIME。
 *   3. 写 mie.MTIE = 1 允许 timer 中断。
 *   4. 写 CTRL.enable = 1 启动计数。
 *   5. 开全局中断（至此 timer 中断可用）。
 *   6. 等待 handler 置 flag。
 *   7. 返回 0 → crt0.S 写 RAM[64] = 1 → PASS。
 */
int main(void)
{
    timer_irq_seen = 0u;

    /* 关全局中断。配置期间不应响应任何中断。 */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_write_mie(0u);

    /* 停 timer，清 MTIME，设置比较值。
     * 注意：写 MTIME 的同拍不自增，写入 0 后 MTIME 保持为 0。
     * 从使能 timer 那一刻起，MTIME 才开始递增。 */
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), 0u);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIMECMP_OFFSET), TIMER_COMPARE_VALUE);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_MTIME_OFFSET), 0u);

    /* 允许 timer interrupt，启动计数器。 */
    csr_write_mie(MIE_MTIE);
    mmio_write32(timer32_reg(TIMER0_BASE, TIMER32_CTRL_OFFSET), TIMER32_CTRL_ENABLE);

    /* 开全局中断。此后的任意指令边界都可能被 timer interrupt 打断。 */
    csr_set_mstatus(MSTATUS_MIE);

    /* 等待 handler 置位。timer interrupt 到来时 core 自动跳转到
     * mtvec（0x80），进入 crt0.S 的 trap entry，调用本文件的
     * __trap_handler_c，mret 回来后继续在此处轮询。 */
    while (timer_irq_seen == 0u) {
    }

    return 0u;
}
