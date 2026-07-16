# v6.0 Simple Data Bus UVM Verification Spec

本文定义 `uvm/v6_0/simple_bus` 这套独立 UVM 工作区对应的验证对象、simple data bus 协议语义、transaction 抽象、检查边界和非目标。

本 spec 绑定项目 `v6.0` 阶段的 simple data bus 语义。后续若 data bus 被 AXI-Lite 或其它协议替换，本 spec 应作为历史版本保留或归档；新的验证环境应另起目录和 spec，不应静默复用本文。

## 1. 定位

本 UVM 环境用于验证 0834 后形成的 data-side simple request/response 总线和 `data_subsystem` 访问边界。

0835 完整环境的目标是：

- 用 UVM master 直接驱动 simple data bus。
- 实例化 `data_subsystem`、外置 `simple_ram` 和现有 GPIO0/UART0/TIMER0 寄存器模型。
- 覆盖 DMEM/MMIO read/write、response delay、error response 和部分 MMIO 副作用。
- 沉淀 driver、monitor、scoreboard、SVA 和 coverage 的基础组织方式。

本环境不实例化整颗 `rv32i_soc`，不运行 `.mem` 程序，不验证 CPU 指令流、GPR、CSR、trap handler 或 interrupt 精确提交。

现有 Verilator ASM/C self-check regression 继续保留。本 UVM 环境是补充验证资产，不替代 directed regression。

## 2. 文件与版本边界

UVM 源码目录：

```text
uvm/v6_0/simple_bus/tb
```

DUT RTL/ABI 快照目录：

```text
uvm/v6_0/simple_bus/dut
```

仿真脚本目录：

```text
uvm/v6_0/simple_bus/sim
```

目录名体现版本绑定；文件名、package 名、class 名保持 `simple_bus_*` 风格即可。v6.0 filelist 只编译本工作区的 DUT 快照，不引用根目录主线 RTL。不同版本的 UVM 环境不应同时放入同一个 VCS filelist 编译，避免 package/class/module 重名冲突。快照来源、文件映射和同步/冻结规则见 `dut/README.md`。

## 3. DUT Harness

第一版 DUT harness 应包含：

```text
UVM simple bus master
        |
        v
simple data bus interface
        |
        v
data_subsystem
        |
        +--> external simple_ram as DMEM model
        +--> mmio_gpio  GPIO0
        +--> mmio_uart  UART0
        +--> mmio_timer32 TIMER0

UVM delay configuration
        |
        v
resp_delay_cfg_if
        |
        +--> per-target response delay inputs
```

`simple_bus_if` 只表达 core-side request/response 协议。`resp_delay_cfg_if` 是 v6.0 DUT 专用的验证配置通道，用于控制各 target 的 response delay；它不是 simple data bus 的组成部分，也不应进入通用 simple bus agent 的 transaction payload。

`data_subsystem` core 侧接口是验证主接口：

| 信号 | 方向 | 说明 |
|---|---|---|
| `core_req_i.valid` | master -> DUT | request payload 有效。 |
| `core_req_i.write` | master -> DUT | 1 表示 write/store，0 表示 read/load。 |
| `core_req_i.be` | master -> DUT | byte enable，bit0 对应低 byte。 |
| `core_req_i.addr` | master -> DUT | byte address。 |
| `core_req_i.wdata` | master -> DUT | write data，按 byte lane 对齐。 |
| `core_req_ready_o` | DUT -> master | DUT 可接受新 request。 |
| `core_resp_o.valid` | DUT -> master | response payload 有效。 |
| `core_resp_o.rdata` | DUT -> master | read response data；write 或 error 时不作为主要检查对象。 |
| `core_resp_o.error` | DUT -> master | 1 表示本次访问产生 bus/access error。 |

`core_req_i` 和 `core_resp_o` 类型来自 `dut/rtl/common/data_bus_pkg.sv`：

- `data_bus_pkg::data_req_t`
- `data_bus_pkg::data_resp_t`

`ready` 当前保持为离散信号，不在结构体内。

response 侧没有 `resp_ready`。master 不能对 response 施加 backpressure，必须在 `core_resp_o.valid=1` 的采样点接收结果；DUT 也不能等待 master 的额外确认。

## 4. Simple Data Bus 协议

### 4.1 Request 接受

一笔 request 在下列条件同时成立的时钟采样点被 DUT 接受：

```text
req_accept = core_req_i.valid && core_req_ready_o
```

UVM driver 应在 request 被接受前保持 request payload 稳定。payload 包括：

- `write`
- `be`
- `addr`
- `wdata`

当 `core_req_i.valid=1` 且 `core_req_ready_o=0` 时，driver 不得改变上述 payload。

master 可以在两笔 transaction 之间主动保持 request idle。对于非首笔 transaction，`idle_cycles` 定义为：上一笔 response 完成后，到本笔 `core_req_i.valid` 首次为 1 前，额外保持 `core_req_i.valid=0` 的完整采样拍数。第一笔 transaction 没有“上一笔 response”，其 `idle_cycles` 定义为 reset 释放锚点后、首个 `core_req_i.valid=1` 前的完整采样拍数，即 initial idle。

`idle_cycles=0` 表示 driver 在上一笔 response 完成后的最早下一采样拍发起 request；首笔则表示 reset 释放后按最小时序发起 request。`idle_cycles=N` 且 `N>0` 表示额外保持 N 个完整采样拍 request idle。该间隔由 sequence 决定、driver 执行，不能由 driver 自行随机。sequence 不应在相邻 item 之间另外用时钟等待制造隐含 gap；所有有意的 request 间隔都通过 `idle_cycles` 表达。request idle 且没有 outstanding transaction 时，DUT 不应产生 response。

### 4.2 Response 完成

一笔 transaction 在 `core_resp_o.valid=1` 的时钟上升沿采样点完成。

`data_subsystem` 支持 0 wait-state response：request 被接受的同一个采样点，`core_resp_o.valid` 可以同时为 1。

非 0 wait-state 时，DUT 在 request accepted 后若干拍返回 `core_resp_o.valid=1`。在 response 返回前，`core_req_ready_o` 应保持为 0，避免接受第二笔 request。

### 4.3 Single Outstanding

v6.0 simple data bus 只支持 single outstanding、in-order completion：

- 同一时刻最多只有一笔 accepted 但未 response 的 transaction。
- 没有 transaction ID。
- 每个 response 必须对应最近一笔尚未完成的 accepted request。
- 不允许 orphan response。
- 不允许在 outstanding 未完成时接受第二笔 request。

UVM monitor 可以用一个 pending transaction 建模，不需要 queue。

testbench 必须设置全局仿真 timeout，driver 也应对单笔 transaction 设置 response 等待上限。超时属于协议或 DUT 失败，应报告当前 request 的 addr、op、target 和已等待拍数，不能让回归永久挂起。等待上限应大于本次 test 允许配置的最大 target delay，并留有调度裕量。

### 4.4 Reset 语义

复位期间，UVM driver 应驱动 request idle：

```text
core_req_i.valid = 0
```

DUT 在 reset 有效期间不应对外产生有效 response。SVA 可以检查 reset quiet，但第一版若遇到初始化 X，可根据 VCS 实际表现调整断言使能时机。

### 4.5 Error 语义

`core_resp_o.error=1` 表示该 transaction 访问失败。第一版 UVM 不需要模拟 CPU trap，只需要把 error 作为 transaction 结果检查。

error response 的 `rdata` 不作为软件可见有效数据检查对象。

## 5. 地址与 Target

地址常量来源：

| 常量 | package | 说明 |
|---|---|---|
| `DMEM_BASE` | `core_pkg` | DMEM 起始地址。 |
| `DMEM_SIZE_BYTES` | `core_pkg` | DMEM 窗口大小。 |
| `GPIO0_BASE` | `soc_pkg` | GPIO0 实例基地址。 |
| `GPIO0_SIZE_BYTES` | `soc_pkg` | GPIO0 窗口大小。 |
| `UART0_BASE` | `soc_pkg` | UART0 实例基地址。 |
| `UART0_SIZE_BYTES` | `soc_pkg` | UART0 窗口大小。 |
| `TIMER0_BASE` | `soc_pkg` | TIMER0 实例基地址。 |
| `TIMER0_SIZE_BYTES` | `soc_pkg` | TIMER0 窗口大小。 |

Target 译码：

| Target | 地址范围 | 期望 |
|---|---|---|
| DMEM | `[DMEM_BASE, DMEM_BASE + DMEM_SIZE_BYTES)` | 命中外置 `simple_ram`，窗口内当前不产生 bus error。 |
| GPIO0 | `[GPIO0_BASE, GPIO0_BASE + GPIO0_SIZE_BYTES)` | 命中 `mmio_gpio`。未知 offset 返回 error。 |
| UART0 | `[UART0_BASE, UART0_BASE + UART0_SIZE_BYTES)` | 命中 `mmio_uart`。未知 offset 返回 error。 |
| TIMER0 | `[TIMER0_BASE, TIMER0_BASE + TIMER0_SIZE_BYTES)` | 命中 `mmio_timer32`。未知 offset 返回 error。 |
| undefined | 其它地址 | 同拍返回 error，`rdata=0`。 |

MMIO 寄存器 offset、bit 定义、访问属性和副作用以 `dut/docs/periph_register_abi.md` 为准。本 spec 只规定 UVM 应引用这些 ABI 进行检查，不重复维护完整寄存器手册。

## 6. Transaction 抽象

UVM item 应描述一笔完整 simple bus transaction，而不是只描述 request。

建议字段：

| 字段 | 来源 | 说明 |
|---|---|---|
| `write` | driver/monitor | 1=write，0=read。 |
| `addr` | driver/monitor | byte address。 |
| `be` | driver/monitor | byte enable。 |
| `wdata` | driver/monitor | write data。 |
| `idle_cycles` | sequence/driver/monitor | 本笔 request 前由 master 插入的额外 idle 拍数；首笔表示 reset 释放后的 initial idle。 |
| `rdata` | monitor | response read data。 |
| `error` | monitor | response error。 |
| `target` | monitor 或 scoreboard 推导 | DMEM/GPIO0/UART0/TIMER0/undefined。 |
| `resp_delay` | driver/monitor | accepted request 到 response valid 的间隔拍数；monitor 观察值是 scoreboard/coverage 的主要来源。 |

`resp_delay=0` 表示 request accepted 与 response valid 出现在同一个采样点。

sequence 为每笔 item 设置 `idle_cycles`，driver 按该值保持 request idle 后再发 request，并等待 response。driver 也可以把本笔实际 response 等待拍数回填到原始 item，供 sequence 做定向自检；monitor 独立观察总线，把 request 前实际出现的 idle 间隔、accepted request 和 response 合成为一笔 transaction，并通过 analysis port 提供给 scoreboard、coverage 或专用 checker 等订阅者。

item 中的 `idle_cycles` 是 sequence 计划值，driver 在取得该 item 后执行；monitor 中的 `idle_cycles` 是 interface 引脚上的实际观测值。正常 sequence 不在相邻 item 之间插入额外时间控制，按 clocking event 连续交付时两者必须一致。若未来某个 sequence 在相邻 clocking event 之间交付 item，request 只能在下一次 clocking output skew 生效，monitor 可能额外观察到一个用于对齐的完整 idle 拍；该情况属于验证平台调度偏差，不是当前测试的正常预期，也不归因于 DUT。DUT 功能检查和 coverage 仍以 monitor 观测值为准，计划值与实际值的精确比较由专用 driver idle-gap checker 诊断，不由通用 scoreboard 静默放宽。

`idle_cycles` 与 response delay 相互独立：前者模拟 CPU 在两次 data access 之间没有发起总线请求的周期，后者模拟 request accepted 后 DUT 返回 response 的等待周期。基础 smoke 固定 `idle_cycles=0`；定向 idle-gap test 覆盖若干固定间隔；constrained-random sequence 再逐笔随机合法间隔。

### 6.1 约束归属与激励分层

`simple_bus_item` 是协议级 transaction，通用约束只要求 `be != 0`，不在 item
中加入 CPU access size、地址窗口、MMIO 寄存器 offset 或 target 权重。这样 generic
bus-corner sequence 可以覆盖任意非零 byte-enable 组合，而不会被当前 RV32I core 的
访存指令形状限制。

模拟当前 CPU 请求时，专属 sequence 对同一个 item 施加 access profile 约束：

| profile | `addr` / `be` 关系 |
|---|---|
| CPU byte | `be = 4'b0001 << addr[1:0]`。 |
| CPU halfword | `addr[0] == 0`；`addr[1] == 0` 时 `be = 4'b0011`，否则 `be = 4'b1100`。 |
| CPU word | `addr[1:0] == 0`，`be = 4'b1111`。 |
| generic bus corner | 地址与任意非零 `be` 独立生成，不代表当前 CPU 一定会产生该请求。 |

因此，DMEM、known-MMIO、unknown-MMIO 和 unmapped-address 应由不同 sequence 或
sequence mode 生成，而不是通过 item 子类区分。只有 simple bus 协议增加了新的
transaction 字段时，才考虑新增 item 类型。

随机 sequence 先在 sequence 层选择 target，再约束 `addr`。legal traffic 的初始
建议分布为 DMEM 50%、GPIO0 20%、UART0 15%、TIMER0 15%；窗口外地址由独立
negative sequence 覆盖。对每个 MMIO target，必须再区分 ABI 已定义的 register
word offset 和 unknown offset：正常功能流以 known offset 为主，unknown offset
作为独立 error 流或较低权重 bucket。这样不会让大量未定义 offset 淹没有效 MMIO
访问。

MMIO known-register sequence 从 `dut/docs/periph_register_abi.md` 选择寄存器，
再按其访问属性和 access profile 生成请求。对当前 `RTL-001`，已定义寄存器的
`reg+1` byte 和 `reg+2` halfword 请求应先作为预期失败的定向用例；修复后再纳入
正常的 known-MMIO byte-enable 随机流。

## 7. Response Delay 模型

`data_subsystem` 当前通过 wrapper 给固定响应 DMEM/MMIO target 注入 response delay。

每个 target 独立配置一个 7-bit delay：

| 输入 | 说明 |
|---|---|
| `dmem_resp_delay_cycles_i` | DMEM response delay。 |
| `gpio0_resp_delay_cycles_i` | GPIO0 response delay。 |
| `uart0_resp_delay_cycles_i` | UART0 response delay。 |
| `timer0_resp_delay_cycles_i` | TIMER0 response delay。 |

语义：

- `delay=0`：同拍 response。
- `delay=N` 且 `N>0`：request accepted 后延迟 N 拍返回 response。
- undefined target 当前不经过 target delay，保持同拍 error response。

response delay wrapper 是验证配套层，不表示外设本体一定是多拍 slave。GPIO/UART/TIMER32 本体仍是固定响应寄存器块；wrapper 在 request accepted 当拍访问本体并锁存结果，再延迟返回给 core/simple bus master。

delay 配置通过独立的 `resp_delay_cfg_if` 连接到上述四个 DUT 输入。该 interface 由 UVM top 实例化，通过 `uvm_config_db` 把 virtual interface 句柄交给需要动态配置的 test/sequence；通用 simple bus driver 仍只负责 `req/req_ready/resp`，不直接拥有 DUT 专用 delay 配置。

delay 配置的生效和切换规则：

- top 在仿真开始时把所有 target delay 初始化为 0，plusarg 可以覆盖本次仿真的固定初值。
- DUT 在 request accepted 的采样点选择本笔 target delay；配置必须在该采样点前稳定。
- 动态 test 只在没有 outstanding transaction 时修改 delay。上一笔 response 完成后，才能为下一笔 transaction 设置新值。
- transaction outstanding 期间不修改配置，避免把“本笔已锁存值”和“下一笔预配置值”混为一谈。

wait-state 验证分三层保留：

| 层次 | delay 行为 | 主要用途 | 检查要求 |
|---|---|---|---|
| fixed smoke | 一次 test/run 全程固定为 0、1、3、7 等值 | 基础调试和单一 delay 失败定位。 | 独立 checker 自动比较 expected/observed delay。 |
| deterministic dynamic | 单次 test 按 `0 -> 3 -> 1 -> 7 -> 0` 等序列逐笔切换 | 检查计数器清理、重新锁存和跨 transaction 污染。 | sequence 定向自检，同时经过独立 checker。 |
| constrained random | 每笔 transaction 随机合法 delay | 扩展组合覆盖，放在确定性动态测试稳定之后。 | 独立 checker 自动比较，并采集 delay coverage。 |

### 7.1 Response Delay 检查要求

response delay wrapper 属于本环境需要验证的 DUT 行为。除 sequence 根据 driver 回填结果进行定向自检外，还应有一条独立的 expected/observed 检查路径；不能只依赖发起配置的 sequence 自己判断 wrapper 是否正确。

每笔 transaction 按以下口径检查：

| 检查信息 | 来源与时机 |
|---|---|
| `expected_delay` | request accepted 时，根据地址译码 target，并快照该 target 当拍生效的 delay 配置。 |
| `observed_delay` | monitor 从 accepted request 到对应 response valid 独立统计得到的 `resp_delay`。 |

response 完成后比较 `expected_delay == observed_delay`。undefined target 不经过 target delay wrapper，因此 `expected_delay` 固定为 0。当前协议是 single outstanding、in-order completion，expected 与 observed 可以按顺序关联，不需要 transaction ID。

该检查与通用 simple bus 功能 scoreboard 并列：功能 scoreboard 负责 data/error/MMIO 结果，response-delay checker 负责 wrapper 的配置值与实际等待拍数。sequence 对原始 item 的比较可以保留用于快速定位，但不能替代这条独立检查。固定 delay、确定性 dynamic delay 和后续 random delay 都必须经过相同的 checker。

动态 test 应自动比较本笔配置的 expected delay 和 driver/monitor 观察到的 `resp_delay`；日志仍保留 addr、target、configured delay 和 observed delay，便于定位 off-by-one 问题。

## 8. DMEM 检查边界

DMEM 使用 `simple_ram` 作为固定响应 memory model：

- 读路径是组合读。
- 写路径在时钟上升沿按 byte enable 更新 byte lane。
- `DMEM_BASE` 映射到 `mem[0]`。

UVM scoreboard 第一版至少应检查：

- word write 后，后续 word read 返回最后一次写入值。
- 多个地址的写后读互不污染。
- `delay=0` 和 `delay>0` 下数据结果一致。
- DMEM 窗口内访问不应返回 error。

byte enable 可以分阶段支持：

- 第一版 smoke 可以只检查 `be=4'hf` 的 word write/read。
- 后续再扩展 `be` 组合，按 byte lane 更新 reference memory。

未初始化地址读值如果依赖 `simple_ram` 初始清零，则 scoreboard 可以把未写地址期望为 0；若后续允许 `$readmemh` 初始化，则 reference model 也应同步初始化来源。

## 9. MMIO 检查边界

MMIO 检查应以软件可见 ABI 为准，而不是直接检查 RTL 内部实现细节。

通用规则：

- 未知 offset 应返回 error。
- RO 写入当前忽略，不触发 error。
- WO 读取当前返回 0，不触发 error。
- 写保留 bit 当前不触发 error，但软件不应依赖保留 bit 读回值。
- byte enable 对 RW/R/W1C 寄存器有意义，未选 byte 不应被更新或清除。

### 9.1 GPIO0

第一版建议覆盖：

- `OUT` 写后读一致，并反映到 `gpio0_out_o`。
- `OE` 写后读一致，并反映到 `gpio0_oe_o`。
- `IN` 读同步后的 `gpio0_in_i` 视图。
- `IRQ_PENDING` W1C 清除语义。
- `IRQ_STATUS = IRQ_PENDING & IRQ_EN`。
- 未知 offset 返回 error。

GPIO 输入同步带来约两拍延迟。UVM 若直接驱动 `gpio0_in_i`，检查 `IN` 或中断触发时应等待同步链传播。

### 9.2 UART0

第一版建议覆盖：

- `CTRL.tx_enable=1` 时写 `TXDATA[7:0]` 产生一拍 TX event。
- `CTRL.tx_enable=0` 时写 `TXDATA` 不产生 TX event。
- `STATUS.tx_ready` 当前固定为 1。
- RX event 后 `STATUS.rx_valid=1`，`RXDATA[7:0]` 返回收到的 byte。
- 读 `RXDATA` 清 `rx_valid` 和 `IRQ_PENDING[0]`。
- `IRQ_PENDING` 支持 W1C；读 `IRQ_PENDING` 本身不清 pending。
- 未知 offset 返回 error。

当前 UART 是单拍事件模型，不是真实串口物理层；UVM 不验证 baud rate、start/stop bit、FIFO full/empty 或异步 RX CDC。

### 9.3 TIMER0

第一版建议覆盖：

- `MTIME` 可读写。
- 写 `MTIME` 的同拍不自增。
- 写 `MTIMECMP` 不阻止 `MTIME` 自增。
- `CTRL.enable=1` 后计数自增。
- `STATUS.mtip` 与 `timer0_irq_o` 反映 `CTRL.enable && (MTIME >= MTIMECMP)`。
- 未知 offset 返回 error。

timer 是 free-running 类型外设。UVM 检查时应避免把精确拍数和总线 wait-state 混在一起；需要精确计数时，应明确扣除或固定 response delay。

## 10. SVA 检查边界

SVA 应检查协议级 invariant，不应写成具体 test case。

第一批推荐断言：

| 断言 | 意义 |
|---|---|
| payload stable when wait | `valid && !ready` 期间 request payload 不变。 |
| single outstanding | outstanding response 返回前不接受第二笔 request。 |
| response matched / no orphan response | 每个 response 都对应一笔未完成 request，或对应本拍刚 accepted 的 0 wait-state request。 |
| reset quiet | reset 有效期间 request/response 不应有效。 |

若断言放在 `simple_bus_if` 内，可由 VCS/UVM filelist 控制；若后续需要复用到 SoC directed TB，可考虑 bind 到 core/data_subsystem 观察口。

本阶段暂不要求用 SVA 验证 CPU 内部 trap 精确提交、CSR 原子性、branch flush 或 interrupt priority。这些属于 SoC/CPU 级验证，不是第一版 simple bus UVM 的主要边界。

## 11. Scoreboard 与 Reference Model

scoreboard 负责检查 transaction 结果，不负责驱动 DUT。

第一版建议分层：

```text
simple_bus_monitor
  -> observed transaction
  -> simple_bus_scoreboard
       - target decode
       - DMEM reference memory
       - selected MMIO register reference state
       - error expectation
```

DMEM reference model 可以先做 associative array：

- write 时按地址记录期望值。
- read 时比较 `rdata`。
- 第一版只支持 word write/read，后续扩展 byte enable。

MMIO reference model 可以逐步扩展：

- 先检查 known/unknown offset 的 error 语义。
- 再加入 GPIO OUT/OE。
- 再加入 UART/TIMER 副作用。

带副作用寄存器应在 spec 层定义“访问完成后软件可见状态”，scoreboard 决定用何种内部状态机建模。不要在 spec 中规定 scoreboard 的具体类结构。

## 12. Coverage 目标

coverage 用于证明测试覆盖过关键组合，不替代 scoreboard/SVA。

0835 完整环境的基础覆盖点：

| 覆盖点 | 取值 |
|---|---|
| target | DMEM/GPIO0/UART0/TIMER0/undefined |
| op | read/write |
| response | OK/error |
| delay | 0 / small non-zero / larger non-zero |
| request idle gap | 0 / small non-zero / larger non-zero |
| byte enable | `4'hf`，后续扩展其它组合 |
| access profile | word，后续扩展 CPU byte/halfword 与 generic bus corner |
| MMIO offset | known/unknown |

后续可加入 cross：

- target x delay
- target x request idle gap
- request idle gap x delay
- target x read/write
- target x OK/error
- MMIO register x read/write
- target x access profile
- MMIO known/unknown offset x read/write
- GPIO/UART/TIMER side effect x delay

0835 coverage 不追求完整闭合，重点是建立可运行的 covergroup 和覆盖报告入口。

## 13. UVM 与 Directed Test 的边界

UVM simple bus 环境不使用：

- `.mem` 程序。
- crt0。
- C/ASM 自检测试。
- TB mailbox DMEM command 协议。
- CPU commit trace。
- trap handler。

这些仍属于 Verilator SoC directed regression。

UVM 使用本工作区快照中的这些定义：

- `dut/docs/periph_register_abi.md`：外设寄存器 ABI。
- `dut/rtl/common/core_pkg.sv`：IMEM/DMEM 基本地址常量。
- `dut/rtl/common/soc_pkg.sv`：MMIO 地址图和寄存器 offset 常量。
- `dut/rtl/common/data_bus_pkg.sv`：simple data bus 结构体。

## 14. Out of Scope

本 spec 不覆盖：

- AXI-Lite 协议。
- AXI-Lite adapter/interconnect。
- full SoC/CPU UVM。
- ISS lockstep。
- random instruction generation。
- RISC-V ISA reference model。
- 真实 UART 串口物理层。
- FPGA 板级时序、PLL、外部 SRAM/Flash controller。

这些内容可在后续阶段另写 spec。

## 15. MVP 与阶段完成标准

第一阶段先达到可运行 MVP，至少满足：

- VCS 能编译并运行 `simple_bus_base_test`。
- VCS 能运行一个 DMEM read/write smoke test。
- monitor 能把 accepted request 和 response 合成为 transaction。
- scoreboard 能自动判断 DMEM word write/read PASS/FAIL。
- 能配置至少 DMEM 的 0 wait 和非 0 wait。
- 一个定向 idle-gap test 能在相邻 transaction 之间插入 0/1/3/7 等不同间隔，且 monitor 能观察到对应 gap，scoreboard/SVA 仍通过。
- 至少一个确定性动态 test 能在单次仿真中逐笔切换多个 delay，并自动检查 configured/observed delay 一致。
- 独立 response-delay checker 能对固定和动态 delay 自动比较 expected/observed 拍数。
- 至少有一组 simple bus SVA 处于可运行状态。
- log 中能看出 transaction 的 addr、op、target、idle gap、response delay、error。
- 全局 timeout 和单 transaction response timeout 能把无响应转换为明确失败，而不是永久挂起。

MVP 之后继续扩展 MMIO、byte enable、side effect、random idle gap、random delay 和 coverage。0835 阶段最终完成标准以 `docs/08xx/0835 wait-state验证收口、SVA与UVM入门demo规划.md` 第 13 章为准；扩展时仍应以本文为验证边界，避免把本环境扩大成 full CPU UVM。
