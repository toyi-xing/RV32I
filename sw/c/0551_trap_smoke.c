/*
 * 0551_trap_smoke.c - C runtime trap handler smoke test.
 *
 * 目的：
 *   - 使用 crt0.S 中共享的 .text.trap 入口，验证 C 语言侧的 trap handler 能正确接管异常。
 *   - 用内联汇编嵌入 ECALL 指令触发 environment call exception。
 *   - 在 __trap_handler_c 中记录 mcause/mepc/mtval，然后返回 mepc+4 实现"跳过"ecall。
 *   - main 返回到 ecall 之后，逐项检查各寄存器和控制流是否正确。
 *
 * 关于内联汇编：
 *   合法的 C 代码无法生成 ecall、ebreak、非法指令编码或 JALR 对齐错误等异常
 *   ——编译器永远不会从标准 C 语句产生这些编码。因此触发 trap 的指令必须通过
 *   __asm__ 嵌入。当前仅在触发点使用一行 asm，测试逻辑和检查代码保持纯 C。
 *
 * 通过条件：
 *   - trap_seen == 1（handler 确已被调用）
 *   - trap_mcause == 11（ECALL from M-mode）
 *   - trap_mepc == ecall 指令的 PC
 *   - trap_mtval == 0（ECALL 不携带额外地址/指令信息）
 *   - after_ecall == 1（mret 后确实回到了 ecall 的下一条指令）
 *
 * 失败返回码：
 *   1: trap_seen 不为 1
 *   2: mcause != 11
 *   3: mepc != ecall 指令 PC
 *   4: mtval != 0
 *   5: after_ecall 不为 1（mret 返回位置不对）
 */

static volatile unsigned int trap_seen;      // handler 调用计数；ecall 应恰好触发 1 次
static volatile unsigned int trap_mcause;    // handler 保存的 mcause 值
static volatile unsigned int trap_mepc;      // handler 保存的 mepc 值
static volatile unsigned int trap_mtval;     // handler 保存的 mtval 值
static volatile unsigned int after_ecall;    // ecall 之后的代码是否执行到

unsigned int __trap_handler_c(unsigned int mcause, unsigned int mepc, unsigned int mtval)
{
    // crt0.S 已保存/恢复全部 GPR，这里可以安全地读写全局变量。
    // 参数：a0=mcause, a1=mepc, a2=mtval；返回值写入 mepc 后 mret。
    trap_seen = trap_seen + 1u;
    trap_mcause = mcause;
    trap_mepc = mepc;
    trap_mtval = mtval;

    return mepc + 4u;   // 让 mret 返回到 ecall 的下一条指令
}

int main(void)
{
    unsigned int ecall_pc;

    ecall_pc = 0u;
    trap_seen = 0u;
    trap_mcause = 0u;
    trap_mepc = 0u;
    trap_mtval = 0xffffffffu;   // 预置非 0，用来确认 handler 确实写入 0
    after_ecall = 0u;

    // 用内联汇编嵌入 ecall，同时获取 ecall 指令自身的 PC。
    // "1:\n" 是局部 label，"%%hi(1f)" / "%%lo(1f)" 用于获取其地址。
    __asm__ volatile (
        "lui  %[pc], %%hi(1f)\n"
        "addi %[pc], %[pc], %%lo(1f)\n"   // %[pc] = 局部 label 1: 的绝对地址
        "1:\n"
        "ecall\n"                           // 触发 trap；handler 返回后继续执行下一条
        : [pc] "=r" (ecall_pc)
        :
        : "memory"
    );

    after_ecall = 1u;   // 走到这里说明 mret 正确返回到 ecall 之后

    // 以下为逐项检查
    if (trap_seen != 1u) {
        return 1;
    }

    if (trap_mcause != 11u) {
        return 2;
    }

    if (trap_mepc != ecall_pc) {
        return 3;
    }

    if (trap_mtval != 0u) {
        return 4;
    }

    if (after_ecall != 1u) {
        return 5;
    }

    return 0;   // 全部通过 → crt0.S 写 PASS
}
