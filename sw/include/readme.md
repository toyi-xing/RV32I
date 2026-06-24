# Software Include Headers

本目录放裸机测试程序使用的公共头文件。这里的头文件服务于当前教学 SoC 和仿真测试，不等同于 RISC-V 标准平台头。

## `platform.h`

`platform.h` 描述当前 SoC 平台的软件可见地址图、外设寄存器 offset、bit mask、CSR bit mask，以及常用 C helper。

该文件同时给 C 和 `.S` 汇编测试使用：

- 公共常量使用 `#define`，可被 C 编译器和汇编预处理器共同展开。
- C-only 内容放在 `#ifndef __ASSEMBLER__` 内，包括 `stdint.h`、MMIO helper 和 CSR helper。
- 汇编测试应优先 include `platform.h` 复用公共地址和 bit 定义，不再在每个 `.S` 文件重复写 `.equ` 平台常量。

具体外设寄存器语义仍以 `rtl/periph/readme.md` 为准；`platform.h` 只绑定当前 SoC 实例的基地址和软件常用宏。

## `tb_rv32i_soc_test.h`

`tb_rv32i_soc_test.h` 描述 `tb/sv/tb_rv32i_soc.sv` 专用的 directed-test mailbox 协议。测试程序通过向保留 DMEM 地址执行普通 store，请求 testbench 驱动 GPIO 输入或 UART RX 事件。

这个文件只适用于当前 SoC testbench：

- 它不是真实 SoC 地址图。
- 它不是 `rtl/periph` 外设寄存器 ABI。
- tb 驱动请求不应连续发送，否则当前 tb 可能漏事件。
- 换成其他 testbench 或后续 UVM 平台时，可以替换成另一套测试协议头文件。

C 测试可以调用其中的 inline helper；汇编测试通常只使用其中的地址和 mask 常量，直接构造 store 指令即可。
