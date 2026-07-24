# v6.0 Data Subsystem UVM Verification Spec

本文定义 `uvm/v6_0/data_subsystem` 独立 UVM 工作区的验证对象、协议语义、验证架构、数据对象所有权、检查边界、coverage 口径和非目标。

本 spec 绑定项目 v6.0 的 simple data bus 与 `data_subsystem` response-delay wrapper。后续若 data bus 被 AXI-Lite 或其它协议替换，本 spec 和对应工作区作为历史 release 资产保留；新协议必须建立新的版本目录、verification spec 和 filelist，不能静默复用本文。

## 1. 定位

本 UVM 环境验证 0834 后形成的 data-side simple request/response bus、`data_subsystem` 地址译码、DMEM/GPIO0 的当前软件可见行为，以及 per-target response-delay wrapper。

当前环境具备：

- UVM active master 驱动 simple data bus。
- 独立 wrapper agent 驱动并观测 DMEM、GPIO0、UART0、TIMER0 的 response-delay 配置。
- virtual sequence 协调 bus sequence 与 wrapper sequence。
- simple bus monitor 从 interface 独立重建 observed transfer。
- simple bus scoreboard 检查 DMEM 和 GPIO0 当前已建模行为。
- wrapper scoreboard 独立检查 request accepted 时的实际 wrapper 配置与 observed response delay。
- SVA 检查 simple bus 引脚级协议 invariant。
- functional coverage 只采样 monitor 实际观察到的完整 transaction。

本环境不实例化整颗 `rv32i_soc`，不运行 `.mem` 程序，不验证 CPU 指令流、GPR、CSR、trap handler 或 interrupt 精确提交。现有 Verilator ASM/C self-check regression 必须继续保留；VCS/UVM/SVA 是并行验证平台，不替代 directed regression。

## 2. 文件与版本边界

| 内容 | 路径 |
|---|---|
| UVM testbench | `uvm/v6_0/data_subsystem/tb` |
| DUT RTL/ABI 快照 | `uvm/v6_0/data_subsystem/dut` |
| VCS 脚本与日志 | `uvm/v6_0/data_subsystem/sim` |
| 仿真流程说明 | `uvm/v6_0/data_subsystem/dut/docs/uvm_simulation_flow.md` |
| 实际验证结果 | `uvm/v6_0/data_subsystem/verification_report.md` |

目录名体现 release 绑定；package/class 名按 data-subsystem、simple-bus 和 wrapper 的职责命名。归档后的 v6.0 filelist 只编译本工作区 DUT 快照，不引用根目录主线 RTL。不同 release 环境不进入同一个 VCS filelist，避免 package/class/module 重名和行为漂移。

开发期若 UVM 暴露真实 RTL 问题，必须先修复主工程 RTL 并运行主线回归，再同步 DUT 快照。快照来源、文件映射和冻结规则见 `dut/readme.md`。

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

wrapper_if
    +--> dmem/gpio0/uart0/timer0 response-delay inputs
~~~

`simple_bus_if` 表达 core-side request/response 协议。`wrapper_if` 是 v6.0 DUT wrapper 专用的 testbench 配置与观测通道，不属于 simple bus，也不进入通用 bus transaction payload。

GPIO input 和 UART RX 等 DUT 外部输入在当前 harness 中保持固定 idle 值；GPIO output、UART TX event 和 IRQ 等 sideband 未建立独立 UVM agent。涉及这些信号的外设 side effect 不属于当前自动检查范围。

### 3.2 UVM 组件关系

~~~text
test
  -> physical sequence or virtual sequence
       -> data_subsystem_virtual_sequencer
            +--> simple_bus_agent.sequencer
            |      -> simple_bus_driver
            |      -> simple_bus_if
            |
            +--> wrapper_agent.sequencer
                   -> wrapper_driver
                   -> wrapper_if

simple_bus_monitor.transfer_ap
    +--> simple_bus_scoreboard.tr_imp
    +--> wrapper_scoreboard.bus_tr_fifo
    +--> data_subsystem_coverage.analysis_export

wrapper_monitor.transfer_ap
    +--> wrapper_scoreboard.wrp_tr_fifo
~~~

`data_subsystem_env` 创建两个 active agent、virtual sequencer、两个 scoreboard 和 coverage collector。普通 simple-bus smoke 可以直接启动 bus physical sequence；需要逐笔配置 wrapper 的场景通过 virtual sequence 协调两个 physical sequencer。test、sequence、scoreboard 和 coverage 不直接驱动 virtual interface。

bus driver 的 `planned_item_ap` 与 wrapper driver 的 `applied_item_ap` 已提供扩展观察口，但当前 env 没有把它们接入 checker；当前 PASS/FAIL 依据以 monitor、scoreboard 和 SVA 为准。

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

`ready` 保持为离散信号。response 侧没有 `resp_ready`；master 不能对 response 施加 backpressure，必须在 `core_resp_o.valid=1` 的采样点接收结果。

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

对于非首笔 transaction，planned `idle_cycles` 定义为：上一笔 response 完成后，到本笔 `core_req_i.valid` 首次为 1 前，额外保持 valid=0 的完整采样拍数。

第一笔 transaction 没有上一笔 response，其 planned `idle_cycles` 表示 reset 释放锚点后的 initial idle。initial idle 受 test 启动和 clocking block 对齐影响，不作为当前功能 scoreboard 的检查项。

`idle_cycles=0` 表示在协议允许的最早采样拍发起下一笔 request；`idle_cycles=N` 表示额外保持 N 个完整 idle 拍。sequence 产生计划值，driver 只执行；sequence 不使用额外 `@(clock)` 隐式制造 gap。

monitor 独立统计 observed idle gap，并写入 `simple_bus_transfer.observed_item.idle_cycles`。功能 scoreboard 与 coverage 以该 observed 值为准；planned/observed idle 的严格执行检查属于第 16 章的可扩展项。

### 4.3 Response 完成与 delay

transaction 在 `core_resp_o.valid=1` 的时钟采样点完成。

- `resp_delay=0`：request accepted 与 response valid 同拍。
- `resp_delay=N`：response 在 accepted request 后第 N 个采样间隔返回。

monitor 把实际延迟写入 `simple_bus_transfer.resp_delay`。在非 0 wait-state outstanding 期间，`core_req_ready_o` 必须保持为 0，避免接受第二笔 request。

### 4.4 Single Outstanding

v6.0 simple bus 只支持 single outstanding、in-order completion：

- 同一时刻最多一笔 accepted 但未 response 的 transaction。
- 没有 transaction ID。
- response 对应最近一笔未完成 request。
- 不允许 orphan response。
- outstanding 未完成时不接受第二笔 request。

monitor 只需一个 pending transfer。driver、monitor 和 SVA 都应具有防御性检查，但协议 invariant 的主要静态检查路径是 SVA。

testbench 必须有全局 timeout，bus driver 必须有单 transaction response timeout。timeout 上限大于最大 wrapper delay 127，并保留调度裕量；超时时打印 op、addr、target 和等待拍数。

### 4.5 Reset

reset 有效期间：

- bus driver 驱动 request idle，即 `core_req_i.valid=0`。
- DUT 不产生有效 response。
- wrapper driver 将四路 delay 配置初始化为 0。
- driver 不从 sequencer 取得并执行普通 item，monitor 不发布 transfer；sequence 即使已在 run phase 启动，也只会阻塞等待 driver。

当前环境只要求仿真开始时 reset；运行中 reset 不属于 reference model 的强制场景。若后续加入 mid-test reset，所有 agent、monitor pending state、checker expected state 和 reference model 必须统一定义 reset 行为。

### 4.6 Error

`core_resp_o.error=1` 表示 transaction 失败。UVM 不模拟 CPU trap，只检查 bus-visible error 和软件可见结果。

error response 的 `rdata` 不作为有效数据比较。DMEM window 内访问不应 error；MMIO known/unknown offset 和 unmapped address 按第 5、9 章处理。

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
| GPIO0 | GPIO0 window | 命中 `mmio_gpio`；unknown word offset 返回 error。 |
| UART0 | UART0 window | 命中 `mmio_uart`；unknown word offset 返回 error。 |
| TIMER0 | TIMER0 window | 命中 `mmio_timer32`；unknown word offset 返回 error。 |
| undefined | 其它地址 | 不经过 target wrapper，同拍返回 error，`rdata=0`。 |

总线传递原始 byte address。CPU 已根据 `addr[1:0]` 和访问类型生成 `be`、按 byte lane 对齐 store `wdata`，并在 load response 返回后自行选取和扩展 byte/half 数据。DMEM 和 MMIO target 使用 `{addr[31:2], 2'b00}` 选择 word/register，`addr[1:0]` 不参与 target 内部 word/register decode；实际有效 byte lane 只由 `be` 决定，read 返回完整的对齐 word/register 数据。

MMIO offset、bit、访问属性和 side effect 以 `dut/docs/periph_register_abi.md` 为唯一 ABI 来源。本 spec 规定验证边界，不复制维护完整寄存器手册。RTL-001 曾违反上述 word-aligned decode 规则，现已修复并由 `DS_map_random_test` 固定 seed 回归覆盖。

## 6. 数据对象、所有权与关联

### 6.1 `simple_bus_item`：planned command

`simple_bus_item` 用于 sequence -> sequencer -> driver，表达 master 计划：

| 字段 | 来源 | 说明 |
|---|---|---|
| `write` | sequence | 计划 read/write。 |
| `addr` | sequence | 计划 byte address。 |
| `be` | sequence | 计划 byte enable。 |
| `wdata` | sequence | 计划 write data。 |
| `idle_cycles` | sequence | 计划 request 前 idle gap；首笔为 initial idle。 |

item 不保存 DUT response，不作为功能 scoreboard 或 coverage 的输入。driver 等到 response 后调用 `item_done()`，并可把开始执行前的 clone 发布到 `planned_item_ap`；当前 checker 不消费该 port。

### 6.2 `simple_bus_transfer`：observed transaction

`simple_bus_transfer` 只由 monitor 创建，表达 interface 上实际完成的 transaction：

| 字段 | 来源 | 说明 |
|---|---|---|
| `observed_item.write/addr/be/wdata` | monitor | 实际 accepted request payload。 |
| `observed_item.idle_cycles` | monitor | interface 上实际 request idle gap。 |
| `rdata/error` | monitor | 实际 response payload。 |
| `resp_delay` | monitor | accepted request 到 response valid 的实际延迟。 |
| `req_cycle/accept_cycle/resp_cycle` | monitor | monitor 的采样周期编号，用于时序关联与 debug。 |
| target | `observed_item` helper | 根据实际 addr 推导。 |

monitor 不读取 sequence item、wrapper item 或 driver 内部状态。它在 request valid 首次出现时记录 `req_cycle`，在 request accepted 时锁存 payload 和 `accept_cycle`，在 response 时填写 response、`resp_delay` 与 `resp_cycle`，随后通过 `transfer_ap` 广播。0 wait-state 同拍 accept/response 必须输出一笔完整 transfer。

### 6.3 `wrapper_item`：planned/applied configuration command

| 字段 | 说明 |
|---|---|
| `target` | DMEM/GPIO0/UART0/TIMER0。 |
| `delay_cycles` | 请求的 delay 值；driver 对负数报 fatal，对大于 127 的值饱和到 127 并 warning。 |

该 item 只在 wrapper agent 内流动，不进入 simple bus agent。wrapper driver 实际调用 `wrapper_if.set_target_resp_delay()` 后，将实际应用值的 clone 发布到 `applied_item_ap`；当前 wrapper scoreboard 不消费该 port。

### 6.4 `wrapper_transfer`：observed configuration snapshot

`wrapper_transfer` 由 wrapper monitor 每个 reset 释放后的采样周期发布，保存四路实际 delay 配置和 `sample_cycle`。它是 interface observation，不是单 target 配置命令。

wrapper scoreboard 按 bus transfer 的 `accept_cycle` 选择同一 `sample_cycle` 的完整配置快照。这样同拍配置与访问的关联不依赖两个 analysis port 的回调顺序，也不信任 sequence 或 driver 自己推导 DUT 实际配置。

### 6.5 数据来源不得混用

| 数据流 | 表示 | 当前消费者 |
|---|---|---|
| planned bus item | sequence 要求 bus driver 执行什么 | bus driver；`planned_item_ap` 保留扩展口 |
| planned/applied wrapper item | wrapper driver 要求并实际应用什么 | wrapper driver；`applied_item_ap` 保留扩展口 |
| observed bus transfer | simple bus interface 实际发生什么 | simple bus scoreboard、wrapper scoreboard、coverage |
| observed wrapper transfer | wrapper interface 实际配置状态 | wrapper scoreboard |

功能 scoreboard 不读取 planned item；wrapper scoreboard 不读取 virtual sequence 内部值；coverage 不采样 sequence 计划值。当前协议 single outstanding、in-order，因此 bus monitor 和 checker 不需要 transaction ID。未来若支持多 outstanding，必须增加 transaction ID 或重新定义关联机制。

### 6.6 约束与激励分层

`simple_bus_item` 的通用约束要求 `be != 0`、`idle_cycles` 位于 0～15，并对 data-side 地址图、write data 和 idle gap 提供基础加权。通用 map random 不强制 `addr/be` 形成 CPU access profile，它有意覆盖 generic non-zero BE 与非零地址低位组合。

CPU-shaped profile 可在专属 sequence 中进一步约束：

| profile | `addr/be` 关系 |
|---|---|
| byte | `be = 4'b0001 << addr[1:0]`。 |
| halfword | `addr[0]=0`；按 `addr[1]` 选择 `0011/1100`。 |
| word | `addr[1:0]=0` 且 `be=1111`。 |
| generic bus corner | addr 与任意非零 be 独立，不代表 CPU 一定产生该形状。 |

当前默认地址总权重为 DMEM 50%、GPIO0 20%、UART0 10%、TIMER0 10%、全地址空间 10%。`simple_bus_dmem_random_access_seq` 在 DMEM 内维护已写 word 地址池；`simple_bus_map_random_access_seq` 在完整 32-bit word 地址图维护已写地址池，并使大部分 read 复用已写 word，从而提高已有 reference model 的有效比较比例。sequence 不读取 scoreboard 实现范围。

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

### 7.2 wrapper agent

~~~text
wrapper_agent
    +--> wrapper_sequencer
    +--> wrapper_driver
    +--> wrapper_monitor
~~~

wrapper driver 通过 `wrapper_if.drv_mp` 独占四路配置驱动，并在 reset 期间调用 interface task 清零配置。wrapper monitor 通过 `wrapper_if.mon_mp` 每拍独立采样四路实际配置并发布 `wrapper_transfer`。top 分别以完全匹配的 virtual-interface 类型向 driver 和 monitor 配置 vif。

cfg channel 是 TB 专用控制侧带，不是待验证的 handshake protocol。wrapper sequence/driver 不在 outstanding transaction 期间改变配置；配置 task 不消耗仿真时间，下一笔 request 可以按协议允许的最早采样拍发起。

### 7.3 virtual sequence 协调规则

需要 wrapper 配置的场景遵循：

~~~text
apply wrapper item
  -> wrapper driver applies value and item_done
  -> send bus item or bus sequence
  -> bus driver waits request/response completion and item_done
  -> apply next wrapper item
~~~

配置在下一笔 request accepted 前稳定，outstanding 期间不得修改。simple-bus smoke 不发送 wrapper item，使用 reset 默认 delay 0。固定、边界和随机 delay 均通过 wrapper agent 配置，不通过 test 直接访问 virtual interface。

### 7.4 wrapper scoreboard

`wrapper_scoreboard` 接收两个 monitor 的 observation：

- `simple_bus_monitor.transfer_ap -> bus_tr_fifo`
- `wrapper_monitor.transfer_ap -> wrp_tr_fifo`

checker 先取得一笔完整 bus transfer，再丢弃早于其 `accept_cycle` 的 wrapper snapshot，最终要求选中的 `wrapper_transfer.sample_cycle == simple_bus_transfer.accept_cycle`。按 observed address 译码 target 后，比较该 target 的实际配置与 `simple_bus_transfer.resp_delay`；undefined target 的 expected delay 固定为 0。

两个 `uvm_tlm_analysis_fifo` 消除了同一采样拍内 analysis port 回调先后顺序对检查结果的影响。checker 只检查 wrapper timing，不检查 rdata、MMIO 状态或 bus driver 的计划值；test 结束时若仍有未处理 bus transfer 则报 fatal，较新的 wrapper 周期快照允许留在 FIFO。

## 8. DMEM 检查边界

DMEM 使用外置 `simple_ram`：

- 组合 read。
- 时钟上升沿按 byte enable 写 byte lane。
- `DMEM_BASE` 映射 `mem[0]`。
- 合法 DMEM window 访问不返回 error。

当前 DMEM reference model 按 `(addr - DMEM_BASE) >> 2` 保存关联数组状态，支持多地址、任意非零 `be` 的逐 byte lane 更新以及 write 后 readback。合法 DMEM 访问返回 error 或已建模地址读回不一致时报告 UVM error。

未写地址没有可靠初始化来源时不比较 `rdata`，计入 `partial_count`；write response 的 `rdata` 没有 spec 语义，只检查 `error` 并计入 `partial_count`。因此 `partial` 不等于失败，但说明该 transaction 只完成了当前可定义部分的检查。

若未来 DUT RAM 使用 `$readmemh` 预加载，reference model 必须加载同一镜像，不能一边预加载 DUT RAM、一边假设 reference 初值为 0。

## 9. MMIO 检查边界

MMIO 的 DUT 语义以 `dut/docs/periph_register_abi.md` 为准。当前 UVM reference model 只实现 GPIO0 的一部分；DUT 支持但 checker 未实现的行为不能因为随机访问通过而宣称已验证。

### 9.1 GPIO0 当前自动检查

当前 `simple_bus_scoreboard`：

- 按 word-aligned offset 译码，覆盖非零 `addr[1:0]`。
- 建模 `OUT` 和 `OE` 的逐 byte-lane write，并检查后续 readback。
- 对 GPIO0 已定义 word offset 检查 `error=0`。
- 对 GPIO0 unknown word offset 检查 `error=1`。
- 对尚未建模的已定义寄存器 read 只完成 error 检查，计入 `partial_count`。
- 对 write 只完成 error 检查并更新当前可建模参考状态，计入 `partial_count`；OUT/OE 的状态更新通过后续 readback 获得端到端可观测检查。

GPIO IN、IRQ_PENDING/W1C、IRQ_STATUS、外部 GPIO 输出和 IRQ side effect 尚未自动检查。

### 9.2 UART0 与 TIMER0

当前 `simple_bus_scoreboard` 未建立 UART0/TIMER0 reference model，相关 transfer 计入 `skip_count`。wrapper scoreboard 仍会检查这些 target 的 response delay，但这不能替代寄存器数据、error 或 side effect 检查。

若后续扩展，至少应按 ABI 覆盖 UART TX/RX event、read-clear/W1C/IRQ 语义，以及 TIMER MTIME/MTIMECMP/CTRL/STATUS、计数和 IRQ 关系。涉及外部输入或输出事件时，应建立独立 sideband monitor/driver，而不是让 reference model 直接访问 DUT interface。

### 9.3 统计口径

`simple_bus_scoreboard` 的四类结果含义：

| 计数 | 含义 |
|---|---|
| `correct_count` | 当前对该 transaction 定义的全部检查均完成且匹配。 |
| `error_count` | 任一已定义检查不匹配。 |
| `partial_count` | 已检查 error 或部分数据语义，但仍有当前基础设施未覆盖的结果。 |
| `skip_count` | target-specific reference model 尚未接入，功能检查整体跳过。 |

四类计数之和必须等于 `compare_count`。`partial_count` 和 `skip_count` 不直接导致 test FAIL，但必须在 verification report 中作为剩余验证边界披露。

## 10. SVA 边界

SVA 检查引脚级协议 invariant，不实现具体 testcase 或功能 reference model。

`tb/sva/simple_bus_sva.svh` 在 `simple_bus_if` 内 include，所有 assertion/state 受 `ASSERT_ON` 控制。SVA 不 import UVM package，不读取 item、transfer 或 checker 状态。

当前检查：

| assertion 类别 | 意义 |
|---|---|
| reset outputs | reset 时 request idle、response quiet，ready 符合当前 DUT 口径。 |
| control/payload known | request/response 有效时相关控制和 payload 无 X/Z。 |
| payload stable on backpressure | `valid && !ready` 期间 request payload 不变。 |
| single outstanding | pending response 返回前不接受第二笔 request。 |
| no orphan response | response 对应 pending request 或本拍 0-delay accepted request。 |

action block 使用清晰 assertion label 和 `[SVA]` 日志。`run_test.sh` 把 assertion `$error` 统计为 `SIM_ERROR`/FAIL。故障注入可用于调试 assertion infrastructure，但不是正常回归的强制用例。

DUT 内部状态断言若有需要，使用 `tb/sva` 下独立 assertion module + bind；不放入 UVM class。CPU trap/CSR/flush/interrupt invariant 不属于本 data-subsystem spec。

## 11. Checker 与 Reference Model 架构

### 11.1 simple bus scoreboard

`simple_bus_scoreboard` 只消费 observed `simple_bus_transfer`，负责 target decode、DMEM reference memory、GPIO0 最小 reference state 以及相应 data/error expectation。它不读取 planned item、wrapper item 或 virtual sequence 状态。

### 11.2 wrapper scoreboard

`wrapper_scoreboard` 按第 7.4 节消费 observed bus transfer 与 observed wrapper snapshot，只检查配置对应的实际 response delay，不检查功能数据。

### 11.3 一对多 observation

simple bus monitor 的 transfer 是唯一 bus truth source，同一对象同步广播给两个 scoreboard 和 coverage。subscriber 当前在回调内完成读取或将对象按 FIFO 顺序消费，不得修改 monitor 发布的共享对象；若未来需要长期保存，必须 clone。

各验证层职责：

- simple bus scoreboard：当前已建模的数据与 error 结果。
- wrapper scoreboard：delay wrapper 时序。
- SVA：周期级协议 invariant。
- coverage：实际场景是否发生。
- regression script：VCS 返回码、UVM severity 和 simulator error 汇总。

driver execution checker、完整 MMIO reference model 和 peripheral sideband checker 属于第 16 章的可扩展项，不计入当前环境完成条件。

## 12. Functional Coverage

`data_subsystem_coverage` 是 `uvm_subscriber #(simple_bus_transfer)`，只采样 simple bus monitor 发布的完整 observed transfer。coverage 证明场景实际发生过，不替代 scoreboard 或 SVA 的正确性判断。

当前 covergroup：

| covergroup | 内容 |
|---|---|
| `rw_data_cg` | read/write 类型、成功 transaction 的 read/write data 区间及 cross。 |
| `bus_behavior_cg` | op、observed idle gap、target、`addr[1:0]`、BE 访问宽度、observed response delay、response error。 |

当前 crosses：

- op x access width。
- op x response delay。
- target x response delay，undefined target 除外。
- target x address low bits。
- GPIO0 address low bits x response error。
- idle gap x response delay。

response delay bins 明确覆盖 0、1、2～7、8～15、16～63、64～126 和 127。console coverage 由 collector 的 `report_phase` 输出；VDB/URG HTML 报告在当前工具环境中不稳定，不作为 0835 收口条件。

当前 coverage 百分比只反映已定义 covergroup 的命中率，不表示 UART0/TIMER0 reference model、MMIO side effect 或完整协议空间已经验证。实际固定 seed 数值记录在 `verification_report.md`。

## 13. Test 与回归入口

当前注册 test：

| test | 目的 |
|---|---|
| `data_subsystem_base_test` | 创建完整 env，验证组件构建、vif 获取和空场景收尾。 |
| `simple_bus_smoke_test` | 直接启动固定 DMEM bus sequence，检查基础 read/write 与 zero-delay。 |
| `data_subsystem_smoke_test` | 通过 virtual sequence 协调固定和随机 DMEM wrapper delay 与 write/read。 |
| `DS_dmem_random_test` | DMEM 随机访问、已写地址复用和逐笔随机 wrapper delay。 |
| `DS_map_random_test` | 全 data-side 地址图随机访问，按固定 delay 档位覆盖四个 target，并回归 RTL-001。 |

`run_test.sh` 的 PASS 条件是 VCS runtime 正常结束，且 UVM_ERROR、UVM_FATAL、SVA/SystemVerilog runtime error 均为 0。`run_all.sh` 汇总上述 test；固定 seed 和逐项证据见 `verification_report.md`。

## 14. UVM、Directed Test 与 Out of Scope

UVM data-subsystem 环境不使用 `.mem` 程序执行流、crt0、trap handler、C/ASM self-check 程序、CPU commit trace、TB mailbox DMEM command 协议或 ISA reference model。这些属于 Verilator SoC directed regression。

本 spec 不覆盖：

- AXI-Lite 协议、adapter 或 interconnect。
- full SoC/CPU UVM。
- ISS lockstep 或 random instruction generation。
- RISC-V ISA reference model。
- CPU 内部 GPR/CSR/trap/interrupt 精确提交。
- multi-outstanding、transaction ID 或 out-of-order response。
- 真实 UART 串口物理层。
- FPGA 板级时序、PLL、外部 SRAM/Flash controller。

Verilator 与 VCS 回归必须并行保留；任何 UVM 文件不进入 Verilator 默认 filelist。超出本工作区边界的能力应在对应后续 release 建立新的 spec。

## 15. v6.0 环境完成标准

当前 v6.0 data-subsystem UVM 环境的收口标准：

- VCS 能运行 base、simple-bus smoke、data-subsystem smoke、DMEM random 和全地址图 random test。
- bus agent 与 wrapper agent 均进入 env，virtual sequence 能协调两者。
- `simple_bus_item`、`simple_bus_transfer`、`wrapper_item` 和 `wrapper_transfer` 的 planned/observed 所有权明确。
- monitor 正确重建 0 wait-state 和非 0 wait-state transaction。
- DMEM scoreboard 自动检查任意非零 BE 的 reference state 与 readback。
- GPIO0 scoreboard 检查 OUT/OE readback、known/unknown word-offset error，并明确标识部分检查。
- wrapper scoreboard 自动检查 0～127 范围内的实际配置与 observed response delay。
- SVA 可由 `ASSERT_ON=1` 启用，assertion runtime error 能被脚本计入 FAIL。
- functional coverage 使用 observed transfer，能输出非空 console report。
- `DS_map_random_test` 能复现 RTL-001 修复前 FAIL，并在同 seed 下验证修复后 PASS。
- Verilator ASM/C directed regression 在 RTL 修复后继续通过。
- DUT snapshot、filelist、README、仿真说明、本 spec 和 verification report 与冻结实现一致。

达到上述条件不表示第 16 章全部完成，也不表示 full CPU/SoC 或全部 MMIO 功能已经验证。

## 16. 可继续扩展的验证面

以下能力有工程价值，但因 0835 的教学目标、时间和 v7.0 即将归档而未纳入当前收口条件：

### 16.1 Driver execution checker

接入 bus driver `planned_item_ap`，与 observed transfer 按 FIFO 配对，检查 request payload 和非首笔 planned/observed idle gap。首笔 initial idle 需要单独定义锚点。

### 16.2 完整 MMIO reference model

补齐 GPIO0 IN、IRQ_PENDING/W1C、IRQ_STATUS，UART0 TX/RX/read-clear/W1C/IRQ，以及 TIMER0 MTIME/MTIMECMP/CTRL/STATUS、计数和 IRQ 语义。

### 16.3 Peripheral sideband agent

为 GPIO input、UART RX 建立受控激励，为 GPIO output/OE、UART TX event 和各 IRQ 建立独立 observation；side-effect checker 关联 bus transfer 与 sideband event。

### 16.4 Access profile 与 negative traffic

增加 CPU-shaped byte/half/word profile、MMIO known/unknown offset 权重、unmapped address、error response 和边界地址专属 sequence，避免通用 map random 的流量分布代替目标明确的 testcase。

### 16.5 Coverage closure

增加 MMIO register/op、known/unknown、side effect、target/idle、边界地址和 error crosses，定义 coverage exclusion、目标阈值和多 seed closure；工具条件允许时恢复 VDB/URG HTML 或合并报告。

### 16.6 Data-subsystem 硬件边界 SVA

增加 wrapper delay 输入不大于 127、配置在 outstanding 期间稳定、target response 只发生一次等 DUT 边界断言。若断言依赖 DUT 内部状态，应使用独立 assertion module + bind。

### 16.7 Reset、长回归与维护

增加 mid-test reset、checker/reference model reset、更多固定 seed、长随机回归和 CI 结果归档。未来若协议升级为 multi-outstanding，必须重做 monitor pending model、scoreboard 关联和 wrapper 配对规则。

## 17. 验证证据

本 spec 定义验证契约，不保存某一次运行的可变结果。v6.0 收口时实际执行的 test、seed、checker 统计、functional coverage、RTL-001 修复前后证据和剩余风险统一记录在 `verification_report.md`；原始 VCS 日志由脚本生成在本地 `sim/logs/`，不作为版本化验证结论。
