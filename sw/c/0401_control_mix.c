/*
 * 0401_control_mix.c - RV32I C bare-metal 综合控制流 + 内存操作测试。
 *
 * 重点：
 *   - 嵌套循环和 branch 密集的 control flow
 *   - stack spill、全局 .data/.bss/.rodata 读取
 *   - 由 C 类型生成的 byte 和 halfword load/store
 *   - 不依赖 libgcc helper 的小函数调用
 *
 * 通过条件：main 返回 0，crt0.S 写 PASS。
 *
 * 失败返回码：
 *   1:  .bss 段全局 g_sink 非 0（crt0 未清零 .bss）
 *   2:  .bss 段 g_work 数组非 0
 *   3:  .bss 段 g_bytes 数组非 0
 *   4:  .bss 段 g_halves 数组非 0
 *   5:  冒泡排序结果无序（比较或交换逻辑出错）
 *   6:  fold_step 累加结果 != 144（函数调用或运算问题）
 *   7:  byte 操作后 acc != 404（byte store/load 通路）
 *   8:  halfword 操作后 acc != 811（halfword store/load 通路）
 *   9:  branch_mix 三次调用结果 != 981（分支密集函数返回值）
 *   10: g_sink 写回验证失败（.data 段 store 后 load）
 */

/* .rodata：排序原始数据 */
static const int seed[8] = {13, -3, 25, 7, -11, 4, 9, 16};

/* .data：全局偏移量，初始值 5 */
static int g_bias = 5;

/* .bss：各操作区，crt0.S 进入 main() 前清零 */
static int g_work[8];
static unsigned char g_bytes[8];
static unsigned short g_halves[4];
static int g_sink;

/*
 * fold_step — 带分支判断的累加辅助函数。
 * 按 value 的符号/奇偶性选择不同计算公式，验证条件分支和整数运算。
 */
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

/*
 * branch_mix — 三个分支路径的函数调用测试。
 * 每次调用走不同路径，验证比较和分支的正确性。
 */
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

    /* ---- Stage 1: .bss 清零检查 ---- */
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

    /* ---- Stage 2: 用 seed[] + g_bias 初始化 g_work ---- */
    for (i = 0; i < 8; i = i + 1) {
        g_work[i] = seed[i] + g_bias - i;
    }
    /* g_work = {18, 1, 28, 9, -10, 4, 8, 14} */

    /* ---- Stage 3: 冒泡排序（嵌套循环 + 临时变量栈 spill） ---- */
    for (i = 0; i < 7; i = i + 1) {
        for (j = 0; j < 7 - i; j = j + 1) {
            if (g_work[j] > g_work[j + 1]) {
                int tmp = g_work[j];
                g_work[j] = g_work[j + 1];
                g_work[j + 1] = tmp;
            }
        }
    }
    /* 排序结果：{-10, 1, 4, 8, 9, 14, 18, 28} */

    /* ---- Stage 4: 验证排序正确 ---- */
    for (i = 0; i < 7; i = i + 1) {
        if (g_work[i] > g_work[i + 1]) {
            return 5;
        }
    }

    /* ---- Stage 5: fold_step 累加（函数调用 + 条件分支） ---- */
    acc = 0;
    for (i = 0; i < 8; i = i + 1) {
        acc = fold_step(acc, g_work[i], i);
    }
    /* 逐元素计算：
     *   -10(<0):  term = 10+0=10          → acc=10
     *   1(odd):   term = 1+2+3=6          → acc=16
     *   4(even):  term = 4+4-2=6          → acc=22
     *   8(even):  term = 8+6-2=12         → acc=34
     *   9(odd):   term = 9+8+3=20         → acc=54
     *   14(even): term = 14+10-2=22       → acc=76
     *   18(even): term = 18+12-2=28       → acc=104
     *   28(even): term = 28+14-2=40       → acc=144
     */
    if (acc != 144) {
        return 6;
    }

    /* ---- Stage 6: byte 操作（unsigned char → LB/SB） ---- */
    for (i = 0; i < 8; i = i + 1) {
        g_bytes[i] = (unsigned char)(g_work[i] + 20 + i);
        acc = acc + g_bytes[i];
    }
    /* g_bytes = {10, 22, 26, 31, 33, 39, 44, 55}
     * acc = 144 + 10+22+26+31+33+39+44+55 = 404
     */
    if (acc != 404) {
        return 7;
    }

    /* ---- Stage 7: halfword 操作（unsigned short → LH/SH） ---- */
    j = 0;
    for (i = 0; i < 4; i = i + 1) {
        g_halves[i] = (unsigned short)(g_bytes[j] + (g_bytes[j + 1] << 1));
        acc = acc + g_halves[i];
        j = j + 2;
    }
    /* g_halves:
     *   10 + (22<<1) = 54
     *   26 + (31<<1) = 88
     *   33 + (39<<1) = 111
     *   44 + (55<<1) = 154
     * acc = 404 + 54+88+111+154 = 811
     */
    if (acc != 811) {
        return 8;
    }

    /* ---- Stage 8: branch_mix 三次调用（验证三条分支路径） ---- */
    acc = acc + branch_mix(g_work[0], g_work[7]);   // -10 < 28  → 38
    acc = acc + branch_mix(g_work[3], g_work[3]);   // 8 == 8    → 8^0x55 = 93
    acc = acc + branch_mix(g_work[7], g_work[0]);   // 28 > -10  → 28-(-10)+1 = 39
    /* acc = 811 + 38 + 93 + 39 = 981 */
    if (acc != 981) {
        return 9;
    }

    /* ---- Stage 9: g_sink 写回验证（.data 段 store 后 load） ---- */
    g_sink = acc;
    if (g_sink != 981) {
        return 10;
    }

    return 0;
}
