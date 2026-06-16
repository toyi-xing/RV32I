/*
 * 0202_dmem_init.c - RV32I C 裸机 dmem 初始化测试。
 *
 * main 返回 0 表示测试通过；返回非 0 表示失败。
 * TEST_STATUS_ADDR 的写入由 sw/c_runtime/crt0.S 统一完成。
 */

static const int k_table[4] = {3, 5, 7, 11};  /* .rodata，经 dmem.mem 初始化 */
static int g_data = 7;                         /* .data，经 dmem.mem 初始化 */
static int g_bss;                              /* .bss，由 crt0.S 清零 */

static int add3(int a, int b, int c)
{
    int tmp = a + b;   /* 使用栈上的局部变量 */
    return tmp + c;
}

int main(void)
{
    int sum = 0;
    int local[4];
    int i;

    /* 检查 .data 初始值是否从 dmem.mem 正确加载。 */
    if (g_data != 7) {
        return 1;
    }

    /* 检查 .bss 是否在进入 main 前被 crt0.S 清零。 */
    if (g_bss != 0) {
        return 2;
    }

    /* 检查 .rodata 只读表是否能通过数据口正常读取。 */
    for (i = 0; i < 4; i = i + 1) {
        sum = sum + k_table[i];
    }
    if (sum != 26) {
        return 3;
    }

    /* 检查全局变量写回和再次读取。 */
    g_data = g_data + 2;
    if (g_data != 9) {
        return 4;
    }

    g_bss = 5;
    if (g_bss != 5) {
        return 5;
    }

    /* 检查局部数组的栈上 load/store。 */
    local[0] = 1;
    local[1] = 2;
    local[2] = 3;
    local[3] = 4;

    sum = 0;
    for (i = 0; i < 4; i = i + 1) {
        sum = sum + local[i];
    }
    if (sum != 10) {
        return 6;
    }

    /* 检查函数调用、返回值和 ABI 返回寄存器 x10/a0。 */
    if (add3(sum, g_data, g_bss) != 24) {
        return 7;
    }

    return 0;
}
