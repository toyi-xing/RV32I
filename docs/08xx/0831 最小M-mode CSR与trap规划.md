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

### 2.1 RV32I 当前缺少的基础系统指令

当前 `core_pkg.sv` 中 `OPCODE_MISC_MEM` 和 `OPCODE_SYSTEM` 仍处于注释占位状态。本步应补上：

| 指令 | opcode/funct | 本步行为 |
|---|---|---|
| `FENCE` | `OPCODE_MISC_MEM`，`funct3=000` | 当前无 cache、无乱序、无复杂设备顺序，先按 NOP 处理 |
| `ECALL` | `OPCODE_SYSTEM`，固定编码 `0x00000073` | 产生 M-mode environment call exception |
| `EBREAK` | `OPCODE_SYSTEM`，固定编码 `0x00100073` | 产生 breakpoint exception |

`FENCE.I` 属于 `Zifencei`，不是本步必须项。若工具链或测试暂时不生成，可继续不支持；如果后续要支持，也可以先按 NOP 处理并在文档中明确无 I-cache。

### 2.2 `MRET`

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

### 2.3 Zicsr 指令

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

## 第3章 最小 CSR 集合

### 3.1 必做 CSR

| CSR | 地址 | 属性 | 本步用途 |
|---|---:|---|---|
| `mstatus` | `0x300` | RW/WARL | 保存 `MIE/MPIE/MPP`，支持 trap entry 和 `MRET` |
| `mtvec` | `0x305` | RW/WARL | trap handler 入口；本步建议只支持 direct mode |
| `mscratch` | `0x340` | RW | 给 handler 使用的临时 CSR |
| `mepc` | `0x341` | RW/WARL | 保存 trap 发生时的 PC |
| `mcause` | `0x342` | RW | 保存 trap 原因 |
| `mtval` | `0x343` | RW | 保存附加信息，如非法指令编码或 fault address |

`mstatus` 本步至少实现：

| bit | 名称 | 本步行为 |
|---:|---|---|
| 3 | `MIE` | trap entry 时清 0，`MRET` 时恢复 |
| 7 | `MPIE` | trap entry 时保存原 `MIE`，`MRET` 后置 1 |
| 12:11 | `MPP` | M-only 下写为 M-mode 合法值 |

`mtvec` 本步建议只支持 direct mode：

```text
trap_pc = mtvec.BASE
```

写 `mtvec` 时可把低 2 bit 作为 WARL 位处理为 0。后续 interrupt 阶段若要支持 vectored mode，再扩展 `MODE=1`。

### 3.2 建议一起补的只读 CSR

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
misa.MXL = 1
misa.I   = 1
```

是否把 `mcycle/minstret` 放进本步可以视工作量决定。它们对 trap 功能不是必需，但对 debug 和性能观察很有价值。如果加入，建议实现 64-bit 计数器和 RV32 下的高低 32-bit CSR：

| CSR | 地址 |
|---|---:|
| `mcycle` | `0xB00` |
| `minstret` | `0xB02` |
| `mcycleh` | `0xB80` |
| `minstreth` | `0xB82` |

## 第4章 要支持的 exception

本步只做 synchronous exception，不做 interrupt。

| exception | `mcause` | `mtval` | 触发来源 |
|---|---:|---|---|
| instruction address misaligned | `0` | 目标 PC | taken branch/JAL/JALR 目标不满足 IALIGN=32 |
| illegal instruction | `2` | 原始 instruction | opcode/funct 不支持、非法 CSR 访问、非法 SYSTEM 编码 |
| breakpoint | `3` | `0` | `EBREAK` |
| load address misaligned | `4` | load 地址 | `LB/LH/LW/LBU/LHU` 中 half/word 地址不对齐 |
| store address misaligned | `6` | store 地址 | `SB/SH/SW` 中 half/word 地址不对齐 |
| environment call from M-mode | `11` | `0` | `ECALL` |

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

## 第6章 建议新增或修改的 RTL 文件

### 6.1 新增文件

| 文件 | 作用 |
|---|---|
| `rtl/core/csr_file.sv` | 保存 M-mode CSR，处理 CSR read/write、trap entry 写 CSR、`MRET` 状态恢复 |
| `rtl/core/trap_ctrl.sv` | 汇总各阶段 exception/`MRET`，生成 trap redirect、flush、CSR trap entry 控制 |

`trap_ctrl.sv` 是否单独存在可以按实现复杂度决定。若第一版控制量不大，也可以先把 trap 选择逻辑放在 `core_pipeline5.sv`，但长期看单独模块更清楚。

### 6.2 需要修改的公共类型

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
| `csr_en` | 是否为 CSR 指令 |
| `csr_op` | `CSRRW/CSRRS/CSRRC` 及 immediate 变体 |
| `csr_addr` | 12-bit CSR 地址 |
| `csr_wdata` 或 CSR 源数据 | CSR 写入计算所需数据 |
| `mret` | 当前指令是否为 `MRET` |

### 6.3 需要修改的现有模块

| 文件 | 修改方向 |
|---|---|
| `decoder.sv` | 译码 `FENCE/ECALL/EBREAK/MRET/CSR*`，输出 CSR/trap 控制 |
| `id_stage.sv` | 传递 CSR 地址、CSR 操作、exception 初始信息 |
| `ex_stage.sv` | 检测 branch/JAL/JALR target misaligned，避免错误 redirect |
| `mem_stage.sv` | 把现有 `mem_misaligned_o` 拆成 load/store exception 信息，并保证 misaligned store 不写 dmem |
| `wb_stage.sv` | 增加 `WB_CSR` 或独立 CSR read data 写回路径 |
| `hazard_unit.sv` | 加入 trap/MRET redirect flush 优先级 |
| `core_pipeline5.sv` | 实例化 CSR/trap 逻辑，连接 flush/redirect/commit trace |
| `tb_core_pipeline5.sv` | 不再把所有 illegal/misaligned 直接当仿真结束，增加 trap trace 观察 |

## 第7章 仿真和测试规划

### 7.1 测试目录

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

### 7.2 handler 编写约定

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

### 7.3 testbench 观察点

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

## 第8章 完成标准

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

