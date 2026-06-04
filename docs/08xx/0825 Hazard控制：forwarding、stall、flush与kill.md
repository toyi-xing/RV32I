# 0825 Hazard 控制：forwarding、stall、flush 与 kill

> 文档编号：0825  
> 所属系列：082x RISC-V 最小教学核项目实践  
> 文档定位：定义第一版 RV32I 五级流水线教学核中的 forwarding、stall、bubble、flush、kill 控制条件和优先级  
> 前置文档：`0802 RISC-V五级流水线与Hazard.md`、`0822 最小教学核工程目录、顶层接口与命名约定.md`、`0824 数据通路、流水线寄存器与控制信号参考.md`

本文是控制条件手册。它不重新解释五级流水线原理，而是把第一版教学核里最容易写错的 hazard 控制拆成可实现规则。

本文默认项目假设：

| 项目 | 假设 |
|---|---|
| pipeline | IF、ID、EX、MEM、WB |
| branch 决策 | EX 阶段 |
| memory | 第一版固定响应，无 wait state |
| forwarding 来源 | EX/MEM、MEM/WB |
| load-use | 通过冻结 PC/IFID，向 IDEX 插 bubble 解决 |
| wrong-path | 通过 flush/kill 清 valid，副作用由 valid gating 屏蔽 |

## 第1章 本篇使用的控制动作

### 1.1 四个动作不要混用

| 动作 | 含义 | 典型对象 |
|---|---|---|
| forwarding | 不等 GPR 写回，直接从后级结果送到 EX 操作数 | ALU 输入、branch 比较输入、store data |
| stall | 某级寄存器保持不变 | PC、IF/ID |
| bubble | 向后级插入一个 invalid 空槽 | ID/EX |
| flush/kill | 清掉错路径年轻指令，使其不能产生副作用 | IF/ID、ID/EX |

`stall` 是保持，`bubble` 是插入空槽，`flush/kill` 是杀掉错误路径。RTL 里不要用一个信号同时表达这些动作。

### 1.2 推荐控制信号

沿用 `0822/0824` 的命名：

| 信号 | 动作 |
|---|---|
| `stall_if` | PC 保持，不取新路径顺序指令 |
| `stall_id` | IF/ID 保持，ID 当前指令不前进 |
| `bubble_ex` | ID/EX 写入 invalid bubble |
| `flush_if_id` | IF/ID valid 清 0 |
| `flush_id_ex` | ID/EX valid 清 0 |
| `redirect_valid` | EX 产生新 PC |
| `redirect_pc` | 新 PC |
| `fwd_a_sel` | EX 阶段 rs1 操作数选择 |
| `fwd_b_sel` | EX 阶段 rs2 操作数选择 |
| `store_fwd_sel` | store data 选择，可和 `fwd_b_sel` 共享 |

## 第2章 forwarding

### 2.1 forwarding 解决什么

forwarding 解决的是：前一条指令已经算出结果，但还没写回 GPR；后一条指令已经进入 EX，需要这个最新结果。

典型例子：

```asm
add  x3, x1, x2
sub  x4, x3, x5
```

`sub` 在 EX 阶段需要 `x3`，但 `add` 还没到 WB 写回。此时应从 EX/MEM 前递 `add` 的 ALU 结果。

### 2.2 forwarding 来源

第一版常用两个来源：

| 来源 | 适合前递的数据 | 注意 |
|---|---|---|
| EX/MEM | ALU 结果、`PC+4`、LUI 结果等已经在 EX 得到的数据 | load 在 EX/MEM 时还没有 load data，不能把地址当前递数据 |
| MEM/WB | 最终写回数据 `wb_rd_wdata` | ALU/load/JAL/LUI 都可以统一前递 |

推荐把 MEM/WB 的前递数据定义成最终写回数据：

```systemverilog
assign mem_wb_forward_data = wb_rd_wdata;
```

这样 `WB_ALU/WB_MEM/WB_PC4/WB_IMM` 都不用分开判断。

### 2.3 rs1/rs2 forwarding 条件

对 EX 阶段当前指令的 `rs1`：

```systemverilog
assign exmem_can_fwd =
    ex_mem_valid &&
    ex_mem_reg_we &&
    (ex_mem_rd_addr != 5'd0) &&
    !ex_mem_mem_re;

assign memwb_can_fwd =
    mem_wb_valid &&
    mem_wb_reg_we &&
    (mem_wb_rd_addr != 5'd0);

assign exmem_match_rs1 =
    exmem_can_fwd &&
    id_ex_uses_rs1 &&
    (ex_mem_rd_addr == id_ex_rs1_addr);

assign memwb_match_rs1 =
    memwb_can_fwd &&
    id_ex_uses_rs1 &&
    (mem_wb_rd_addr == id_ex_rs1_addr);
```

`rs2` 同理：

```systemverilog
assign exmem_match_rs2 =
    exmem_can_fwd &&
    id_ex_uses_rs2 &&
    (ex_mem_rd_addr == id_ex_rs2_addr);

assign memwb_match_rs2 =
    memwb_can_fwd &&
    id_ex_uses_rs2 &&
    (mem_wb_rd_addr == id_ex_rs2_addr);
```

注意 `!ex_mem_mem_re`：load 指令在 EX/MEM 阶段时，`ex_mem_alu_result` 是 load 地址，不是 load 数据。如果把它前递给下一条 ALU，会把地址当成数据。

### 2.4 forwarding 优先级

如果 EX/MEM 和 MEM/WB 同时匹配同一个源寄存器，选 EX/MEM，因为它更新。

```systemverilog
always_comb begin
    fwd_a_sel = FWD_GPR;

    if (exmem_match_rs1) begin
        fwd_a_sel = FWD_EXMEM;
    end else if (memwb_match_rs1) begin
        fwd_a_sel = FWD_MEMWB;
    end
end
```

典型例子：

```asm
addi x1, x0, 1
addi x1, x1, 1
add  x2, x1, x0
```

第三条 `add` 应该看到第二条 `addi` 产生的新 `x1`，不是第一条产生的旧 `x1`。

### 2.5 forwarding 数据选择

```systemverilog
always_comb begin
    unique case (fwd_a_sel)
        FWD_GPR:   ex_rs1_data = id_ex_rs1_rdata;
        FWD_EXMEM: ex_rs1_data = ex_mem_forward_data;
        FWD_MEMWB: ex_rs1_data = mem_wb_forward_data;
        default:   ex_rs1_data = id_ex_rs1_rdata;
    endcase
end
```

`ex_mem_forward_data` 要根据后级指令类型定义。第一版如果 `LUI/AUIPC/JAL` 的结果都已经在 EX 阶段形成，可以统一放在 `ex_mem_alu_result` 或一个专门的 `ex_mem_wb_data_pre` 中。关键是不能对 load 使用 EX/MEM 地址当数据。

### 2.6 branch 和 store 也需要 forwarding

branch 比较在 EX 阶段进行时，比较输入就是 EX 操作数，因此自然应使用 forwarding 后的数据：

```asm
add x1, x2, x3
beq x1, x0, target
```

store 的 `rs2` 是写入 memory 的数据，也可能来自前一条指令：

```asm
add x3, x1, x2
sw  x3, 0(x4)
```

因此 `ex_mem_store_data` 应保存 forwarding 后的 `rs2`，不要保存 ID 阶段读出的旧 `rs2`。

## 第3章 load-use stall

### 3.1 为什么 forwarding 不够

load 的数据不是 EX 阶段 ALU 算出的结果，而是 MEM 阶段从 data memory 返回的结果。

```asm
lw  x3, 0(x1)
add x4, x3, x5
```

当 `add` 下一拍进入 EX 时，`lw` 还在 MEM 阶段读 memory，数据还没稳定到 MEM/WB。因此这类紧邻使用必须 stall 一拍。

### 3.2 检测条件

load-use 在 ID 阶段检测比较自然：当前 ID 指令要读的寄存器，等于 ID/EX 中 load 的 `rd`。

```systemverilog
assign load_use_rs1 =
    if_id_valid_q &&
    id_uses_rs1 &&
    id_ex_valid &&
    id_ex_mem_re &&
    (id_ex_rd_addr != 5'd0) &&
    (id_ex_rd_addr == id_rs1_addr);

assign load_use_rs2 =
    if_id_valid_q &&
    id_uses_rs2 &&
    id_ex_valid &&
    id_ex_mem_re &&
    (id_ex_rd_addr != 5'd0) &&
    (id_ex_rd_addr == id_rs2_addr);

assign load_use_stall = load_use_rs1 || load_use_rs2;
```

`id_uses_rs1/id_uses_rs2` 必须来自 decoder。不要只看 instruction 的 bit 字段，否则 `LUI/JAL` 等不读寄存器的指令可能产生假 stall。

### 3.3 控制动作

检测到 load-use：

| 目标 | 动作 | 原因 |
|---|---|---|
| PC/IF | `stall_if = 1` | 不取下一条新指令 |
| IF/ID | `stall_id = 1` | 当前使用者指令留在 ID |
| ID/EX | `bubble_ex = 1` | 让 EX 下一拍空一拍 |
| EX/MEM | 正常前进 | load 继续去 MEM 读数据 |
| MEM/WB | 正常前进 | load 数据下一拍进入 WB |

时序效果：

```text
cycle N:     lw 在 EX，add 在 ID，检测到 load-use
cycle N+1:   lw 在 MEM，ID/EX 是 bubble，add 仍在 ID
cycle N+2:   lw 在 WB，add 进入 EX，从 MEM/WB forwarding 获得 load data
```

这里“LW 继续从 EX 进入 MEM，再进入 WB”不需要额外控制，它是因为 EX/MEM 和 MEM/WB 没有被 stall；“ADD 下一拍进入 EX”是因为 load-use stall 只持续一拍，下一拍条件解除，IF/ID 正常流入 ID/EX。

### 3.4 load-use 常见错误

| 错误 | 现象 |
|---|---|
| 只停 PC，不停 IF/ID | 使用者指令丢失或重复错乱 |
| 只停 IF/ID，不插 bubble | load 和使用者同时挤在 EX，时序不对 |
| 把 EX/MEM 也停住 | load 不去 MEM，stall 可能无法解除 |
| 没排除 `rd=x0` | `lw x0,...` 后的指令被误停 |
| 没用 `uses_rs1/uses_rs2` | `LUI/JAL` 等产生假相关 |

## 第4章 control hazard 与 flush/kill

### 4.1 EX 决策 branch 的代价

第一版 branch/JAL/JALR 在 EX 阶段得到最终 redirect：

| 指令 | EX 阶段做什么 |
|---|---|
| branch | 比较 `rs1/rs2`，taken 时 `redirect_pc = pc + immB` |
| JAL | `redirect_pc = pc + immJ`，写回 `PC+4` |
| JALR | `redirect_pc = (rs1 + immI) & ~1`，写回 `PC+4` |

当 EX 发现要跳转时，IF 和 ID 中已经有旧路径上的年轻指令。这些指令必须被 flush/kill。

### 4.2 redirect 条件

```systemverilog
assign branch_taken =
    id_ex_valid &&
    (id_ex_branch_op != BR_NONE) &&
    branch_condition_met;

assign jump_taken =
    id_ex_valid &&
    id_ex_jump;

assign redirect_valid = branch_taken || jump_taken;

assign redirect_pc =
    id_ex_jalr ? ((ex_rs1_data + id_ex_imm) & 32'hffff_fffe) :
    id_ex_jump ? (id_ex_pc + id_ex_imm) :
                 (id_ex_pc + id_ex_imm);
```

对 branch 和 JAL，上式 target 都是 `pc + imm`；对 JALR，是 `rs1 + imm` 后清 bit0。实际 RTL 可以写得更清晰。

### 4.3 flush 动作

EX 阶段 redirect 时，常见动作：

| 目标 | 动作 |
|---|---|
| PC | 下一拍改成 `redirect_pc` |
| IF/ID | `flush_if_id = 1` |
| ID/EX | 通常 `flush_id_ex = 1` 或让当前 EX 指令继续、清 younger 槽 |
| EX/MEM | 当前 branch/jump 自己继续向后提交 |

如果 branch 当前在 EX，那么 ID/EX 中保存的就是 branch 自己，不能把“当前正在 EX 的 branch”误杀掉。具体实现上，`flush_id_ex` 通常作用于下一拍即将写入 ID/EX 的内容，使 ID 阶段旧路径年轻指令不能进入 EX；而 EX/MEM 仍接收当前 branch 的信息。

更直观地说：

```text
正在 EX 的 branch/jump：保留，它是正确路径上较老指令
IF/ID 中的年轻指令：kill
ID 阶段准备进入 EX 的年轻指令：kill/bubble
```

### 4.4 kill 的本质是 valid 清零

kill 不一定意味着把所有数据位清零，关键是 `valid=0`。被 kill 的指令即使波形上还带着原始 `instr`，也不能：

- 写 GPR。
- 写 dmem。
- 打印 commit。
- 触发后续异常提交。

因此副作用必须写成：

```systemverilog
assign dmem_we_o = ex_mem_valid && ex_mem_mem_we;

assign wb_gpr_we =
    mem_wb_valid &&
    mem_wb_reg_we &&
    (mem_wb_rd_addr != 5'd0);
```

## 第5章 structural hazard 在第一版中的处理

第一版采用分离 imem/dmem，GPR 两读一写，ALU 单条指令独占，因此结构冒险很少。

| 资源 | 第一版假设 | 是否需要 stall |
|---|---|---|
| imem/dmem | 分离 | 不需要处理取指/访存冲突 |
| GPR | 2 read + 1 write | 不需要为普通 `rs1/rs2/rd` 冲突 stall |
| ALU | 单发射，每拍最多一条 EX 指令 | 不需要 ALU 仲裁 |
| MDU | 第一版无乘除法 | 不需要多周期 busy stall |
| dmem | 固定响应 | 不需要 memory wait stall |

后续若加入单端口统一 memory、多周期乘除法、valid-ready 总线或 cache miss，structural hazard 会重新出现，进入 `0829` 或扩展文档范围。

## 第6章 控制优先级

### 6.1 第一版推荐优先级

在固定响应 memory 的第一版中，常见事件优先级：

```text
reset > redirect/flush > load-use stall > normal advance
```

含义：

| 优先级 | 事件 | 原因 |
|---|---|---|
| 1 | reset | 清空所有状态 |
| 2 | redirect/flush | 一旦确定 PC 要跳转，旧路径年轻指令必须被 kill |
| 3 | load-use stall | 正确路径上的数据等待 |
| 4 | normal | 正常流动 |

如果同一拍同时出现 redirect 和 load-use，通常 redirect 优先，因为 load-use 可能来自即将被 kill 的旧路径年轻指令。具体设计要保证不会把 wrong-path 的 stall 留下来阻止正确 redirect。

### 6.2 组合控制汇总示例

示意写法：

```systemverilog
always_comb begin
    stall_if    = 1'b0;
    stall_id    = 1'b0;
    bubble_ex   = 1'b0;
    flush_if_id = 1'b0;
    flush_id_ex = 1'b0;

    if (redirect_valid) begin
        flush_if_id = 1'b1;
        flush_id_ex = 1'b1;
    end else if (load_use_stall) begin
        stall_if  = 1'b1;
        stall_id  = 1'b1;
        bubble_ex = 1'b1;
    end
end
```

这只是第一版固定 memory 的简化逻辑。后续加 memory wait 时，还要考虑 MEM 阶段向前级施加 backpressure。

## 第7章 最小测试清单

### 7.1 forwarding 测试

| 测试 | 示例 | 目标 |
|---|---|---|
| EX/MEM -> rs1 | `add x3,x1,x2; sub x4,x3,x5` | rs1 前递 |
| EX/MEM -> rs2 | `add x3,x1,x2; sub x4,x5,x3` | rs2 前递 |
| MEM/WB -> rs1 | 中间隔一条无关指令 | MEM/WB 前递 |
| 双来源优先级 | 连续写同一 rd | EX/MEM 优先 |
| rd=x0 | `add x0,x1,x2; add x3,x0,x4` | 不从 x0 前递 |
| branch operand | `add x1,x2,x3; beq x1,x0,L` | branch 比较前递 |
| store data | `add x3,x1,x2; sw x3,0(x4)` | store 写数据前递 |

### 7.2 load-use 测试

| 测试 | 示例 | 目标 |
|---|---|---|
| 紧邻 rs1 | `lw x3,0(x1); add x4,x3,x5` | 停一拍 |
| 紧邻 rs2 | `lw x3,0(x1); add x4,x5,x3` | 停一拍 |
| store data 紧邻 | `lw x3,0(x1); sw x3,0(x2)` | store data 使用 load 值 |
| 隔一条使用 | `lw; nop; add` | 不应额外 stall |
| load rd=x0 | `lw x0,0(x1); add x2,x0,x3` | 不应 stall |

### 7.3 flush/kill 测试

| 测试 | 示例 | 目标 |
|---|---|---|
| taken branch 后写 GPR | branch 后放 `addi x5,...` | `x5` 不应被写 |
| taken branch 后 store | branch 后放 `sw` | dmem 不应被写 |
| not-taken branch | 普通顺序执行 | 不应误 flush |
| JAL | 跳转后旧路径指令无副作用 | `rd=PC+4` 正确 |
| JALR | 目标由寄存器决定 | bit0 清零，旧路径 kill |

## 第8章 常见 bug

| bug | 典型现象 | 根因 |
|---|---|---|
| forwarding 未排除 load | `lw; add` 得到地址而不是数据 | EX/MEM load 地址被当前递数据 |
| forwarding 未排除 x0 | 读 x0 变成非 0 | `rd=0` 仍参与匹配 |
| MEM/WB 前递不是最终 wb 数据 | JAL/load 前递错误 | 没统一用 `wb_rd_wdata` |
| load-use 只停一部分 | 指令丢失或重复执行 | stall/bubble 动作不完整 |
| redirect 被 stall 阻塞 | taken branch 后继续取旧路径 | 优先级错 |
| flush 只清 IF/ID | ID/EX 旧路径指令继续执行 | kill 范围不够 |
| wrong-path store 写入 | dmem 被错误修改 | `dmem_we` 没 valid gating |
| commit trace 打印 bubble | trace 多出奇怪指令 | `commit_valid` 没用 valid |

## 第9章 相关文档

| 文档 | 关系 |
|---|---|
| `0802 RISC-V五级流水线与Hazard.md` | 原理解释和背景 |
| `0822 最小教学核工程目录、顶层接口与命名约定.md` | 本文沿用的控制信号命名 |
| `0824 数据通路、流水线寄存器与控制信号参考.md` | 本文依赖的 pipeline register 字段 |
| `0827 Testbench、commit trace与测试集组织.md` | 后续把本文测试清单变成可运行回归 |
| `0828 波形debug、常见bug与定位清单.md` | 后续从波形角度定位本文这些 bug |

