# RV32I FPGA 上板验证工作区

本工作区用于整理 RV32I SoC 从仿真验证版本迁移到 FPGA 上板验证版本的工程材料。当前主要目标板为正点原子 E10 最小系统板，FPGA 器件为 Intel Cyclone IV E `EP4CE10F17C8`。板卡原理图、器件手册、IO 分配表等资料统一放在 [fpga_e10_board_resources](fpga_e10_board_resources/) 中。

本文档是通用的 FPGA 上板验证方法；具体某个 RTL 版本的改造记录、验证结果和问题闭环放在对应版本目录下。

## 目录结构

```text
.
+-- readme.md
+-- fpga_e10_board_resources/
`-- project_v5.1_original_to_fpga/
    +-- project_v5.1_original/
    `-- project_v5.1_fpga/
```

| 路径 | 内容 |
| --- | --- |
| [fpga_e10_board_resources](fpga_e10_board_resources/) | E10 系统板资料归档，包括 FPGA 器件资料、原理图、IO 分配表、板载存储和外设芯片资料等。 |
| [project_v5.1_original_to_fpga](project_v5.1_original_to_fpga/) | v5.1 从仿真器验证工程迁移到 FPGA 上板工程的版本归档与专项文档入口。 |

## 目标板卡

当前上板目标：

- 板卡：正点原子 E10 最小系统板
- FPGA：Intel Cyclone IV E `EP4CE10F17C8`
- 时钟：板载 50 MHz 时钟
- 基础 IO：LED、KEY、UART、扩展排针
- FPGA 工具：Quartus Prime Lite 25.1

更细的板卡资源、M9K 片内存储、板载 SDRAM/Flash、引脚和原理图资料请查看 [fpga_e10_board_resources/readme.md](fpga_e10_board_resources/readme.md)。

## 通用上板改造项

把一个已经通过仿真的 RV32I SoC 版本搬到 FPGA 上，通常需要完成以下工作：

1. 保留已验证的 CPU core 逻辑，避免在上板适配阶段引入新的流水线行为变化。
2. 根据目标 FPGA 的片上存储资源重新评估 IMEM/DMEM 容量，并同步 RTL 参数、linker script 和 `platform.h`。
3. 分离仿真 memory 与 FPGA memory。仿真可继续使用理想 ROM/RAM，FPGA 侧应使用可综合、可推断或可例化的 block RAM。
4. 为 FPGA 添加板级 top，连接时钟、复位、LED、KEY、UART、扩展 GPIO 等真实 IO。
5. 根据 FPGA RAM 的真实时序适配 IMEM/DMEM wrapper。不能默认仿真 RAM 的组合读行为等价于 FPGA block RAM。
6. 添加 Quartus 工程、器件选择、顶层设置、QSF 引脚约束和存储初始化文件。
7. 建立 C 程序到 FPGA 初始化镜像的构建流程，并确保生成的 IMEM/DMEM 镜像被重新编译进 `.sof`。
8. 用最小可见程序逐步验证 GPIO、按键、timer polling、interrupt、UART 或其他外设。

## 工具依赖

与母仓库不同，本工作区 FPGA 上板验证在 Windows 环境下进行，建议准备：

- Quartus Prime Lite 25.1，用于综合、布局布线、生成 `.sof` 和下载 FPGA。
- USB-Blaster 驱动，用于通过 Quartus Programmer 下载。
- RISC-V bare-metal GCC 工具链，需支持 `rv32i_zicsr` 和 `ilp32`。
- Bash 环境，用于运行工程脚本。
- Python 3，用于二进制镜像、`.mem`、`.mif` 等格式转换。
- 可选 USB-TTL 串口工具，用于验证真实 UART TX/RX。

## C 程序编写规则

FPGA 上板 C 程序遵守以下规则：

- 程序放在对应 FPGA 工程的 `sw/c/` 目录下。
- 文件名使用四位编号开头，例如 `0500_xxx.c`，方便脚本按编号选择程序。
- 使用裸机 C，不依赖操作系统和标准库运行时。
- 包含工程提供的 `platform.h`，通过其中的地址图、寄存器偏移和 CSR helper 访问 SoC。
- 如果 RTL 修改了 IMEM/DMEM 容量或 MMIO 地址图，必须同步 linker script 和 `platform.h`。
- 每次更新 C 程序镜像后，需要重新运行 Quartus compile，因为 FPGA 初始化文件会被打包进 `.sof`。

## 当前版本归档

当前已完成的版本迁移归档见 [project_v5.1_original_to_fpga/readme.md](project_v5.1_original_to_fpga/readme.md)。该目录包含仿真原始工程、FPGA 改造工程，以及 v5.1 专项改造说明、上板流程和边界记录。
