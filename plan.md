# 五级流水 RTL 实现计划

依据 `docs/08xx/0820 RISC-V最小教学核设计流程与方案.md:239` 的阶段 4-7：

## 总体路线

1. ~~**搭五级流水空壳**：pipeline register + valid bit。~~ `已完成 (v1.2-pipe-skeleton)`
2. ~~**接完整数据通路**：IF/ID/EX/MEM/WB 各级控制信号随指令流动。~~ `已完成 (v1.2-pipe-skeleton)`
3. ~~**加 data hazard**：forwarding + load-use stall。~~ `已完成`
4. [ ] **加 control hazard**：branch/JAL/JALR redirect + flush/kill。

---

## RTL 已新增

### 1. `rtl/core/core_pipeline5.sv` `已完成`

五级流水顶层，保留 `core_single_cycle.sv` 作为 golden/reference。
它负责实例化：

- `pc_reg`
- `if_stage`
- `id_stage`
- `ex_stage`
- `mem_stage`
- `wb_stage`
- `regfile`（带 `#(.BYPASS_EN(1))`）
- 四组流水线寄存器：IF/ID、ID/EX、EX/MEM、MEM/WB
- `forwarding_unit`
- `hazard_unit`

### 2. `rtl/core/forwarding_unit.sv` `已完成`

对应 `docs/08xx/0825 Hazard控制：forwarding、stall、flush与kill.md:51`。

核心功能：检测 EX/MEM 和 MEM/WB 两级的 `rd` 是否与当前 EX 输入的 `rs1`/`rs2` 匹配，若匹配则前递对应数据。

模块内部完成 detection + mux，直接输出前递后的数据值，不对外暴露选择信号。

关键规则：

- `rd = x0` 不参与 forwarding。
- EX/MEM 的 load 不能前递（load 的 ALU 结果是访存地址，不是数据）。
- EX/MEM 优先于 MEM/WB。
- 内部 mux 根据 EX/MEM 的 `wb_sel` 选择数据源：`WB_ALU`→alu_result、`WB_IMM`→imm、`WB_PC4`→pc_plus4。

覆盖场景：

- ALU operand forwarding
- branch 比较 operand forwarding
- store data forwarding

### 3. `rtl/core/hazard_unit.sv` `已完成`

对应 `docs/08xx/0825 Hazard控制：forwarding、stall、flush与kill.md:185`。

当前实现 load-use stall：

- `stall_if` + `stall_id`：冻结 PC 和 IF/ID 寄存器
- `bubble_ex`：在 ID/EX 插入 invalid 空槽

待完成（step 4）：

- `flush_if_id`
- `flush_id_ex`

### 4. 流水线寄存器（四组模块，合并为一个文件 `pipe_reg.sv`） `已完成`

- `pipe_reg_if_id` — IF/ID，含 flush + stall
- `pipe_reg_id_ex` — ID/EX，含 flush + bubble + stall（优先级 reset > flush > stall > bubble > normal）
- `pipe_reg_ex_mem` — EX/MEM，含 stall（为后续全流水线暂停预留）
- `pipe_reg_mem_wb` — MEM/WB，含 stall（同上）

---

## RTL 已修改

### 1. `rtl/common/core_pkg.sv` `已完成`

流水线寄存器 struct 和 forwarding 枚举放在独立的 `pipeline_pkg.sv` 中。`core_pkg.sv` 保持 ISA 层级定义不变。

### 2. `rtl/core/regfile.sv` `已完成`

加 `parameter bit BYPASS_EN = 0` 控制同拍写读旁路：

- **单周期**（BYPASS_EN=0，默认）：纯组合读，无旁路。单周期不产生同拍写读窗口，加了反而引入不必要的组合环路。
- **流水线**（BYPASS_EN=1）：读端口检测 `we_i && rd_addr_i == rs_addr_i` 时直接输出写数据。
  - 不加旁路时，producer 与 consumer 之间隔恰好 2 条指令时，producer 已离开 MEM/WB（forwarding 来不及），但 ID 读 GPR 时 producer 尚未写回（同步写），consumer 锁存旧值进入 EX → 计算结果错误。
  - 旁路在 ID 的组合读阶段直接输出写数据，consumer 锁存到正确值。

通过 `generate if (BYPASS_EN)` 在编译期分离两种模式，被禁用分支不生成任何逻辑。
