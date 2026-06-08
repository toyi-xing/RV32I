# 0826 裸机程序、ROM与RAM加载与工具链使用示例

> 文档编号：0826  
> 所属系列：082x RISC-V 最小教学核项目实践  
> 文档定位：说明裸机程序如何变成教学核可加载的 memory image，以及仿真中 ROM/RAM 如何配合 testbench 使用  
> 前置文档：`0801 RISC-V ISA基础.md`、`0802 RISC-V五级流水线与Hazard.md`、`0820 RISC-V最小教学核设计流程与方案.md`、`0821 RV32I最小教学核指令集、编码与译码参考.md`

本文集中放工具链和程序加载示例。`0802` 只讲原理，不放具体命令；从本篇开始，可以把“怎么把汇编程序编成机器码并喂给 CPU”讲清楚。

本文默认第一版教学核满足：

| 项目 | 假设 |
|---|---|
| 指令集 | RV32I，暂不支持 C/M/A/F/D 扩展 |
| reset PC | `32'h0000_0000` |
| instruction memory | CPU 只读，仿真开始前由 `$readmemh` 初始化 |
| data memory | CPU 可 load/store，testbench 可在仿真结束后检查 |
| memory 格式 | 优先使用 32 bit word memory，每行一个 32 bit 指令或数据 |
| 程序形态 | 裸机汇编优先，后续再尝试极小 C 程序 |

## 第1章 总流程

教学核跑程序的完整链路是：

```text
裸机汇编/C 源码
    ↓ riscv64-unknown-elf-gcc 汇编/编译/链接
ELF 文件
    ↓ objdump 查看反汇编，确认指令和地址
二进制文件
    ↓ 转成 $readmemh 可读的 .mem 文件
instruction memory 初始化文件
    ↓ testbench 在仿真 0 时刻加载
CPU reset 后从 reset PC 取指执行
    ↓
testbench 检查 data memory、tohost 地址或 commit trace
```

这里要注意角色边界：

| 角色 | 做什么 |
|---|---|
| 工具链 | 把人写的程序变成 RISC-V 机器码 |
| testbench | 加载机器码、提供时钟复位、判断 pass/fail |
| CPU RTL | 真正取指、译码、执行、写回 |
| ROM/RAM model | 响应 CPU 的 imem/dmem 访问 |

testbench 不执行程序。它只是把程序放到 instruction memory 里，真正执行程序的是 CPU。

## 第2章 当前环境与工具

当前这台机器已经准备了一个本地 RISC-V 裸机工具链：

```bash
source /home/a/tools/riscv-unknown-elf/env.sh
```

执行这句后，当前 shell 会把下面这些工具加入 `PATH`：

| 工具 | 作用 |
|---|---|
| `riscv64-unknown-elf-gcc` | 编译、汇编、链接裸机程序 |
| `riscv64-unknown-elf-objdump` | 反汇编 ELF，查看最终指令 |
| `riscv64-unknown-elf-objcopy` | ELF 转 binary、verilog hex 等格式 |
| `riscv64-unknown-elf-readelf` | 查看 ELF 入口、段地址、符号等信息 |

仿真和 RTL 工具通常来自 OSS CAD Suite。当前环境里常用的是：

| 工具 | 作用 |
|---|---|
| `verilator` | 推荐的 SystemVerilog 仿真器 |
| `iverilog`/`vvp` | 简单 testbench 可用的仿真器 |
| `yosys` | 综合/可综合性检查 |
| `gtkwave` | 查看 VCD/FST 波形 |

如果换到其他机器，路径不一定相同。原则是一样的：保证 RISC-V 裸机工具链和 RTL 仿真器能在当前 shell 中调用即可。

## 第3章 建议目录

本文命令示例假设项目目录大致如下：

```text
rv32i_teaching_core/
    rtl/
        core/
        mem/
    tb/
        sv/
            tb_core.sv
    sw/
        asm/
            0001_smoke.S
        c/
        linker/
            linker.ld
    scripts/
        bin2mem32.py
    build/
```

目录名可以不同，但建议保持几个边界：

- `rtl/` 只放可综合 RTL 或接近可综合的 memory wrapper。
- `tb/` 放不可综合 testbench。
- `sw/` 放裸机程序和链接脚本。
- `scripts/` 放格式转换、回归运行等辅助脚本。
- `build/` 放生成物，不要手写重要源文件。

## 第4章 最小链接脚本

如果 reset PC 是 `0x0000_0000`，链接脚本也要让 `.text` 从这个地址开始。否则 CPU 从 0 取指，程序却被链接到别的地址，会直接取错。

一个最小 `sw/linker/linker.ld` 可以这样写：

```ld
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rwx) : ORIGIN = 0x00010000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text*)
        *(.rodata*)
    } > IMEM

    .data : {
        *(.data*)
    } > DMEM

    .bss : {
        *(.bss*)
        *(COMMON)
    } > DMEM

    . = ORIGIN(DMEM) + LENGTH(DMEM);
    _stack_top = .;
}
```

第一版只跑汇编程序时，`.data/.bss/_stack_top` 不一定马上用到；但把它们放进去，后续尝试 C 程序会更自然。

如果你的 CPU reset PC 不是 `0x0000_0000`，要同步修改：

| 位置 | 必须一致 |
|---|---|
| CPU reset PC | IF 阶段复位后的 PC |
| linker script | `.text` 的 `ORIGIN` |
| memory image 加载 | testbench 把程序放到 imem 的哪个地址 |

本篇后续示例采用一个简单 memory map：指令从 `0x00000000` 开始，数据区从 `0x00010000` 开始。第一版教学核即使使用分离 imem/dmem，也建议在文档和测试中保留这个地址概念；dmem wrapper 可以把 CPU 看到的 `0x00010000` 映射到内部 `mem[0]`。

## 第5章 最小汇编程序

建议先从纯汇编开始，不要一上来写 C。汇编能精确控制生成哪些指令，便于确认教学核支持范围。

一个最小 `sw/asm/0001_smoke.S`：

```asm
.option norvc
.section .text.init
.global _start

_start:
    addi x1, x0, 3
    addi x2, x0, 4
    add  x3, x1, x2
    lui  x4, 0x10
    sw   x3, 0(x4)

done:
    jal  x0, done
```

这段程序做了几件事：

| 指令 | 作用 | 测试到的硬件 |
|---|---|---|
| `addi x1, x0, 3` | 生成常数 3 | I-type decode、x0 读取、ALU、WB |
| `addi x2, x0, 4` | 生成常数 4 | 同上 |
| `add x3, x1, x2` | 计算 7 | R-type ALU、GPR 读写，后续可测 forwarding |
| `lui x4, 0x10` | 生成数据区基址 `0x00010000` | U-type decode、写回 |
| `sw x3, 0(x4)` | 把 7 写到数据区基址 | store 地址、store data、byte enable |
| `jal x0, done` | 原地死循环 | JAL、PC redirect，不写寄存器 |

程序没有 `return`，因为没有 OS。testbench 可以运行固定 cycle 后检查 dmem 内部第 0 个 word 是否为 7；这里的前提是 dmem wrapper 把 CPU 地址 `0x00010000` 映射到内部 `mem[0]`。

## 第6章 编译、反汇编和生成 memory image

### 6.1 启用工具链

在当前 shell 中先执行：

```bash
source /home/a/tools/riscv-unknown-elf/env.sh
```

如果你的工具链装在其他位置，就改成对应路径。后续命令都假设 `riscv64-unknown-elf-*` 可以直接调用。


```text
可以直接执行这一句，把它追加到 ~/.bashrc 末尾：
echo 'source /home/a/tools/riscv-unknown-elf/env.sh' >> ~/.bashrc
然后让当前终端立刻生效：
source ~/.bashrc
之后新开终端就不需要再手动执行 source /home/a/tools/riscv-unknown-elf/env.sh了。
```

### 6.2 编译汇编程序为 ELF

```bash
mkdir -p build

riscv64-unknown-elf-gcc \
    -march=rv32i \
    -mabi=ilp32 \
    -mno-relax \
    -nostdlib \
    -nostartfiles \
    -ffreestanding \
    -Wl,-T,sw/linker/linker.ld \
    -Wl,--no-relax \
    -o build/0001_smoke.elf \
    sw/asm/0001_smoke.S
```

关键选项含义：

| 选项 | 作用 |
|---|---|
| `-march=rv32i` | 只生成 RV32I 指令，不生成 M/C 等扩展指令 |
| `-mabi=ilp32` | 使用 RV32 对应 ABI |
| `-nostdlib` | 不链接标准库，避免引入系统调用和运行时 |
| `-nostartfiles` | 不使用默认启动文件，入口由 `_start` 提供 |
| `-ffreestanding` | 告诉编译器这是无宿主环境 |
| `-mno-relax`、`--no-relax` | 避免链接松弛改变指令形态，便于教学阶段观察 |
| `-T linker.ld` | 指定链接地址，必须和 reset PC/memory map 对齐 |

### 6.3 反汇编检查

```bash
riscv64-unknown-elf-objdump \
    -d \
    -M no-aliases,numeric \
    build/0001_smoke.elf > build/0001_smoke.dump
```

反汇编的作用不是“为了好看”，而是确认最终 ELF 里到底有什么指令、地址是多少。早期 debug 时，建议每次都看一眼：

| 检查点 | 说明 |
|---|---|
| `_start` 地址 | 是否等于 CPU reset PC |
| 是否出现压缩指令 | 第一版不支持 C，不能出现 16 bit 指令 |
| 是否出现乘除法 | 第一版不支持 M，不能出现 `mul/div/rem` |
| 是否出现伪指令别名 | 用 `no-aliases` 尽量显示真实指令 |
| 分支/跳转目标 | 确认 label 被链接到预期地址 |

例如上面的 `0001_smoke.S` 可能得到类似指令编码：

```text
00000000 <_start>:
   0: 00300093    addi x1,x0,3
   4: 00400113    addi x2,x0,4
   8: 002081b3    add  x3,x1,x2
   c: 00010237    lui  x4,0x10
  10: 00322023    sw   x3,0(x4)

00000014 <done>:
  14: 0000006f    jal  x0,14 <done>
```

### 6.4 生成 32 bit word `.mem`

如果你的 `simple_rom` 是这样定义的：

```systemverilog
logic [31:0] mem [0:(1 << AW)-1];
assign rdata_o = mem[addr_i[AW+1:2]];
```

那么 `$readmemh` 文件应该每行一个 32 bit word，例如：

```text
00300093
00400113
002081b3
00010237
00322023
0000006f
```

不要直接把 byte-oriented hex 当成 word memory 输入。RISC-V 通常按 little-endian 存储，机器码 `00300093` 在 byte 文件里会表现成 `93 00 30 00`。如果直接喂给 32 bit word array，很容易端序错。

推荐流程是先导出 binary，再显式转成 32 bit 小端 word：

```bash
riscv64-unknown-elf-objcopy \
    -O binary \
    build/0001_smoke.elf \
    build/0001_smoke.bin

python3 scripts/bin2mem32.py \
    build/0001_smoke.bin \
    build/0001_smoke.mem
```

`scripts/bin2mem32.py` 可以写成：

```python
#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: bin2mem32.py input.bin output.mem")

data = Path(sys.argv[1]).read_bytes()
out = []

for i in range(0, len(data), 4):
    chunk = data[i:i + 4].ljust(4, b"\x00")
    word = int.from_bytes(chunk, byteorder="little")
    out.append(f"{word:08x}")

Path(sys.argv[2]).write_text("\n".join(out) + "\n")
```

如果你的 imem 是 byte array，例如 `logic [7:0] mem[]`，可以采用 byte-oriented 文件；但本系列第一版优先使用 32 bit word imem，便于和 `PC[AW+1:2]` 对应。

## 第7章 testbench 加载 imem

推荐 testbench 用 plusarg 指定 imem 文件，这样不用每次改 RTL：

```systemverilog
module tb_core;
    string imem_file;

    initial begin
        if (!$value$plusargs("imem=%s", imem_file)) begin
            imem_file = "build/0001_smoke.mem";
        end

        $readmemh(imem_file, u_imem.mem);
    end

    // clock/reset、DUT 实例化、pass/fail 检查略
endmodule
```

`$readmemh` 是仿真任务，不是 CPU 执行期间写 ROM。真实硬件里会换成 block RAM 初始化、boot ROM、bootloader 或其他加载机制。

一个最小 pass/fail 检查可以是：

```systemverilog
initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    repeat (100) @(posedge clk);

    if (u_dmem.mem[0] == 32'd7) begin
        $display("PASS");
    end else begin
        $display("FAIL: dmem[0] = %08h", u_dmem.mem[0]);
    end

    $finish;
end
```

这只是 smoke test。后续 `0827` 会把 pass/fail、commit trace、scoreboard 和 directed test 组织得更系统。

## 第8章 运行仿真命令模板

### 8.1 用 Verilator

如果项目使用 filelist，可以先生成：

```bash
find rtl tb/sv -name '*.sv' > build/files.f
```

再编译运行：

```bash
verilator \
    -sv \
    --binary \
    --trace \
    --top-module tb_core \
    -f build/files.f

./obj_dir/Vtb_core +imem=build/0001_smoke.mem
```

如果你的 testbench 没有使用 Verilator 支持的写法，可能需要调整参数或写 C++ harness。第一版建议先让 testbench 保持简单。

### 8.2 用 Icarus Verilog

简单 SystemVerilog 子集也可以先用 `iverilog/vvp`：

```bash
iverilog \
    -g2012 \
    -o build/tb_core.vvp \
    -f build/files.f

vvp build/tb_core.vvp +imem=build/0001_smoke.mem
```

`iverilog` 对 SystemVerilog 支持不如 Verilator 完整。如果遇到语法支持问题，优先以 Verilator 为主。

### 8.3 生成波形

testbench 里可以加：

```systemverilog
initial begin
    $dumpfile("build/wave.vcd");
    $dumpvars(0, tb_core);
end
```

然后用波形工具打开：

```bash
gtkwave build/wave.vcd
```

早期建议至少观察这些信号：

| 信号 | 目的 |
|---|---|
| `pc`、`instr` | 取指地址和指令是否正确 |
| `if_valid/id_valid/ex_valid/mem_valid/wb_valid` | 指令槽是否按预期流动 |
| `stall`、`bubble`、`flush` | hazard 控制是否触发 |
| `rs1/rs2/rd` | 寄存器编号是否译码正确 |
| `rs1_rdata/rs2_rdata` | GPR 读值是否正确 |
| `alu_result` | ALU 结果或地址计算是否正确 |
| `reg_we/rd_wdata` | 写回是否正确 |
| `dmem_we/dmem_addr/dmem_wdata/dmem_be` | store 是否正确 |

## 第9章 尝试极小 C 程序

汇编 smoke test 稳定后，可以尝试极小 C 程序。但要知道：C 程序会引入启动代码、栈、链接脚本和编译器生成指令的问题。

一个很小的 `sw/c/main.c`：

```c
typedef unsigned int uint32_t;

int main(void)
{
    volatile uint32_t *p = (volatile uint32_t *)0x00010000u;
    *p = 3u + 4u;
    return 0;
}
```

需要一个启动文件调用 `main`，例如 `sw/asm/start.S`：

```asm
.option norvc
.section .text.init
.global _start
.extern main

_start:
    la   sp, _stack_top
    call main

done:
    jal  x0, done
```

编译命令类似：

```bash
riscv64-unknown-elf-gcc \
    -march=rv32i \
    -mabi=ilp32 \
    -mno-relax \
    -nostdlib \
    -nostartfiles \
    -ffreestanding \
    -Wl,-T,sw/linker/linker.ld \
    -Wl,--no-relax \
    -o build/main.elf \
    sw/asm/start.S \
    sw/c/main.c
```

早期写 C 时要特别小心：

| 风险 | 说明 |
|---|---|
| 编译器生成未支持指令 | `-march=rv32i` 能限制大部分情况，但仍要看 objdump |
| 乘除法 | C 里的乘除可能引入库函数或 M 扩展相关需求，第一版先避免 |
| 栈未初始化 | 函数调用需要 `sp`，启动文件必须设置栈 |
| 标准库 | `printf/memcpy` 等可能引入大量运行时依赖，第一版不要用 |
| 地址映射 | C 里写的指针地址必须能被 dmem 或 MMIO 解码 |

因此第一阶段推荐：先汇编，后 C；先无函数调用，后有 `main`；先不碰标准库。

## 第10章 常见问题清单

| 现象 | 常见原因 | 排查方向 |
|---|---|---|
| 第一条指令就是 `x` 或全 0 | imem 没加载、路径错、reset PC 和链接地址不一致 | 看 `$readmemh` 文件路径、ELF `_start` 地址、PC |
| 指令编码看起来 byte 反了 | 把 byte-oriented 文件喂给 32 bit word array | 检查 `.mem` 每行是否是完整 32 bit 指令 |
| 仿真能跑但结果错 | decode、ALU、GPR、store 任一环节可能错 | 看 commit trace 和波形，定位第一条错误 |
| 出现 16 bit 指令 | 编译器生成了压缩指令 | 使用 `.option norvc` 和 `-march=rv32i` |
| 出现 `mul/div` | 程序或编译器引入乘除 | 第一版避免乘除，或后续实现 M 扩展 |
| C 程序一跑就乱 | 没有启动代码、栈、链接脚本不对 | 先回到汇编 smoke test |
| branch 跳到奇怪地址 | B/J immediate 拼接错或重复左移 | 检查 `imm_gen` 和 target 计算 |
| `JALR` 目标不对齐 | 没有清 bit0 | 检查 `(rs1 + imm) & ~1` |
| `sw` 没写入预期 memory | byte enable、地址索引、dmem 映射错 | 看 `dmem_addr[1:0]`、`be`、word index |
| 程序结束不了 | 裸机程序没有 OS 返回点 | 用死循环、tohost 或 testbench 超时 |

## 第11章 相关文档

| 文档 | 关系 |
|---|---|
| `0820 RISC-V最小教学核设计流程与方案.md` | 本系列总纲，说明为什么把工具命令集中放到 0826 |
| `0821 RV32I最小教学核指令集、编码与译码参考.md` | 写裸机程序前确认第一版支持哪些真实指令 |
| `0822 最小教学核工程目录、顶层接口与命名约定.md` | 后续统一目录和模块命名 |
| `0827 Testbench、commit trace与测试集组织.md` | 后续系统化组织测试和 pass/fail |
| `0828 波形debug、常见bug与定位清单.md` | 后续把本文第10章的问题展开成 debug 手册 |
