# 0836 AXI-Lite adapter、interconnect 与 APB 外设桥规划

> 文档编号：0836  
> 所属系列：083x RV32I 教学核后续完善阶段  
> 文档定位：定义在 v7.0 已完成 data-side simple request/response bus、MEM backpressure 和 UVM/SVA 验证收口后，如何引入 AXI4-Lite 与 APB4，并记录 0836 的实际实现与验证边界
> 当前状态：RTL 主线切换与 SoC 集成级定向验证已完成，最终 release tag 待阶段文档提交后确定
> 对应总规划：`0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`  
> 前置文档：`0804 RISC-V SoC、MMIO与外设互联.md`、`0829 综合、FPGA上板与SoC扩展方向.md`、`0834 可变延迟memory与MMIO、简化内部总线与backpressure规划.md`、`0835 wait-state验证收口、SVA与UVM入门demo规划.md`

本篇定义“第六阶段实现什么、接口边界是什么、验证到什么程度”，并在阶段完成后保留实际收口结论。它不是执行阶段的 `plan.md`，不写逐文件、逐信号的施工步骤，也不重复大段 AXI 基础原理。

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

本阶段已经完成“单 CPU master、single-outstanding、功能正确”的最小标准总线系统，不追求通用 AXI crossbar、峰值吞吐或完整协议覆盖。

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
| 新建完整 AXI UVM 平台 | 0836 以现有 SoC 程序回归完成主线功能集成，避免重复搭建大规模验证基础设施 |
| 全面 coverage closure | 当前记录未动态覆盖的协议 corner case，不以 coverage 百分比作为本阶段完成条件 |

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

IMEM/DMEM model 继续保持在 testbench 或 FPGA wrapper 一侧，不重新塞回 `rv32i_soc`。当前 testbench 分别使用 `simple_rom` 和 `axi_lite_ram`，主线 SoC 透出下游 DMEM AXI-Lite port，由不同环境连接：

| 环境 | DMEM AXI-Lite slave |
|---|---|
| 当前 Verilator testbench | 固定 ready 的可综合 `axi_lite_ram`，由 TB 负责加载 memory image |
| 后续协议验证 wrapper | 可配置 AW/W/AR/B/R backpressure 的 AXI-Lite slave model |
| FPGA wrapper | BRAM controller 或 AXI-Lite memory adapter |
| 后续系统集成 | 片上 SRAM、总线 bridge 或其它 AXI-Lite slave |

本阶段已经新增独立可复用的可综合 `axi_lite_ram`。该模块不依赖 `$readmemh`、mailbox 或随机延迟；当前 testbench 通过层级访问其 `mem` 数组加载程序数据镜像，FPGA 或其它系统集成环境可替换为自己的 memory 初始化方式。

`rv32i_soc` 已从旧离散 DMEM 端口切换为 downstream AXI-Lite port，`tb_rv32i_soc` 在同一实现节点完成端口迁移、`axi_lite_ram` 实例化和 ASM/C 仿真 filelist 更新。当前 RAM 不额外注入随机 backpressure；该能力保留给后续独立协议验证 wrapper。

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

当前 `axi_lite_ram` 支持：

- AW/W 独立接受。
- 4-bit `WSTRB` 逐 byte 更新。
- AR read。
- B/R backpressure。
- request 完成后产生并保持注册式 B/R response。
- 地址越界返回明确错误。

当前可综合 RAM 固定允许 request，不内置随机 READY 或 response delay。后续若开展协议级验证，可在独立 testbench slave model 或 simulation wrapper 中注入各 channel backpressure，不把验证专用配置混入 memory slave 的功能语义。

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

当前现有寄存器块固定 `PREADY=1`，SoC 程序回归已经验证 APB SETUP/ACCESS 和外设功能集成。bridge 对多周期 `PREADY=0` 的保持能力由 RTL 结构支持，但尚未通过独立可等待 APB slave model 动态验证，列为后续协议验证项。

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
- AXI master 侧延迟 `BREADY/RREADY` 时，增加 response channel 被接受前的等待周期；当前 CPU adapter 进入 response 状态后会立即拉高对应 READY，后续 slave/router 协议验证仍需覆盖这一合法 backpressure。
- MMIO 增加 APB `PREADY=0` 的 ACCESS 周期。
- 后续若加入仲裁、register slice、CDC 或更慢的真实 slave，还需增加对应等待。

因此，0836 删除旧 wrapper 后仍然具备比固定计数器更真实的可变延迟来源。后续若开展协议级验证，应分别控制各 channel，不能只把所有等待折叠成一个统一的 `resp_delay_cycles`。当前 SoC 回归使用固定 request readiness、注册式 response 和固定 `PREADY=1`，没有动态覆盖这些额外等待组合。

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

RTL 结构必须允许以下合法 backpressure；后续协议级验证应分别覆盖：

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

当前 0836 SoC 程序回归使用固定 readiness，只能证明现有 CPU 流量与固定 slave 组合的功能集成，不能据此声称已经动态证明上述五通道独立状态。该边界不阻塞本阶段收口，但必须保留为后续协议验证缺口。

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
| [cocotbext-axi](https://github.com/alexforencich/cocotbext-axi) | AXI、AXI-Lite 和 AXI-Stream master、slave、RAM simulation model | 可选 AXI-Lite 独立验证工具；APB 需另选 package/model |

### 11.2 使用边界

- 默认不把完整开源 AXI 仓库复制进本项目。
- 项目关键模块应按当前 single-outstanding 架构独立设计，使代码规模和状态机与本教学核匹配。
- 若直接复用任何源码，必须固定 upstream commit/tag、保留原许可证和版权头，并放入清晰的 third-party 边界。
- 文档应区分“参考设计”“直接复用”和“本项目实现”，不能把开源模块包装后描述为完全自研。
- 开源实现不能替代本项目验证；它只能作为参考或独立对照。
- 0836 实际 RTL 均为项目内独立实现，没有直接复制第三方 RTL；上述项目只用于协议、状态机和验证思路对照。

## 第12章 验证方案

### 12.1 实际验证选择与结论边界

0836 没有新增 AXI/APB 协议级 testbench、UVM 环境或 SVA 文件，而是继续使用现有 Verilator SoC testbench、mailbox 外部激励和 38 个 ASM/C 程序自检用例完成主线切换验证。该方案能够证明 CPU、adapter、router、AXI-Lite RAM、AXI-Lite-to-APB bridge、APB mux 和外设在当前固定响应组合下功能闭合，但不等价于 AXI4-Lite/APB4 完整协议合规验证。

本阶段可以确认读写与 byte strobe 数据语义、地址路由、错误传播、MEM backpressure、精确 trap/interrupt、外设 ABI 和副作用；不能声称已经动态覆盖 AW/W 任意先后、各 channel 长时间 backpressure、上游 B/R response stall 或多周期 `PREADY`。

### 12.2 旧 wait-state 用例迁移

- 删除 TB 中已经失效的 response-delay mailbox 地址、配置打包和 C helper，mailbox 只保留 PASS/FAIL、GPIO 输入控制和 UART RX 激励职责。
- 删除 0801、0802、0804、0805、0853、0856 中对旧 delay mailbox 的无效写入，避免测试无声通过却继续声称覆盖旧 wrapper 延迟。
- 保留原测试文件名和编号以维持回归入口稳定；测试头注释与说明改为当前实际覆盖的 AXI-Lite DMEM 固定多周期访问、固定 `PREADY` APB 外设、错误传播和混合路由语义。
- 没有把旧统一 `resp_delay` 映射到某个 AXI channel，也没有为验证重新向可综合 RTL 添加 delay 配置端口。

### 12.3 SoC 集成验证矩阵

| 验证面 | 主要既有用例 | 当前能够证明的行为 |
|---|---|---|
| AXI-Lite DMEM 数据语义 | `0104_load_store`、`0801_dmem_wait_basic`、`0802_dmem_wait_forwarding` | word/byte/halfword、`WSTRB` lane、外部 RAM 读写、load-use/forwarding 与 MEM backpressure |
| APB 外设与副作用 | `0602_uart_tx`、`0603_gpio_rw`、`0651/0652`、`0751`～`0754`、`0853_mmio_wait_basic` | GPIO/UART/TIMER 寄存器 ABI、W1C、读清、TX event exactly once 和固定 `PREADY` 端到端访问 |
| 总线错误传播 | `0604_mmio_access_fault`、`0804_mmio_wait_access_fault` | router 未映射地址产生 AXI `DECERR`，APB `PSLVERR` 转 AXI `SLVERR`，最终形成精确 load/store access fault |
| kill 与精确提交 | `0605_mmio_misaligned_priority`、`0606_wrong_path_mmio`、`0705/0706`、`0805_wait_interrupt_boundary` | misaligned 优先级、wrong-path 无副作用、CSR/MRET 同拍中断和 older DMEM 访问完成后再接受 interrupt |
| DMEM/MMIO 路由切换 | `0856_wait_mixed_random_smoke` | 同一程序在外部 AXI-Lite DMEM 与内部 APB GPIO/UART/TIMER 路径间交替访问且不死锁、不串响应 |

没有为 0836 新增测试程序。既有用例已经覆盖本次 SoC 集成所需的功能路径，commit/trap/data transaction 观察仍用于定位 CPU、adapter、router、AXI slave、APB bridge 和 peripheral 层的问题。

### 12.4 回归结果

- `sim/soc_asm/run_all.sh`：25 passed，0 failed。
- `sim/soc_c/run_all.sh`：13 passed，0 failed。
- `0757_gpio_periodic_irq` 在修正测试吞吐前提后记录 `B30 CNT=21 AVG=500`、`B31 CNT=6 AVG=2000` 和 `RATIO(B31/B30)=4 (expect 4)`，周期测量通过。
- 代表性日志确认 0804 的 6 次 APB 外设非法 offset trap、0805 的 older load/interrupt 边界和 0757 的周期测量均实际发生，不只依据脚本退出码判断。

### 12.5 明确保留的协议验证缺口

- 当前 `axi_lite_ram` 和 CPU adapter 的实际流量通常同拍给出 AW/W，尚未用独立 master/slave model 动态覆盖 AW/W 任意先后。
- 尚未注入 AWREADY/WREADY/ARREADY、BVALID/RVALID 的随机或长时间 backpressure，也未验证上游主动拉低 BREADY/RREADY 的组合。
- 正式 GPIO/UART/TIMER 路径固定 `PREADY=1`，`axi_lite_to_apb` 对多周期 `PREADY=0` 的保持能力仅由 RTL 结构实现，未在本阶段动态验证。
- 当前结论是 SoC 功能集成通过，不是 AXI4-Lite/APB4 完整协议 compliance 结论。

以上缺口不阻塞 0836 收口。后续若继续投入协议验证，可使用轻量 SystemVerilog/cocotb testbench、SVA 或新的版本化 UVM 工作区，至少覆盖 channel payload stable、AW/W 任意顺序、B/R response 保持、route state、APB SETUP/ACCESS 与多周期 `PREADY`。v6.0 `data_subsystem` UVM/SVA 工作区继续冻结，不混编新的 AXI/APB 主线 RTL；若使用 `cocotbext-axi`，其适用于 AXI-Lite 侧，APB 侧需单独选择 model/package。

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
| optional protocol verification | 后续可新增的 AXI/APB driver、monitor、scoreboard、SVA 和确定性/random testcase；0836 未创建 |
| system verification | 现有 Verilator ASM/C 程序、固定 readiness 的外部 AXI-Lite RAM、固定响应 APB 外设链路、commit/trap/bus trace |
| documentation | 协议边界、开源来源、实际验证矩阵、已知限制和结果 |

主线 SoC 已切换到新 AXI data subsystem，旧 simple bus data subsystem 不再并行保留在主线 RTL。v7.0 tag 和 `uvm/v6_0/data_subsystem/dut/rtl` 快照已经冻结，因此主线删除旧实现不影响历史复现。

## 第14章 本阶段完成标准

0836 完成后，应能用一句话描述：

```text
RV32I core 保留稳定的 single-outstanding LSU request/response 接口；
SoC 数据侧通过自有 adapter 转换为标准 AXI4-Lite 五通道，
DMEM 使用 AXI-Lite slave，GPIO/UART/TIMER 通过 AXI-Lite-to-APB4 bridge 接入，
并经 38 个程序自检用例验证当前固定响应组合下的精确访存与 trap/interrupt 语义。
```

具体完成标准：

| 标准 | 判断 |
|---|---|
| CPU 边界稳定 | core/mem_stage 不感知 AXI 五通道，internal simple bus 语义不变 |
| AXI-Lite 结构闭合 | AW/W 独立状态、五通道 payload 保持和 B/R response 匹配由 RTL 实现；完整动态 compliance 验证保留为后续项 |
| single outstanding 明确 | 系统不接受会覆盖 pending/route state 的第二笔 transaction |
| APB 结构闭合 | setup/access/PREADY/PSLVERR 由 RTL 实现，固定 `PREADY=1` 已集成验证，多周期等待保留为后续项 |
| byte access 正确 | SB/SH/SW 通过 WSTRB/PSTRB 保持现有 lane 语义 |
| error 正确 | OKAY/SLVERR/DECERR 映射清楚，并进入正确 CPU access fault |
| side effect 正确 | 当前固定 `PREADY=1` 下 MMIO write/read 副作用不重复 |
| 地址图兼容 | 现有 GPIO/UART/TIMER 软件和链接布局无需修改 |
| 验证结论清楚 | SoC 集成通过与协议 compliance 缺口分别记录，不用程序通过替代完整协议结论 |
| 程序回归通过 | Verilator ASM 25/25、C 13/13，覆盖 DMEM、APB 外设、错误、精确提交和混合路由 |
| 可综合边界清楚 | testbench RAM、随机 delay 和验证代码不进入主线综合层 |
| 开源归属清楚 | 参考或直接复用内容均有来源、版本和许可证记录 |
| 后续接口明确 | ACCEL0 direct AXI-Lite control slot 已预留，完整 AXI4/DMA/accelerator 本体不混入本阶段 |

当前实现已达到上述 0836 功能集成标准。后续可以按项目收益选择进入 0837 AXI-Lite 协议验证深化，也可以直接基于已经稳定的 AXI-Lite/APB 控制面展开 accelerator 专题；两条方向都不应反向破坏本阶段已经冻结的 CPU simple bus 与标准总线边界。
