# 五级流水 RTL 实现计划

依据 `docs/08xx/0820 RISC-V最小教学核设计流程与方案.md:239` 的阶段 4-7：

## 总体路线

1. **搭五级流水空壳**：pipeline register + valid bit。
2. **接完整数据通路**：IF/ID/EX/MEM/WB 各级控制信号随指令流动。
3. **加 data hazard**：forwarding + load-use stall。
4. **加 control hazard**：branch/JAL/JALR redirect + flush/kill。

---

## RTL 应新增

### 1. `rtl/core/core_pipeline5.sv`

新的五级流水顶层，保留 `core_single_cycle.sv` 作为 golden/reference。
它负责实例化：

- `pc_reg`
- `if_stage`
- `id_stage`
- `ex_stage`
- `mem_stage`
- `wb_stage`
- `regfile`
- 四组流水线寄存器：IF/ID、ID/EX、EX/MEM、MEM/WB
- `forwarding_unit`
- `hazard_unit`

外部接口建议尽量和当前 `core_single_cycle.sv` 保持一致，方便后面 TB 和脚本切换。

### 2. `rtl/core/forwarding_unit.sv`

对应 `docs/08xx/0825 Hazard控制：forwarding、stall、flush与kill.md:51`。

核心功能：检测 EX/MEM 和 MEM/WB 两级的 `rd` 是否与当前 EX 输入的 `rs1`/`rs2` 匹配，若匹配则用前递结果替代 regfile 输出。

输出选择信号：

- `fwd_a_sel` — 控制 ALU 输入 a 的来源（rs1_rdata / ex_mem_rd_wdata / mem_wb_rd_wdata）
- `fwd_b_sel` — 控制 ALU 输入 b 的来源（rs2_rdata / ex_mem_rd_wdata / mem_wb_rd_wdata）
- `fwd_mem_wdata_sel` — store data 的前递选择

编码对应 `core_pkg` 中的枚举：

| 来源 | 含义 |
|------|------|
| `FWD_GPR` | 不使用前递，直接取 regfile 输出 |
| `FWD_EXMEM` | 从 EX/MEM 寄存器取前递值 |
| `FWD_MEMWB` | 从 MEM/WB 寄存器取前递值 |

覆盖场景：

- ALU operand forwarding — `fwd_a_sel`/`fwd_b_sel` 选择 EX/MEM 或 MEM/WB 的运算结果
- branch 比较 operand forwarding — 同理，分支比较器使用前递后的值
- store data forwarding — `fwd_mem_wdata_sel` 选择 rs2 的前递来源

关键规则：

- `rd = x0` 不参与 forwarding，写 x0 不改变任何寄存器的语义值
- EX/MEM 的 load 不能前递：EX/MEM 寄存器中 load 指令的 `rd_wdata` 是 load 地址，不是 load 数据（数据 MEM 阶段才从 DMEM 读出）
- EX/MEM 优先于 MEM/WB：同一拍内 EX/MEM 的 `rd` 比 MEM/WB 的 `rd` 更新

### 3. `rtl/core/hazard_unit.sv`

对应 `docs/08xx/0825 Hazard控制：forwarding、stall、flush与kill.md:185`。

建议输出：

- `stall_if`
- `stall_id`
- `bubble_ex`
- `flush_if_id`
- `flush_id_ex`

控制优先级按文档：

```
reset > redirect/flush > load-use stall > normal advance
```

也就是 redirect 不能被 load-use stall 卡住。

### 4. 流水线寄存器（四组独立模块）

创建四个独立的流水线寄存器文件，各对应一个阶段间的流水控制：

- `rtl/core/pipe_reg_if_id.sv` — IF/ID，含 flush 接口（redirect 时清空 ID 阶段）
- `rtl/core/pipe_reg_id_ex.sv` — ID/EX，含 bubble 接口（load-use 时插入气泡）
- `rtl/core/pipe_reg_ex_mem.sv` — EX/MEM
- `rtl/core/pipe_reg_mem_wb.sv` — MEM/WB

每个寄存器负责：
- 在时钟上升沿锁存前一级的控制信号和数据通路值
- 处理 valid/kill/flush/bubble 等流水控制信号
- 公共逻辑（如暂停时保持不动、刷新时清零）直接在各自模块内实现

---

## RTL 应修改

### 1. `rtl/common/core_pkg.sv`

补充流水线用 typedef/enum：

- forwarding 选择枚举：`FWD_GPR`、`FWD_EXMEM`、`FWD_MEMWB`
- 可选补充 pipeline register struct：
  - `if_id_reg_t`
  - `id_ex_reg_t`
  - `ex_mem_reg_t`
  - `mem_wb_reg_t`

如果当前 package 已经有 decoder 控制 enum，就沿用，不要重命名。

### 2. `rtl/core/regfile.sv`

**保持不动，不加 WB 同拍旁路。**

流水线中 ID 阶段与 WB 阶段相差 3 拍，当 ID 需要读取刚被 WB 写入的寄存器时，`forwarding_unit` 已经通过 MEM/WB → EX 路径前递到 ALU，不会出现读旧值的问题。

唯一需要同拍旁路的场景是 ID 阶段提前做分支比较（early branch resolution），但那是后续优化，初版不需要。

所以 `regfile.sv` 完全沿用单周期版本，单周期和流水线两套顶层共用同一个 regfile，互不影响。
