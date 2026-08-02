# 0836 AXI-Lite adapter、interconnect 与 APB 外设桥规划

> 文档编号：0836  
> 所属系列：083x RV32I 教学核后续完善阶段  
> 文档定位：规划在 v7.0 已完成 data-side simple request/response bus、MEM backpressure 和 UVM/SVA 验证收口后，如何引入 AXI4-Lite 与 APB4，形成可运行、可验证且不污染 CPU 流水线内部接口的标准总线子系统  
> 对应总规划：`0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`  
> 前置文档：`0804 RISC-V SoC、MMIO与外设互联.md`、`0829 综合、FPGA上板与SoC扩展方向.md`、`0834 可变延迟memory与MMIO、简化内部总线与backpressure规划.md`、`0835 wait-state验证收口、SVA与UVM入门demo规划.md`

本篇只规划“第六阶段实现什么、接口边界是什么、验证到什么程度”。它不是执行阶段的 `plan.md`，不写逐文件、逐信号的施工步骤，也不重复大段 AXI 基础原理。

0834 已经让 CPU MEM 阶段摆脱固定响应假设：core LSU 通过 single-outstanding simple request/response bus 发起访问，MEM 在 response 返回前 backpressure 流水线，error 可以精确进入 load/store access fault。0835 又把这套边界沉淀为 Verilator 程序回归、VCS/UVM/SVA、scoreboard 和 functional coverage。

0836 的任务不是推翻这套接口，而是在 CPU 外部增加标准总线层：

```text
core LSU
  -> v7.0 internal simple data bus
  -> simple_bus_to_axi_lite
  -> AXI-Lite router
       -> AXI-Lite DMEM slave port
       -> AXI-Lite-to-APB4 bridge
            -> APB4 mux
                 -> GPIO0
                 -> UART0
                 -> TIMER0
       -> reserved AXI-Lite accelerator control window
       -> decode-error response
```

本阶段优先完成“单 CPU master、single-outstanding、功能正确”的最小标准总线系统，不追求通用 AXI crossbar、峰值吞吐或完整验证覆盖。

## 第1章 本步目标和非目标

### 1.1 当前已经完成的基础

进入 0836 前，项目已经具备：

| 能力 | 当前状态 |
|---|---|
| CPU data-side 接口 | `data_req_t/data_resp_t + req_ready`，single outstanding、in-order completion |
| 流水线等待 | MEM wait 能冻结前级，WB 可以自然完成 |
| 精确错误 | data response error 能进入 load/store access fault，保持 precise trap |
| byte lane | CPU 输出原始 byte address、按 lane 对齐的 `wdata` 和非零 `be` |
| memory map | IMEM、DMEM、GPIO、UART、TIMER、ACCEL 预留窗口已经集中定义 |
| 外设 ABI | GPIO0/UART0/TIMER0 寄存器地址、访问属性和副作用已经稳定 |
| 程序回归 | Verilator ASM/C self-check 能验证 CPU、trap、interrupt、DMEM 和 MMIO 端到端行为 |
| 协议验证 | v6.0 data_subsystem UVM/SVA 工作区已经冻结，可作为 simple bus 历史验证资产 |

这些基础决定了 AXI-Lite 应被放在 core 外部，由 adapter 吸收五通道状态，而不是把 AXI channel 状态扩散到 `mem_stage`、pipeline register 或 hazard/control 网络。

### 1.2 本步目标

本阶段完成后，应具备：

| 能力 | 目标 |
|---|---|
| AXI-Lite master adapter | 把一笔 internal simple bus read/write 转换成合规的 AXI4-Lite 五通道事务 |
| AXI-Lite router | 单 master 按地址路由到 DMEM、APB bridge、预留 accelerator slot 或 default error |
| DMEM 接入 | 通过 AXI-Lite slave 访问 backing RAM，支持 32-bit read/write 和 4-bit byte strobe |
| APB 外设层 | AXI-Lite-to-APB4 bridge 驱动 GPIO0/UART0/TIMER0，保留现有寄存器 ABI |
| 错误传播 | AXI `SLVERR/DECERR` 映射回 simple bus error，再进入 CPU access fault |
| backpressure | AW/W/B/AR/R 和 APB `PREADY` 均可等待，CPU 仍只看到一笔 request 最终完成或失败 |
| 标准协议边界 | 保留 AXI-Lite 五通道独立握手，不假设 AW/W 必须同拍接受 |
| 可综合边界 | 主线 RTL 不依赖 testbench RAM、随机延迟模型或验证专用代码 |
| 端到端兼容 | 现有软件地址图、外设寄存器 ABI、trap/interrupt 行为和程序回归不因总线替换而改变 |
| 展示与维护 | 架构、协议限制、开源参考、验证证据和已知边界可以独立说明 |

### 1.3 本步非目标

本阶段不做：

| 暂不做 | 原因 |
|---|---|
| 完整 AXI4 | 当前无 cache、burst、DMA、多 ID 或乱序需求 |
| AXI burst | AXI-Lite 每笔访问只有一个 data beat |
| 多 master 仲裁 | 当前只有一个 CPU data master，不需要 CPU/DMA/accelerator master 竞争 |
| 多 outstanding | core 前端本来就是 single outstanding，本阶段不为吞吐额外增加队列 |
| read/write 并发优化 | 系统级同一时刻只保留一笔未完成 read 或 write，先保证协议正确 |
| 通用 crossbar | 当前只需要单 master 的 address router，不实现任意 M×N 拓扑 |
| CDC | AXI-Lite、APB、CPU 和当前外设统一使用同一时钟和复位 |
| AXI QoS/cache/region/user | 当前教学 SoC 没有对应系统语义 |
| AXI exclusive/atomic | AXI-Lite 不承担 exclusive、ATOP 或 RISC-V A 扩展 |
| 修改 IMEM | 本阶段只改 data side，固定响应取指接口继续保留 |
| accelerator 本体 | 只保留 AXI-Lite control window，不实现计算数据通路、DMA 或中断协议 |
| 新建完整 AXI UVM 平台 | 0836 以模块级协议验证和现有 SoC 程序回归为主，避免重复搭建大规模验证基础设施 |
| 全面 coverage closure | 要求关键功能和协议 corner case 有证据，不追求所有合法交叉组合达到 100% |

## 第2章 本阶段总线架构

### 2.1 CPU 内部接口保持不变

core 继续使用 v7.0 已稳定的 internal simple data bus：

```text
request:
  valid, ready, write, addr, wdata, be

response:
  valid, rdata, error
```

CPU 只理解以下事务语义：

1. `valid && ready` 时 request 被接受。
2. accepted request 在 response 返回前保持为唯一 outstanding transaction。
3. `response.valid` 表示本次访问结束。
4. `response.error` 表示 load/store access fault。

AXI-Lite 的 AW/W/B/AR/R channel 状态全部由 adapter 管理。已经被 AXI 接受的 transaction 不因 younger pipeline flush、redirect 或 interrupt pending 而取消；CPU 等待 transaction 完成后再按现有 precise commit/trap 规则处理。

### 2.2 AXI-Lite 层次

本阶段采用单 master、多个目标的轻量层次：

```text
simple_bus_to_axi_lite
  |
  | one AXI-Lite master port
  v
axi_lite_router
  |
  +-- DMEM region ----------> AXI-Lite DMEM slave port
  |
  +-- implemented MMIO -----> AXI-Lite-to-APB4 bridge
  |                              |
  |                              +--> APB4 GPIO0
  |                              +--> APB4 UART0
  |                              +--> APB4 TIMER0
  |
  +-- ACCEL control region --> reserved AXI-Lite target / DECERR before implementation
  |
  +-- other address --------> AXI-Lite default error response
```

这里的 `router` 是单 master address decoder 和 response router，不是支持多 master 并发仲裁的 crossbar。模块命名和文档应准确表达这一限制。

对应到本阶段规划的 RTL module，连接关系如下：

```text
core
  |
  v
simple_bus_to_axi_lite
  |
  v
axi_lite_router
  |    DMEM
  +------------> axi_lite_ram
  |    MMIO
  +------------> axi_lite_to_apb
  |                       |
  |                       v
  |                    apb_mux
  |                       |
  |                       +--> apb_to_reg_adapter --> mmio_gpio
  |                       +--> apb_to_reg_adapter --> mmio_uart
  |                       +--> apb_to_reg_adapter --> mmio_timer32
  |  ACCEL0
  +------------> AXI-Lite slave module（0836 只预留端口）
  |  default
  +------------> axi_lite_error_slave
```

该图只表达 module 之间的 transaction 连接，不表示所有模块都在同一级实例化。`rv32i_soc` 实例化 `core` 和 `data_subsystem`，`data_subsystem` 再组织 adapter、router、bridge、APB mux、register adapter 和当前外设；`axi_lite_ram` 位于 testbench 或 FPGA wrapper，通过 SoC 透出的 DMEM AXI-Lite port 连接。`axi_lite_error_slave` 是 router 的一个下游目标分支，正常 DMEM/MMIO 访问不会经过它。

### 2.3 各模块的组合直通与注册边界

本文所说的“组合直通”是指某一层没有在当前 request/response 数据路径中插入 register slice，不代表该模块完全没有状态。router 仍需保存 outstanding transaction 的 target 和 AW/W 完成情况，bridge 仍需保存跨协议 transaction，只是这些状态是否产生额外固定延迟取决于它们是否阻止同一拍的上下游 handshake。

第一版各模块采用以下取舍：

| 模块 | request 路径 | response 路径 | 选择原因 |
|---|---|---|---|
| `simple_bus_to_axi_lite` | 接受并锁存 simple request，下一拍再发起 AXI request | AXI B/R handshake 直接形成 simple response，不再额外寄存 | 两侧协议语义不同，优先隔离 CPU ready 与 AXI fabric READY 的组合路径，并可靠保持拆分后的 AXI channel payload |
| `axi_lite_router` | 地址译码和 selected target READY 组合直通 | selected target 的 B/R 组合返回 | 两侧均为 AXI-Lite，只需路由和保存历史 target；不插入 register slice 可以避免 fabric 无条件增加一拍 |
| `axi_lite_ram` / default error slave | 空闲时接受 AXI request | 产生并保持注册式 B/R response | slave 必须在 request 完成后生成对应 response，并在上游 backpressure 时稳定保持 payload |
| `axi_lite_to_apb` | 接受并保存 AXI request，再启动 APB transaction | APB completion 后形成并保持 AXI response | 两侧协议阶段不同，必须保存 transaction，并严格执行 APB SETUP/ACCESS |
| `apb_mux` | 根据 PADDR 译码并组合分发 PSEL、地址和 payload | selected peripheral 的 PREADY/PRDATA/PSLVERR 组合返回 | APB master 会在整个 SETUP/ACCESS 期间保持地址和控制稳定，mux 无需再保存一份 route state |
| `apb_to_reg_adapter` 与当前寄存器外设 | APB ACCESS completion 组合形成一次寄存器访问条件 | 固定响应 read data/error 组合返回，寄存器 side effect 在 completion 边沿更新 | 当前外设本体是固定响应寄存器模型，不再人为增加一层 transaction 延迟 |

因此，协议转换边界倾向于保存 transaction，纯路由/译码边界倾向于组合直通，真正的 slave 则倾向于注册 response。若后续时序分析表明 router 或 APB mux 的组合路径过长，可以显式加入 register slice，但必须把新增延迟、outstanding 状态和验证边界一起纳入设计，而不能只改信号连接。

### 2.4 SoC 与 memory model 边界

`simple_rom/simple_ram` 继续保持在 testbench 或 FPGA wrapper 一侧，不重新塞回 `rv32i_soc`。主线 SoC 可以透出下游 DMEM AXI-Lite port，由不同环境连接：

| 环境 | DMEM AXI-Lite slave |
|---|---|
| Verilator/VCS testbench | 可配置 backpressure 的 AXI-Lite RAM model |
| FPGA wrapper | BRAM controller 或 AXI-Lite memory adapter |
| 后续系统集成 | 片上 SRAM、总线 bridge 或其它 AXI-Lite slave |

若本阶段新增可综合 `axi_lite_ram`，它应是独立可复用模块，而不是依赖 `$readmemh`、mailbox 或随机延迟的 SoC 内部测试模型。程序镜像加载仍由 testbench/FPGA wrapper 负责。

`rv32i_soc` 从旧离散 DMEM 端口切换为 downstream AXI-Lite port 时，现有 `tb_rv32i_soc` 必须在同一实现节点完成最小迁移：连接新端口、实例化 zero-wait AXI-Lite RAM，并同步当前 ASM/C 仿真 filelist。随机 backpressure 和详细 testcase 可以后续补充，但不能让主线 SoC 与现有仿真 top 长时间处于接口不兼容状态。

## 第3章 本阶段采用的 AXI4-Lite 子集

### 3.1 相比完整 AXI4 删除的能力

AXI4-Lite 保留 AXI 的五通道和 ready/valid 规则，但面向单 beat、memory-mapped register/memory access。与完整 AXI4 相比，本阶段不出现：

| 完整 AXI4 能力 | 本阶段 AXI4-Lite |
|---|---|
| burst length/type | 无 `AxLEN/AxBURST`，每笔只有一个 data beat |
| beat size negotiation | 32-bit data width固定，byte lane 由 `WSTRB` 表达 |
| transaction ID | 无 `AWID/ARID/BID/RID` |
| response reorder | 不支持，response 按请求顺序完成 |
| `WLAST/RLAST` | 单 beat，无需 last |
| multiple outstanding | 本项目额外限制为全局 single outstanding |
| exclusive/atomic | 不支持 |

“全局 single outstanding”是本项目基于当前 CPU 的实现限制，不是 AXI4-Lite 标准本身要求。文档和 README 不应把它误写成 AXI-Lite 的通用能力上限。

### 3.2 必须保留的 AXI-Lite 行为

虽然本阶段限制了并发能力，但以下标准行为不能简化掉：

- AW、W、B、AR、R 是五个独立 channel。
- 每个 channel 均通过 `VALID && READY` 在时钟采样点完成一次 transfer。
- source 在 `VALID=1 && READY=0` 时必须保持 payload 稳定。
- write address 与 write data 可以在不同周期握手，不能要求二者必须同拍被接受。
- adapter 必须分别记录 AW 和 W 是否已经完成，只有两者均完成后才能等待并接收 write response。
- `BVALID` 必须对应已经完成地址与数据接受的 write transaction。
- `RVALID` 必须对应已经接受的 read address transaction。
- slave 在 `BVALID && !BREADY` 或 `RVALID && !RREADY` 时必须保持 response payload 稳定。
- 不依赖 `READY` 预先为 1 才拉高 `VALID`，避免不合法的互等和死锁。

为减少组合路径和同拍边界，本阶段允许所有 AXI-Lite slave 使用注册 response；不要求 request handshake 当拍组合产生 B/R response。

### 3.3 信号边界

第一版固定：

| 参数 | 取值 |
|---|---|
| address width | 32 bit |
| data width | 32 bit |
| write strobe width | 4 bit |
| clock | 单一 SoC clock |
| reset | 与当前 SoC 一致的 active-low reset |
| protection | `AWPROT/ARPROT` 保留标准字段，第一版可由 adapter 输出固定合法值 |

建议集中定义 AXI-Lite channel payload 类型和端口方向，避免每个模块重复声明一组宽散信号。无论实际采用 SystemVerilog `interface` 还是 request/response struct，静态顶层和 filelist 都必须保持 VCS、Verilator 与综合工具可编译。

## 第4章 simple bus 到 AXI-Lite master adapter

### 4.1 基本职责

`simple_bus_to_axi_lite` 是 CPU 与标准总线之间最关键的语义转换层：

| internal simple bus | AXI-Lite |
|---|---|
| read request | AR channel |
| read response | R channel |
| write request | AW + W channel |
| write response | B channel |
| `be` | `WSTRB` |
| `error=0` | `OKAY` |
| `error=1` | `SLVERR` 或 `DECERR` |

adapter 只在自身 idle 且能够保存 transaction 时拉高 internal `req_ready`。request 被接受后，adapter 锁存 write、addr、wdata 和 be，直到 AXI transaction 完整结束，不再依赖上游 payload。

### 4.2 Read 路径

read transaction 至少经历：

```text
accept simple request
  -> drive ARVALID/ARADDR
  -> wait AR handshake
  -> assert RREADY and wait R handshake
  -> map RDATA/RRESP to simple response
  -> return idle
```

AR payload 在 handshake 前保持稳定。R channel stalled 时，由 AXI slave 保持 `RDATA/RRESP`；adapter 不重复产生 simple response。

### 4.3 Write 路径

write transaction 至少经历：

```text
accept simple request
  -> drive AWVALID/AWADDR
  -> drive WVALID/WDATA/WSTRB
  -> track AW and W handshakes independently
  -> after both are accepted, wait B handshake
  -> map BRESP to simple response
  -> return idle
```

AW 和 W 可以同拍握手，也可以 AW 先、W 先或相隔多拍。adapter 可以从同一笔 simple request 同时开始驱动 AWVALID 和 WVALID，但不能把 `AWREADY && WREADY` 同拍为 1 当作正确性的前提。

### 4.4 Response 和错误映射

| AXI response | simple bus | CPU 可见结果 |
|---|---|---|
| `OKAY` | `error=0` | load/store 正常完成 |
| `SLVERR` | `error=1` | load/store access fault |
| `DECERR` | `error=1` | load/store access fault |

CPU 当前不区分 `SLVERR` 与 `DECERR`，但 AXI monitor、日志和 assertion 应保留原始 response，便于区分“目标存在但访问失败”和“地址未命中任何目标”。

### 4.5 第一版状态机与性能取舍

第一版 adapter 明确采用注册式 transaction 状态机，而不是把 simple request 组合直通 AXI-Lite channel：

1. `IDLE` 接受 simple request，并在时钟沿锁存 addr、wdata 和 be。
2. 下一周期进入 read address 或 write request 状态，开始驱动 AXI-Lite `ARVALID` 或 `AWVALID/WVALID`。
3. read 路径记录 AR 已完成并等待 R；write 路径分别记录 AW、W 是否完成并等待 B。
4. B/R handshake 直接形成 simple response，不在 adapter 内再次增加 response 寄存级。
5. response 完成后回到 `IDLE`，才允许接受下一笔 simple request。

这不是 AXI-Lite 强制要求的唯一实现方式，而是本阶段为了降低协议实现和时序收敛风险做出的选择。adapter 必须具备某种 transaction 状态，才能在下游 backpressure、AW/W 分拍握手和 response 等待期间保存上下文；这些状态可以表现为显式 FSM，也可以表现为 pending、AW-sent、W-sent 等标志。第一版使用显式 FSM，可以避免 CPU request、AXI router `READY` 与 CPU `req_ready` 之间形成较长组合路径，也便于模块级验证逐项观察 channel 状态。

该结构会在 simple request 接受和 AXI request channel 握手之间增加一个注册拍。它不代表 AXI-Lite 协议天然固定增加一拍，也不代表 adapter 在 response 方向又额外寄存一拍。正常访问的其余延迟来自 AXI request/response 分离、slave 的注册 response，以及 MMIO 路径上的 APB SETUP/ACCESS。

第一版先保留这一实现以完成协议和系统功能收口，不把最低访问延迟作为 0836 完成条件。后续若程序性能或 load/store CPI 表明这一拍值得优化，可以增加“请求组合直通”版本：在 simple request 有效当拍直接驱动 AR 或 AW/W，并只保留 AW/W 分拍完成和 response pending 所需的状态。该优化应单独验证组合路径、AW/W 任意先后、single-outstanding 和无组合环，并以时序结果和实际 CPI 对比决定是否采用。

## 第5章 AXI-Lite router 与地址译码

### 5.1 Router 能力边界

第一版 router 只负责：

- 一个上游 AXI-Lite master。
- 若干固定地址目标。
- write address 目标锁存与 W/B 路由。
- read address目标锁存与 R 路由。
- 未命中地址生成 `DECERR`。
- 当内部资源忙时通过 READY backpressure 上游。

它不负责多 master 仲裁、QoS、公平性、跨时钟、宽度转换或乱序 response。

第一版 router 不插入 request/response register slice。空闲时，AW/W/AR request 经过地址比较和组合 mux 直接到达 selected slave，selected slave 的 READY 也在同一周期组合返回；request handshake 后，状态机只锁存 target 和 AW/W 完成状态。B/R response 同样通过组合 mux 返回上游。因此 router 虽然包含状态机，但不会因为状态数量而固定增加访问拍数；只有下游 backpressure、response 延迟或未来主动加入的 register slice 才会增加对应等待。

### 5.2 Write route 的关键状态

W channel 不携带地址，因此 router 不能仅靠当前组合 `AWADDR` 路由 WDATA。它必须正确处理：

- AW/W 同拍到达。
- AW 先握手，W 后到达。
- W 先有效，等待 AW 决定目标。
- downstream AWREADY 与 WREADY 独立变化。
- B response 返回前不能把本笔 write 的目标选择覆盖掉。

实现可以选择在 AW 决定目标前不接受 W，也可以在内部保存一拍 W payload；无论选择哪种，不能形成 AW/W channel 相互等待的死锁。

### 5.3 Read route

AR handshake 时锁存目标，随后只允许该目标驱动本笔 R response。R transaction 完成前不接受会覆盖 route state 的下一笔 read。

### 5.4 同拍 read/write 请求

当前 CPU adapter 不会同时发起 read 和 write，但模块级验证仍应对异常或未来流量进行防御性检查。若 router 不能并行服务 read/write，应通过 READY 明确只接受其中一类，并采用固定、可说明的优先级；不能同拍接受两笔后只保存一笔状态。

## 第6章 AXI-Lite DMEM 接入

### 6.1 软件可见语义

DMEM 地址范围、byte address 语义和 load/store lane 规则保持不变：

- AXI 地址继续传递 CPU 原始 byte address。
- `WSTRB` 直接来自 internal `be`。
- store data 已由 CPU 按 byte lane 对齐。
- read 返回包含目标 byte/half 的完整 32-bit word，CPU 继续负责截取和符号/零扩展。
- 未对齐访问仍由 CPU 原有规则处理；总线层不重新解释 RISC-V load/store 类型。

### 6.2 AXI-Lite memory slave

第一版 memory slave 应支持：

- AW/W 独立接受。
- 4-bit `WSTRB` 逐 byte 更新。
- AR read。
- B/R backpressure。
- 固定响应和可配置 wait-state 的验证模型。
- 地址越界返回明确错误。

验证专用随机 READY/response delay 应位于 testbench wrapper 或仿真配置层，不进入可综合 memory slave 的功能语义。

## 第7章 AXI-Lite-to-APB4 bridge

### 7.1 为什么选择 APB4

GPIO/UART/TIMER 属于低带宽寄存器外设，不需要各自实现完整 AXI-Lite 五通道。AXI-Lite-to-APB bridge 可以集中处理 AXI channel 状态，外设侧只保留 APB setup/access 两阶段。

本阶段使用 APB4 而不是只实现 APB3 子集，主要原因是 APB4 提供 `PSTRB`，可以自然保留当前 CPU `SB/SH/SW` 的 byte enable 语义。

### 7.2 Bridge 能力边界

第一版 bridge：

- 作为一个 AXI-Lite slave。
- 作为一个 APB4 master。
- 全局只处理一笔 read 或 write。
- write 必须分别接收 AW 和 W，再启动 APB write。
- read 接收 AR 后启动 APB read。
- APB transaction 严格经过 SETUP 和 ACCESS。
- `PREADY=0` 时保持 `PSEL/PENABLE/PADDR/PWRITE/PWDATA/PSTRB` 稳定。
- `PSLVERR` 映射为 AXI `SLVERR`。
- `PRDATA` 映射为 AXI `RDATA`。
- B/R response 在 AXI master 接受前保持有效且 payload 稳定。

### 7.3 APB 外设接入

APB mux 根据地址选择 GPIO0、UART0 或 TIMER0，并把 selected peripheral 的响应返回 bridge。现有外设寄存器本体可以保留，通过薄 APB wrapper 或公共 APB register access 层转换：

| APB4 | 现有外设寄存器访问 |
|---|---|
| `PSEL && PENABLE && PREADY` | 一次真正完成的 access pulse |
| `PWRITE` | write enable |
| `PSTRB` | byte enable |
| `PADDR` | 原始 byte address |
| `PWDATA` | write data |
| `PRDATA` | register read data |
| `PSLVERR` | access fault |

GPIO W1C、UART TX event、UART RX read side effect 和 TIMER register write 必须只在 APB access completion 时生效一次，不能在 SETUP 或 `PREADY=0` 的每个等待周期重复触发。

第一版现有寄存器块可以固定 `PREADY=1`；模块级验证必须使用可等待的 APB slave model 检查 bridge 的 wait-state 行为，以免系统正确性依赖固定响应外设。

## 第8章 data subsystem 改造与预计访存延迟

### 8.1 data subsystem 职责迁移

0836 继续保留 `data_subsystem` 作为 core data-side 与 SoC 数据设备之间的集成边界，但其内部职责从“simple bus 地址译码、固定响应 target 和人工延迟包装”迁移为“simple bus 到 AXI-Lite/APB 的标准协议子系统”：

```text
v7.0 data_subsystem
  = simple bus decoder
  + fixed-response DMEM/MMIO access
  + response delay wrapper

0836 data_subsystem
  = simple_bus_to_axi_lite
  + AXI-Lite router/default error
  + external AXI-Lite DMEM port
  + AXI-Lite-to-APB4 bridge
  + APB mux/peripheral wrapper
  + GPIO/UART/TIMER register blocks
```

本轮需要完成以下职责调整：

- core 侧 `data_req_t/data_resp_t + req_ready` 接口保持不变，CPU 流水线不感知 AXI-Lite 和 APB channel。
- 删除旧 `data_subsystem` 内按 target 选择、计数并回放 response 的 delay wrapper 逻辑。
- 删除 `dmem/gpio0/uart0/timer0_resp_delay_cycles_i` 等验证专用 delay 配置端口，并在同一 SoC/TB 迁移节点同步其连接。
- 旧 simple bus 组合地址译码与 response mux 由 AXI-Lite router、default error response、AXI-Lite-to-APB4 bridge 和 APB mux 取代。
- 外置 DMEM 的离散 simple RAM 端口切换为下游 AXI-Lite slave port；RAM 仍位于 testbench、FPGA wrapper 或其它系统集成层，不进入 `rv32i_soc`。
- GPIO0/UART0/TIMER0 的软件寄存器 ABI、外部 IO 和中断语义保持不变，但寄存器访问只在 APB ACCESS completion 时生效。
- single-outstanding 的保存、等待和完成状态由 adapter/router/bridge 各自按协议边界管理，不再由公共 response delay 计数器模拟。

删除 delay wrapper 不等于失去 wait-state 验证能力。正式 RTL 中的可变等待改由标准协议本身表达：外部 AXI-Lite DMEM model 可以控制各 channel 的 `READY/VALID`，`axi_lite_to_apb` 模块级 testbench 可以控制 `PREADY`。SoC 集成级正式外设第一版固定 `PREADY=1`，不重新加入只服务验证的 delay input。

v7.0 的旧 data subsystem 和 delay wrapper 已由 tag、UVM 工作区 RTL 快照及既有回归保存；主线切换后不要求继续保留两套可综合实现。

### 8.2 延迟统计口径和基准假设

本文把一次 data transaction 的传输延迟定义为：simple request 在上升沿 `E0` 通过 `valid && ready` 被接受，到 CPU 在后续上升沿采样到 `response.valid` 并完成该笔访存之间的周期数。该口径统计的是 CPU MEM 等待的总线传输部分，不包括指令到达 MEM 之前的流水线周期，也不把 testbench 日志显示时间误算为额外周期。

以下基准延迟采用第一版预期结构：

- adapter 使用 4.5 节所述注册式状态机。
- AXI-Lite router 只做组合选择和 route 状态保存，不插入额外 register slice；其状态机与 selected slave 在同一 handshake 边沿并行更新，因此基准延迟不额外计入 router 一拍。
- 下游 `ARREADY/AWREADY/WREADY` 立即可用。
- AXI-Lite DMEM slave 在接受 request 后产生注册式 B/R response。
- AXI-Lite-to-APB4 bridge 严格执行 SETUP、ACCESS，并在 APB completion 后产生注册式 AXI response。
- GPIO0/UART0/TIMER0 固定 `PREADY=1`。
- 没有额外仲裁、随机 delay 或 response backpressure。

状态机数量不能直接换算成访问拍数。只有以下情况会在本统计口径中增加周期：某层先锁存输入、到下一拍才允许下游握手；协议规定必须跨越新的阶段；或者 READY/VALID backpressure 使 handshake 推迟。多个模块若在同一个 handshake 边沿同时更新状态，则这些状态转换并行发生，不会逐个累加。

以无 backpressure 的 DMEM 访问为例，adapter 在 `E0` 锁存 simple request，因此直到 `E0` 之后才产生 AXI request，这是一个真实的 request 注册边界；`E1` 发生 AXI request handshake 时，adapter、router 和 RAM 同时更新状态，router 锁存 target 与 RAM 开始生成 response 并不是先后串行的两个周期；RAM 的注册式 response 在下一周期被接受，形成第二个真实阶段。因此约 2 拍来自“adapter 请求入口 1 拍 + RAM 注册 response 1 拍”，而不是 adapter、router、RAM 三个状态机各加一拍。MMIO 路径还必须经过 APB SETUP/ACCESS，所以 bridge 的这些协议阶段会真实增加周期。

在这些假设下，预计延迟为：

| 访问路径 | 从 `E0` 接受到 response completion | 主要来源 |
|---|---:|---|
| v7.0 simple bus，wrapper delay=0 | 0 拍 | 固定响应 target 当拍组合返回 |
| v7.0 simple bus，wrapper delay=N | N 拍 | 人工 response delay 计数器 |
| 0836 AXI-Lite DMEM read | 2 拍 | adapter 请求入口 1 拍 + RAM 注册 R response 1 拍 |
| 0836 AXI-Lite DMEM write | 2 拍 | adapter 请求入口 1 拍 + RAM 注册 B response 1 拍 |
| 0836 未映射地址或未启用 ACCEL0 | 2 拍 | adapter 请求入口 1 拍 + error slave 注册 DECERR response 1 拍 |
| 0836 AXI-Lite-to-APB4 MMIO read | 约 4 拍 | adapter 入口、APB SETUP/ACCESS、bridge 注册 R response |
| 0836 AXI-Lite-to-APB4 MMIO write | 约 4 拍 | adapter 入口、APB SETUP/ACCESS、bridge 注册 B response |

以无 backpressure 的 DMEM read 为例：

```text
E0：simple request 被 adapter 接受并锁存
E1：AXI AR handshake，DMEM slave 产生注册式 R response
E2：AXI R handshake，CPU 接收 simple response
```

MMIO 在 AXI request handshake 后还要依次经过一个 APB SETUP 周期和至少一个 ACCESS 周期。若 bridge 或 router 的最终实现增加额外寄存级，表中相应路径继续增加；若 bridge 在满足协议与时序要求的前提下直接从 APB completion 形成 AXI response，则可能减少一拍，因此表中 MMIO 数值是第一版注册式实现的预计值，不是 APB4 对整个 SoC 固定规定的访问拍数。

### 8.3 可变等待和后续性能优化

AXI-Lite 不规定固定 request-to-response 延迟。实际访问时间应在 8.2 节基准上增加各层真实等待：

- read 增加等待 `ARREADY` 和 `RVALID` 的周期。
- write 增加 AW/W 中最晚完成 channel 的等待，以及等待 `BVALID` 的周期。
- AXI master 侧延迟 `BREADY/RREADY` 时，增加 response channel 被接受前的等待周期；当前 CPU adapter 进入 response 状态后会立即拉高对应 READY，模块级 slave/router 验证仍需覆盖这一合法 backpressure。
- MMIO 增加 APB `PREADY=0` 的 ACCESS 周期。
- 后续若加入仲裁、register slice、CDC 或更慢的真实 slave，还需增加对应等待。

因此，0836 删除旧 wrapper 后仍然具备比固定计数器更真实的可变延迟来源。模块级验证必须分别控制各 channel，不能只把所有等待折叠成一个统一的 `resp_delay_cycles`。

“请求组合直通”保留为 0836 之后的明确性能优化项，而不是本阶段缺失功能。若实施该优化，在相同的无 backpressure 和注册式 slave 假设下，DMEM 基准可由约 2 拍降为约 1 拍，MMIO 基准可由约 4 拍降为约 3 拍；代价是引入 CPU request 到 AXI fabric/READY 的组合路径，并需要重新检查时序、组合环和 channel corner case。优化不得删除 AW/W 独立完成状态，也不得改变 CPU 的 single-outstanding 和精确提交语义。

推荐的优化边界类似 FIFO 空时的 fall-through：adapter 在 `IDLE` 时可以把当前 simple request 直接送到 AXI request channel；若 AR 或 AW/W 在该拍完成 handshake，则下一状态直接进入 response 等待，若下游未全部接受，则锁存 payload 和已完成 channel 状态，继续在 `READ_ADDR/WRITE_REQ` 中保持剩余请求。AXI `VALID` 不能依赖对应 `READY` 才产生，stall 时 payload 仍必须稳定。

该优化只旁路 request 入口寄存，不把同一笔新 request 对应的 B/R response 继续组合穿透回 CPU。AXI slave 必须在确认 AR 或 AW/W transfer 后再产生对应 response，其中 write response 尤其要求 AW 和 W 均已完成；让新请求在同一采样沿完成 request 与 response，通常需要形成 slave 输入到输出的组合路径，也会重新引入从 CPU request 穿过 adapter、router、slave 再返回 CPU response 的长组合路径。0836 及其后续性能优化都以“request 可直通、response 保持注册式阶段边界”为推荐上限，不追求恢复旧 simple bus 的当拍组合完成。

## 第9章 地址图、错误类型与 accelerator 预留

### 9.1 地址图保持兼容

本阶段不改变现有软件地址：

| 区域 | 地址 | 路由 |
|---|---:|---|
| DMEM | `0x0004_0000`–`0x0007_FFFF` | AXI-Lite DMEM slave |
| GPIO0 | `0x0008_0000`–`0x0008_00FF` | AXI-Lite-to-APB4 -> GPIO0 |
| TIMER0 | `0x0008_1000`–`0x0008_10FF` | AXI-Lite-to-APB4 -> TIMER0 |
| UART0 | `0x0008_2000`–`0x0008_20FF` | AXI-Lite-to-APB4 -> UART0 |
| ACCEL0 | `0x0008_8000`–`0x0008_8FFF` | 预留 direct AXI-Lite control slave slot |
| 其它地址 | 未实现 | default error |

具体常量继续以 `core_pkg.sv/soc_pkg.sv` 为唯一来源，本文只记录路由关系。

### 9.2 `DECERR` 与 `SLVERR`

建议统一：

| 场景 | AXI response |
|---|---|
| 地址未命中任何系统 target | `DECERR` |
| 已命中 DMEM/APB target，但目标内部访问失败 | `SLVERR` |
| 合法访问 | `OKAY` |

例如 GPIO0 window 内未定义 register offset 属于已选中 GPIO0 slave 后的访问失败，返回 `SLVERR`；完全不属于任何已实现窗口的地址返回 `DECERR`。

### 9.3 Accelerator control window

0836 只完成地址和接口预留：

- `ACCEL0_BASE/ACCEL0_SIZE_BYTES` 继续保留。
- accelerator control slave 未来直接挂 AXI-Lite，不强制经过 APB。
- accelerator 未实现前，访问该窗口返回 `DECERR`，不能静默读零或丢弃写。
- 本阶段不固定 SRC/DST/LEN 等详细寄存器 ABI，避免在 accelerator 数据搬运方式尚未确定前写死软件契约。
- 后续 accelerator 即使有 AXI4/DMA data master，其控制面仍可以使用本阶段预留的 AXI-Lite slave。

## 第10章 Reset、backpressure 与精确提交边界

### 10.1 Reset

reset 后必须满足：

- 所有 AXI master `VALID` 清零。
- 所有 AXI slave response `VALID` 清零。
- adapter/router/bridge 的 pending、route、AW-seen、W-seen 状态清零。
- APB `PSEL/PENABLE` 清零。
- CPU simple bus 不看到 orphan response。

本阶段不支持“reset 中途要求未完成 transaction 可恢复”。reset 会清除系统事务状态，软件从 reset vector 重新开始。

### 10.2 Backpressure

必须分别验证：

- AWREADY 延迟。
- WREADY 延迟。
- AW 先于 W。
- W 先于 AW。
- BVALID 延迟。
- BREADY 延迟。
- ARREADY 延迟。
- RVALID 延迟。
- RREADY 延迟。
- APB PREADY 多拍为 0。

这些场景不能只测试“所有 READY 永远为 1”。否则虽然程序可能通过，但没有真正证明五通道独立状态机正确。

### 10.3 与 CPU trap/interrupt 的关系

CPU 的精确语义继续以 0834 为准：

- accepted simple request 对应的 AXI/APB transaction 必须完成，不能因 younger redirect 被取消。
- bus error 完成后由当前 memory instruction 产生 access fault。
- memory transaction outstanding 期间，younger redirect 不越过 older memory instruction。
- interrupt pending 等待 memory completion 边界，再按既有优先级接受。
- failed write 不应产生成功的外设副作用。

AXI-Lite 接入只改变 transaction transport，不改变 CPU 架构提交规则。

## 第11章 开源项目参考与代码归属

### 11.1 主要参考

本阶段允许并建议参考成熟开源实现，重点对照 channel 状态、AW/W 解耦、response 保持、错误处理和验证方法：

| 项目 | 参考内容 | 本阶段定位 |
|---|---|---|
| [pulp-platform/axi](https://github.com/pulp-platform/axi) | `axi_lite_xbar`、`axi_lite_to_apb`、AXI-Lite driver/random master/slave 和模块组织 | 主要架构与协议参考 |
| [fpganinja/taxi](https://github.com/fpganinja/taxi) | AXI-Lite/APB interface、interconnect、adapter 和 RAM | 交叉对照，注意 CERN-OHL-S-2.0 许可 |
| [ZipCPU/wb2axip](https://github.com/ZipCPU/wb2axip) | AXI-Lite formal properties、常见错误和协议断言 | SVA/formal 思路参考 |
| [cocotbext-axi](https://github.com/alexforencich/cocotbext-axi) | AXI-Lite/APB master、slave、RAM simulation model | 可选独立验证工具 |

### 11.2 使用边界

- 默认不把完整开源 AXI 仓库复制进本项目。
- 项目关键模块应按当前 single-outstanding 架构独立设计，使代码规模和状态机与本教学核匹配。
- 若直接复用任何源码，必须固定 upstream commit/tag、保留原许可证和版权头，并放入清晰的 third-party 边界。
- 文档应区分“参考设计”“直接复用”和“本项目实现”，不能把开源模块包装后描述为完全自研。
- 开源实现不能替代本项目验证；它只能作为参考或独立对照。

## 第12章 验证方案

### 12.1 总体选择

0836 不在“只跑程序”和“重新搭一套完整 AXI UVM”之间二选一，而是采用两层验证：

```text
模块级：VCS/SystemVerilog transaction driver + scoreboard + SVA
系统级：现有 Verilator ASM/C self-check 程序回归
```

模块级验证负责证明 AXI/APB 协议和独立 backpressure；程序级验证负责证明 CPU、trap、interrupt、memory map、外设 ABI 和总线集成后的端到端行为。两者缺一不可。

本阶段不新建完整 AXI UVM 平台。0835 已经展示了 UVM agent、sequence、monitor、scoreboard、coverage 和 SVA 的方法；现在重新从零搭建五通道 UVM agent 会明显延长交付时间，而不会直接提高 SoC 集成速度。若后续需要协议级完整 UVM，可由 0837 单独承接。

### 12.2 模块级验证对象

至少独立验证：

| DUT | 主要检查 |
|---|---|
| `simple_bus_to_axi_lite` | read/write 转换、AW/W 任意先后、五通道 backpressure、response/error 映射、single outstanding |
| AXI-Lite router | 地址译码、W channel route state、B/R 返回目标、default DECERR、同拍 read/write admission |
| AXI-Lite DMEM slave | byte strobe、readback、B/R stall、越界 error |
| AXI-Lite-to-APB4 bridge | APB setup/access、PREADY wait、PSLVERR、AW/W 解耦、B/R backpressure |
| APB peripheral path | GPIO/UART/TIMER register access、非法 offset、side effect exactly once |

测试平台可以使用轻量 class/task driver、queue/reference model 和随机 delay，不要求为每个模块建立完整 UVM agent。若采用第三方 AXI-Lite/APB VIP，应保留项目自己的 scoreboard 和 SVA，避免验证结果完全依赖外部黑盒。

`axi_lite_to_apb` 的模块级 testbench 直接实例化 bridge，并在其下游 APB 端口连接可配置 slave model。该 model 负责驱动 `PREADY/PRDATA/PSLVERR`，因此可以合法注入 zero-wait、multi-cycle wait 和 error response，而无需穿透已经封装在 `data_subsystem` 内部的 APB 网络。SoC 集成级 peripheral path 继续连接正式外设并固定 `PREADY=1`。

### 12.3 SVA 重点

至少覆盖：

- 各 channel `VALID && !READY` 时 payload stable。
- B response 之前已经完成对应 AW 和 W handshake。
- R response 之前已经完成对应 AR handshake。
- response 不重复、不凭空产生。
- pending transaction 数不超过本项目限制。
- router 在 response 完成前保持 target route。
- APB `PENABLE` 只能出现在 setup 之后。
- APB wait 期间控制和 payload 保持稳定。
- 一笔 APB write side effect 最多发生一次。
- reset 后无有效 response 和 pending state。

SVA 应允许合法的任意 channel delay，不能把当前 testbench 的固定时序误写成协议要求。

### 12.4 模块级 testcase

最小 testcase matrix：

| 类别 | 场景 |
|---|---|
| write channel order | AW/W 同拍、AW 先、W 先 |
| write backpressure | AWREADY、WREADY、BVALID、BREADY 分别延迟和组合延迟 |
| read backpressure | ARREADY、RVALID、RREADY 分别延迟 |
| byte lane | `WSTRB=0001/0010/0100/1000/0011/1100/1111` |
| target | DMEM、GPIO0、UART0、TIMER0、ACCEL0 reserved、unmapped |
| response | OKAY、SLVERR、DECERR |
| APB | zero wait、multi-cycle PREADY wait、PSLVERR |
| reset | idle reset、transaction 中 reset |
| side effect | UART TX、GPIO W1C 等在 wait-state 下只发生一次 |

可以增加 constrained-random ready/valid delay，但 random test 不能替代上述确定性 corner case。

### 12.5 Verilator 程序级回归

现有 `sim/soc_asm` 和 `sim/soc_c` 继续作为端到端主线。AXI-Lite 接入后至少执行：

1. 全量 ASM/C zero-wait regression，证明总线替换没有改变软件可见行为。
2. 选取 DMEM load/store、trap 和 interrupt 代表性程序，在外部 DMEM AXI-Lite channel backpressure 配置下运行。
3. 在固定 `PREADY=1` 下运行 GPIO/UART/TIMER 端到端程序；APB 自身仍有 SETUP/ACCESS 的协议延迟，但程序级 harness 不额外注入 multi-cycle `PREADY`。
4. 增加至少一条总线专项程序，连续混合 DMEM 与 GPIO/UART/TIMER 访问，覆盖 byte/half/word、合法响应和 access fault。
5. 保留 commit/trap/data transaction 观察，失败时能够区分 CPU、adapter、router、AXI slave、APB bridge 和 peripheral 层。

APB multi-cycle `PREADY`、PSLVERR 和等待期间 payload/side-effect 行为由 `axi_lite_to_apb` 模块级 testbench 与 SVA 负责。若未来确实需要程序级随机 APB wait，应先增加清晰的 simulation wrapper 或外部 APB 边界，不通过层级 force，也不把测试专用 delay input 塞回正式 SoC RTL。

程序自检负责确认：

- CPU 真的能通过新 AXI/APB 链路运行裸机程序。
- DMEM read-after-write、stack 和 C runtime 正常。
- GPIO/UART/TIMER ABI 不变。
- MMIO side effect 不重复。
- unmapped/illegal offset 能进入正确 access fault。
- memory wait 期间 trap/interrupt/redirect 仍保持精确语义。

### 12.6 UVM 与 coverage 口径

v6.0 `data_subsystem` UVM 工作区继续作为 v7.0 历史资产保留，不改 filelist 去验证新 AXI RTL，也不与 AXI-Lite 版本混编。

0836 可以用 covergroup/SVA cover 记录以下基本覆盖：

- read/write。
- target。
- AW/W handshake order。
- channel delay 档位。
- OKAY/SLVERR/DECERR。
- WSTRB。
- APB wait/error。

coverage 用来确认关键场景确实发生，不把百分比本身作为本阶段唯一完成条件。完整 AXI-Lite UVM agent、protocol coverage 和更系统的 random traffic 保留给 0837，是否继续实施取决于求职时间和后续项目收益。

## 第13章 建议的 RTL 与验证资产边界

本章只定义职责分层，不规定最终文件名：

| 层次 | 资产 |
|---|---|
| common | AXI-Lite/APB 类型、宽度参数和地址常量 |
| adapter | internal simple bus 到 AXI-Lite master |
| fabric | 单 master AXI-Lite router/default error slave |
| memory | AXI-Lite DMEM slave 或外部 memory port adapter |
| bridge | AXI-Lite-to-APB4 |
| peripheral | APB mux 和 GPIO/UART/TIMER wrapper |
| SoC | 新 data subsystem 与 `rv32i_soc` 集成 |
| module verification | AXI/APB driver、monitor、scoreboard、SVA、确定性/random testcase |
| system verification | Verilator ASM/C 程序、外部 DMEM AXI-Lite delay model、固定响应 APB 外设链路、commit/trap/bus trace |
| documentation | 协议边界、开源来源、验证矩阵、已知限制和结果 |

开发期间可以让新 AXI data subsystem 与 v7.0 `data_subsystem` 并行存在，待模块验证和程序回归通过后再切换主线 SoC。v7.0 tag 和 `uvm/v6_0/data_subsystem/dut/rtl` 快照已经冻结，因此主线后续删除或重构旧 `data_subsystem` 不影响历史复现。

## 第14章 本阶段完成标准

0836 完成后，应能用一句话描述：

```text
RV32I core 保留稳定的 single-outstanding LSU request/response 接口；
SoC 数据侧通过自有 adapter 转换为标准 AXI4-Lite 五通道，
DMEM 使用 AXI-Lite slave，GPIO/UART/TIMER 通过 AXI-Lite-to-APB4 bridge 接入，
并在独立 channel backpressure、错误响应和程序级回归下保持精确访存与 trap/interrupt 语义。
```

具体完成标准：

| 标准 | 判断 |
|---|---|
| CPU 边界稳定 | core/mem_stage 不感知 AXI 五通道，internal simple bus 语义不变 |
| AXI-Lite 合规 | AW/W 独立、五通道 payload stable、B/R response matched |
| single outstanding 明确 | 系统不接受会覆盖 pending/route state 的第二笔 transaction |
| APB 合规 | setup/access/PREADY/PSLVERR 正确，等待期间 payload 稳定 |
| byte access 正确 | SB/SH/SW 通过 WSTRB/PSTRB 保持现有 lane 语义 |
| error 正确 | OKAY/SLVERR/DECERR 映射清楚，并进入正确 CPU access fault |
| side effect 正确 | wait/backpressure 下 MMIO write/read 副作用不重复 |
| 地址图兼容 | 现有 GPIO/UART/TIMER 软件和链接布局无需修改 |
| 模块验证通过 | adapter/router/DMEM slave/bridge/APB path 的关键 testcase 和 SVA 通过 |
| 程序回归通过 | Verilator ASM/C zero-wait 全量回归、代表性 DMEM AXI backpressure 回归和固定响应 APB 外设端到端回归通过 |
| 可综合边界清楚 | testbench RAM、随机 delay 和验证代码不进入主线综合层 |
| 开源归属清楚 | 参考或直接复用内容均有来源、版本和许可证记录 |
| 后续接口明确 | ACCEL0 direct AXI-Lite control slot 已预留，完整 AXI4/DMA/accelerator 本体不混入本阶段 |

达到这些标准后，0836 才算真正完成。后续可以按项目收益选择进入 0837 AXI-Lite UVM 深化，也可以直接基于已经稳定的 AXI-Lite/APB 控制面展开 accelerator 专题；两条方向都不应反向破坏本阶段已经冻结的 CPU simple bus 与标准总线边界。
