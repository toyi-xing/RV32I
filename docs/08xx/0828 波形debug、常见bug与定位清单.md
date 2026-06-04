# 0828 波形 debug、常见 bug 与定位清单

> 文档编号：0828  
> 所属系列：082x RISC-V 最小教学核项目实践  
> 文档定位：汇总第一版 RV32I 五级流水线教学核的常见错误现象、波形观察顺序和定位方法  
> 前置文档：`0824 数据通路、流水线寄存器与控制信号参考.md`、`0825 Hazard控制：forwarding、stall、flush与kill.md`、`0827 Testbench、commit trace与测试集组织.md`

本文是 debug checklist。目标不是讲新原理，而是当测试失败时，能按步骤缩小问题范围。

本文默认你已经有：

| 工具/信息 | 作用 |
|---|---|
| `objdump` | 知道程序实际指令和地址 |
| commit trace | 知道第一条错误提交 |
| waveform | 观察 PC、valid、stall、flush、forwarding、GPR 写回 |
| directed test | 测试足够短，失败点明确 |

## 第1章 总体定位顺序

### 1.1 先找第一条错误提交

不要从波形第一拍开始盲看。先看：

```text
expected trace:
pc=00000008 instr=002081b3 rd=x3 wdata=00000007

rtl trace:
pc=00000008 instr=002081b3 rd=x3 wdata=00000003
```

第一条错误提交告诉你：

| 信息 | 说明 |
|---|---|
| PC | 哪条指令错 |
| instr | 工具链实际生成的编码 |
| rd/wdata | 写回错在哪里 |
| 是否 store | memory 副作用是否错 |

然后再回到波形看这条指令在 ID/EX/MEM/WB 每级经历了什么。

### 1.2 按问题类型分流

| 现象 | 优先看 |
|---|---|
| PC 从第一条就错 | reset PC、imem 加载、链接地址 |
| 指令编码不符合预期 | `.mem` 端序、objdump、imem 索引 |
| 单条 ALU 结果错 | decoder、imm_gen、ALU op、GPR 读值 |
| 连续相关才错 | forwarding、load-use stall |
| branch 后错 | branch compare、target、flush/kill |
| store 错 | store data forwarding、byte enable、dmem 地址映射 |
| load 错 | dmem rdata、地址低位、符号/零扩展 |
| 偶发多提交/少提交 | valid、stall、bubble、flush 优先级 |

## 第2章 必看波形信号

### 2.1 取指和 PC

| 信号 | 看什么 |
|---|---|
| `pc_q` 或 `if_pc` | 是否从 reset PC 开始，是否按 4 递增 |
| `imem_addr_o` | 是否等于当前取指 PC |
| `imem_rdata_i` | 是否等于 `.mem` 对应行 |
| `redirect_valid` | branch/jump 时是否拉高 |
| `redirect_pc` | target 是否正确 |
| `stall_if` | PC 是否因 load-use 被保持 |

### 2.2 pipeline valid

| 信号 | 看什么 |
|---|---|
| `if_id_valid` | reset/flush 后是否清 0 |
| `id_ex_valid` | load-use bubble 是否出现 |
| `ex_mem_valid` | invalid 是否继续产生副作用 |
| `mem_wb_valid` | commit 是否只来自 valid 指令 |

valid 是 debug 的主线。很多 bug 的本质是“这个槽已经不是有效指令，但仍然做了事”。

### 2.3 decode 和操作数

| 信号 | 看什么 |
|---|---|
| `id_rs1_addr/id_rs2_addr/id_rd_addr` | 字段提取是否正确 |
| `id_uses_rs1/id_uses_rs2` | 是否把 LUI/JAL 误认为读寄存器 |
| `id_imm` | 立即数拼接和符号扩展是否正确 |
| `id_reg_we/id_mem_we/id_wb_sel` | 控制信号是否符合指令 |
| `id_ex_rs1_rdata/id_ex_rs2_rdata` | GPR 读值是否正确 |

### 2.4 EX 和 forwarding

| 信号 | 看什么 |
|---|---|
| `fwd_a_sel/fwd_b_sel` | 是否选择了正确来源 |
| `ex_rs1_data/ex_rs2_data` | forwarding 后值是否正确 |
| `ex_mem_rd_addr/mem_wb_rd_addr` | 是否匹配当前 rs |
| `ex_mem_reg_we/mem_wb_reg_we` | 后级是否真的写 GPR |
| `ex_mem_mem_re` | load 是否被禁止从 EX/MEM 前递 |
| `alu_result` | ALU 结果或地址是否正确 |

### 2.5 MEM/WB 和副作用

| 信号 | 看什么 |
|---|---|
| `dmem_we_o` | wrong-path store 是否被屏蔽 |
| `dmem_be_o` | `SB/SH/SW` lane 是否正确 |
| `dmem_addr_o` | 是否经过 DMEM_BASE 映射 |
| `dmem_wdata_o` | store data 是否已对齐 |
| `mem_wb_load_data` | load 扩展是否正确 |
| `wb_rd_wdata` | 最终写回选择是否正确 |
| `wb_gpr_we` | 是否同时满足 valid、reg_we、rd!=0 |

## 第3章 启动和程序加载问题

| 现象 | 可能原因 | 看什么 |
|---|---|---|
| PC 是 `x` | reset 没初始化、复位极性错 | `rst_n_i`、`pc_q` reset 分支 |
| 第一条指令全 0 | imem 没加载、路径错 | `$readmemh` log、`.mem` 文件 |
| 第一条指令 byte 反 | `.mem` 端序错 | objdump 编码 vs imem_rdata |
| PC 正确但取错行 | imem 索引位错 | `addr[AW+1:2]` |
| 程序跳到空地址 | 链接地址和 reset PC 不一致 | objdump `_start`、linker script |

快速检查：

```text
objdump 里 0x00000000 的指令
        是否等于
仿真第一拍 imem_rdata_i
```

如果不等，先别看 CPU，先修程序加载。

## 第4章 decoder 和 immediate 问题

| 现象 | 可能原因 | 看什么 |
|---|---|---|
| `LUI` 结果低 12 bit 不为 0 | U-imm 拼错 | `id_imm` |
| branch 跳到奇怪地址 | B-imm bit 拼接错或重复左移 | `id_imm`、`redirect_pc` |
| JAL 跳转偏移错 | J-imm 拼接错 | `id_imm` |
| `JALR` 目标奇数 | 没清 bit0 | `redirect_pc[0]` |
| `SLTIU` 结果错 | 立即数未先符号扩展 | `id_imm`、比较输入 |
| shift immediate 错 | shamt 位宽或 funct7 检查错 | `instr[24:20]`、`funct7` |

B/J immediate 已经在 `imm_gen` 补了最低 `0` 后，target 计算不要再左移。

## 第5章 GPR 和 x0 问题

| 现象 | 可能原因 | 看什么 |
|---|---|---|
| 读 x0 不是 0 | regfile 读口没特殊处理或写入 x0 | `rs*_addr`、`rs*_rdata` |
| 写 x0 后影响后续 | 写端没屏蔽 `rd=0` | `wb_gpr_we` |
| forwarding 让 x0 非 0 | forwarding 匹配没排除 `rd=0` | `ex_mem_rd_addr`、`fwd_sel` |
| 同拍读写不符合预期 | regfile 写读时序未定义 | 同拍 `we/rd/rs/rdata` |

建议 regfile 保证：

```text
写 rd=0 被丢弃
读 rs=0 返回 0
```

同拍写读同一非零寄存器的语义要在项目中明确；五级流水中通常依赖 WB 写和 ID 读的时序或显式 bypass。

## 第6章 forwarding 问题

| 现象 | 可能原因 | 看什么 |
|---|---|---|
| `add; sub` 相关错 | EX/MEM forwarding 没触发 | `exmem_match_rs*` |
| 隔一条相关错 | MEM/WB forwarding 没触发 | `memwb_match_rs*` |
| 连续写同一 rd 用旧值 | 优先级错 | EX/MEM 是否优先 MEM/WB |
| `lw; add` 得到地址 | EX/MEM load 被错误前递 | `ex_mem_mem_re` |
| branch 判断错 | branch 操作数没 forwarding | branch compare 输入 |
| store 写旧值 | store data 没 forwarding | `ex_mem_store_data` |

定位时先看 forwarding 选择，再看被选择的数据源是否正确。

## 第7章 load-use 问题

| 现象 | 可能原因 | 看什么 |
|---|---|---|
| `lw; add` 结果错 | 没 stall 或 stall 不完整 | `load_use_stall` |
| 指令丢失 | IF/ID 没保持 | `stall_id`、`if_id_instr` |
| 指令重复提交 | PC/IFID/IDEX 控制不一致 | valid 流动 |
| 卡死一直 stall | ID/EX load 没前进到 EX/MEM | `id_ex_mem_re`、`ex_mem_mem_re` |
| 多停一拍 | 条件解除慢或匹配错误 | `id_ex_valid`、`id_ex_rd_addr` |

正确波形应类似：

```text
cycle N:   lw in EX,  add in ID,  load_use_stall=1
cycle N+1: lw in MEM, bubble in EX, add still in ID
cycle N+2: lw in WB,  add in EX,  forwarding from MEM/WB
```

## 第8章 branch/JAL/JALR flush 问题

| 现象 | 可能原因 | 看什么 |
|---|---|---|
| taken 后仍执行旧路径 | `flush_if_id/flush_id_ex` 没拉高 | redirect 当拍 |
| wrong-path 写 GPR | WB 写回没 valid gating | `mem_wb_valid`、`wb_gpr_we` |
| wrong-path store | dmem_we 没 valid gating | `ex_mem_valid`、`dmem_we_o` |
| not-taken 被 flush | branch condition 反了 | `branch_taken` |
| JAL 写回错 | `PC+4` 没随指令保存 | `id_ex_pc_plus4`、`mem_wb_pc_plus4` |
| JALR target 错 | forwarding 或 bit0 清零错 | `ex_rs1_data`、`redirect_pc` |

如果 branch 在 EX 决策，重点看 redirect 当拍 IF/ID 和下一拍 ID/EX 的 valid 是否被清掉。

## 第9章 load/store 和 dmem 问题

| 现象 | 可能原因 | 看什么 |
|---|---|---|
| `SW` 写不到预期地址 | DMEM_BASE 映射错 | `dmem_addr_o`、内部 word index |
| `SB` 写错 byte | byte enable 或 wdata 对齐错 | `dmem_be_o`、`dmem_wdata_o` |
| `LH/LHU` 结果错 | halfword 选择或扩展错 | `addr[1]`、load mux |
| load 返回旧值 | memory 读写同拍语义不清 | dmem 模型 |
| store data 旧 | store data forwarding 漏了 | `ex_mem_store_data` |

先确认地址，再确认 byte enable，最后确认数据。

## 第10章 常见“看起来像 CPU 错，其实不是”的问题

| 现象 | 实际可能 |
|---|---|
| 出现不支持指令 | 编译命令没用 `-march=rv32i`，或 C 代码引入库函数 |
| 出现 16 bit 指令 | 没禁用 C 扩展或没写 `.option norvc` |
| 程序访问奇怪地址 | 链接脚本、栈指针或 C 指针地址错 |
| 仿真不结束 | 程序没有写 tohost，timeout 太长或没有 timeout |
| 波形文件为空 | testbench 没 `$dumpvars`，或仿真提前退出 |
| trace 对不上 cycle | 单周期参考和流水线 cycle 本来不同，应比较提交顺序 |

## 第11章 debug 顺序模板

一次失败可以按这个顺序：

1. 看回归 log，确认哪个测试失败。
2. 看 objdump，确认测试实际指令。
3. 看 commit trace，找第一条错误提交。
4. 找该 PC 在波形中经过 IF/ID/EX/MEM/WB 的位置。
5. 若写回值错，看 decoder、operand、forwarding、ALU、WB。
6. 若 PC 错，看 immediate、branch compare、redirect、flush。
7. 若 memory 错，看 address、be、wdata、valid gating。
8. 修一个最小问题后，只跑对应 directed test。
9. 通过后再跑全量回归。

## 第12章 相关文档

| 文档 | 关系 |
|---|---|
| `0824 数据通路、流水线寄存器与控制信号参考.md` | 本文观察信号的来源 |
| `0825 Hazard控制：forwarding、stall、flush与kill.md` | 本文多数控制 bug 的规则依据 |
| `0826 裸机程序、ROM与RAM加载与工具链使用示例.md` | 程序加载和工具链问题排查 |
| `0827 Testbench、commit trace与测试集组织.md` | trace、pass/fail 和测试组织 |

