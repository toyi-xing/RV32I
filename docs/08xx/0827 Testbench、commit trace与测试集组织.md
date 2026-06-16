# 0827 Testbench、commit trace 与测试集组织

> 文档编号：0827  
> 所属系列：082x RISC-V 最小教学核项目实践  
> 文档定位：定义第一版 RV32I 教学核的 testbench 结构、pass/fail 机制、commit trace 和 directed test 组织方式  
> 前置文档：`0822 最小教学核工程目录、顶层接口与命名约定.md`、`0825 Hazard控制：forwarding、stall、flush与kill.md`、`0826 裸机程序、ROM与RAM加载与工具链使用示例.md`

本文解决的是“怎么证明教学核真的跑对了”。第一版不要只靠看波形，也不要只跑一个 smoke test。最低目标是：每个关键功能都有 directed test，testbench 能自动判断 pass/fail，出错时能通过 commit trace 定位到第一条错误提交。

本文默认项目假设：

| 项目 | 假设 |
|---|---|
| DUT | 当前维护路径为五级流水 `core_pipeline5`；早期单周期顶层只作为历史阶段 |
| imem | `$readmemh` 加载 32 bit word `.mem` |
| dmem | testbench 可观察内部 memory 或 store 事件 |
| pass/fail | 当前实现采用固定 `TEST_STATUS_ADDR` store 检查 |
| trace | 第一版以 WB 阶段 valid 指令作为 commit |
| 测试类型 | directed test 优先，后续再加随机/参考模型 |

当前实现状态：

| 项目 | 当前状态 |
|---|---|
| PASS/FAIL | 已实现，程序写 `DMEM_BASE + 0x100`，写 1 为 PASS，其他值为 FAIL |
| timeout | 已实现，超过固定周期未结束则打印 TIMEOUT |
| commit trace | 已实现，当前五级流水 testbench 打印提交 PC、指令 ID、原始指令和写回信息 |
| DMEM/stack 统计 | 已实现，仿真结束时打印运行期 DMEM 访问范围和最大栈深 |
| directed test 编号分组 | 已实现，测试文件使用四位编号前缀，脚本支持四位编号或完整 basename |
| scoreboard / reference model / ISS | 选择实现，可暂时不用；当前 directed self-check + commit trace 已满足 v2.0 教学核验证 |
| unsupported / illegal / misaligned 测试 | 选择实现，可暂时不用；当前 v2.0 假设程序只使用合法指令且访存对齐 |
| SystemVerilog assertion / coverage | 选择实现，可暂时不用；后续验证收口或加 CSR/trap 时再系统补 |

## 第1章 testbench 顶层结构

### 1.1 基本结构

```text
tb_core
    ├── clock/reset 产生
    ├── simple_rom/imem
    ├── simple_ram/dmem
    ├── core_top DUT
    ├── imem 加载
    ├── pass/fail 检查
    ├── commit trace monitor
    └── timeout watchdog
```

testbench 的职责是搭环境和检查结果，不是替 CPU 执行指令。

### 1.2 顶层连接

```systemverilog
core_top u_core (
    .clk_i              (clk),
    .rst_n_i            (rst_n),

    .imem_addr_o        (imem_addr),
    .imem_rdata_i       (imem_rdata),

    .dmem_we_o          (dmem_we),
    .dmem_be_o          (dmem_be),
    .dmem_addr_o        (dmem_addr),
    .dmem_wdata_o       (dmem_wdata),
    .dmem_rdata_i       (dmem_rdata),

    .commit_valid_o     (commit_valid),
    .commit_pc_o        (commit_pc),
    .commit_instr_o     (commit_instr),
    .commit_reg_we_o    (commit_reg_we),
    .commit_rd_o        (commit_rd),
    .commit_rd_wdata_o  (commit_rd_wdata)
);
```

`commit_*` 信号不是 ISA 必需接口，但对教学项目非常有价值。

## 第2章 pass/fail 机制

### 2.1 固定 cycle 后检查 dmem

最简单方式：

```systemverilog
initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    repeat (200) @(posedge clk);

    if (u_dmem.mem[0] == 32'd7) begin
        $display("PASS");
    end else begin
        $display("FAIL: dmem[0] = %08h", u_dmem.mem[0]);
    end

    $finish;
end
```

优点是简单；缺点是每个测试要写不同检查逻辑，且程序提前失败时不一定能马上停。

### 2.2 TEST_STATUS_ADDR 地址

更通用的方式是约定一个 dmem 地址作为测试结束状态：

| 地址 | 含义 |
|---|---|
| `0x0001_0100` | 程序写 1 表示 pass，写其他值表示 fail |

testbench 观察 store：

```systemverilog
localparam logic [31:0] TEST_STATUS_ADDR = 32'h0001_0100;

always_ff @(posedge clk) begin
    if (rst_n && dmem_we && (dmem_addr == TEST_STATUS_ADDR)) begin
        if (dmem_wdata == 32'd1) begin
            $display("PASS");
        end else begin
            $display("FAIL: status = %08h", dmem_wdata);
        end
        $finish;
    end
end
```

为了和本文 DMEM_BASE `0x0001_0000` 保持一致，推荐把 `TEST_STATUS_ADDR` 放在数据区起始处附近，例如：

| 地址 | 用途 |
|---|---|
| `0x0001_0000` | 普通测试结果 word0 |
| `0x0001_0004` | 普通测试结果 word1 |
| `0x0001_0100` | `TEST_STATUS_ADDR` |

汇编中写 `0x0001_0100`：

```asm
    lui  x31, 0x10
    addi x30, x0, 1
    sw   x30, 0x100(x31)
```

### 2.3 timeout 必须有

任何自动化仿真都要有 timeout：

```systemverilog
initial begin
    repeat (5000) @(posedge clk);
    $display("FAIL: timeout");
    $finish;
end
```

否则 PC 卡死、程序没写 `TEST_STATUS_ADDR`、flush 出错等情况会让回归一直挂着。

## 第3章 commit trace

### 3.1 trace 格式

建议每条提交指令打印一行：

```text
cycle pc        instr     rd  wdata     mem_we mem_addr  mem_wdata
12    00000000  00300093  01  00000003  0      --------  --------
13    00000004  00400113  02  00000004  0      --------  --------
14    00000008  002081b3  03  00000007  0      --------  --------
15    00000010  00322023  --  --------  1      00010000  00000007
```

第一版可以把 GPR 写回和 store 事件分开打印，也可以打印在同一行。关键是能定位：

- 哪个 cycle。
- 哪个 PC。
- 哪条 instruction。
- 写了哪个 rd，写入什么值。
- 是否 store，store 地址和值是什么。

### 3.2 trace monitor 示例

```systemverilog
integer trace_fd;

initial begin
    trace_fd = $fopen("build/commit.trace", "w");
end

always_ff @(posedge clk) begin
    if (rst_n && commit_valid) begin
        $fwrite(trace_fd, "%0t %08h %08h", $time, commit_pc, commit_instr);

        if (commit_reg_we) begin
            $fwrite(trace_fd, " x%0d %08h", commit_rd, commit_rd_wdata);
        end else begin
            $fwrite(trace_fd, " -- --------");
        end

        $fwrite(trace_fd, "\n");
    end
end
```

store trace 可以在 dmem monitor 里另写：

```systemverilog
always_ff @(posedge clk) begin
    if (rst_n && dmem_we) begin
        $display("STORE addr=%08h be=%b wdata=%08h", dmem_addr, dmem_be, dmem_wdata);
    end
end
```

### 3.3 commit 定义

第一版可以简单定义：

| 事件 | commit 定义 |
|---|---|
| ALU/load/JAL/LUI | WB 阶段 valid |
| store | MEM 阶段 dmem 写发生 |
| branch | WB 阶段 valid，也可只记录 PC/instr |
| bubble/flush | 不 commit |

后续加入异常、中断、可变延迟 memory 后，commit 定义要更严格，不能简单等同于 WB valid。

## 第4章 DMEM/stack 运行时统计

除 PASS/FAIL 和 commit trace 之外，testbench 还可以在仿真结束时打印本次程序的 DMEM 访问范围和最大栈深：

```text
PASS after 3652 cycles
DMEM access range: 0x00010200 - 0x00010ffc
Stack max used:    80 bytes
```

当前五级流水 testbench 采用以下统计口径：

| 统计项 | 统计方法 | 说明 |
|---|---|---|
| `DMEM access range` | 监控 `dmem_re || dmem_we`，记录 `dmem_addr` 最小值和最大值 | 用来快速判断程序是否访问到预期数据区、栈区或越界地址 |
| `Stack max used` | 通过层级路径读取 `u_core.u_regfile.gpr_q[2]`，记录 `sp/x2` 的最小值 | 栈向低地址增长，所以 `STACK_TOP - min(sp)` 就是运行期间看到的最大栈深 |

注意：DMEM 地址范围和**真正“用了多少 RAM”**不是完全等价的，因为程序可能访问了高地址和低地址，中间未必全用；而栈深度用 `min(sp)` 统计通常最有价值。

还有两个实现细节：

- `TEST_STATUS_ADDR = DMEM_BASE + 0x100` 是 testbench 的结束标志地址，不计入程序自身的 DMEM 访问范围，否则所有测试的最低访问地址都会被 PASS/FAIL 写状态字污染。
- 汇编测试通常不初始化 `sp`，这时栈统计会打印 `SP not initialized to stack top`；C 测试由 `crt0.S` 初始化 `sp = __stack_top`，所以更适合观察栈深。

## 第5章 directed test 组织

### 5.1 测试命名

建议测试按功能分组：

```text
sw/asm/
    0001_smoke.S
    0101_branch.S
    0102_alu_imm.S
    0103_alu_reg.S
    0104_load_store.S
    0105_jump.S
    0106_u_type.S
    0301_pipeline5_nofwd_noredirect.S
    0302_pipeline5_fwd_noredirect.S
    0303_pipeline5_fwd_redirect.S

sw/c/
    0201_c_smoke.c
    0202_dmem_init.c
    0401_control_mix.c
```

当前使用四位编号：前两位表示测试部分，后两位表示该部分内的测试序号。脚本支持两种参数形式：

```bash
sim/pipeline5_asm/run_test.sh 0102
sim/pipeline5_asm/run_test.sh 0102_alu_imm
```

编号能保证回归输出稳定排序，也能让单个测试命令更短。

### 5.2 每个测试只证明少数事情

| 测试 | 不要混入 |
|---|---|
| `addi` | branch、load-use、复杂函数调用 |
| `load_ext` | branch flush |
| `forward_exmem` | JALR、store byte enable |
| `branch_flush_store` | 大量无关 ALU 运算 |

测试短，失败时才容易定位。

当前仓库里有些文件为了减少数量，会把一组相关指令或一组流水线场景合在一起，例如 `0102_alu_imm.S` 覆盖全部 I-type ALU，`0302_pipeline5_fwd_noredirect.S` 覆盖多类 data hazard。这个选择对当前教学阶段是可以接受的；如果后续要做更严格 regression，可再拆成更细的 directed test。

### 5.3 汇编测试模板

```asm
.option norvc
.section .text.init
.global _start

_start:
    # test body
    addi x1, x0, 3
    addi x2, x0, 4
    add  x3, x1, x2

    # write result
    lui  x10, 0x10
    sw   x3, 0(x10)

    # pass
    addi x30, x0, 1
    sw   x30, 0x100(x10)

done:
    jal  x0, done
```

实际测试里可以把写 pass/fail 的代码做成宏，但初期先展开写清楚更直观。

## 第6章 scoreboard 和参考模型

### 6.1 第一版 scoreboard 可以很简单

当前 v2.0 没有实现独立 scoreboard 类或参考模型。现在采用的是“程序自检 + testbench 观察状态地址 + commit trace 辅助 debug”：

| 检查对象 | 当前实现 |
|---|---|
| pass/fail | 已实现，观察 `TEST_STATUS_ADDR` |
| dmem 结果 | 主要由测试程序自己 load 后比较；testbench 只统计访问范围 |
| commit trace | 已实现打印，但尚未自动和 expected trace 比较 |

这个强度足够支撑当前合法 RV32I + 对齐访存的教学核验证。它不能替代 reference model；如果后续加入随机测试、CSR/trap、非法指令、不对齐访问、可变延迟 memory 或外设 MMIO，再补 scoreboard/reference model 更合适。

最简单 scoreboard：

| 检查对象 | 方法 |
|---|---|
| pass/fail | 观察 `TEST_STATUS_ADDR` |
| dmem 结果 | 仿真结束检查指定地址 |
| commit trace | 与预期文本比较 |

不必一开始写复杂 UVM。第一版 CPU 项目里，清晰的 directed test + commit trace 已经很有价值。

### 6.2 自写简单 reference model

选择实现，可暂时不用。

可以写一个很小的 Python 模型，只支持当前指令子集：

```text
读取 .mem 指令
维护 pc、gpr、dmem
每次执行一条指令
输出 commit trace
```

再和 RTL trace 比较：

```text
RTL trace:  cycle pc instr rd wdata
REF trace:        pc instr rd wdata
```

比较时通常忽略 cycle，因为流水线和单周期模型的 cycle 不同；重点比较提交顺序和架构结果。

### 6.3 使用 ISS

选择实现，可暂时不用。

后期可以接 Spike、Sail 或其他 RISC-V ISS。但第一版有两个注意点：

| 注意点 | 说明 |
|---|---|
| 支持范围 | ISS 默认完整架构，教学核可能不支持 CSR/trap |
| 环境约定 | `TEST_STATUS_ADDR`、链接脚本、memory map 要匹配 |

所以前期更实用的是先自写小参考模型或手写 expected trace。

## 第7章 回归脚本思路

### 7.1 单测试流程

每个测试大致流程：

```text
test.S
  ↓ gcc 生成 test.elf
  ↓ objdump 生成 test.dump
  ↓ objcopy + bin2mem32 生成 test.mem
  ↓ 运行 RTL 仿真 +imem=test.mem
  ↓ 检查 PASS/FAIL 和 trace
```

命令细节见 `0826`。本篇只强调组织方式。

当前仓库的单测试脚本支持四位编号或完整 basename：

```bash
sim/pipeline5_asm/run_test.sh 0102
sim/pipeline5_asm/run_test.sh 0102_alu_imm
sim/pipeline5_c/run_test.sh 0401
```

`run_all.sh` 不扫描目录自动运行所有测试，而是维护阶段专属列表。这样基础 RV32I 回归、流水线 hazard 回归和后续 CSR/trap 回归可以有不同范围。

### 7.2 回归输出

建议回归输出简洁：

```text
[PASS] 0001_smoke
[PASS] 0102_alu_imm
[FAIL] 0302_pipeline5_fwd_noredirect
       see build/0302_pipeline5_fwd_noredirect/wave.vcd
       see build/0302_pipeline5_fwd_noredirect/commit.trace
```

失败时要保留：

- ELF。
- dump。
- mem。
- trace。
- wave。
- 仿真 log。

这样才能复现。

## 第8章 最小覆盖清单

### 8.1 ISA 功能

| 类别 | 至少覆盖 |
|---|---|
| U-type | `LUI`、`AUIPC` |
| I-type ALU | 每个 funct3，shift immediate 的两种 funct7 |
| R-type ALU | 每个 funct3/funct7 |
| load | `LB/LH/LW/LBU/LHU` |
| store | `SB/SH/SW` |
| branch | taken/not-taken，signed/unsigned |
| jump | `JAL/JALR`，`rd=x0` 和 `rd!=x0` |
| unsupported | 非法 opcode 或未支持系统指令，选择实现，可暂时不用 |

### 8.2 pipeline hazard

| 类别 | 至少覆盖 |
|---|---|
| EX/MEM forwarding | rs1、rs2 |
| MEM/WB forwarding | rs1、rs2 |
| 优先级 | 两个后级同时匹配 |
| load-use | rs1、rs2、store data |
| branch forwarding | branch 操作数来自前一条 |
| store data forwarding | store 数据来自前一条 |
| flush | wrong-path GPR write、wrong-path store |

### 8.3 基础断言

选择实现，可暂时不用。当前 v2.0 主要靠 directed test 自检和 commit trace；后续做更系统验证时再补断言和覆盖率。

可以在 testbench 或 RTL 中加：

```systemverilog
assert property (@(posedge clk) disable iff (!rst_n)
    !(commit_valid && commit_reg_we && (commit_rd == 5'd0)));
```

如果 RTL 内部能观察 GPR，也可以断言：

```systemverilog
assert property (@(posedge clk) disable iff (!rst_n)
    (u_core.u_regfile.gpr[0] == 32'b0));
```

断言要少而准，先盯不变量。

## 第9章 常见测试误区

| 误区 | 后果 |
|---|---|
| 只跑一个大程序 | 失败后不知道哪类功能错 |
| 只看最终 memory | 不知道第一条错误指令 |
| 不保存 objdump | 不知道工具链实际生成了什么指令 |
| 没有 timeout | 回归可能挂死 |
| pass/fail 地址和 dmem map 不一致 | 程序写了，但 testbench 看错地址 |
| 测试里用了未支持指令 | 误以为 CPU 错，其实编译产物超出范围 |
| 没测 wrong-path store | flush bug 可能长期隐藏 |

## 第10章 相关文档

| 文档 | 关系 |
|---|---|
| `0825 Hazard控制：forwarding、stall、flush与kill.md` | 本文测试清单的重要来源 |
| `0826 裸机程序、ROM与RAM加载与工具链使用示例.md` | 编译和加载测试程序 |
| `0828 波形debug、常见bug与定位清单.md` | 回归失败后的定位手册 |
| `0829 综合、FPGA上板与SoC扩展方向.md` | 后续将仿真测试扩展到综合/上板 |
