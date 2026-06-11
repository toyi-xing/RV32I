# 0831 最小 M-mode CSR 与 trap 规划

> 文档编号：0831  
> 所属系列：083x RV32I 教学核后续完善阶段  
> 文档定位：规划当前五级流水线 v2.0 之后第一步要加入的最小 M-mode CSR、SYSTEM 指令和 precise trap 能力  
> 对应总规划：`0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`  
> 前置文档：`0803 CSR、异常中断与特权级.md`、`0821 RV32I最小教学核指令集、编码与译码参考.md`、`0825 Hazard控制：forwarding、stall、flush与kill.md`、`0827 Testbench、commit trace与测试集组织.md`

本篇只规划“第一步做什么”。它不是执行阶段的 `plan.md`，因此不会写成“先改某个 enum，再连某个端口，再跑某个脚本”的逐项施工清单。

第一步的目标是：让当前核支持最小 M-mode CSR/trap，使非法指令、`ECALL`、`EBREAK`、不对齐访问等事件不再由 testbench 直接停止，而是由硬件进入 trap handler，软件读取 `mcause/mepc/mtval` 后通过 `MRET` 返回。

## 第1章 本步目标和非目标

### 1.1 本步目标

本步完成后，core 应具备：

| 能力 | 目标 |
|---|---|
| SYSTEM 指令译码 | 支持 `ECALL/EBREAK/MRET` 和 6 条 Zicsr CSR 指令 |
| `FENCE` | 在无 cache、无复杂 memory ordering 的当前模型下按 NOP 完成 |
| CSR 文件 | 支持最小 M-mode CSR 读写 |
| precise trap | trap 指令本身不产生错误副作用，younger instruction 被 kill |
| trap entry | 写 `mepc/mcause/mtval/mstatus`，redirect 到 `mtvec` |
| trap return | `MRET` 从 `mepc` 返回，并恢复 `mstatus.MIE/MPIE/MPP` |
| directed test | 能用裸机汇编测试 CSR 读写、trap entry、handler 和 `MRET` |

### 1.2 本步非目标

本步不做：

| 暂不做 | 原因 |
|---|---|
| interrupt | interrupt 依赖 trap entry/return，放到下一阶段 |
| MMIO timer | timer 通常和 MMIO、interrupt 一起做，暂不混入第一步 |
| S-mode/U-mode | 当前不跑 OS，先保持 M-mode-only |
| delegation | 只有 M-mode 时不需要 `medeleg/mideleg` |
| PMP/MMU | 当前无地址权限和虚拟内存需求 |
| nested trap 完整策略 | 第一版只保证单层 trap handler 正常工作 |
| vectored `mtvec` | 第一版可只支持 direct mode，`mtvec.MODE` 写入后按 WARL 归零 |

## 第2章 要补的指令

### 2.1 和当前 37 条主路径指令的关系

当前五级流水线已经支持 37 条 RV32I 主路径指令：U-type、I/R-type ALU、load/store、branch、`JAL/JALR`。这些指令覆盖了普通数据通路和 hazard 主线，但还没有覆盖 RISC-V 基础 ISA 里的同步/系统类入口。

本步要补的指令可以分成三类：

| 类别 | 指令 | 属于哪里 | 和当前 37 条是否重合 |
|---|---|---|---|
| RV32I 基础指令 | `FENCE`、`ECALL`、`EBREAK` | RV32I 基础 ISA 里存在，但第一版暂缓 | 不重合，使用 `MISC-MEM` 或 `SYSTEM` opcode |
| 特权指令 | `MRET` | RISC-V privileged architecture | 不属于 37 条主路径；和 `ECALL/EBREAK` 共用 `SYSTEM` opcode，用 `imm12` 区分 |
| 标准扩展指令 | `CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI` | `Zicsr` 扩展 | 不属于 RV32I 37 条主路径；和 SYSTEM 类共用 opcode，用 `funct3` 区分 |

因此，这一步不是修改已有 ALU/load/store/branch 指令的编码空间，而是把之前在 `0821` 中“可暂缓”的 `MISC-MEM` 和 `SYSTEM` 类补起来。

| opcode 名称 | 二进制 | 十六进制 | 用途 |
|---|---:|---:|---|
| `OPCODE_MISC_MEM` | `0001111` | `0x0f` | `FENCE` |
| `OPCODE_SYSTEM` | `1110011` | `0x73` | `ECALL/EBREAK/MRET/CSR*` |

这两个 opcode 和当前已实现的 37 条主路径指令没有 opcode 级冲突。`SYSTEM` 内部的多类指令需要继续看 `funct3` 和 `instr[31:20]`：

| `SYSTEM` 子类 | `funct3` | 继续区分字段 |
|---|---:|---|
| `ECALL/EBREAK/MRET` 等 | `000` | `instr[31:20]`，且 `rs1/rd` 通常为 `x0` |
| CSR register 形式 | `001/010/011` | `csr[11:0]`、`rs1`、`rd` |
| CSR immediate 形式 | `101/110/111` | `csr[11:0]`、`uimm`、`rd` |

### 2.2 RV32I 当前缺少的基础系统指令

本步应补上：

| 指令 | opcode/funct | 本步行为 |
|---|---|---|
| `FENCE` | `OPCODE_MISC_MEM`，规范编码 `funct3=000` | 当前无 cache、无乱序、无复杂设备顺序，先按 NOP 处理 |
| `ECALL` | `OPCODE_SYSTEM`，固定编码 `0x00000073` | 产生 M-mode environment call exception |
| `EBREAK` | `OPCODE_SYSTEM`，固定编码 `0x00100073` | 产生 breakpoint exception |

本步的 `FENCE` 实现语义是 NOP。也就是说，当前流水线只需要知道 `opcode=0001111` 属于 `MISC-MEM` 同步类，然后让它不写 GPR、不访存、不改变 PC、不产生 trap 即可；`fm/pred/succ/rs1/rd` 暂时不参与功能。

如果实现上为了简单把整个 `MISC-MEM` opcode 都按 NOP 兼容处理，那么 `FENCE.I` 也会被当作 NOP 吃掉；这只能理解为“当前无 I-cache 时的兼容处理”，不等于实现了 `Zifencei`。`FENCE.I` 和 `FENCE` 共用 `OPCODE_MISC_MEM = 0001111`，但 `funct3=001`，属于 `Zifencei` 扩展，不是 RV32I base 的必做项。后续如果加入 I-cache，或需要严格支持/区分 `fence.i`，再单独补 `FENCE.I` 的译码和缓存一致性语义。

虽然本步 `FENCE` 只按 NOP 做，但为了后续补完整 memory ordering 时不用重新查编码，这里仍把 `fm/pred/succ` 字段列出来。

`FENCE/ECALL/EBREAK` 的格式如下：

```text
FENCE：MISC-MEM 类，字段位置类似 I-type，但 imm[11:0] 被拆成 fm/pred/succ

 31    28 27    24 23    20 19     15 14    12 11     7 6          0
+--------+--------+--------+---------+--------+--------+------------+
|   fm   |  pred  |  succ  |   rs1   | funct3 |   rd   |   opcode   |
+--------+--------+--------+---------+--------+--------+------------+

opcode = 0001111
funct3 = 000

本步按 NOP 执行，因此这些字段暂不参与功能：
fm   = instr[31:28]，后续用于指定 fence mode
pred = instr[27:24]，后续用于描述 predecessor 访问类型
succ = instr[23:20]，后续用于描述 successor 访问类型
rs1  = instr[19:15]，标准 FENCE 当前通常为 x0
rd   = instr[11:7]，标准 FENCE 当前通常为 x0
```

```text
ECALL/EBREAK：SYSTEM 类，I-type 字段位置

 31             20 19     15 14    12 11     7 6          0
+-----------------+---------+--------+--------+------------+
|    imm[11:0]    |   rs1   | funct3 |   rd   |   opcode   |
+-----------------+---------+--------+--------+------------+

opcode = 1110011
funct3 = 000
rs1    = 00000
rd     = 00000

ECALL  : imm12 = 12'h000，完整编码 32'h0000_0073
EBREAK : imm12 = 12'h001，完整编码 32'h0010_0073
```

对 `FENCE`，第一版可以只要求 `opcode=0001111` 且 `funct3=000`，把 `fm/pred/succ/rs1/rd` 都视为不产生架构状态的字段。更严格的编码检查可以后续再加。

### 2.3 `MRET`

`MRET` 是 privileged instruction，用于从 M-mode trap handler 返回。

本步行为：

| 项目 | 行为 |
|---|---|
| PC | redirect 到 `mepc` |
| `mstatus.MIE` | 恢复为 `mstatus.MPIE` |
| `mstatus.MPIE` | 置 1 |
| `mstatus.MPP` | M-only 实现中可保持或归为 M-mode 合法值 |
| younger instruction | flush/kill |

因为本步只有 M-mode，所以暂不需要实现真正的 privilege mode 切换状态机。但 `mstatus` 的关键位仍建议按规范方向实现，避免后续加 interrupt 时返工。

`MRET` 编码：

```text
MRET：SYSTEM 类，I-type 字段位置

 31             20 19     15 14    12 11     7 6          0
+-----------------+---------+--------+--------+------------+
|    imm[11:0]    |   rs1   | funct3 |   rd   |   opcode   |
+-----------------+---------+--------+--------+------------+

opcode = 1110011
funct3 = 000
rs1    = 00000
rd     = 00000
imm12  = 12'h302
完整编码 = 32'h3020_0073
```

特权架构里还有 `SRET`、`URET`、`WFI`、`SFENCE.VMA` 等 SYSTEM 类指令。本步只做 `MRET`，原因是当前目标是 M-mode-only 裸机 core：

- trap entry 统一进入 M-mode handler，所以返回指令只需要 `MRET`。
- 没有 S-mode/U-mode，因此 `SRET/URET` 没有合法使用场景。
- 没有 MMU/TLB，因此 `SFENCE.VMA` 没有对象。
- interrupt 还不是本阶段目标，因此 `WFI` 可以后续和 interrupt/pending 语义一起规划。

### 2.4 Zicsr 指令

本步建议加入 6 条 CSR 指令：

| 指令 | 作用 | 写 CSR 条件 |
|---|---|---|
| `CSRRW` | CSR 与 GPR 交换式写入 | 总是写，除非 CSR 不可写或非法 |
| `CSRRS` | 按 `rs1` 置位 CSR bit | `rs1 != x0` 时写 |
| `CSRRC` | 按 `rs1` 清位 CSR bit | `rs1 != x0` 时写 |
| `CSRRWI` | 用 `uimm` 写 CSR | 总是写，除非 CSR 不可写或非法 |
| `CSRRSI` | 按 `uimm` 置位 CSR bit | `uimm != 0` 时写 |
| `CSRRCI` | 按 `uimm` 清位 CSR bit | `uimm != 0` 时写 |

写回规则：

- `rd != x0` 时，`rd` 写入 CSR 修改前的旧值。
- `rd == x0` 时，不需要产生 GPR 写回。
- 对不存在 CSR、只读 CSR 写入、非法 CSR 访问，应产生 illegal instruction exception。

当前实现的 CSR 暂时没有复杂 read side effect，所以可以先不用区分“读被抑制”的微妙规则，但文档和代码注释里应保留这个方向。

CSR 指令的编码格式如下。它们全部使用 `OPCODE_SYSTEM = 1110011`，但 `funct3 != 000`，因此不会和 `ECALL/EBREAK/MRET` 混淆。

```text
CSR register 形式：CSRRW/CSRRS/CSRRC

 31             20 19     15 14    12 11     7 6          0
+-----------------+---------+--------+--------+------------+
|   csr[11:0]     |   rs1   | funct3 |   rd   |   opcode   |
+-----------------+---------+--------+--------+------------+

opcode = 1110011
funct3 = 001: CSRRW
funct3 = 010: CSRRS
funct3 = 011: CSRRC
```

```text
CSR immediate 形式：CSRRWI/CSRRSI/CSRRCI

 31             20 19     15 14    12 11     7 6          0
+-----------------+---------+--------+--------+------------+
|   csr[11:0]     |  uimm   | funct3 |   rd   |   opcode   |
+-----------------+---------+--------+--------+------------+

opcode = 1110011
funct3 = 101: CSRRWI
funct3 = 110: CSRRSI
funct3 = 111: CSRRCI
uimm   = instr[19:15]，零扩展到 XLEN
```

从软件视角看，`Zicsr` 是访问 `mstatus/mtvec/mepc/mcause/mtval` 的入口；从流水线视角看，它给普通 `rd` 写回路径新增了一个来源：CSR 修改前的旧值。也就是说，CSR 指令既是 SYSTEM 类译码问题，也是数据通路写回问题。

### 2.5 当前框架下的译码规则

当前框架中，`decoder.sv` 的职责是识别 `instr_id_o`、生成通用控制信号、CSR 控制候选和 exception 候选。它不需要为每一类简单指令都输出独立布尔端口，例如 `fence_o/ecall_o/ebreak_o/mret_o`；这些需要结合流水线 valid 才有意义的简单标志，可以由 `id_stage.sv` 根据 `instr_id_o` 和 `if_valid_i` 生成。

因此，虽然 `decoder` 不直接输出 `fence_o/mret_o`，但它必须把新增指令识别成对应的 `instr_id_o`。所有不满足完整编码约束的情况都应保持 `INSTR_INVALID`，后续再由 illegal instruction exception 路径处理。

| opcode 分支 | 进一步检查条件 | `instr_id_o` | 说明 |
|---|---|---|---|
| `OPCODE_MISC_MEM` | `funct3_o == 3'b000` | `INSTR_FENCE` | 本阶段 `FENCE` 作为 NOP；`fm/pred/succ/rs1/rd` 暂不影响功能。 |
| `OPCODE_MISC_MEM` | 其他 `funct3_o` | `INSTR_INVALID` | 例如 `FENCE.I` 属于 `Zifencei`，本阶段不支持。 |
| `OPCODE_SYSTEM` | `instr_i == 32'h0000_0073` | `INSTR_ECALL` | 必须精确匹配整条指令。 |
| `OPCODE_SYSTEM` | `instr_i == 32'h0010_0073` | `INSTR_EBREAK` | 必须精确匹配整条指令。 |
| `OPCODE_SYSTEM` | `instr_i == 32'h3020_0073` | `INSTR_MRET` | 特权指令，本阶段只支持 M-mode return。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b001` | `INSTR_CSRRW` | CSR 地址是否合法、只读 CSR 是否被写，交给 `csr_file` 判断。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b010` | `INSTR_CSRRS` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b011` | `INSTR_CSRRC` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b101` | `INSTR_CSRRWI` | immediate 形式使用 `instr_i[19:15]` 作为 `uimm`。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b110` | `INSTR_CSRRSI` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b111` | `INSTR_CSRRCI` | 同上。 |
| `OPCODE_SYSTEM` | `funct3_o == 3'b000` 但不是上述精确编码，或 `funct3_o == 3'b100` | `INSTR_INVALID` | 未支持的 SYSTEM 编码统一作为 illegal instruction。 |

按这个边界划分后：

- `decoder` 只负责“这条编码到底是什么，以及它是否属于本步支持范围”。
- `id_stage` 可以派生 `fence_o = if_valid_i & (instr_id_o == INSTR_FENCE)`、`mret_o = if_valid_i & (instr_id_o == INSTR_MRET)` 这类简单标志。
- `ECALL/EBREAK` 不需要作为跨模块布尔端口传递；它们由 ID 阶段形成 `exception_valid/cause/tval`，再随流水线传到统一 trap 接受点。
- CSR 地址是否存在、只读 CSR 是否被写，不在 decoder 最终裁决，交给 `csr_file` 在 CSR 访问点判断。

现有通用控制信号也要同步扩展：

- `uses_rs1_o` 是通用 RAW hazard 语义信号，CSR register 形式也要计入；`csr_uses_rs1_o` 只是 CSR 专用分类信号。
- `uses_rs2_o` 不因 CSR 指令置位，CSR 指令不读取 rs2。
- `reg_we_o` 是通用 GPR 写回语义信号，CSR 写 rd 时也要计入；`csr_writes_rd_o` 只是 CSR 专用分类信号。
- `wb_sel_o` 对 CSR 写 rd 的指令应选择 `WB_CSR`，表示 WB 阶段写回旧 CSR 值。

CSR register 形式的 operand 虽然后续才用于 CSR 新值计算，但当前数据通路仍然在 ID 阶段读 GPR，并把 rs1 数据随流水线传递。因此对当前实现来说，CSR register 形式必须进入通用 `uses_rs1_o`，让现有 hazard/forwarding 能看到这条 GPR RAW 依赖。后续若专门把 CSR operand 延迟到更晚阶段获取，可以再做更细的 stall 优化。

## 第3章 最小 CSR 集合

### 3.1 CSR 集合选择思路

本步选 CSR 的原则是：只放入 trap handler 必须读写、以及裸机调试非常常见的最小集合。

trap entry 至少需要：

- `mtvec`：硬件知道 trap handler 在哪里。
- `mepc`：handler 知道从哪里返回或跳过 faulting instruction。
- `mcause`：handler 知道为什么进 trap。
- `mtval`：handler 获取非法指令编码或错误地址等附加信息。
- `mstatus`：保存/恢复全局 interrupt enable 相关位，为后续 interrupt 打基础。

handler 编写还常用：

- `mscratch`：给 handler 留一个无需占用 GPR ABI 的临时寄存器。

裸机环境识别常用：

- `misa/mvendorid/marchid/mimpid/mhartid`：软件或测试可以读取环境信息。它们不是 precise trap 的必要条件，但实现成本低，能让环境更像真实 core。

### 3.2 必做 CSR

| CSR | 地址 | 属性 | 本步用途 |
|---|---:|---|---|
| `mstatus` | `0x300` | RW/WARL | 保存 `MIE/MPIE/MPP`，支持 trap entry 和 `MRET` |
| `mtvec` | `0x305` | RW/WARL | trap handler 入口；本步建议只支持 direct mode |
| `mscratch` | `0x340` | RW | 给 handler 使用的临时 CSR |
| `mepc` | `0x341` | RW/WARL | 保存 trap 发生时的 PC |
| `mcause` | `0x342` | RW | 保存 trap 原因 |
| `mtval` | `0x343` | RW | 保存附加信息，如非法指令编码或 fault address |

这些 CSR 的 32 bit 规划如下。**图中带 `*` 的字段表示“规范中有这个位置或这个概念，但本步不用/不实现”**：读取返回 0，写入时忽略，或按 WARL 约束归零。没有带 `*` 的字段是本步真正需要保存或解释的字段。

#### `mstatus`，地址 `0x300`

本步只实现 M-mode trap/return 需要的几个 bit：

```text
mstatus (32bit)

 31  30      23 22 21 20  19   18   17    16   15    14    13 12   11 10    9   8     7    6    5   4   3  2   1   0
+---+----------+----+---+----+----+----+-----+------+--------+-------+-------+-----+----+----+-----+--+---+--+----+--+
|SD*|  WPRI*   |TSR*|TW*|TVM*|MXR*|SUM*|MPRV*| XS*  |  FS*   |  MPP  |  VS*  |SPP* |MPIE|UBE*|SPIE*|W*|MIE|W*|SIE*|W*|
+---+----------+----+---+----+----+----+-----+------+--------+-------+-------+-----+----+----+-----+--+---+--+----+--+
```

字段说明：

| 图中字段 | bit | 本步行为 |
|---|---:|---|
| `SD*` | 31 | 不实现，读 0 |
| `WPRI*` | 30:23 | 保留位，读 0，写忽略 |
| `TSR*/TW*/TVM*` | 22/21/20 | S-mode/MMU 相关，本步不用，读 0 |
| `MXR*/SUM*/MPRV*` | 19/18/17 | 权限/MMU 相关，本步不用，读 0 |
| `XS*/FS*/VS*` | 16:15 / 14:13 / 10:9 | 扩展状态，本步不用，读 0 |
| `MPP` | 12:11 | M-only 下保持 M-mode 合法值 `2'b11` |
| `SPP*/UBE*/SPIE*/SIE*` | 8/6/5/1 | S/U mode 相关，本步不用，读 0 |
| `MPIE` | 7 | trap entry 时保存原 `MIE`，`MRET` 后置 1 |
| `MIE` | 3 | trap entry 时清 0，`MRET` 时恢复 |
| `W*` | 4/2/0 | 保留位，读 0，写忽略 |

| bit | 名称 | 本步行为 |
|---:|---|---|
| 3 | `MIE` | trap entry 时清 0，`MRET` 时恢复 |
| 7 | `MPIE` | trap entry 时保存原 `MIE`，`MRET` 后置 1 |
| 12:11 | `MPP` | M-only 下写为 M-mode 合法值 |

trap entry 时：

```text
MPIE <= MIE
MIE  <= 0
MPP  <= M
```

`MRET` 时：

```text
MIE  <= MPIE
MPIE <= 1
MPP  <= M
```

当前不做 interrupt 时，`MIE/MPIE` 暂时不会影响外部事件是否进入 core，但现在按这个方向实现，后续接 machine interrupt 时不需要重写 `MRET` 和 trap entry 语义。

#### `mtvec`，地址 `0x305`

`mtvec` 本步建议只支持 direct mode：

```text
 31                                                           2 1      0
+-------------------------------------------------------------+--------+
|                         BASE[31:2]                          | MODE*  |
+-------------------------------------------------------------+--------+

本步固定支持 MODE=00 direct：
trap_pc = {mtvec[31:2], 2'b00}
```

写 `mtvec` 时可把低 2 bit 作为 WARL 位处理为 0。后续 interrupt 阶段若要支持 vectored mode，再扩展 `MODE=1`。

#### `mscratch`，地址 `0x340`

```text
 31                                                                    0
+----------------------------------------------------------------------+
|                            scratch[31:0]                             |
+----------------------------------------------------------------------+
```

硬件不解释它的内容。它主要给 trap handler 保存临时上下文或指针。

#### `mepc`，地址 `0x341`

```text
 31                                                           2 1      0
+-------------------------------------------------------------+--------+
|                         EPC[31:2]                           |  0*    |
+-------------------------------------------------------------+--------+
```

当前不支持 C 压缩指令，所有合法指令 4 字节对齐，所以 `mepc[1:0]` 可以按 WARL 归零。trap entry 写入 faulting instruction 的 PC；handler 可以修改 `mepc`，例如把 `mepc += 4` 用来跳过 `ECALL/EBREAK/illegal/misaligned` 这类 faulting instruction。

#### `mcause`，地址 `0x342`

```text
 31 30                                      5 4                         0
+---+----------------------------------------+---------------------------+
|I* |                  0*                    |      exception code        |
+---+----------------------------------------+---------------------------+
```

`I*` 是 interrupt 标志。本步只规划 synchronous exception，因此 `mcause[31]` 暂时固定为 0。后续做 interrupt 时，machine timer/external/software interrupt 会使用 `mcause[31]=1`，低位保存 interrupt code。

#### `mtval`，地址 `0x343`

```text
 31                                                                    0
+----------------------------------------------------------------------+
|                              tval[31:0]                              |
+----------------------------------------------------------------------+
```

本步建议约定：

| trap | `mtval` |
|---|---|
| illegal instruction | 原始 32 bit instruction |
| instruction address misaligned | 错误目标 PC |
| load/store address misaligned | 错误访存地址 |
| `ECALL` | 0 |
| `EBREAK` | 0 |

### 3.3 建议一起补的只读 CSR

为了让裸机程序和调试代码更像真实环境，建议本步一起支持：

| CSR | 地址 | 属性 | 建议值 |
|---|---:|---|---|
| `mvendorid` | `0xF11` | RO | `0` |
| `marchid` | `0xF12` | RO | `0` |
| `mimpid` | `0xF13` | RO | `0` 或版本号 |
| `mhartid` | `0xF14` | RO | 单 hart 固定 `0` |
| `misa` | `0x301` | RO 或 WARL | RV32 + I，建议至少反映 `I` |

`misa` 若只声明 RV32I，可用：

```text
 31 30 29           26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9  8 7  6  5  4  3  2  1  0
+-----+---------------+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+-+--+--+--+--+--+--+--+--+
| MXL |      0*       |Z*|Y*|X*|W*|V*|U*|T*|S*|R*|Q*|P*|O*|N*|M*|L*|K*|J*|I|H*|G*|F*|E*|D*|C*|B*|A*|
+-----+---------------+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+-+--+--+--+--+--+--+--+--+

MXL = 2'b01，表示 XLEN=32
I   = 1，表示支持 RV32I base integer ISA
其余扩展位本步为 0
建议值 = 32'h4000_0100
```

只读识别 CSR 的 32 bit 规划：

| CSR | 32 bit 内容 |
|---|---|
| `mvendorid` | 固定 `32'h0000_0000` |
| `marchid` | 固定 `32'h0000_0000` |
| `mimpid` | 固定 `32'h0000_0000`，或后续放实现版本号 |
| `mhartid` | 单 hart 固定 `32'h0000_0000` |
| `misa` | `32'h4000_0100`，即 `MXL=RV32` 且 `I=1` |

对只读 CSR 的写入应触发 illegal instruction exception。这样可以覆盖 CSR illegal trap 路径，也符合后续扩展方向。

是否把 `mcycle/minstret` 放进本步可以视工作量决定。它们对 trap 功能不是必需，但对 debug 和性能观察很有价值。如果加入，建议实现 64-bit 计数器和 RV32 下的高低 32-bit CSR：

| CSR | 地址 |
|---|---:|
| `mcycle` | `0xB00` |
| `minstret` | `0xB02` |
| `mcycleh` | `0xB80` |
| `minstreth` | `0xB82` |

## 第4章 要支持的 exception

本步只做 synchronous exception，不做 interrupt。

### 4.1 支持范围

| exception | `mcause` | `mtval` | 触发来源 | 最早可发现阶段 | 接受点 |
|---|---:|---|---|---|---|
| instruction address misaligned | `0` | 目标 PC | taken branch/JAL/JALR 目标不满足 IALIGN=32 | EX | MEM/commit 附近 |
| illegal instruction | `2` | 原始 instruction | opcode/funct 不支持、非法 SYSTEM 编码 | ID | MEM/commit 附近 |
| illegal instruction | `2` | 原始 instruction | 非法 CSR 访问，如访问不存在 CSR、写只读 CSR | MEM/CSR read-write 点 | MEM/commit 附近 |
| breakpoint | `3` | `0` | `EBREAK` | ID | MEM/commit 附近 |
| load address misaligned | `4` | load 地址 | `LH/LHU/LW` 地址不对齐 | MEM | MEM/commit 附近 |
| store address misaligned | `6` | store 地址 | `SH/SW` 地址不对齐 | MEM | MEM/commit 附近 |
| environment call from M-mode | `11` | `0` | `ECALL` | ID | MEM/commit 附近 |

“最早可发现阶段”和“接受点”不是同一个概念。ID 阶段能发现 `ECALL/EBREAK/illegal encoding`，但它们不能立刻改 CSR 和 redirect，否则 older instruction 还没走完；EX 阶段能算出 branch/JAL/JALR target，也不能让 younger 指令继续沿错误路径产生副作用。因此本步建议把 exception 信息先随指令后传，到统一 trap 接受点再真正写 `mepc/mcause/mtval` 和 redirect。

### 4.2 各异常为什么在这些阶段产生

#### illegal instruction

普通非法编码在 ID 阶段由 decoder 发现：

- opcode 不支持。
- opcode 支持，但 `funct3/funct7/imm12` 组合不合法。
- `SYSTEM` opcode 内部不是本步支持的 `ECALL/EBREAK/MRET/CSR*`。

这类 illegal 的 `mtval` 应保存原始 instruction，便于 handler 判断是哪条指令触发。

CSR illegal 有一部分也可以在 ID 阶段预判，例如 `funct3` 不合法；但“CSR 地址是否存在、这个 CSR 是否只读、当前这条 CSR 是否尝试写”更适合由 `csr_file` 在 CSR 访问点统一判断。这样 CSR 地址表只需要在一个模块里维护。

#### instruction address misaligned

顺序取指 `PC+4` 在当前模型下天然 4 字节对齐；真正需要检查的是会改变 PC 的指令：

- branch taken 时的 `pc + immB`。
- `JAL` 的 `pc + immJ`。
- `JALR` 的目标地址。

这些目标要到 EX 阶段 ALU 和 branch compare 完成后才知道。因此 instruction address misaligned 最早在 EX 阶段产生。

注意：RISC-V 对 `JALR` 会把目标 bit0 清零。如果当前不支持 C 扩展，IALIGN=32，那么最终 target 仍需要满足 `target[1:0] == 2'b00`。也就是说，`JALR` 清 bit0 不等于一定 4 字节对齐，`target[1]` 仍可能为 1。

#### load/store address misaligned

load/store 地址来自 `rs1 + imm`，当前设计在 EX 得到 ALU 地址，在 MEM 阶段根据 `mem_size` 和地址低位决定 byte lane、读写数据。为了和现有 `mem_stage.sv` 结构一致，本步建议在 MEM 阶段统一判断：

| 访问 | 对齐要求 |
|---|---|
| byte | 任意地址 |
| halfword | `addr[0] == 0` |
| word | `addr[1:0] == 0` |

misaligned store 必须禁止 dmem 写使能；misaligned load 必须禁止后续 GPR 写回。

#### ECALL/EBREAK

`ECALL/EBREAK` 在 ID 阶段就能由固定编码识别。它们不读 GPR、不写 GPR、不访问 memory，本质上是“这条指令请求进入 trap”。但为了 precise trap，它们仍应像其他异常一样随指令流到接受点，再由硬件写 CSR 和 redirect。

#### MRET

`MRET` 不是 exception，但它和 trap 一样是架构级控制流重定向：从 handler 返回到 `mepc`。因此它也需要参与流水线 flush/kill 优先级。规划上可以把它视为“trap 控制类事件”，但不能写 `mcause/mtval`。

本步不做：

| exception | 暂不做原因 |
|---|---|
| instruction access fault | 当前 imem 无访问错误模型 |
| load/store access fault | 当前 dmem 无 bus error/MMIO fault 模型 |
| page fault | 当前无 MMU |
| privilege violation | 当前只有 M-mode |

## 第5章 precise trap 与流水线关系

### 5.1 本步最重要的行为

trap 不能只是“另一种跳转”。它必须保证：

1. faulting instruction 自己不产生错误副作用。
2. faulting instruction 之前的 older instruction 可以正常提交。
3. faulting instruction 之后的 younger instruction 全部被 kill。
4. `mepc` 记录 faulting instruction 的 PC。
5. `mcause/mtval` 记录正确原因和附加信息。
6. PC redirect 到 `mtvec`，handler 结束后 `MRET` 返回。

### 5.2 推荐 trap 接受点

当前设计中 store 副作用发生在 MEM 阶段，GPR 写回发生在 WB 阶段。因此本步建议把 trap 接受点放在**接近 MEM/commit 的边界**，而不是简单等到 WB 再处理。

推荐思路：

| 事件来源 | 产生位置 | 建议处理 |
|---|---|---|
| illegal/`ECALL`/`EBREAK`/CSR illegal | ID 识别，随流水线后传 | 到 trap 接受点统一 entry |
| branch/JAL/JALR target misaligned | EX 可判断 | 不跳到错误目标，作为 exception 后传 |
| load/store misaligned | MEM 判断 | 当前 MEM 不发 dmem side effect，进入 trap |
| `MRET` | ID 识别，随流水线后传 | 到 trap 接受点统一 redirect 到 `mepc` |

这样可以避免 older trap 发生时，younger store 已经在同一拍写入 memory。

如果后续实现时选择 WB 作为唯一 commit 点，则必须额外加入全局 kill/gating，保证 older trap 在 WB 被接受时，younger MEM 阶段 store 不会在同一拍写 memory。这个方案可行，但控制上比 MEM 边界更容易出错。

### 5.3 redirect 和 flush 优先级

当前 `hazard_unit.sv` 的优先级是：

```text
EX redirect > load-use stall
```

加入 trap 后建议扩展为：

```text
trap/MRET redirect > EX branch/JAL/JALR redirect > load-use stall
```

原因：

- trap/MRET 是更高优先级的架构控制流。
- 如果 older instruction trap，younger branch redirect 必须被 kill，不能改写 PC。
- load-use stall 不能阻塞 trap redirect，否则错误路径可能继续停在流水线里。

### 5.4 副作用屏蔽

本步需要明确这些屏蔽规则：

| 情况 | 必须屏蔽 |
|---|---|
| faulting instruction 是 load | 不写 rd |
| faulting instruction 是 store | 不写 dmem |
| faulting instruction 是 JAL/JALR | 不写 link rd |
| faulting instruction 是 CSR 指令且 CSR illegal | 不写 CSR，不写 rd |
| younger instruction 被 trap flush | 不写 GPR，不写 dmem，不写 CSR |

当前 valid bit 已经能表达“这个槽是否允许产生副作用”。本步应把 trap kill 和 flush 后的 valid 语义继续贯彻到 GPR、dmem 和 CSR 写入口。

## 第6章 流水线传递视角的规划

### 6.1 为什么基础 RV32I 流水线还不够

基础 37 条 RV32I 主路径指令主要传递的是：

- 这条指令的 PC、instr、立即数、寄存器读数。
- ALU、branch、memory、writeback 控制信号。
- `rd/rs1/rs2` 等 hazard 需要的寄存器号。
- valid bit，用来描述流水线槽是否真实有效。

加入 CSR/trap 后，流水线还必须额外回答几类问题：

1. 这条指令是否已经发现 exception。
2. 如果有 exception，cause 是什么，`mtval` 应该写什么。
3. 这条指令是否是 CSR 指令，访问哪个 CSR，执行哪种 CSR 操作。
4. CSR 写入数据来自 forwarded `rs1` 还是 `uimm`。
5. CSR 旧值在哪里读出，如何作为 `WB_CSR` 写回 `rd`。
6. 这条指令是否是 `MRET`，到接受点时是否要 redirect 到 `mepc`。

这些信息不能只停留在 ID 阶段。因为真正允许写 CSR、写 dmem、写 GPR、redirect PC 的时刻，需要和流水线中的 older/younger 关系对齐。

### 6.2 各阶段新增职责

| 阶段 | 新增职责 | 产生的信息 | 消费的信息 |
|---|---|---|---|
| IF | 暂无复杂变化 | `pc/instr/pc_plus4` | trap/MRET/branch redirect 后更新 PC |
| ID | 识别 `FENCE/ECALL/EBREAK/MRET/CSR*`；识别普通 illegal encoding | `exception_valid/cause/tval`、`fence`、`mret`、CSR 控制字段 | regfile 读数、指令字段 |
| EX | 使用 forwarding 后的 rs1 生成 CSR 操作数；计算 branch/jump target；检查 redirect target misaligned | `csr_operand`、EX 产生的 exception 信息 | ID/EX 中的 CSR/exception/control 字段 |
| MEM | 判断 load/store misaligned；读 CSR 旧值；执行 CSR 写；接受 trap/MRET | `csr_rdata`、trap redirect、mret redirect、side effect gating | EX/MEM 中的 exception/CSR/memory/control 字段 |
| WB | 把 CSR 旧值通过 `WB_CSR` 写回 rd | GPR writeback data | MEM/WB 中的 `csr_rdata/wb_sel/reg_we/rd` |

可以把这一步理解成：ID 负责“看懂这是什么”，EX 负责“准备好要写的数据和目标地址”，MEM/commit 负责“决定它是否真的提交或进入 trap”，WB 负责“把最终结果写回 GPR”。

### 6.3 exception 信息如何流动

建议把 exception 信息作为指令自身的一部分随流水线移动：

```text
ID 发现 ECALL/EBREAK/illegal encoding
    -> ID/EX.exception_valid/cause/tval
    -> EX/MEM.exception_valid/cause/tval
    -> MEM 接受 trap

EX 发现 branch/JAL/JALR target misaligned
    -> EX/MEM.exception_valid/cause/tval
    -> MEM 接受 trap

MEM 发现 load/store misaligned 或 CSR illegal
    -> MEM 当拍接受 trap
```

这里的关键点是：exception 一旦和某条指令绑定，就要跟着这条指令一起走，而不是变成一个脱离指令顺序的全局脉冲。否则很容易出现 `mepc` 记错、younger 指令先写 memory、或者 older 指令被错误 kill 的问题。

异常优先级建议按“同一条指令先发现的异常先保持”的方式处理：

- ID 已经把某条指令标为 illegal/`ECALL/EBREAK`，后级不应再把它当普通 load/store/branch 产生新的副作用。
- EX 若发现 target misaligned，应禁止这条 branch/jump 的正常 redirect，转为 exception 后传。
- MEM 若发现 load/store misaligned，应禁止对应 memory 副作用，并覆盖为 load/store misaligned trap。
- CSR illegal 在 CSR 访问点产生，表现为 illegal instruction exception，`mtval` 使用原始 instruction。

### 6.4 CSR 信息如何流动

CSR 指令同时涉及 CSR 文件和 GPR 写回，所以它的数据流比普通 ALU 指令多一段：

```text
ID:
    译码 csr/csr_op/csr_addr/csr_uimm
    判断 csr_uses_rs1/csr_writes_rd/csr_write_en

EX:
    如果是 register 形式 CSR 指令，使用 forwarding 后的 rs1 作为 CSR 操作数
    如果是 immediate 形式 CSR 指令，使用 zero-extend(uimm) 作为 CSR 操作数

MEM:
    用 valid、csr、已有 exception 门控出 mem_csr_valid
    csr_file 组合读出 CSR 旧值 csr_rdata
    csr_file 根据 csr_op/csr_operand/csr_write_en 计算新值并写 CSR
    如果 CSR 不存在或写只读 CSR，改为 illegal instruction trap

WB:
    如果 rd != x0 且指令有效，通过 WB_CSR 把 csr_rdata 写入 rd
```

这里需要单独保留 `csr_write_en`，不能简单用 `csr_operand != 0` 替代。原因是：

- `CSRRS/CSRRC` 是否写 CSR 看 `rs1_addr != x0`，即使 `rs1` 里的数据是 0，也仍然是一次 CSR 写尝试。
- `CSRRSI/CSRRCI` 是否写 CSR 看 `uimm != 0`。
- 对只读 CSR，如果这条指令构成“写尝试”，就应该产生 illegal instruction exception。

CSR 指令的 `rd` 写回也是独立概念。`csr_writes_rd` 表示这条 CSR 指令是否需要把 CSR 旧值写回 GPR；真正写 GPR 还要继续受 valid、trap kill、`rd != x0` 约束。

### 6.5 MRET 信息如何流动

`MRET` 在 ID 阶段能被固定编码识别，但不能在 ID 直接 redirect，因为它前面可能还有 older 指令没有提交。规划上建议：

```text
ID 识别 MRET
    -> mret 随 ID/EX、EX/MEM 后传
    -> 到 MEM/commit 接受点
    -> csr_file 恢复 mstatus
    -> PC redirect 到 mepc
    -> flush younger instruction
```

`MRET` 不写 `mepc/mcause/mtval`，也不写 GPR/dmem。它和 trap entry 的共同点是都会改变 PC 并 flush younger instruction；不同点是 trap entry 写 trap CSR 并跳到 `mtvec`，`MRET` 恢复 `mstatus` 并跳到 `mepc`。

### 6.6 对 pipeline register 的字段规划

从流水线信息流角度看，字段应该按“谁产生、谁消费”来决定。

`ID/EX` 需要新增：

| 字段 | 产生阶段 | 消费阶段 | 作用 |
|---|---|---|---|
| `exception_valid/cause/tval` | ID | EX/MEM/MEM | 携带 ID 已发现的 exception |
| `fence` | ID | 后级 | 当前先按 NOP，保留可观察/扩展点 |
| `mret` | ID | MEM/trap 控制 | 到接受点后执行 trap return |
| `csr` | ID | EX/MEM | 标记 CSR 指令 |
| `csr_op` | ID | MEM/CSR file | 选择 CSR 新值计算方式 |
| `csr_addr` | ID | MEM/CSR file | 选择访问哪个 CSR |
| `csr_uimm` | ID | EX | 生成 immediate 形式 CSR 写源 |
| `csr_uses_rs1` | ID | EX/forwarding | register 形式 CSR 指令需要 forwarded rs1 |
| `csr_writes_rd` | ID | MEM/WB | CSR 旧值是否需要写回 rd |
| `csr_write_en` | ID | MEM/CSR file | 这条 CSR 指令是否尝试写 CSR |

`EX/MEM` 需要新增：

| 字段 | 产生阶段 | 消费阶段 | 作用 |
|---|---|---|---|
| `exception_valid/cause/tval` | ID 或 EX | MEM/trap 控制 | 到接受点写 `mcause/mtval` |
| `fence` | ID 后传 | MEM | 当前无副作用，保留扩展点 |
| `mret` | ID 后传 | MEM/trap 控制 | 到接受点 redirect 到 `mepc` |
| `csr` | ID 后传 | MEM | 标记 CSR 指令；到 MEM 阶段再结合 valid/exception 生成 `mem_csr_valid` |
| `csr_op` | ID 后传 | MEM/CSR file | 选择 CSR 写操作 |
| `csr_addr` | ID 后传 | MEM/CSR file | CSR 地址 |
| `csr_operand` | EX | MEM/CSR file | forwarded rs1 或 zero-extend(uimm) |
| `csr_writes_rd` | ID 后传 | MEM/WB | 是否把旧 CSR 值送去 WB |
| `csr_write_en` | ID 后传 | MEM/CSR file | 是否尝试写 CSR |

`MEM/WB` 需要新增：

| 字段 | 产生阶段 | 消费阶段 | 作用 |
|---|---|---|---|
| `csr_rdata` | MEM/CSR file | WB | CSR 修改前旧值，作为 `WB_CSR` 写回 |

这些字段就是执行计划中 `pipeline_pkg.sv` 需要扩展的核心原因。文件落地时可以把字段放在 struct 末尾或相关字段附近，但语义上要保持“exception 随指令传递、CSR 写源在 EX 准备、CSR 旧值在 MEM 读出、CSR 旧值在 WB 写回”这条线不变。

## 第7章 建议新增或修改的 RTL 文件

### 7.1 新增文件

| 文件 | 作用 |
|---|---|
| `rtl/core/csr_file.sv` | 保存 M-mode CSR，处理 CSR read/write、trap entry 写 CSR、`MRET` 状态恢复 |
| `rtl/core/trap_ctrl.sv` | 汇总各阶段 exception/`MRET`，生成 trap redirect、flush、CSR trap entry 控制 |

`trap_ctrl.sv` 是否单独存在可以按实现复杂度决定。若第一版控制量不大，也可以先把 trap 选择逻辑放在 `core_pipeline5.sv`，但长期看单独模块更清楚。

### 7.2 需要修改的公共类型

| 文件 | 修改方向 |
|---|---|
| `rtl/common/core_pkg.sv` | 恢复 `OPCODE_MISC_MEM/OPCODE_SYSTEM`，新增 SYSTEM/CSR 指令 ID、CSR op enum、trap cause enum、CSR 地址常量 |
| `rtl/common/pipeline_pkg.sv` | 在 pipeline register struct 中增加 exception、CSR、`MRET` 相关字段 |

建议新增的控制字段包括：

| 字段 | 含义 |
|---|---|
| `exception_valid` | 当前指令是否已经检测到 exception |
| `exception_cause` | exception cause code |
| `exception_tval` | 写入 `mtval` 的附加信息 |
| `csr` | 是否为 CSR 指令 |
| `csr_op` | `CSRRW/CSRRS/CSRRC` 及 immediate 变体 |
| `csr_addr` | 12-bit CSR 地址 |
| `csr_operand` | CSR 写入计算所需操作数 |
| `csr_write_en` | CSR 指令是否尝试写 CSR，用于区分读 CSR 和写 CSR |
| `csr_writes_rd` | CSR 旧值是否需要写回 GPR |
| `mret` | 当前指令是否为 `MRET` |

### 7.3 需要修改的现有模块

| 文件 | 修改方向 |
|---|---|
| `decoder.sv` | 译码 `FENCE/ECALL/EBREAK/MRET/CSR*`，输出 CSR/trap 控制和 CSR 写回控制 |
| `id_stage.sv` | 传递 CSR 地址、CSR 操作、exception 初始信息 |
| `ex_stage.sv` | 检测 branch/JAL/JALR target misaligned，避免错误 redirect |
| `mem_stage.sv` | 把现有 `mem_misaligned_o` 拆成 load/store exception 信息，并保证 misaligned store 不写 dmem |
| `wb_stage.sv` | 增加 `WB_CSR` 或独立 CSR read data 写回路径 |
| `hazard_unit.sv` | 加入 trap/MRET redirect flush 优先级 |
| `core_pipeline5.sv` | 实例化 CSR/trap 逻辑，连接 flush/redirect/commit trace |
| `tb_core_pipeline5.sv` | 不再把所有 illegal/misaligned 直接当仿真结束，增加 trap trace 观察 |

## 第8章 仿真和测试规划

### 8.1 测试目录

本步可以继续使用 `sw/asm/` 和 `sim/pipeline5_asm/`，不必立刻新建测试框架。

建议新增的汇编测试：

| 测试 | 覆盖内容 |
|---|---|
| `csr_rw.S` | `CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI`，重点测 `mscratch/mtvec/mepc` |
| `fence_nop.S` | `FENCE` 不破坏前后 load/store/ALU 结果 |
| `trap_ecall_mret.S` | `ECALL` 写 `mcause=11`，handler 修改 `mepc += 4` 后 `MRET` 返回 |
| `trap_ebreak_mret.S` | `EBREAK` 写 `mcause=3`，handler 返回 |
| `trap_illegal.S` | `.word` 注入非法指令，检查 `mcause=2` 和 `mtval=instr` |
| `trap_load_misaligned.S` | load misaligned 写 `mcause=4`，faulting load 不写 rd |
| `trap_store_misaligned.S` | store misaligned 写 `mcause=6`，faulting store 不写 dmem |
| `trap_inst_misaligned.S` | taken branch/JAL/JALR 目标不对齐写 `mcause=0` |
| `trap_wrong_path_kill.S` | trap 后 younger store/rd write/CSR write 不产生副作用 |

这些测试都应继续使用现有 PASS/FAIL 约定：程序最终写 `TEST_STATUS_ADDR`，testbench 自动结束。

### 8.2 handler 编写约定

第一版 trap 测试可以采用简单 handler：

```asm
trap_handler:
    csrr t0, mcause
    csrr t1, mepc
    csrr t2, mtval
    ...
    addi t1, t1, 4
    csrw mepc, t1
    mret
```

注意：

- `ECALL/EBREAK/illegal/misaligned` 这类测试若要跳过 faulting instruction，handler 应把 `mepc += 4`。
- instruction address misaligned 的 faulting instruction 是触发跳转的 branch/jump 本身，handler 同样可以选择跳过它。
- handler 中不要依赖尚未支持的 interrupt、MMIO 或复杂运行时。

### 8.3 testbench 观察点

`tb_core_pipeline5.sv` 当前在 `illegal_instr_o` 或 `mem_misaligned_o` 时直接 `$finish`。本步之后应改成：

| 信号/行为 | 新策略 |
|---|---|
| `illegal_instr_o` | 可作为 trace 观察，不直接结束仿真 |
| `mem_misaligned_o` | 可作为 trace 观察，不直接结束仿真 |
| `trap_valid_o` | 建议新增，打印 trap PC/cause/tval |
| `trap_return_o` | 可选新增，打印 `MRET` 返回 PC |
| PASS/FAIL | 仍由 DMEM status 地址决定 |

commit trace 建议增加 trap 信息，例如：

```text
TRAP pc=0x00000020 cause=0x0000000b tval=0x00000000 mtvec=0x00000080
MRET pc=0x00000084 -> 0x00000024
```

## 第9章 完成标准

本步完成后，应满足：

| 验收项 | 标准 |
|---|---|
| 原有回归 | 现有 pipeline asm/C 测试仍然 PASS |
| CSR 读写 | `csr_rw.S` 覆盖 6 条 CSR 指令并 PASS |
| `FENCE` | 作为 NOP 不破坏程序结果 |
| `ECALL/EBREAK` | 能进入 handler，检查 `mcause/mepc/mtval`，`MRET` 返回 |
| illegal instruction | 不再由 testbench 直接停机，而是进入 trap |
| misaligned load/store | 进入 trap，且 faulting load/store 无错误副作用 |
| instruction misaligned | taken branch/jump 目标不对齐进入 trap |
| wrong-path kill | trap 后 younger instruction 不写 GPR、dmem 或 CSR |
| trace | commit/trap trace 能帮助定位 trap 发生的 PC 和原因 |

达到这些标准后，当前核就完成了从“合法 RV32I 主路径流水线”到“具备最小 M-mode trap 能力的裸机 core”的第一步升级。下一篇 `083x` 再规划 MMIO 和最小外设会更合适。
