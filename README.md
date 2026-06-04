# RV32I Teaching Core

本仓库是一个 RV32I 教学核实现仓库。当前阶段先跑通单周期 demo core，后续再把顶层替换为五级流水版本。

本仓库 README 只作为工程入口，重点说明当前如何运行仿真。工程的规划、说明文档不在当前仓库，而是 082x 系列文档。

## 当前状态

- `rtl/core/core_single_cycle.sv`：单周期 RV32I demo 顶层。
- `tb/sv/tb_core_single_cycle.sv`：单周期 core testbench。
- `sw/asm/smoke.S`：最小裸机 smoke test。
- `sim/single_cycle_asm/`：单周期汇编测试编译和仿真脚本。
- `sw/c/c_smoke.c`：最小 C 裸机 smoke test。
- `sim/single_cycle_c/`：单周期 C 测试编译和仿真脚本。

当前 smoke 测试约定：裸机程序向 `core_pkg::DMEM_BASE + 0x100` 写入 `1` 表示 PASS，testbench 检测到该 store 后结束仿真。

## 快速运行

汇编测试在仓库根目录执行：

```bash
sim/single_cycle_asm/run_test.sh smoke
```

C 裸机测试在仓库根目录执行：

```bash
sim/single_cycle_c/run_test.sh c_smoke
```

期望输出中出现：

```text
PASS after ... cycles
```

如果只修改了 `sw/asm/smoke.S`，重新执行上面两条命令即可。如果修改了 RTL 或 testbench，也执行同样两条命令，第二个脚本会重新调用 Verilator 构建仿真程序。

## 编写新测试

新增测试时，在 `sw/asm/` 下创建一个同名 `.S` 文件，例如：

```text
sw/asm/alu_imm.S
```

然后运行：

```bash
sim/single_cycle_asm/run_test.sh alu_imm
```

汇编仿真详细流程见 [docs/simulation_flow_singlecycle_asm.md](docs/simulation_flow_singlecycle_asm.md)。

C 裸机仿真详细流程见 [docs/simulation_flow_singlecycle_c.md](docs/simulation_flow_singlecycle_c.md)。
