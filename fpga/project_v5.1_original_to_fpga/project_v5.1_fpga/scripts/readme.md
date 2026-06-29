# FPGA 镜像构建脚本

本目录包含将 RV32I 裸机 C 程序构建为 FPGA 存储器初始化文件的辅助脚本。

## 脚本总览

| 脚本 | 作用 |
| --- | --- |
| `build_rv32i_c_image.sh` | 编译单个 C 程序，生成 ELF/dump/map 文件，以及 IMEM `.mem` 和 DMEM `.mif` 镜像，输出到 `build/fpga_c/` |
| `bin2mem32.py` | 将二进制文件转换为每行一个 32-bit little-endian 十六进制字的格式，供 `$readmemh` 使用 |
| `mem32_to_mif.py` | 将每行一个 32-bit 字的 `.mem` 文件转换为 Quartus `.mif` 格式 |
| `update_fpga_mem.sh` | 串联执行前三个脚本：C 镜像构建，并将结果替换到 `fpga/mem/current_imem.mem` 和 `fpga/mem/current_dmem.mif` |

## 常用流程

在 `project_v5.1_fpga/` 目录下执行：

```bash
scripts/update_fpga_mem.sh 0500
```

参数可以是以下任意形式：

```text
0500
0504_fpga_timer_irq
sw/c/0505_fpga_key_led_uart.c
```

脚本会更新当前活跃的 FPGA 存储器镜像：

```text
fpga/mem/current_imem.mem
fpga/mem/current_dmem.mif
```

之后重新运行 Quartus 编译，将新的存储器文件打包进 SOF。

## 构建输出

默认情况下，中间构建产物位于：

```text
build/fpga_c/
```

典型输出包括：

| 输出文件 | 说明 |
| --- | --- |
| `<test>.elf` | 链接后的 RV32I 裸机可执行文件 |
| `<test>.dump` | 反汇编文件，用于人工审查 |
| `<test>.map` | 链接映射表，用于检查各 section 大小和地址 |
| `<test>_imem.mem` | 安装前的 IMEM 镜像 |
| `<test>_dmem.mif` | 安装前的 DMEM MIF 镜像 |
| `last_build.txt` | 上一次 C 镜像构建的摘要信息 |

## 工具链变量

| 变量 | 用途 |
| --- | --- |
| `RISCV_PREFIX` | 工具链前缀，默认为 `riscv64-unknown-elf` |
| `RISCV_CC` | 覆盖编译器命令 |
| `RISCV_OBJCOPY` | 覆盖 objcopy |
| `RISCV_OBJDUMP` | 覆盖 objdump |
| `TOOLCHAIN_ENV` | 构建前 source 的可选 shell 脚本 |
| `BUILD_DIR` | 覆盖输出目录 |
| `EXTRA_CFLAGS` | 添加额外的 C 编译器 flags |

## 冒烟测试镜像行为

`0500_fpga_led_spark.c` 是最简单的板级冒烟测试程序。更新存储器文件、重新编译 Quartus 并下载新 SOF 后，LED0 和 LED1 会交替闪烁形成流水灯：

```text
LED0 亮, LED1 灭
LED0 灭, LED1 亮
重复
```

该程序不产生 UART 输出，也不依赖中断，因此是检查板级配置通路时的首选测试程序。

## 容量检查

`build_rv32i_c_image.sh` 会拒绝超过当前 v5.1 限制的镜像：

```text
IMEM <= 16 KiB
DMEM <= 16 KiB
```

若后续 RTL 存储器尺寸发生变化，需要同步更新 linker script、`platform.h`、memory wrapper、MIF 深度以及脚本侧的这些限制。
