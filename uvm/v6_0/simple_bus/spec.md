# v6.0 Simple Data Bus UVM Verification Spec

本文定义 `uvm/v6_0/simple_bus` 独立 UVM 工作区最终形态的验证对象、协议语义、验证架构、
数据对象所有权、检查边界、coverage 目标和非目标。

本 spec 绑定项目 v6.0 的 simple data bus 与 `data_subsystem` response-delay wrapper。
后续若 data bus 被 AXI-Lite 或其它协议替换，本 spec 和对应工作区作为历史 release 资产保留；
新协议必须建立新的版本目录、verification spec 和 filelist，不能静默复用本文。

## 1. 定位

本 UVM 环境验证 0834 后形成的 data-side simple request/response bus、`data_subsystem` 地址
译码与外设访问边界，以及验证配套的 per-target response-delay wrapper。

完整环境应具备：

- UVM active master 驱动 simple data bus。
- 独立 wrapper configuration agent 驱动 per-target delay 配置。
- 独立 peripheral sideband 组件驱动 GPIO input/UART RX，并观测 GPIO/UART/TIMER 输出事件。
- virtual sequence 按 testcase 需要协调 bus、wrapper cfg 和 peripheral sideband stimulus。
- monitor 从 interface 独立重建 observed transfer。
- DMEM/MMIO 功能 scoreboard、wrapper delay checker、driver execution checker 分层检查。
- SVA 检查引脚级协议 invariant。
- functional coverage 只采样实际观察到的 transaction。
- 覆盖 DMEM/MMIO read/write、byte enable、error response、response delay、idle gap 和规定的
  MMIO side effect。

本环境不实例化整颗 `rv32i_soc`，不运行 `.mem` 程序，不验证 CPU 指令流、GPR、CSR、
trap handler 或 interrupt 精确提交。

现有 Verilator ASM/C self-check regression 必须继续保留。VCS/UVM/SVA 是并行验证平台，
不替代 directed regression。

## 2. 文件与版本边界

UVM 源码目录：

~~~text
uvm/v6_0/simple_bus/tb
~~~

DUT RTL/ABI 快照目录：

~~~text
uvm/v6_0/simple_bus/dut
~~~

仿真脚本目录：

~~~text
uvm/v6_0/simple_bus/sim
~~~

目录名体现 release 绑定；package/class 名保持 simple_bus 与 v6.0 data-subsystem wrapper
语义。最终归档后的 v6.0 filelist 只编译本工作区 DUT 快照，不引用根目录主线 RTL。不同 release
环境不进入同一个 VCS filelist，避免 package/class/module 重名和行为漂移。

开发期允许在修复 VCS 兼容性或已记录 RTL 问题时临时引用主工程 RTL；环境冻结时必须保存
snapshot、核对映射并切回归档镜像。快照来源和同步规则见 `dut/README.md`。

## 3. DUT Harness 与验证架构

### 3.1 静态 harness

~~~text
simple_bus_if
    |
    v
data_subsystem
    +--> external simple_ram as DMEM model
    +--> mmio_gpio    GPIO0
    +--> mmio_uart    UART0
    +--> mmio_timer32 TIMER0

resp_delay_cfg_if
    |
    +--> dmem/gpio0/uart0/timer0 response-delay inputs

data_subsystem_periph_if
    +--> gpio0 input/output/output-enable/irq
    +--> uart0 RX event/TX event/irq
    +--> timer0 irq
~~~

`simple_bus_if` 只表达 core-side request/response 协议。`resp_delay_cfg_if` 是 v6.0 DUT
wrapper 专用配置通道，不属于 simple bus，也不进入通用 bus transaction payload。

`data_subsystem_periph_if` 承载 simple bus 之外的外设侧带激励与观测。它同样不属于 simple
bus：GPIO input 和 UART RX 由专用 sideband driver 驱动，GPIO output/output-enable、UART TX
event 及三类 IRQ 由 sideband monitor 观察。若只运行 DMEM 或纯寄存器 smoke，可以保持输入
idle，但最终 MMIO side-effect 回归不能把这些端口常量绑死。

### 3.2 UVM 组件关系

~~~text
test
  -> virtual sequence
       -> simple_bus_virtual_sequencer
            +--> simple_bus_agent.sequencer
            |      -> simple_bus_driver
            |      -> simple_bus_if
            |
            +--> data_subsystem_resp_delay_wrapper_cfg_agent.sequencer
            |      -> wrapper cfg driver
            |      -> resp_delay_cfg_if
            |
            +--> data_subsystem_periph_agent.sequencer
                   -> peripheral sideband driver
                   -> data_subsystem_periph_if

simple_bus_monitor.transfer_ap
    +--> simple_bus_scoreboard
    +--> data_subsystem_resp_delay_wrapper_checker
    +--> simple_bus_driver_execution_checker
    +--> simple_bus_coverage

wrapper cfg driver.applied_cfg_ap
    +--> data_subsystem_resp_delay_wrapper_checker

simple_bus_driver.planned_item_ap
    +--> simple_bus_driver_execution_checker

data_subsystem_periph_agent.monitor.event_ap
    +--> target-specific MMIO checker/reference model
    +--> simple_bus_coverage
~~~

普通 bus smoke 可以直接启动 bus sequence；任何需要逐笔配置 wrapper 的场景必须通过 virtual
sequence 协调 bus agent 与 wrapper cfg agent。需要 GPIO input 或 UART RX 的场景由 virtual
sequence 协调 bus agent 与 peripheral sideband agent。test 和 virtual sequence 不直接访问
virtual interface。

### 3.3 DUT 主接口

| 信号 | 方向 | 说明 |
|---|---|---|
| `core_req_i.valid` | master -> DUT | request payload 有效。 |
| `core_req_i.write` | master -> DUT | 1=write/store，0=read/load。 |
| `core_req_i.be` | master -> DUT | byte enable，bit0 对应最低 byte lane。 |
| `core_req_i.addr` | master -> DUT | byte address。 |
| `core_req_i.wdata` | master -> DUT | 按 byte lane 对齐的 write data。 |
| `core_req_ready_o` | DUT -> master | DUT 可以接受新 request。 |
| `core_resp_o.valid` | DUT -> master | response payload 有效。 |
| `core_resp_o.rdata` | DUT -> master | read response data；write/error 时不作为软件有效数据。 |
| `core_resp_o.error` | DUT -> master | 1 表示本次访问失败。 |

`core_req_i` 和 `core_resp_o` 类型来自 `data_bus_pkg.sv`：

- `data_bus_pkg::data_req_t`
- `data_bus_pkg::data_resp_t`

`ready` 保持为离散信号。response 侧没有 `resp_ready`；master 不能对 response 施加
backpressure，必须在 `core_resp_o.valid=1` 的采样点接收结果。

## 4. Simple Data Bus 协议

### 4.1 Request 接受

request 在以下时钟采样点被接受：

~~~text
req_accept = core_req_i.valid && core_req_ready_o
~~~

request 被接受前，driver 必须保持以下 payload 稳定：

- `write`
- `be`
- `addr`
- `wdata`

当 `valid=1 && ready=0` 时，driver 不得改变 payload 或提前撤销 valid。

### 4.2 Request idle gap

对于非首笔 transaction，planned `idle_cycles` 定义为：上一笔 response 完成后，到本笔
`core_req_i.valid` 首次为 1 前，额外保持 valid=0 的完整采样拍数。

第一笔 transaction 没有上一笔 response，其 planned `idle_cycles` 表示 reset 释放锚点后的
initial idle。initial idle 受 test 启动和 clocking block 对齐影响，不进入 driver execution
checker 的严格比较。

`idle_cycles=0` 表示在协议允许的最早采样拍发起下一笔 request；`idle_cycles=N` 表示额外
保持 N 个完整 idle 拍。sequence 产生计划值，driver 只执行；sequence 不使用额外
`@(clock)` 隐式制造 gap。

monitor 独立统计 observed idle gap，并写入 transfer 的 `observed_idle_cycles`。非首笔
transaction 的 planned/observed gap 必须由 driver execution checker 精确比较，不默认接受
调度造成的 +1。

### 4.3 Response 完成与 delay

transaction 在 `core_resp_o.valid=1` 的时钟采样点完成。

- `observed_resp_delay=0`：request accepted 与 response valid 同拍。
- `observed_resp_delay=N`：response 在 accepted request 后第 N 个采样间隔返回。

在非 0 wait-state outstanding 期间，`core_req_ready_o` 必须保持为 0，避免接受第二笔
request。

### 4.4 Single Outstanding

v6.0 simple bus 只支持 single outstanding、in-order completion：

- 同一时刻最多一笔 accepted 但未 response 的 transaction。
- 没有 transaction ID。
- response 对应最近一笔未完成 request。
- 不允许 orphan response。
- outstanding 未完成时不接受第二笔 request。

monitor 只需一个 pending transfer。driver、monitor 和 SVA 都应具有防御性检查，但协议
invariant 的主要静态检查路径是 SVA。

testbench 必须有全局 timeout，bus driver 必须有单 transaction response timeout。timeout
上限大于最大 wrapper delay 127，并保留调度裕量；超时时打印 op、addr、target 和等待拍数。

### 4.5 Reset

reset 有效期间：

- bus driver 驱动 request idle，即 `core_req_i.valid=0`。
- DUT 不产生有效 response。
- wrapper delay 配置初始化为 0。
- 不启动 bus/config sequence。

当前环境只要求仿真开始时 reset；运行中 reset 不属于 reference model 的强制场景。若后续加入
mid-test reset，所有 agent、monitor pending state、checker expected state 和 reference model
必须统一定义 reset 行为。

### 4.6 Error

`core_resp_o.error=1` 表示 transaction 失败。UVM 不模拟 CPU trap，只检查 bus-visible
error 和软件可见结果。

error response 的 `rdata` 不作为有效数据比较。DMEM window 内访问不应 error；MMIO known/
unknown offset 和 unmapped address 按第 5、9 章检查。

## 5. 地址与 Target

地址常量来源：

| 常量 | package | 说明 |
|---|---|---|
| `DMEM_BASE` / `DMEM_SIZE_BYTES` | `core_pkg` | DMEM window。 |
| `GPIO0_BASE` / `GPIO0_SIZE_BYTES` | `soc_pkg` | GPIO0 window。 |
| `UART0_BASE` / `UART0_SIZE_BYTES` | `soc_pkg` | UART0 window。 |
| `TIMER0_BASE` / `TIMER0_SIZE_BYTES` | `soc_pkg` | TIMER0 window。 |

Target 译码：

| Target | 地址范围 | 期望 |
|---|---|---|
| DMEM | `[DMEM_BASE, DMEM_BASE + DMEM_SIZE_BYTES)` | 外置 `simple_ram`，合法访问不产生 error。 |
| GPIO0 | GPIO0 window | 命中 `mmio_gpio`；unknown offset 返回 error。 |
| UART0 | UART0 window | 命中 `mmio_uart`；unknown offset 返回 error。 |
| TIMER0 | TIMER0 window | 命中 `mmio_timer32`；unknown offset 返回 error。 |
| undefined | 其它地址 | 不经过 target wrapper，同拍返回 error，`rdata=0`。 |

MMIO offset、bit、访问属性和 side effect 以 `dut/docs/periph_register_abi.md` 为唯一 ABI
来源。本 spec 规定验证边界，不复制维护完整寄存器手册。

## 6. 数据对象、所有权与关联

### 6.1 simple_bus_item：planned command

`simple_bus_item` 只用于 sequence -> sequencer -> driver，表达 master 计划：

| 字段 | 来源 | 说明 |
|---|---|---|
| `write` | sequence | 计划 read/write。 |
| `addr` | sequence | 计划 byte address。 |
| `be` | sequence | 计划 byte enable。 |
| `wdata` | sequence | 计划 write data。 |
| `idle_cycles` | sequence | 计划 request 前 idle gap；首笔为 initial idle。 |

item 不保存 monitor 观察到的 response，不作为 scoreboard 或 coverage 的输入。driver 等到
response 后调用 `item_done()`，但 observed bus truth 只来自 monitor transfer。

driver 在开始执行 item 前把 clone 发布到 `planned_item_ap`。不能广播后续仍可能复用或修改的
原 item。

### 6.2 simple_bus_transfer：observed transaction

`simple_bus_transfer` 只由 monitor 创建，表达 interface 上实际完成的 transaction：

| 字段 | 来源 | 说明 |
|---|---|---|
| `write/addr/be/wdata` | monitor | 实际 accepted request payload。 |
| `rdata/error` | monitor | 实际 response payload。 |
| `observed_idle_cycles` | monitor | interface 上实际 request idle gap。 |
| `observed_resp_delay` | monitor | accepted request 到 response valid 的实际延迟。 |
| `accept_cycle/response_cycle` | monitor | 可选 debug 时间戳，不作为跨 test 稳定接口。 |
| target | transfer helper/checker | 根据实际 addr 推导。 |

monitor 不读取 item、cfg item 或 driver 内部状态。它在 request accepted 时建立 pending
transfer，在 response 时完成并通过 `transfer_ap` 广播。0 wait-state 同拍 accept/response
必须输出一笔完整 transfer。

### 6.3 wrapper cfg item：applied configuration command

`data_subsystem_resp_delay_wrapper_cfg_item` 表达 wrapper 配置命令：

| 字段 | 说明 |
|---|---|
| `target` | DMEM/GPIO0/UART0/TIMER0。 |
| `delay_cycles` | 7 bit，范围 0～127。 |

该 item 只在 wrapper cfg agent 内流动，不进入 simple bus agent。cfg driver 实际调用
`resp_delay_cfg_if.set_target_resp_delay()` 后，将 item clone 发布到 `applied_cfg_ap`。

### 6.4 三类数据来源不得混用

| 数据流 | 表示 | 主要消费者 |
|---|---|---|
| planned bus item | sequence 要求 driver 执行什么 | driver execution checker |
| applied wrapper cfg item | cfg driver 已执行什么配置 | wrapper delay checker |
| observed bus transfer | interface 实际发生什么 | scoreboard、两类 checker、coverage |

功能 scoreboard 不读取 planned item；wrapper checker 不读取 bus item；coverage 不采样
sequence 计划。这样 DUT 错误、wrapper 错误和 testbench driver 错误能分别定位。

当前协议 single outstanding、in-order，因此 planned item 与 observed transfer 可以 FIFO 顺序
配对；wrapper cfg state 可以按 target 保存最新 applied value。未来若支持多 outstanding，必须
增加 transaction ID 或重新定义关联机制。

### 6.5 约束与激励分层

`simple_bus_item` 的通用约束只要求 `be != 0` 和合法 idle 范围，不绑定 CPU access size、
target、MMIO offset 或 target 权重。

CPU-shaped profile：

| profile | `addr/be` 关系 |
|---|---|
| byte | `be = 4'b0001 << addr[1:0]`。 |
| halfword | `addr[0]=0`；按 `addr[1]` 选择 `0011/1100`。 |
| word | `addr[1:0]=0` 且 `be=1111`。 |
| generic bus corner | addr 与任意非零 be 独立，不代表 CPU 一定产生该形状。 |

DMEM、known-MMIO、unknown-MMIO 和 unmapped-address 使用不同 sequence mode/virtual
sequence。target 先在 sequence 层选择，再约束 addr；target 本身不成为 simple bus 协议字段。

legal random traffic 的目标分布建议为 DMEM 50%、GPIO0 20%、UART0 15%、TIMER0 15%。
unknown offset 和 unmapped address 使用独立 negative traffic bucket，不能淹没 known-register
功能访问。

对已记录 `RTL-001`，`reg+1` byte 和 `reg+2` halfword 先作为定向预期失败场景；RTL 修复后
才进入 known-MMIO legal random traffic。

## 7. Response-delay Wrapper 配置与检查

### 7.1 DUT wrapper 语义

`data_subsystem` 为固定响应 target 注入 per-target delay：

| 输入 | 说明 |
|---|---|
| `dmem_resp_delay_cycles_i` | DMEM delay。 |
| `gpio0_resp_delay_cycles_i` | GPIO0 delay。 |
| `uart0_resp_delay_cycles_i` | UART0 delay。 |
| `timer0_resp_delay_cycles_i` | TIMER0 delay。 |

- delay 0：同拍 response。
- delay N：request accepted 后延迟 N 拍 response。
- undefined target 不经过 wrapper，固定同拍 error response。
- wrapper 在 request accepted 时访问 target、锁存 data/error，再延迟 core-side response。
- wrapper 是验证配套层，不表示外设本体是多拍 slave。

### 7.2 wrapper cfg agent

完整环境使用独立 active agent：

~~~text
data_subsystem_resp_delay_wrapper_cfg_agent
    +--> cfg sequencer
    +--> cfg driver
~~~

cfg driver 独占 `resp_delay_cfg_if` virtual interface。top 只把 vif 配置给该 driver；test、
virtual sequence、simple bus driver、monitor 和 scoreboard 不直接取得它。

cfg driver 在 reset 释放后执行命令；virtual sequence 保证配置不与 outstanding transaction
重叠。配置完成后先发布 `applied_cfg_ap`，再结束 cfg item。

cfg channel 是 TB 专用控制侧带，不是待验证的 handshake protocol，因此不强制建立 cfg
monitor。cfg driver 是否正确生效由 wrapper checker 通过后续实际 response delay 验证。

### 7.3 virtual sequence 协调规则

需要 wrapper 配置的场景必须遵循：

~~~text
apply cfg item
  -> cfg driver applies value and item_done
  -> send bus item
  -> bus driver waits request/response completion and item_done
  -> apply next cfg item
~~~

配置在下一笔 request accepted 前稳定，outstanding 期间不得修改。normal smoke 不发送 cfg
item，使用 reset 默认 delay 0。

固定、确定性动态和 constrained-random delay 统一走 cfg agent：

| 场景 | 配置方式 | 必须检查 |
|---|---|---|
| zero-delay smoke | reset 默认 0 | scoreboard + wrapper checker |
| deterministic delay | 单 test 按 0/3/1/7/0 等序列 | scoreboard + wrapper checker + SVA |
| boundary delay | 定向覆盖 0/1/3/7/127 | wrapper checker |
| random delay | 每笔随机 0～127，边界加权 | wrapper checker + coverage |

命令行 `+DMEM_DELAY` 不作为主回归配置路径；如保留，仅用于 debug convenience，不能替代
cfg agent 场景。

### 7.4 wrapper delay checker

`data_subsystem_resp_delay_wrapper_checker` 接收：

- wrapper cfg driver 的 applied cfg item。
- simple bus monitor 的 observed transfer。

checker 为四个 target 保存当前 expected delay，初值均为 0。cfg item 更新对应 target；
transfer 到达时按实际地址译码并比较：

~~~text
expected_delay[target] == transfer.observed_resp_delay
~~~

undefined target 的 expected 固定为 0。mismatch 报告 target、addr、expected、actual。

checker 不驱动 interface、不读取 sequence 内部值、不检查 rdata/MMIO 状态。它与功能
scoreboard 并列，固定、动态和随机 delay 都走同一检查路径。

## 8. DMEM 检查边界

DMEM 使用外置 `simple_ram`：

- 组合 read。
- 时钟上升沿按 byte enable 写 byte lane。
- `DMEM_BASE` 映射 `mem[0]`。
- 合法 DMEM window 访问不返回 error。

DMEM reference model 必须支持：

- 多地址互不污染。
- write 后 read 返回最后一次软件可见值。
- byte/half/word 和 generic non-zero be 的逐 lane 更新。
- delay 不影响最终数据结果。
- error response 被报告为功能错误。

reference model 按 word-aligned address 保存状态；未选 byte lane 保留旧值。未写地址若没有
同步初始化来源，不比较 rdata，只记录跳过原因。若 UVM 启用 `+dmem`/`$readmemh`，reference
model 必须加载同一镜像；不能一边预加载 DUT RAM、一边假设 reference 初值为 0。

word smoke 是基础回归，但不是完整环境对 byte enable 的最终限制。

## 9. MMIO 检查边界

MMIO checker/reference model 以软件可见 ABI 为准，不复制 RTL 内部实现。

bus monitor 提供寄存器访问 transfer；peripheral sideband monitor 提供输出、event 和 IRQ 的
实际观察结果。需要外部事件的 testcase 通过 sideband sequence/driver 产生 GPIO input 或 UART
RX，不允许 test、功能 scoreboard 或 reference model 直接驱动 interface。纯 bus 寄存器检查
不依赖 sideband agent traffic，但涉及副作用的检查必须关联 bus transfer 与对应 sideband event。

通用规则：

- known offset 按寄存器属性检查 read/write。
- unknown offset 返回 error。
- RO write 当前忽略，不 error。
- WO read 当前返回 0，不 error。
- 写保留 bit 不 error，软件不依赖保留 bit 读回。
- byte enable 对 RW/W1C 等寄存器有效，未选 byte 不更新或清除。
- wait-state 下每笔访问和 side effect 只发生一次。

### 9.1 GPIO0

应覆盖：

- OUT/OE 写后读及外部输出。
- IN 同步后的输入视图。
- IRQ_PENDING W1C。
- IRQ_STATUS = IRQ_PENDING & IRQ_EN。
- unknown offset error。

GPIO input 同步约两拍；检查 IN/IRQ 时必须等待同步传播，不能把同步延迟当作 bus response
delay。

### 9.2 UART0

应覆盖：

- tx_enable=1 时 TXDATA write 产生单拍 event。
- tx_enable=0 时 TXDATA write 不产生 event。
- STATUS.tx_ready 固定为 1。
- RX event 后 rx_valid/RXDATA。
- RXDATA read-clear。
- IRQ_PENDING W1C，读取本身不清 pending。
- unknown offset error。

UART 是寄存器/事件模型，不验证 baud、start/stop bit、FIFO 或异步串口 CDC。

### 9.3 TIMER0

应覆盖：

- MTIME/MTIMECMP/CTRL/STATUS 软件可见语义。
- 写 MTIME 当拍不自增。
- 写 MTIMECMP 不阻止 MTIME 自增。
- enable 后计数。
- mtip/irq 与 enable、mtime、mtimecmp 的关系。
- unknown offset error。

timer free-running 检查必须明确 transaction 时点，并区分 timer 自增拍与 wrapper wait-state。

## 10. SVA 边界

SVA 检查引脚级协议 invariant，不实现具体 testcase 或功能 reference model。

`tb/sva/simple_bus_sva.svh` 在 `simple_bus_if` 内 include，所有 assertion/state 受
`ASSERT_ON` 控制。SVA 不 import UVM package，不读取 item/transfer/checker 状态。

至少检查：

| assertion | 意义 |
|---|---|
| reset outputs | reset 时 request idle、response quiet，ready 符合当前 DUT 口径。 |
| control/payload known | 有效控制与 payload 无 X/Z。 |
| payload stable on backpressure | valid && !ready 期间 request 不变。 |
| single outstanding | pending response 返回前不接受第二笔 request。 |
| no orphan response | response 对应 pending request 或本拍 0-delay accepted request。 |

action block 使用清晰 assertion label 和 `[SVA]` 日志。`run_test.sh` 把 assertion `$error`
统计为 `SIM_ERROR`/FAIL。故障注入可用于调试 assertion infrastructure，但不是正常回归的
强制用例。

DUT 内部状态断言若有需要，使用 `tb/sva` 下独立 assertion module + bind；不放入 UVM
class。CPU trap/CSR/flush/interrupt invariant 不属于本 simple bus spec。

## 11. Checker 与 Reference Model 架构

### 11.1 功能 scoreboard

`simple_bus_scoreboard` 只消费 observed transfer：

- target decode。
- DMEM reference memory。
- 不依赖外设侧带事件的 MMIO software-visible reference state，或向 target-specific checker
  分发。
- data/error expectation。

它不读取 planned item、wrapper cfg item 或 virtual sequence 状态。

GPIO/UART/TIMER target-specific checker 可以同时消费 observed bus transfer 和 peripheral
sideband monitor event，用 reference state 关联寄存器访问、外部输入、输出事件及 IRQ。checker
只消费 observed 数据；sideband sequence 的计划值若需检查，由独立 stimulus-execution checker
处理，不能作为 DUT 实际行为替代品。

### 11.2 wrapper checker

wrapper checker 按第 7.4 节消费 applied cfg + observed transfer，只检查配置与实际 delay，
不检查功能数据。

### 11.3 driver execution checker

`simple_bus_driver_execution_checker` 消费：

- bus driver 发布的 planned item clone。
- monitor 发布的 observed transfer。

在 single outstanding/in-order 条件下按 FIFO 配对，检查：

- planned 与 observed `write/addr/be/wdata` 完全一致。
- 非首笔 planned `idle_cycles` 与 `observed_idle_cycles` 完全一致。
- 首笔 initial idle 不参与严格比较。
- test 结束时两侧队列为空。

该 checker 验证 UVM stimulus 执行正确性；mismatch 属于 testbench 错误，不归因于 DUT，也不
进入功能 scoreboard。

### 11.4 一对多 observation

monitor transfer 是唯一 bus truth source，同一对象可以被多个 subscriber 同步消费。各
subscriber 若需要保存对象，必须 clone，不能修改 monitor 发布的共享对象。

checker/coverage 的职责不能重叠成互相替代：

- scoreboard：功能结果。
- wrapper checker：delay wrapper。
- execution checker：driver 执行。
- SVA：周期级 invariant。
- coverage：场景是否发生。

## 12. Coverage 目标

functional coverage 由 env 中的 UVM subscriber/collector 订阅 observed transfer；MMIO
side-effect coverage 同时订阅 peripheral sideband monitor event。coverage 只采样实际完成的
transaction/event，不采样 planned item、cfg item 或 sideband sequence 计划值。

基础 coverpoints：

| coverpoint | bins |
|---|---|
| target | DMEM/GPIO0/UART0/TIMER0/undefined |
| op | read/write |
| response | OK/error |
| observed delay | 0、1、small、medium、large、127 |
| observed idle gap | 0、small、large |
| byte enable/access profile | word、CPU byte/half、generic corner |
| MMIO offset | known/unknown |
| side effect | 各 ABI 定义事件 |

基础 crosses：

- op x delay。
- idle gap x delay。
- target x delay。
- target x idle gap。
- target x read/write。
- target x response。
- target x access profile。
- MMIO known/unknown x read/write。
- MMIO register x read/write。
- side effect x delay。

第一批 DMEM random 环境只要求 op/delay/idle 基础 bins 非空；target/MMIO/side-effect bins
随对应 checker/reference model 接入后纳入 closure。不能为了提高覆盖率生成没有明确 expected
行为的“legal”流量。

0835 不要求完整 coverage closure，但必须有可运行 covergroup、稳定采样源、非空报告入口和
明确未覆盖项。若使用 `COVERAGE_ON` 编译/运行配置，必须与普通/ASSERT_ON build 隔离。

SVA `cover property` 与 UVM functional coverage 是不同资产：前者放 `tb/sva`，后者放
`tb/coverage`，两者不重复承担 PASS/FAIL 判断。

## 13. UVM 与 Directed Test 边界

UVM simple bus 环境不使用：

- `.mem` 程序执行流、crt0、trap handler。
- C/ASM self-check 程序。
- CPU commit trace。
- TB mailbox DMEM command 协议。
- ISA reference model。

这些属于 Verilator SoC directed regression。

UVM 使用 v6.0 snapshot 中的：

- `dut/docs/periph_register_abi.md`。
- `dut/rtl/common/core_pkg.sv`。
- `dut/rtl/common/soc_pkg.sv`。
- `dut/rtl/common/data_bus_pkg.sv`。
- `data_subsystem`、`simple_ram` 和三个 MMIO peripheral RTL。

Verilator 与 VCS 回归必须并行保留；任何 UVM 文件不进入 Verilator 默认 filelist。

## 14. Out of Scope

本 spec 不覆盖：

- AXI-Lite 协议、adapter 或 interconnect。
- full SoC/CPU UVM。
- ISS lockstep。
- random instruction generation。
- RISC-V ISA reference model。
- CPU 内部 GPR/CSR/trap/interrupt 精确提交。
- 真实 UART 串口物理层。
- FPGA 板级时序、PLL、外部 SRAM/Flash controller。

这些内容在对应后续 release 建立新的 spec。

## 15. 完整环境完成标准

完整 v6.0 simple bus UVM 环境至少满足：

- VCS 能编译并运行 base、DMEM smoke、SVA smoke、deterministic wrapper delay、
  deterministic idle gap 和 fixed-seed random delay test。
- `simple_bus_item`、wrapper cfg item、`simple_bus_transfer` 三类对象来源清楚且不混用。
- bus agent 与 response-delay wrapper cfg agent 均进入 env；virtual sequence 能协调两者。
- peripheral sideband stimulus/monitor 进入 env；GPIO input、UART RX 和外设输出/IRQ 不由 test
  直接访问 virtual interface。
- monitor 正确重建 0 wait-state 和非 0 wait-state transfer。
- DMEM scoreboard 自动检查 word/byte/half/generic byte-enable 行为。
- MMIO checker/reference model 按 ABI 检查 known/unknown offset、基础寄存器和规定 side effect。
- wrapper checker 自动覆盖 0/1/3/7/127、确定性动态和逐笔随机 delay。
- driver execution checker 自动检查 request payload 与非首笔 idle gap。
- SVA 在固定和随机 wait-state 下不误报，协议错误能转为 `SIM_ERROR`/FAIL。
- global/transaction timeout 能把无响应转为明确失败。
- coverage 只采样 observed transfer，能生成非空报告，并明确未闭合 bins。
- 日志能区分 planned item、applied wrapper cfg、observed transfer、功能 mismatch、
  wrapper mismatch 和 testbench execution mismatch。
- Verilator ASM/C directed regression 继续可运行。
- 最终 DUT snapshot、filelist、README、仿真说明和本 spec 与实现一致。

该环境验证 v6.0 simple bus/data_subsystem 边界，不扩大为 full CPU UVM。
