/*
 * control_mix.c - 稍大一些的 RV32I C bare-metal 测试。
 *
 * 重点：
 *   - 嵌套循环和 branch 密集的 control flow
 *   - stack spill、全局 .data/.bss、.rodata 读取
 *   - 由 C 类型生成的 byte 和 halfword load/store
 *   - 不依赖 libgcc helper 的小函数调用
 *
 * main 返回 0 表示通过。最终 PASS/FAIL 状态由 crt0.S 写入。
 */

static const int seed[8] = {13, -3, 25, 7, -11, 4, 9, 16};

static int g_bias = 5;
static int g_work[8];
static unsigned char g_bytes[8];
static unsigned short g_halves[4];
static int g_sink;

static int fold_step(int acc, int value, int index)
{
    int term;

    if (value < 0) {
        term = -value + index;
    } else if ((value & 1) != 0) {
        term = value + (index << 1) + 3;
    } else {
        term = value + (index << 1) - 2;
    }

    return acc + term;
}

static int branch_mix(int a, int b)
{
    if (a < b) {
        return b - a;
    }

    if (a == b) {
        return a ^ 0x55;
    }

    return a - b + 1;
}

int main(void)
{
    int i;
    int j;
    int acc;

    if (g_sink != 0) {
        return 1;
    }

    for (i = 0; i < 8; i = i + 1) {
        if (g_work[i] != 0) {
            return 2;
        }
        if (g_bytes[i] != 0) {
            return 3;
        }
    }

    for (i = 0; i < 4; i = i + 1) {
        if (g_halves[i] != 0) {
            return 4;
        }
    }

    for (i = 0; i < 8; i = i + 1) {
        g_work[i] = seed[i] + g_bias - i;
    }

    for (i = 0; i < 7; i = i + 1) {
        for (j = 0; j < 7 - i; j = j + 1) {
            if (g_work[j] > g_work[j + 1]) {
                int tmp = g_work[j];
                g_work[j] = g_work[j + 1];
                g_work[j + 1] = tmp;
            }
        }
    }

    for (i = 0; i < 7; i = i + 1) {
        if (g_work[i] > g_work[i + 1]) {
            return 5;
        }
    }

    acc = 0;
    for (i = 0; i < 8; i = i + 1) {
        acc = fold_step(acc, g_work[i], i);
    }

    if (acc != 144) {
        return 6;
    }

    for (i = 0; i < 8; i = i + 1) {
        g_bytes[i] = (unsigned char)(g_work[i] + 20 + i);
        acc = acc + g_bytes[i];
    }

    if (acc != 404) {
        return 7;
    }

    j = 0;
    for (i = 0; i < 4; i = i + 1) {
        g_halves[i] = (unsigned short)(g_bytes[j] + (g_bytes[j + 1] << 1));
        acc = acc + g_halves[i];
        j = j + 2;
    }

    if (acc != 811) {
        return 8;
    }

    acc = acc + branch_mix(g_work[0], g_work[7]);
    acc = acc + branch_mix(g_work[3], g_work[3]);
    acc = acc + branch_mix(g_work[7], g_work[0]);

    if (acc != 981) {
        return 9;
    }

    g_sink = acc;
    if (g_sink != 981) {
        return 10;
    }

    return 0;
}

