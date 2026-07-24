# Known Issues

本文档用于记录已经暴露的问题（及其当前状态），避免问题因阶段切换或 `plan.md` 更新而丢失。这里记录问题现象、影响范围、暂缓原因、验证方法和关闭条件。

问题状态使用以下口径：

- `Open`：问题已经确认，正在但尚未修复。
- `Fixed`：根因已经修复，并完成相应回归验证。
- `Deferred`：问题确认存在，但明确推迟到后续阶段或版本处理。

## RTL-001：MMIO 子字节访问的寄存器偏移解码不一致

| 项目 | 内容 |
| --- | --- |
| 状态 | `Fixed` |
| 发现日期 | 2026-07-13 |
| 修复日期 | 2026-07-24 |
| 修复版本 | v6.17（提交 `8930f3a`） |
| 影响范围 | 当前主线 RTL、v6.0 UVM DUT 快照 |
| 相关模块 | `rtl/core/mem_stage.sv`、`rtl/soc/data_subsystem.sv`、各 MMIO 外设 |
| 修复内容 | GPIO0、UART0、TIMER0 的寄存器 offset decode 改为 word-aligned offset；保留原始 byte address 与 byte enable 总线语义 |

### 问题说明

CPU 当前向 simple data bus 输出未经对齐的字节地址，同时根据地址低两位生成 `be`，并将写数据移动到对应 byte lane。例如：

- `SB reg+1`：总线地址为 `reg+1`，`be = 4'b0010`。
- `SH reg+2`：总线地址为 `reg+2`，`be = 4'b1100`。

该语义在 data memory 中可以正常工作：RAM 使用地址的 word index 选择存储字，再使用 `be` 更新对应 byte lane。

修复前 GPIO、UART、timer 等 MMIO 外设直接使用完整的低 12 位地址偏移匹配 word-aligned 寄存器地址。因此，访问已定义寄存器内部的非零 byte offset 时，地址无法命中寄存器：

| 访问形式 | 修复前结果 |
| --- | --- |
| 对齐的 `LW/SW reg+0` | 正常命中 |
| `LB/SB reg+0` | 可以命中 |
| `LB/SB reg+1`、`reg+2` 或 `reg+3` | 被识别为未知偏移并返回 access fault |
| `LH/SH reg+0` | 可以命中 |
| 对齐的 `LH/SH reg+2` | 被识别为未知偏移并返回 access fault |

这不是一套完整一致的“MMIO 仅支持 word 访问”规则。外设内部已经使用 `be` 控制 byte lane；若请求使用 word-aligned 地址并携带非零 lane 的 `be`，外设可以处理，但 CPU 生成的等价子字节请求却会因地址偏移不匹配而失败。因此，按当前simple data bus 的“字节地址 + byte enable”口径，应将其视为 RTL 问题。

### UVM 修复前复现证据

2026-07-23 使用固定 seed `1` 运行 `uvm/v6_0/data_subsystem/sim/run_test.sh DS_map_random_test 1`，该 test 在 `0/1/3/8/32/64/127` 七个 response delay 档位下分别配置 DMEM、GPIO0、UART0、TIMER0，并共完成 2100 笔 data-side transaction。

UVM 汇总得到 `UVM_ERROR=52`、`UVM_FATAL=0`。其中 48 条为 GPIO0 已定义 word offset 的非零 byte address 被错误返回 error，例如 `offset=0x014 addr=0x00080015`：scoreboard 按 word-aligned offset 正确识别 `0x014` 是已定义寄存器，而当前 GPIO RTL 直接使用原始偏移 `0x015` 解码，因而返回 access fault。其余 2 条 OUT read mismatch 和 2 条 OE read mismatch 是上述错误拒绝写请求后，DUT 寄存器状态未更新导致的后续可观测结果，不是独立问题。

同一日志中，真正未知的 GPIO0 word offset（例如对齐 offset `0x038`）均返回 error 并被 scoreboard 记录为 expected behavior；DMEM 没有 mismatch/error，wrapper scoreboard 为 `check_num=2100, correct_num=2100, error_num=0`。functional coverage 为 data `96.67%`、behavior `97.12%`。因此该 FAIL 能隔离为 RTL-001 的修复前证据，可用于同 seed 修复后的 PASS 对比。

### 当前定向测试未暴露问题的原因

现有定向测试分别覆盖了 data memory 的子字节访问和 MMIO 的 word 访问，但尚未覆盖“已映射 MMIO 寄存器的合法子字节访问”这一交叉场景：

- `sw/asm/0801_dmem_wait_basic.S` 包含 `SB/LB/LBU` 和 `SH/LH/LHU`，但访问对象是 data memory。RAM 会忽略地址低两位进行 word 选择，再由 `be` 选择 byte lane，因此这些测试能够通过。
- 现有 MMIO 汇编测试主要使用 word-aligned 的 `LW/SW` 访问寄存器，没有产生 `reg+1` 或 `reg+2` 形式的合法子字节请求。
- C 测试通过 `mmio_read32`、`mmio_write32` 等 32-bit 接口访问 MMIO，编译后同样是 word-aligned 的 word load/store。
- `sw/asm/0605_mmio_misaligned_priority.S` 验证的是未对齐 `LW/SW` 的异常优先级。这类请求会在 core 内被判定为 misaligned，并在到达 data subsystem 前被抑制，因而不能覆盖已映射 MMIO 寄存器上的合法 byte/halfword 访问。

所以，当前回归通过只能说明 DMEM 子字节语义和 MMIO word 访问语义分别正确，不能说明 MMIO 子字节访问已经正确实现。

### 修复内容

修复保留 simple data bus 的原始 byte address 语义，未在 `mem_stage` 强制清除地址低两位。GPIO0、UART0、TIMER0 的寄存器 decode 均改为使用 `{full_offset[11:2], 2'b00}` 形成 word-aligned offset，再由原有 `be` 逻辑选择有效 byte lane。

因此 core 继续保留 byte address、MMIO register decode 忽略地址低两位、byte lane 仍由 `be` 决定，三者的职责边界保持一致。真正未定义的 word offset 不发生 alias，仍由各外设输出 `access_fault_o`。

### 验证与关闭依据

修复后使用相同命令和 seed `1` 运行 `uvm/v6_0/data_subsystem/sim/run_test.sh DS_map_random_test 1`，结果从修复前的 `UVM_ERROR=52` 变为 `UVM_ERROR=0`、`UVM_FATAL=0`。同一 2100 笔事务中，simple bus scoreboard 汇总为 `correct_num=819, error_num=0, partial_num=703, skip_num=578`，wrapper scoreboard 为 `check_num=2100, correct_num=2100, error_num=0`，functional coverage 为 data `96.67%`、behavior `100.00%`。

修复前日志中的未知 GPIO0 word offset 在修复后仍返回 error，说明修复没有把未定义寄存器错误 alias 为已定义寄存器。用户已运行现有 Verilator C/ASM 定向自检仿真，结果通过。至此，修复前 FAIL、修复后同 seed PASS、wrapper timing 检查和主线软件回归均具备证据，RTL-001 关闭。

## REG-001：SoC 回归脚本将 FAIL/TIMEOUT 误统计为 PASS

| 项目 | 内容 |
| --- | --- |
| 状态 | `Fixed` |
| 发现日期 | 2026-07-01 |
| 修复日期 | 2026-07-01 |
| 修复版本 | v5.6（提交 `7af8c51`，tag `v5.6-bugfix-regression-stat`） |
| 影响范围 | SoC 汇编和 C directed regression 的结果统计；被掩盖的失败用例包括汇编 `0603_gpio_rw`、C `0651_soc_mmio_smoke` 和 `0652_soc_mmio_gpio_uart` |
| 相关文件 | `sim/soc_asm/run_all.sh`、`sim/soc_c/run_all.sh`、`sw/asm/0603_gpio_rw.S`、`sw/c/0651_soc_mmio_smoke.c`、`sw/c/0652_soc_mmio_gpio_uart.c`、`tb/sv/tb_rv32i_soc.sv`、`rtl/soc/data_subsystem.sv` |

### 问题说明

早期 ASM/C 回归脚本只根据仿真器进程退出码判断单项测试是否通过。testbench 使用 `$fatal`/`$finish` 结束仿真时，退出码不能可靠地区分 PASS、FAIL 和 TIMEOUT；因此，部分已经打印失败或超时信息的测试仍会被脚本计为 PASS，导致回归汇总不可信，并掩盖了后续列出的测试程序问题。

### 修复内容与关联问题

- 两个 `run_all.sh` 均为每个测试保留日志；只有仿真退出码为 0、日志包含 `PASS after `，且不包含 `FAIL after ` 或 `TIMEOUT:` 时才统计为 PASS。否则明确统计为 FAIL，并打印日志路径。
- 统计修复后暴露出 GPIO IN 检查假设错误：`GPIO_IN[31:30]` 由 TB 周期信号驱动，不是固定输入。`0603`、`0651`、`0652` 改为屏蔽高两位，仅比较稳定的 `GPIO_IN[29:0]`。
- TB 中 `gpio0_in[29:0]` 的复位默认值由 `'0` 改为 `30'hA5A55A5A`，与上述用例的默认输入约定一致。
- 同一提交还将 `data_subsystem.sv` 中 `resp_target` 改为显式声明后再连续赋值，修正该处的连续赋值声明问题。

### 验证与关闭依据

修复后的回归入口会把 PASS/FAIL/TIMEOUT 文本结果纳入统计，失败测试不再仅因进程返回码而误报成功。相关 GPIO 用例已按 TB 的实际驱动语义更新，修复提交已随 v5.6 及后续 release 保留。

## UVM-001：DMEM scoreboard 截断地址导致随机回归误报

| 项目 | 内容 |
| --- | --- |
| 状态 | `Fixed` |
| 发现日期 | 2026-07-23 |
| 修复日期 | 2026-07-23 |
| 影响范围 | `uvm/v6_0/data_subsystem` 的 DMEM 随机测试及其 scoreboard 结果 |
| 相关文件 | `uvm/v6_0/data_subsystem/tb/checker/simple_bus_scoreboard.svh`、`uvm/v6_0/data_subsystem/tb/seq/simple_bus_sequences.svh`、`uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_virtual_sequences.svh` |
| 关联 RTL | `rtl/mem/simple_ram.sv`（本问题中未发现 RTL 读写错误） |

### 问题说明

`DS_dmem_random_test_200` 通过，但 `DS_dmem_random_test_2000` 失败并报告 108 个 DMEM read mismatch。根因是 scoreboard 的 `addr_2_dmem_word_addr()` 以 `{addr[DMEM_ADDR_WIDTH-3:2], 2'b00}` 生成参考模型 key。当前 `DMEM_ADDR_WIDTH = 16`，该表达式没有先减去 `DMEM_BASE`，并且丢弃了 DMEM offset 的高两位，导致相隔 `0x4000` 字节的不同 DMEM 地址发生别名。

首个误报可由日志直接确认：

- 先前写 `0x0004_6a81`，`be=4'b1101`，`wdata=0x3746_d5ca`。
- 后续读 `0x0004_aa81`；两地址相差 `0x4000`，在 256 KiB DMEM 中是不同存储位置，RTL 正确返回初始化值 `0`。
- scoreboard 将二者都映射为 key `0x0000_2a80`，错误地期望前一笔写合并后的值 `0x3746_00ca`，从而报 mismatch。

RTL 的 `simple_ram` 使用 `(addr_i - DMEM_BASE) >> 2` 作为 16-bit word index，能区分上述两个地址。因此，这些失败是 golden model 的误报，不能据此判定 RTL 存在 DMEM 数据损坏。

### 为什么 200 次回归会通过

`DS_dmem_random_test_200` 的汇总为 `correct_num=0, error_num=0, skip_num=200`：它没有形成一次被 scoreboard 正确比较的写后读，只是尚未随机触发该错误别名。2000 次运行扩大了随机碰撞概率，最终得到 `correct_num=18, error_num=108, skip_num=1874`。

此外，当前随机激励的地址池实际上未跨事务生效：virtual sequence 在每轮 `repeat` 内新建 `simple_bus_dmem_random_access_seq`，并将 `num_items` 设为 1。该 sequence 内维护的 `written_word_keys` 和 `written_word_seen` 会在唯一一笔请求结束后随对象丢弃。因此后续 read 无法从先前 write 的地址池中选择地址，当前随机测试主要是读从未写过的位置；200 次日志的 `correct_num=0` 正是这一问题的表现。

### 随机地址池的修复方式

保留 `simple_bus_dmem_random_access_seq` 作为地址池的唯一所有者，但将 `bus_seq` 的创建移至 virtual sequence 的 `repeat` 外。随后在每轮中启动同一个 `bus_seq`，并保持 `bus_seq.num_items = 1`；这样该对象的已写地址池能覆盖整个 200/2000 笔访问流。wrapper sequence 也可在循环外创建并在每轮重复 `start()`，其 `body()` 每次都会重新随机生成一笔 delay 配置，不会复用上次的配置值。推荐结构如下：

```systemverilog
bus_seq = simple_bus_dmem_random_access_seq::type_id::create("bus_seq");
bus_seq.num_items = 1;
wrp_seq = wrapper_dmem_cfg_random_seq::type_id::create("wrp_seq");
wrp_seq.num_items = 1;

repeat (num_items) begin
    wrp_seq.start(p_sequencer.wrp_sequencer);
    bus_seq.start(p_sequencer.bus_sequencer);
end
```

`simple_bus_dmem_random_access_seq` 当前以 `addr[XLEN-1:2]` 保存 word 地址，足以区分完整 DMEM 空间；其地址池本身不需要采用 scoreboard 现有的错误截断方式。应确保其生命周期按上述方式延续，并可补充显式清池方法以便同一个 sequence 对象被不同测试阶段复用时重置状态。

### 预期修复方向

scoreboard 应以完整的 DMEM 相对 byte offset 对齐后作为 key，例如使用 `(addr - DMEM_BASE) >> 2` 的 16-bit word index；该口径应与 RAM 的实际 16-bit word index / 256 KiB 容量一致。与此同时，按上述方式延续随机 sequence 的地址池生命周期，确保产生真实的写后读事务。

### 验证与关闭条件

- 修复后使用原测试、原随机种子运行 `DS_dmem_random_test_200` 与 `DS_dmem_random_test_2000`，两者均无 UVM error 即可关闭。
