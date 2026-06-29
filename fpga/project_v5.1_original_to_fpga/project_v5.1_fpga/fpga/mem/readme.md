# FPGA 存储器镜像文件

此目录存放 Quartus FPGA 构建流程所需的存储器初始化文件。

## 文件列表

| 文件 | 使用者 | 说明 |
| --- | --- | --- |
| `current_imem.mem` | `rtl/fpga/fpga_imem.sv` | 当前活跃的 IMEM 镜像，会被打包进下一次 SOF 构建 |
| `current_dmem.mif` | `rtl/fpga/fpga_dmem.sv` | 当前活跃的 DMEM 镜像，会被打包进下一次 SOF 构建 |
| `default_imem.mem` | 手动回退备用 | 精简的默认/冒烟测试 IMEM 镜像 |
| `default_dmem.mif` | 手动回退备用 | 精简的默认/冒烟测试 DMEM 镜像 |

`current_*` 文件是 Quartus 的实时输入。修改这些文件后，需要重新运行 Quartus 编译，新内容才会被嵌入到 `output_files/e10_rv32i.sof` 中。

## 默认板级行为

默认/冒烟测试镜像用作简单的板级 sanity check。在 E10 开发板上，它会驱动 GPIO LED0 和 LED1 交替闪烁，形成流水灯效果：

```text
LED0 亮, LED1 灭
LED0 灭, LED1 亮
重复
```

该最小镜像不产生 UART 输出，也不依赖中断。适用于快速验证 FPGA 配置、复位、时钟、IMEM 以及 GPIO 输出通路是否基本正常。

## 更新活跃镜像

在 `project_v5.1_fpga/` 目录下执行：

```bash
scripts/update_fpga_mem.sh 0500
```

或将 `0500` 替换为 `sw/c/` 下其他 C 程序代码的名称。

脚本会更新以下文件：

```text
fpga/mem/current_imem.mem
fpga/mem/current_dmem.mif
```

更新完成后，重新运行 Quartus 编译并下载新生成的 SOF 文件。

## 注意事项

- `fpga_imem.sv` 通过 `$readmemh` 加载 `../mem/current_imem.mem`
- `fpga_dmem.sv` 例化 `altsyncram` 并加载 `../mem/current_dmem.mif`
- `current_dmem.mem` **不**用于 FPGA DMEM wrapper（此为有意设计）
- 当前 v5.1 镜像假定 IMEM 和 DMEM 均为 16 KiB
