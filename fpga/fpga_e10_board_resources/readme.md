# FPGA E10 系统板资料

本目录归档正点原子 E10 最小系统板相关资料，用于 RV32I SoC 以及后续其他 RTL 版本的 FPGA 上板验证。当前使用的 FPGA 器件为 Intel Cyclone IV E `EP4CE10F17C8`。

这里主要保存板卡与器件资料，不放具体 RTL 版本的改造说明。具体工程如何使用这些资源，请查看对应版本目录下的上板文档。

## 目录结构

```text
fpga_e10_board_resources/
+-- 01_FPGA/
+-- 03_SDRAM/
+-- 04_FLASH/
+-- 05_UART/
+-- 1_正点原子E10最小系统板入门资料/
`-- 3_正点原子E10最小系统板原理图/
```

| 路径 | 内容 |
| --- | --- |
| [01_FPGA](01_FPGA/) | Cyclone IV / EP4CE10 器件手册、引脚资料和产品表。 |
| [03_SDRAM](03_SDRAM/) | 板载 SDRAM 芯片资料。 |
| [04_FLASH](04_FLASH/) | 板载 SPI Flash 芯片资料。 |
| [05_UART](05_UART/) | 板载 USB-UART / CH340 相关资料。 |
| [1_正点原子E10最小系统板入门资料](1_%E6%AD%A3%E7%82%B9%E5%8E%9F%E5%AD%90E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BF%E5%85%A5%E9%97%A8%E8%B5%84%E6%96%99/) | E10 最小系统板入门教程和 FAQ。 |
| [3_正点原子E10最小系统板原理图](3_%E6%AD%A3%E7%82%B9%E5%8E%9F%E5%AD%90E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BF%E5%8E%9F%E7%90%86%E5%9B%BE/) | E10 原理图、IO 分配表、官方 IO TCL 和板框 DXF。 |

## 关键资料

| 文件 | 用途 |
| --- | --- |
| [01_FPGA/Cyclone IV EP4CE10引脚信息.pdf](01_FPGA/Cyclone%20IV%20EP4CE10%E5%BC%95%E8%84%9A%E4%BF%A1%E6%81%AF.pdf) | EP4CE10 引脚信息。 |
| [01_FPGA/Cyclone IV器件手册.pdf](01_FPGA/Cyclone%20IV%E5%99%A8%E4%BB%B6%E6%89%8B%E5%86%8C.pdf) | Cyclone IV 英文器件手册。 |
| [01_FPGA/Cyclone IV 中文手册.pdf](01_FPGA/Cyclone%20IV%20%E4%B8%AD%E6%96%87%E6%89%8B%E5%86%8C.pdf) | Cyclone IV 中文器件手册。 |
| [01_FPGA/cyclone-iv-product-table.pdf](01_FPGA/cyclone-iv-product-table.pdf) | Cyclone IV 产品资源表。 |
| [3_正点原子E10最小系统板原理图/E10最小系统板原理图_V1.1.pdf](3_%E6%AD%A3%E7%82%B9%E5%8E%9F%E5%AD%90E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BF%E5%8E%9F%E7%90%86%E5%9B%BE/E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BF%E5%8E%9F%E7%90%86%E5%9B%BE_V1.1.pdf) | E10 最小系统板原理图。 |
| [3_正点原子E10最小系统板原理图/E10最小系统板IO分配表.xlsx](3_%E6%AD%A3%E7%82%B9%E5%8E%9F%E5%AD%90E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BF%E5%8E%9F%E7%90%86%E5%9B%BE/E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BFIO%E5%88%86%E9%85%8D%E8%A1%A8.xlsx) | E10 最小系统板 IO 分配表。 |
| [3_正点原子E10最小系统板原理图/E10_MicroSYS_IO.tcl](3_%E6%AD%A3%E7%82%B9%E5%8E%9F%E5%AD%90E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BF%E5%8E%9F%E7%90%86%E5%9B%BE/E10_MicroSYS_IO.tcl) | 官方 Quartus TCL 引脚分配参考，可按工程端口名改写到 QSF。 |
| [05_UART/CH340.pdf](05_UART/CH340.pdf) | 板载 USB-UART 芯片资料。 |
| [03_SDRAM/W9825G6KH.pdf](03_SDRAM/W9825G6KH.pdf) | 板载 SDRAM 芯片资料。 |
| [04_FLASH/W25Q16JVSSIQ.pdf](04_FLASH/W25Q16JVSSIQ.pdf) | 板载 SPI Flash 芯片资料。 |

## 存储资源

E10 最小系统板同时包含 FPGA 片内存储资源和板载外部存储芯片。片内 M9K 适合做小容量、低延迟的 IMEM/DMEM；外部 SDRAM/Flash 容量更大，但需要额外控制器，当前 RV32I 最小上板工程尚未接入。

### FPGA 片内 M9K

`EP4CE10F17C8` 属于 Cyclone IV E 系列，片内 block RAM 为 M9K。M9K 是 FPGA 内部同步 RAM 资源，读数据不是仿真 RAM 那种任意时刻组合返回；RTL 上板时应按同步读 RAM 处理，并在 CPU/SoC 接口或 wrapper 里处理好读时序。

| 项目 | 数值 | 说明 |
| --- | --- | --- |
| M9K 数量 | 46 blocks | 以 EP4CE10 器件资源表为准。 |
| 单块原始容量 | 9,216 bits | 即 9 Kbit。 |
| 单块原始 32-bit word 换算 | 288 words / M9K | `9216 / 32 = 288`，这是纯 bit 容量换算。 |
| 单块常用 32-bit RAM 估算 | 256 words / M9K | 常见 32-bit 端口映射可按 `256 x 32` 估算，剩余 bit 可能因宽度配置未充分利用。 |
| 原始总容量 | 423,936 bits | `46 x 9216` bits，约 51.75 KiB。 |
| 常用 32-bit word 估算 | 11,776 words | `46 x 256` 个 32-bit word，约 46 KiB 可用数据容量估算。 |

当前 RV32I FPGA 工程使用 32-bit word memory：

| 存储 | RTL 深度 | 字节容量 | M9K 估算 |
| --- | --- | --- | --- |
| IMEM | 4,096 x 32-bit word | 16 KiB | 约 16 块 M9K |
| DMEM | 4,096 x 32-bit word | 16 KiB | 约 16 块 M9K |
| IMEM + DMEM | 8,192 x 32-bit word | 32 KiB | 约 32 块 M9K |

因此在 EP4CE10 上将 IMEM/DMEM 各设为 16 KiB 是比较保守的选择，既能容纳当前裸机测试程序，也给其他逻辑和后续小型 RAM 留出一定 M9K 余量。最终资源占用仍应以 Quartus Fitter report 为准。

### 板载外部存储

| 器件 | 资料 | 容量 | 接口 | 当前用途 |
| --- | --- | --- | --- | --- |
| Winbond W9825G6KH SDRAM | [03_SDRAM/W9825G6KH.pdf](03_SDRAM/W9825G6KH.pdf) | 256 Mbit / 32 MiB | SDRAM, 16-bit data bus | 当前最小 RV32I SoC 未接入，后续可用于大容量数据区、framebuffer 或外部内存实验。 |
| Winbond W25Q16JVSSIQ Flash | [04_FLASH/W25Q16JVSSIQ.pdf](04_FLASH/W25Q16JVSSIQ.pdf) | 16 Mbit / 2 MiB | SPI NOR Flash | 当前最小 RV32I SoC 未接入，后续可用于程序镜像、配置数据或简单文件/数据存储。 |

如果后续接入板载 SDRAM 或 SPI Flash，需要新增对应控制器、时序约束、引脚约束和软件驱动；不要把它们和 FPGA 片内 M9K 的固定延迟 RAM 直接等同。

## 基础板级信号

当前 RV32I FPGA 上板工程只使用了 E10 的最小基础资源：

| 信号 | FPGA 引脚 | 方向 | 说明 |
| --- | --- | --- | --- |
| `sys_clk` | `PIN_E1` | input | 板载 50 MHz 时钟。 |
| `sys_rst_n` | `PIN_M1` | input | 低有效复位。 |
| `led[0]` | `PIN_A4` | output | 板载 LED0。 |
| `led[1]` | `PIN_B5` | output | 板载 LED1。 |
| `key[0]` | `PIN_E16` | input | 板载 KEY0。 |
| `key[1]` | `PIN_E15` | input | 板载 KEY1。 |
| `uart_rxd` | `PIN_B13` | input | FPGA UART RXD。 |
| `uart_txd` | `PIN_A13` | output | FPGA UART TXD。 |

以上引脚来自官方 IO 资料，并已在 v5.1 FPGA 工程 QSF 中使用。具体工程端口名应以当前版本 QSF 和 top-level RTL 为准。

## 引脚约束注意事项

- 官方 [E10_MicroSYS_IO.tcl](3_%E6%AD%A3%E7%82%B9%E5%8E%9F%E5%AD%90E10%E6%9C%80%E5%B0%8F%E7%B3%BB%E7%BB%9F%E6%9D%BF%E5%8E%9F%E7%90%86%E5%9B%BE/E10_MicroSYS_IO.tcl) 是引脚分配参考，不应不加检查地整文件导入工程。
- 导入或复制 TCL/QSF 约束时，要确认工程 top-level 端口名与官方示例端口名一致。
- E10 板上许多 FPGA 引脚可能在不同扩展模块示例中复用，实际使用前应同时核对原理图、IO 表和当前外设连接。
- 当前基础上板工程使用 `3.3-V LVTTL` IO standard；扩展外设前应根据器件手册和外设电平重新确认 IO standard。
- 扩展 GPIO 到排针或外设时，应先在 top-level RTL 中增加端口，再在 QSF 中分配对应 pin，并避免与已使用的 LED、KEY、UART、SDRAM、FLASH 等信号冲突。

## 使用建议

为新 RTL 版本做 E10 上板验证时，建议按以下顺序使用本目录资料：

1. 从 `01_FPGA` 确认目标器件型号、资源规模和引脚限制。
2. 从 `3_正点原子E10最小系统板原理图` 查找原理图、IO 分配表和官方 TCL。
3. 在 Quartus QSF 中只添加当前工程真正使用的 pin assignment。
4. 编译后检查 pin report，确认所有顶层 IO 都已分配到预期引脚和 IO standard。
5. 外接 UART、排针或其他模块前，再回到原理图确认信号方向、电平和是否存在板载复用。
