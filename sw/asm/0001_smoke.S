#===============================================================================
# 0001_smoke.S — RV32I 基础最小 smoke test
#
# 功能：
#   1. 执行一条 addi x1, x0, 42，验证取指→译码→执行→写回路径。
#   2. 往约定 DMEM 地址写 1，通知 testbench 测试通过。
#   3. 最后死循环，防止跑飞。
#
# PASS 条件：
#   testbench 检测到 DMEM_BASE+0x100 写入 1 后打印 PASS
#===============================================================================

# .section .text.init 告诉汇编器：下面这段入口代码放到 text.init 段
# linker script 会把 .text.init 放在 IMEM 起始地址，和 core 的 RESET_PC 一致
.section .text.init

# .globl 把 _start 声明为全局符号，链接器或 debugger 能看到它
.globl _start

# _start: 定义一个标签，代表这一行的地址
# CPU 复位后第一条指令从这里开始取
_start:
    addi  x1, x0, 42         # x1 = 42
    lui   x10, 0x10          # x10 = DMEM_BASE
    addi  x11, x0, 1         # x11 = PASS value
    sw    x11, 0x100(x10)    # dmem[DMEM_BASE+0x100] = 1

# 死循环，防止指令继续往下执行到未定义区域
loop:
    jal   x0, loop           # jump 到 loop 自身；不使用 j 伪指令
