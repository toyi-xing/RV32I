# E10 RV32I FPGA 上板验证

本 Quartus 项目面向 **E10 最小系统板**（搭载 EP4CE10F17C8 芯片）。

**默认硬件配置：**

- **顶层模块**：`e10_rv32i_top`
- **时钟**：`sys_clk`，50 MHz，引脚 `E1`
- **复位**：`sys_rst_n`，低电平有效，引脚 `M1`
- **LED**：`led[1:0]`，引脚 `B5/A4`
- **按键**：`key[1:0]`，引脚 `E15/E16`
- **UART**：`uart_rxd/uart_txd`，引脚 `B13/A13`，115200 8N1
- **IMEM/DMEM**：各 16 KiB

**RV32I 使用的存储器映像文件：**

- `../mem/current_dmem.mif`
- `../mem/current_dmem.mem`

可以用替换为默认存储器映像文件`..\mem\default_dmem.mif`、`../mem/default_imem.mem` 进行硬件 smoke 检测，这两个文件目前包含一个简短的 RV32I LED 闪烁循环程序。

若要运行 C 语言程序，请将生成的 `current_imem.mem` 和 `current_dmem.mif` 文件复制覆盖到上述两个活动文件，然后重新编译 Quartus 项目。
