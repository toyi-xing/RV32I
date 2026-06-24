/*
 * 0752_gpio_irq_basic.c — GPIO0 外部中断基础行为测试。
 *
 * 目的：
 *   - IRQ_EN 与 IRQ_STATUS = IRQ_PENDING & IRQ_EN 的寄存器关系。
 *   - 上升沿、下降沿、高电平、低电平四类触发条件。
 *   - IRQ_PENDING R/W1C 清除行为。
 *   - GPIO 输入两级同步后的最终 pending/handler 行为。
 *   - GPIO interrupt 以 machine external interrupt（mcause=0x8000000B）
 *     进入 core。
 *
 * 关于 TB mailbox：
 *   测试通过 tb_rv32i_soc_test.h 的 helper 驱动 GPIO0 输入，
 *   由 tb_rv32i_soc.sv 的 command mailbox 响应。
 *
 * 关于 handler：
 *   handler 记录 mcause 和 GPIO IRQ_STATUS，然后关闭 IRQ_EN 中
 *   已 pending 的位（防止电平触发模式在 mret 后立刻再次中断），
 *   最后返回 mepc 恢复执行。
 *
 * 通过条件：
 *   Stage1: IRQ_EN + IRQ_STATUS 基本关系正确。
 *   Stage2: 上升沿触发 → handler 记录 mcause=0x8000000B。
 *   Stage3: 下降沿触发 → handler 记录 mcause=0x8000000B。
 *   Stage4: 高电平触发 → handler 记录 mcause=0x8000000B。
 *   Stage5: 低电平触发 → handler 记录 mcause=0x8000000B。
 *   Stage6: IRQ_PENDING R/W1C 清除与 IRQ_STATUS 联动正确。
 *
 * 失败场景：
 *   - timeout：中断未发生（mie.MEIE 或 mstatus.MIE 未正确设置、
 *     GPIO 配置有误、TB mailbox 未响应）。
 *   - 错误 mcause：handler 收到非 MEIP 的 trap → infinite loop → timeout。
 *   - R/W1C 行为异常（写 1 不清、读后又自动置位等）。
 */

#include "platform.h"
#include "tb_rv32i_soc_test.h"

/* handler 记录的中断信息 */
static volatile unsigned int irq_count;
static volatile unsigned int irq_mcause;
static volatile unsigned int irq_gpio_status;

/*
 * __trap_handler_c — C trap handler 强定义。
 *
 * 仅接受 machine external interrupt（cause code = 11）。
 * 记录 mcause 和当前 GPIO IRQ_STATUS，关闭对应 IRQ_EN 位
 * 防止 level re-trigger，返回 mepc 恢复执行。
 * 非预期的 trap 进入无限循环 → timeout → FAIL。
 */
unsigned int __trap_handler_c(unsigned int mcause, unsigned int mepc, unsigned int mtval)
{
    unsigned int gpio_status;

    (void)mtval;

    /* 确认是 MEIP（machine external interrupt） */
    if (((mcause & MCAUSE_INTERRUPT_BIT) != 0u) &&
        ((mcause & MCAUSE_CODE_MASK) == 11u)) {

        irq_count++;
        irq_mcause = mcause;

        /* 记录 IRQ_STATUS（pending & en 组合），并关闭 pending
         * 位的 IRQ_EN 来阻止电平重触发。 */
        gpio_status = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
        irq_gpio_status = gpio_status;

        if (gpio_status != 0u) {
            mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET),
                mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET)) & ~gpio_status);
        }

        return mepc;
    }

    /* 非预期 trap：无限循环等待 timeout。 */
    for (;;) {
    }
}

/*
 * wait_cycles — 通过空循环消耗约 n 个 cycle。
 * 用于等待 TB mailbox 响应和 GPIO 同步链传播。
 * 不精确但足够可靠。
 */
static void wait_cycles(unsigned int n)
{
    volatile unsigned int i;
    for (i = 0u; i < n; i++) {
    }
}

/*
 * wait_for_irq — 等待 handler 被调用至少 expected 次。
 * 返回 0 表示成功，非 0 表示超时。
 */
static unsigned int wait_for_irq(unsigned int expected, unsigned int timeout)
{
    while (irq_count < expected && timeout > 0u) {
        timeout--;
    }
    return (irq_count >= expected) ? 0u : 1u;
}

int main(void)
{
    unsigned int val;

    /* ----------------------------------------------------------------
     * Stage1: IRQ_EN + IRQ_STATUS 基本关系（无全局中断）
     * 使用 bit 0，高电平触发
     * ---------------------------------------------------------------- */

    /* 1a: TB 驱动 bit 0 为高, 等待同步 */
    tb_gpio0_clear_mask(1u);
    wait_cycles(20u);
    tb_gpio0_set_mask(1u);
    wait_cycles(20u);

    /* 1b: 仅设 IRQ_EN，无触发使能 → STATUS 应为 0 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 1u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if (val != 0u) {
        return 1;
    }

    /* 1c: 加 IRQ_HIGH_EN → pending 置位 → STATUS = 1 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 1u);
    wait_cycles(10u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET));
    if ((val & 1u) == 0u) {
        return 2;
    }
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 1u) == 0u) {
        return 3;
    }

    /* 1d: 清除 stimulus 和触发使能，W1C pending */
    tb_gpio0_clear_mask(1u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 0u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 1u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET));
    if ((val & 1u) != 0u) {
        return 4;
    }
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 1u) != 0u) {
        return 5;
    }

    /* 1e: 清 IRQ_EN */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);

    /* ----------------------------------------------------------------
     * Stage2: 上升沿触发中断
     * 使用 bit 1
     * ---------------------------------------------------------------- */
    irq_count = 0u;

    /* 2a: 确保 bit 1 初始为低 */
    tb_gpio0_clear_mask(2u);
    wait_cycles(20u);

    /* 2b: 配置上升沿触发 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 2u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_RISE_EN_OFFSET), 2u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 2u);

    /* 2c: 开全局中断和外部中断使能 */
    csr_set_mie(MIE_MEIE);
    csr_set_mstatus(MSTATUS_MIE);

    /* 2d: 制造上升沿（bit 1 低→高） */
    tb_gpio0_set_mask(2u);
    if (wait_for_irq(1u, 5000u) != 0u) {
        return 11;  /* timeout — 中断未发生 */
    }

    /* 2e: 验证 handler 记录 */
    val = irq_mcause;
    if ((val & MCAUSE_INTERRUPT_BIT) == 0u) {
        return 12;  /* 不是 interrupt */
    }
    if ((val & MCAUSE_CODE_MASK) != 11u) {
        return 13;  /* cause code 不是 MEIP */
    }
    if ((irq_gpio_status & 2u) == 0u) {
        return 14;  /* IRQ_STATUS 应包含 bit 1 */
    }

    /* 2f: 清理 */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_clear_mie(MIE_MEIE);
    tb_gpio0_clear_mask(2u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 2u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_RISE_EN_OFFSET), 0u);

    /* ----------------------------------------------------------------
     * Stage3: 下降沿触发中断
     * 使用 bit 2
     * ---------------------------------------------------------------- */
    irq_count = 0u;

    /* 3a: 确保 bit 2 初始为高（才能产生下降沿） */
    tb_gpio0_set_mask(4u);
    wait_cycles(20u);

    /* 3b: 配置下降沿触发 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 4u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_FALL_EN_OFFSET), 4u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 4u);

    /* 3c: 开中断 */
    csr_set_mie(MIE_MEIE);
    csr_set_mstatus(MSTATUS_MIE);

    /* 3d: 制造下降沿（bit 2 高→低） */
    tb_gpio0_clear_mask(4u);
    if (wait_for_irq(1u, 5000u) != 0u) {
        return 21;
    }

    /* 3e: 验证 */
    val = irq_mcause;
    if ((val & MCAUSE_INTERRUPT_BIT) == 0u) {
        return 22;
    }
    if ((val & MCAUSE_CODE_MASK) != 11u) {
        return 23;
    }
    if ((irq_gpio_status & 4u) == 0u) {
        return 24;
    }

    /* 3f: 清理 */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_clear_mie(MIE_MEIE);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 4u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_FALL_EN_OFFSET), 0u);

    /* ----------------------------------------------------------------
     * Stage4: 高电平触发中断
     * 使用 bit 3
     * ---------------------------------------------------------------- */
    irq_count = 0u;

    /* 4a: 确保 bit 3 初始为低 */
    tb_gpio0_clear_mask(8u);
    wait_cycles(20u);

    /* 4b: 配置高电平触发 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 8u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 8u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 8u);

    /* 4c: 开中断后拉高 bit 3 — 电平触发会持续置 pending */
    csr_set_mie(MIE_MEIE);
    csr_set_mstatus(MSTATUS_MIE);
    tb_gpio0_set_mask(8u);
    if (wait_for_irq(1u, 5000u) != 0u) {
        return 31;
    }

    /* 4d: 验证 */
    val = irq_mcause;
    if ((val & MCAUSE_INTERRUPT_BIT) == 0u) {
        return 32;
    }
    if ((val & MCAUSE_CODE_MASK) != 11u) {
        return 33;
    }
    if ((irq_gpio_status & 8u) == 0u) {
        return 34;
    }

    /* 4e: 清理（handler 已关 IRQ_EN，这里移除电平源再 W1C） */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_clear_mie(MIE_MEIE);
    tb_gpio0_clear_mask(8u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 8u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 0u);

    /* ----------------------------------------------------------------
     * Stage5: 低电平触发中断
     * 使用 bit 4
     * ---------------------------------------------------------------- */
    irq_count = 0u;

    /* 5a: 确保 bit 4 为低 */
    tb_gpio0_clear_mask(16u);
    wait_cycles(20u);

    /* 5b: 配置低电平触发。bit 4 为低，满足条件。 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 16u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_LOW_EN_OFFSET), 16u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 16u);

    /* 5c: 开中断，低电平已经满足触发条件 */
    csr_set_mie(MIE_MEIE);
    csr_set_mstatus(MSTATUS_MIE);
    if (wait_for_irq(1u, 5000u) != 0u) {
        return 41;
    }

    /* 5d: 验证 */
    val = irq_mcause;
    if ((val & MCAUSE_INTERRUPT_BIT) == 0u) {
        return 42;
    }
    if ((val & MCAUSE_CODE_MASK) != 11u) {
        return 43;
    }
    if ((irq_gpio_status & 16u) == 0u) {
        return 44;
    }

    /* 5e: 清理 */
    csr_clear_mstatus(MSTATUS_MIE);
    csr_clear_mie(MIE_MEIE);
    tb_gpio0_set_mask(16u);  /* 移除低电平 */
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 16u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_LOW_EN_OFFSET), 0u);

    /* ----------------------------------------------------------------
     * Stage6: IRQ_PENDING R/W1C 验证（无全局中断）
     * 使用 bit 5
     * ---------------------------------------------------------------- */

    /* 6a: 配置高电平触发并置 pending */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 32u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 32u);
    tb_gpio0_set_mask(32u);
    wait_cycles(20u);

    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET));
    if ((val & 32u) == 0u) {
        return 51;  /* pending 应已置位 */
    }
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 32u) == 0u) {
        return 52;  /* IRQ_EN 已置，IRQ_STATUS 应与 pending 一致 */
    }

    /* 6b: 移除 stimulus 和触发使能，W1C */
    tb_gpio0_clear_mask(32u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 0u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 32u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET));
    if ((val & 32u) != 0u) {
        return 53;  /* W1C 后 pending 应为 0 */
    }

    /* 6c: IRQ_STATUS 应随 pending 和 IRQ_EN 联动 */
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 32u) != 0u) {
        return 54;  /* pending=0，IRQ_EN=1，STATUS=0 */
    }

    /* 6d: 重新置 pending 后，关 IRQ_EN → STATUS=0 仍成立 */
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 32u);
    tb_gpio0_set_mask(32u);
    wait_cycles(20u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 32u) == 0u) {
        return 55;  /* pending=1, IRQ_EN=1, 应有 STATUS */
    }

    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);
    val = mmio_read32(gpio_reg(GPIO0_BASE, GPIO_IRQ_STATUS_OFFSET));
    if ((val & 32u) != 0u) {
        return 56;  /* IRQ_EN=0, 即使 pending=1, STATUS 也应为 0 */
    }

    /* 6e: 最终清理 */
    tb_gpio0_clear_mask(32u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_HIGH_EN_OFFSET), 0u);
    wait_cycles(20u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_PENDING_OFFSET), 32u);
    mmio_write32(gpio_reg(GPIO0_BASE, GPIO_IRQ_EN_OFFSET), 0u);

    /* ----------------------------------------------------------------
     * 全部通过
     * ---------------------------------------------------------------- */
    return 0u;
}
