/*
 * 0201_c_smoke.c - RV32I C 裸机 smoke 测试。
 *
 * main 返回 0 表示测试通过；返回非 0 表示失败。
 * TEST_STATUS_ADDR 的写入由 sw/c_runtime/crt0.S 统一完成。
 */

int main(void)
{
    int a,b,c;
    a = 1;
    b = 2;
    c = a + b;
    if (c != 3)
    {
        return 1;
    }
    return 0;
}