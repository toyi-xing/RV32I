# 0834 可变延迟 memory 与 MMIO、简化内部总线与 backpressure 规划

> 文档编号：0834  
> 所属系列：083x RV32I 教学核后续完善阶段  
> 文档定位：规划当前五级流水线 SoC 在完成最小 M-mode CSR/trap、MMIO 外设和 machine interrupt 后，如何加入 data-side 可变延迟访问、简化内部总线和流水线 backpressure  
> 对应总规划：`0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`  
> 前置文档：`0802 RISC-V五级流水线与Hazard.md`、`0804 RISC-V SoC、MMIO与外设互联.md`、`0825 Hazard控制：forwarding、stall、flush与kill.md`、`0831 最小M-mode CSR与trap规划.md`、`0832 最小memory map与MMIO外设规划.md`、`0833 machine interrupt与timer规划.md`

本篇只规划“第四阶段做什么”。它不是执行阶段的 `plan.md`，因此不会写成逐文件逐信号的施工清单。

第四阶段的目标是：把当前固定一拍响应的 LSU 数据侧访问，升级为单 outstanding 的 request/response 模型。完成后，load/store/MMIO 可以等待若干周期才完成，MEM 阶段会在访问完成前阻塞流水线，response 可以携带 `rdata/error`，并且已有的 precise trap、machine interrupt、MMIO 副作用语义仍然保持精确。

本阶段的关键不是“给 memory 加几拍延迟”，而是把下面几件事说清楚：

- memory/MMIO 访问从组合固定响应变成一个事务。
- load/store 指令在事务完成前不能作为已提交指令继续前进。
- store/MMIO write/read 副作用不能因为 stall 或 retry 被重复触发。
- delayed response error 要自然变成 load/store access fault。
- younger branch redirect、trap、interrupt 和未完成 memory request 之间必须有确定优先级。
- 这一阶段只做项目内简化 data bus，不直接把 CPU 内部接口改成 AXI-Lite。

## 第1章 本步目标和非目标

### 1.1 当前已经完成的基础

进入本步之前，当前系统已经具备：

| 能力 | 当前状态 |
|---|---|
| 五级流水线主路径 | IF/ID/EX/MEM/WB、forwarding、load-use/CSR-use stall、branch/JAL/JALR redirect 已完成 |
| precise trap | 同步 exception、CSR illegal、`MRET`、trap redirect 和 younger kill 已完成 |
| machine interrupt | `mstatus/mie/mip`、`MTIP/MEIP`、CSR 写同拍 interrupt、`MRET` 同拍 interrupt 已完成 |
| MMIO 平台 | SoC wrapper、data subsystem、GPIO0、UART0、TIMER0 和 MMIO access fault 已完成 |
| 外设寄存器语义 | GPIO/UART/TIMER32 寄存器 ABI 已文档化，W1C、读副作用、unknown offset fault 已有口径 |
| 软件测试 | 已有 RV32I、hazard、trap/CSR、MMIO、timer/GPIO/UART interrupt directed tests |
| 当前短板 | core LSU 和 data subsystem 仍假设固定响应，没有 ready/valid 或 request/response |

因此，本阶段不是重新设计 MMIO，也不是重新设计 trap，而是在既有精确提交语义上加入：

```text
LSU request/response + MEM wait + pipeline backpressure + delayed error
```

### 1.2 本步目标

本步完成后，平台应具备：

| 能力 | 目标 |
|---|---|
| data-side request/response | LSU 数据侧从固定响应改为单 outstanding 的事务接口 |
| ready/valid 边界 | request 使用 valid/ready 表达是否被 data subsystem 接收 |
| delayed response | response 可以在请求接受后的后续周期返回 |
| MEM backpressure | MEM 指令等待访问完成时，EX/ID/IF 不能继续覆盖流水线状态 |
| load 完成语义 | load 的 rd 写回数据必须来自完成 response，不允许使用未返回数据 |
| store 完成语义 | store/MMIO write 必须等待写响应，且副作用最多发生一次 |
| delayed access fault | response error 转换为 load/store access fault，复用既有 trap 路径 |
| precise state | memory wait、response error、branch redirect、trap 和 interrupt 的优先级有确定定义 |
| wait-state 仿真 | testbench 或 memory/MMIO 模型可以插入 0～N 拍响应延迟 |
| 后续 AXI-Lite 边界 | 简化 data bus 语义稳定后，可在 0836 包装为 AXI-Lite |

### 1.3 本步非目标

本步不做：

| 暂不做 | 原因 |
|---|---|
| AXI-Lite | 放到 0836；本步先稳定 CPU 内部简化 data bus 和 backpressure |
| 完整 AXI4 | 当前单发射、单 outstanding、无 cache/无 DMA，不需要 burst、ID、多 outstanding |
| IMEM 可变延迟 | 第一版只处理 data side，避免同时改前端取指和 LSU |
| I-cache/D-cache | cache miss/refill 会引入更复杂 replay、line fill 和 memory attribute |
| write buffer/store buffer | 会改变 FENCE、MMIO ordering 和 store 可见性，当前不引入 |
| 多 outstanding | 会引入 tag、response 匹配、乱序/保序和异常回放问题 |
| 总线仲裁 | 当前只有 CPU data master；accelerator/DMA master 是后续专题 |
| accelerator 本体 | 0836 只预留 accelerator 控制窗口，计算加速器本体不属于本项目主线 |
| UVM 完整平台 | 0835 开始做 SVA 和 UVM 入门 demo，本步只定义应被验证的行为 |
| 性能优化 | 本步优先正确性和边界清晰，不追求吞吐、面积或频率最优 |

## 第2章 为什么需要可变延迟访问

### 2.1 固定响应模型的价值和局限

当前固定响应模型适合早期教学核：

```text
MEM 阶段给出 addr/we/be/wdata
data_subsystem 同拍给出 rdata/access_fault
下一拍指令进入 WB 或 trap
```

这个模型简单，便于先把 RV32I、CSR/trap、MMIO 和 interrupt 跑通。但它隐含了一个很强的假设：

```text
所有 memory 和 MMIO 都能在同一个组合周期内完成。
```

真实系统里这个假设通常不成立：

| 访问对象 | 为什么可能不是 1-cycle |
|---|---|
| SRAM/BRAM | 真实 SRAM/FPGA BRAM 常见同步读，数据下一拍或多拍返回 |
| UART/GPIO/timer | 外设寄存器可能经过译码、同步、握手或跨时钟域 |
| bus fabric | 地址译码、仲裁、slave 选择和 response 都可能插入等待 |
| access fault | 未映射地址或非法 offset 可能通过 response error 返回 |
| 后续 AXI-Lite | AXI-Lite 本身就是 valid/ready 握手协议，不保证固定响应 |

因此，第四阶段要移除“固定响应”这个系统假设，但不改变 RV32I 软件可见语义。

### 2.2 可变延迟访问带来的三个核心问题

可变延迟不是简单“多等几拍”。它会影响三个核心语义。

第一，load 数据什么时候可用：

```text
固定响应：MEM 同拍已有 rdata，下一拍 WB 写 rd
可变延迟：response 未回来前，rd 数据不存在
```

第二，store/MMIO 副作用什么时候发生：

```text
固定响应：store 在当前 MEM 拍完成
可变延迟：request 可能被保持多拍，若设计不当会重复写同一地址（同一条 store 被多次执行）
```

第三，错误什么时候被发现：

```text
固定响应：access_fault 同拍给 core
可变延迟：error 可能在若干拍后作为 response 返回， access_fault 的检测点从 MEM 阶段组合逻辑变成了一个跨多拍的异步事件。
```

如果这三点没有定义清楚，就会出现：

- load-use hazard 的 stall 拍数不够。
- store 在 memory wait 期间重复写入。
- UART TX/RX 或 GPIO IRQ pending 被重复触发/清除。
- delayed access fault 的 `mepc/mcause/mtval` 不精确。
- interrupt 在 older memory request 未完成时提前进入 handler。

### 2.3 为什么第一版只做 data side

本阶段建议先只做 LSU/data side，不做 IMEM 可变延迟。

原因如下：

| 原因 | 说明 |
|---|---|
| data side 有副作用 | store/MMIO write/read 副作用对精确提交更敏感 |
| data side 已有 access fault | delayed `error` 可以直接验证 trap 语义 |
| data side 已有外设 | GPIO/UART/TIMER32 能覆盖 MMIO 慢响应场景 |
| data side 是 AXI-Lite 前置 | 后续 AXI-Lite 主要先服务 MMIO/peripheral/control plane |
| 降低变量数量 | 同时改 IF 和 MEM 会让 PC hold、取指 valid、redirect flush 一起复杂化 |

从对比维度可以更直观地看到为什么 IMEM 更简单、data side 更难：

| 对比维度 | IMEM（取指） | data side（DMEM/MMIO） |
|---|---|---|
| 访问类型 | 只读 | 读 + 写 |
| 软件可见副作用 | 无 | store 写入、MMIO 读清/W1C、TX event |
| 精确异常约束 | 无（flush wrong-path 即可） | load/store access fault 必须精确 |
| 外设集成复杂度 | 无 | GPIO/UART/TIMER32 各寄存器语义需绑定 completion |
| response error 影响 | 直接丢弃、不影响异常精度 | delayed access fault 需 trap 精确 |
| AXI-Lite 前置需求 | 非必需 | control plane 必经之路 |
| 需要 hold 的范围 | PC + IF/ID | 全流水线 backpressure（EX/ID/IF + PC） |

因此，data side 可变延迟是更复杂且更高优先级的方向。IMEM 可变延迟可以在 data-side 边界稳定后再做。到那时需要额外讨论：

- PC request 是否需要 valid/ready。
- instruction response 回来时是否仍在正确路径。
- branch/trap redirect 是否要取消或丢弃旧取指 response。
- IF/ID valid 如何与 outstanding fetch 对齐。

这些问题和 data-side LSU 类似，但不应抢在本阶段第一版里混在一起。

### 2.4 为什么本步不直接接 AXI-Lite

AXI-Lite 是后续确定要做的方向，但本步不建议直接把 CPU LSU 改成 AXI-Lite 五通道。

原因是 AXI-Lite 至少包含：

```text
AW: write address channel
W : write data channel
B : write response channel
AR: read address channel
R : read data response channel
```

如果直接把这些通道接入 CPU，会同时引入：

- CPU MEM stall。
- request/response 状态机。
- read/write response 区分。
- address/data channel 配对。
- `WSTRB`、`BRESP/RRESP`。
- slave decode error。
- 外设寄存器副作用时机。

调试维度过多。更稳的路线是：

```text
0834: CPU 内部 simple data bus 语义稳定
0836: simple data bus <-> AXI-Lite adapter/interconnect
```

这样 CPU 内部只理解“一个 load/store 事务完成或出错”，AXI-Lite 的五通道复杂性留给 adapter 和 interconnect。

## 第3章 简化 data bus 语义

### 3.1 基本术语

本阶段需要先统一几个术语：

| 术语 | 含义 |
|---|---|
| request | CPU 发起一次 load/store/MMIO 访问 |
| request accepted | request 被 data subsystem 捕获，形成一个 outstanding transaction |
| outstanding | 已接受但尚未返回 response 的事务 |
| response | data subsystem 返回一次事务完成结果 |
| completion | CPU 看到 response 后，该 load/store 指令到达可提交边界 |
| error response | 事务失败，转换为 load/store access fault |
| 副作用 | store 写入、MMIO 写触发、读清 pending 等软件可见副作用 |

本项目第一版只支持：

```text
single outstanding, in-order completion
```

也就是说：

- 同一时刻最多只有一笔 data transaction 未完成。
- response 一定对应当前唯一 outstanding transaction。
- 不需要 transaction ID。
- 不需要 reorder buffer 或 replay queue。

### 3.2 request channel

建议的 request channel 语义如下：

```text
request:
  valid, ready, write, addr, wdata, be
```

| 字段 | 方向 | 含义 |
|---|---|---|
| `valid` | master -> slave | CPU 当前有一笔 data access request |
| `ready` | slave -> master | data subsystem 当前可以接受该 request |
| `write` | master -> slave | 1 表示 store/MMIO write，0 表示 load/MMIO read |
| `addr` | master -> slave | 访问地址 |
| `wdata` | master -> slave | store 写数据，已按 byte lane 对齐 |
| `be` | master -> slave | byte enable；load/store 宽度和低地址对齐后的字节选择 |

request 被接受的条件是：

```text
valid && ready
```

在 `valid=1` 但 `ready=0` 时，request payload 必须保持稳定：

```text
addr/write/wdata/be 不允许变化
```

这条规则是后续包装 AXI-Lite 的基础，也是避免“同一条 store 因 ready 拉低而变成多次不同访问”的基础。

### 3.3 response channel

建议的 response channel 语义如下：

```text
response:
  valid, rdata, error
```

| 字段 | 方向 | 含义 |
|---|---|---|
| `valid` | slave -> master | 当前 outstanding transaction 完成 |
| `rdata` | slave -> master | read 成功时返回数据；write 或 error 时无软件意义 |
| `error` | slave -> master | 1 表示该 transaction 失败，应转换为 access fault |

第一版可以不引入 `resp_ready`。原因是 CPU 在等待 response 时会阻塞 MEM 阶段，天然总是 ready 接收唯一 response。

若后续进入 AXI-Lite 或更复杂总线，`resp_ready` 可以由 adapter 内部处理；CPU 内部仍可保持“等待 response valid 即完成”的简单模型。

### 3.4 事务生命周期

一次 data access 的生命周期可以抽象为：

```text
IDLE
  |
  | CPU 在 MEM 阶段产生 request
  v
REQ_WAIT
  |
  | valid && ready
  v
OUTSTANDING
  |
  | response.valid
  v
COMPLETE_OK / COMPLETE_ERROR
```

读事务：

```text
request accepted
等待 response
若 response.error = 0：使用 response.rdata 生成 load_data
若 response.error = 1：产生 load access fault
```

写事务：

```text
request accepted
等待 response
若 response.error = 0：store/MMIO write 成功完成
若 response.error = 1：产生 store access fault
```

对 CPU 来说，load/store 在 response 返回前都不能被视为已经完成。

### 3.5 read 语义

load/MMIO read 的软件可见语义是：

```text
read response OK 后，读数据才有效。
```

这意味着：

- response 未返回前，rd 不能写回。
- response 未返回前，依赖该 rd 的年轻指令不能继续进入会消费该值的位置。
- 若 response error，不能写 rd，必须进入 load access fault。

对普通 DMEM read 来说，`rdata` 是 memory word。

对 MMIO read 来说，`rdata` 是寄存器当前软件可见值，并且读副作用必须与本次 read completion 绑定。

例如：

| 外设语义 | 可变延迟下的要求 |
|---|---|
| 读状态寄存器 | response OK 返回时的状态值 |
| 读清 pending | 一次成功读最多清一次 |
| 读未知 offset | response error，不产生读副作用 |

### 3.6 write 语义

store/MMIO write 的软件可见语义是：

```text
write response OK 后，该 store 被认为完成。
```

本项目第一版建议采用更严格的教学约束：

```text
error response 不产生写副作用；
successful write 的副作用与该事务绑定，最多发生一次。
```

这条约束比某些真实总线/IP 更保守，但更适合教学核 precise trap：

- 如果 unknown offset 返回 error，不应同时改外设寄存器。
- 如果 store access fault 进入 handler，软件不应看到该失败 store 已经部分生效。
- 如果 request 因 `ready=0` 被保持多拍，不应重复写入。

对普通 DMEM store：

```text
response OK 表示 byte enable 选择的字节已经写入。
```

对 MMIO write：

```text
response OK 表示寄存器写、W1C、TX event 等副作用已经按寄存器语义完成。
```

从软件可见语义看，写副作用在 response OK 时才算完成。RTL 内部可以在 request accepted 后进入外设状态机，但必须保证 error transaction 没有成功副作用，并且同一事务不会因为等待 response 而重复生效。

### 3.7 error response 语义

response `error=1` 是阶段2固定响应 `access_fault` 的自然迁移。

来源可以包括：

| error 来源 | 转换成 CPU exception |
|---|---|
| 未映射地址窗口 | load/store access fault |
| 已映射外设的 unknown offset | load/store access fault |
| 外设拒绝非法访问类型 | load/store access fault |
| 后续 bus decoder error | load/store access fault |

`mtval` 应保存 faulting address。

`mcause` 根据原指令类型区分：

| 指令类型 | cause |
|---|---|
| load/MMIO read | load access fault |
| store/MMIO write | store access fault |

若一个 load/store 在发 request 前已经有更早发现的 exception，例如 illegal instruction 或地址不对齐，则不应再发起 bus request。

### 3.8 地址对齐和 byte enable

当前 `mem_stage` 已经在 MEM 阶段检测 load/store misaligned，并在不对齐时屏蔽 LSU 访问。

这个原则在可变延迟阶段保持不变：

```text
misaligned 是发 request 前即可确定的同步 exception；
misaligned 指令不发 request；
misaligned store 不产生任何 memory/MMIO 副作用。
```

`be` 仍表示实际参与访问的 byte lane：

| 指令 | `be` 语义 |
|---|---|
| `LB/LBU/SB` | 只选中一个 byte lane |
| `LH/LHU/SH` | 选中连续两个 byte lane，且地址必须 halfword 对齐 |
| `LW/SW` | 选中四个 byte lane，且地址必须 word 对齐 |

第一版 simple data bus 不必额外携带 `size` 字段；`be` 和 `addr[1:0]` 已足够让后端判断字节选择。若后续 AXI-Lite adapter 需要，也可以由 `be` 直接映射到 `WSTRB`。

## 第4章 流水线 backpressure 语义

### 4.1 MEM 阶段成为 data transaction owner

在固定响应模型中，MEM 阶段只是组合生成 LSU 访问控制，并立刻使用返回值。

在可变延迟模型中，MEM 阶段需要成为 data transaction owner：

```text
一条 load/store 到达 MEM；
MEM 负责发起 request；
MEM 持有该指令直到 response 返回；
response 返回后再决定普通完成或进入 trap。
```

因此，MEM 阶段不再只是“组合逻辑访问 memory”，而是“等待一个外部事务完成的提交边界”。

### 4.2 MEM 指令状态

对 MEM 阶段的一条指令，可以抽象为下面几类状态：

| 状态 | 含义 |
|---|---|
| 非访存指令 | ALU/CSR/MRET/branch 等，不需要 data request |
| 访存但不应发 request | 前级已有 exception，或本级检测到 misaligned |
| request 等待接受 | request valid 已拉高，但 data subsystem 未 ready |
| request 已接受 | 有 outstanding transaction，等待 response |
| response OK | load/store/MMIO 成功完成 |
| response error | load/store/MMIO 失败，产生 access fault |

只有到达下面两种情况，MEM 指令才可以离开 MEM 边界：

```text
非访存指令或不需要 data transaction 的指令；
访存指令收到 response OK/error。
```

### 4.3 backpressure 的传播方向

当 MEM 阶段因为 data transaction 未完成而等待时，流水线必须向前级施加 backpressure：

```text
MEM busy
  -> EX/MEM 保持当前 MEM 指令
  -> ID/EX 保持或阻止年轻指令覆盖
  -> IF/ID 保持
  -> PC 保持
```

直观地说，older memory instruction 卡在 MEM 时，younger instruction 不能越过它，也不能继续产生新的控制流或副作用。

这和 load-use stall 不同：

| stall 类型 | 作用 |
|---|---|
| load-use/CSR-use stall | 只是在 ID/EX 插入 bubble，让 producer 继续前进 |
| memory wait backpressure | producer 已经到 MEM，但尚未完成，整个前端和 EX 都要保持 |

### 4.4 hold、bubble、flush、kill 的区别

当前流水线已经有 `stall/flush/kill/bubble` 口径。可变延迟阶段需要继续区分它们：

| 控制动作 | 语义 |
|---|---|
| hold/stall | 当前寄存器保持原值，不前进也不清空 |
| bubble | 插入一个 invalid 空槽，常用于 load-use 让 producer 前进 |
| flush | 普通 EX redirect 清除 younger wrong-path 指令 |
| kill | MEM 边界 trap/MRET/interrupt 清除 younger 指令或终止当前 MEM 指令普通生命周期 |

memory wait 使用的是 hold/stall 语义，不是 bubble。

原因是 MEM 当前指令不能前进；如果插入 bubble，会丢掉这条尚未完成的 load/store。

### 4.5 load-use stall 在可变延迟下如何扩展

固定响应时，load-use 通常只需要插入一个 bubble：

```text
load 在 ID/EX
consumer 在 IF/ID
插入 bubble 一拍
load 进入 MEM，下一拍数据可前递/写回
```

可变延迟后，load 数据不一定下一拍可用。因此 load-use 语义应自然扩展为：

```text
load 进入 MEM 后，如果 response 未返回；
memory wait backpressure 会继续冻结 consumer；
直到 load response OK，consumer 才能继续前进。
```

也就是说，load-use 检测仍负责“阻止 consumer 过早进入 EX”，而 memory wait 负责“load 尚未完成期间继续保持流水线”。

不要用固定数量 bubble 猜测 memory latency。latency 是外部响应决定的。

### 4.6 younger branch redirect 与 memory wait

如果 older memory instruction 正在 MEM 等 response，EX 阶段可能保存着一条 younger branch/JAL/JALR。

这时不能让 younger redirect 抢先改变 PC：

```text
older memory request 尚未完成；
younger redirect 不能越过 older instruction 生效。
```

否则如果 older memory transaction 最终返回 error，硬件已经沿 younger redirect 改了前端，精确异常和 commit 边界会变得混乱。

因此原则是：

| 场景 | 处理原则 |
|---|---|
| MEM 仍在等待 response | younger EX redirect 被 backpressure 抑制，前端保持 |
| MEM response error | older access fault trap 优先，kill younger redirect |
| MEM response OK 且无 trap/interrupt | younger EX redirect 可以在该边界后按普通 control hazard 生效 |
| MEM response OK 且同拍接受 interrupt | interrupt kill younger 指令，younger redirect 不生效 |

这一条是 0834 的关键控制语义之一。

### 4.7 wrong-path request 不允许发出

wrong-path 指令不能产生 memory/MMIO 副作用。

在固定响应阶段，这主要靠 valid/kill 门控 `lsu_re/lsu_we`。可变延迟阶段仍应保持：

```text
只有有效且未被 kill 的 MEM 指令才能发起 request。
```

如果一条 younger store 在 older trap/interrupt 之后被 kill，它不应进入 outstanding 状态。

如果一条 request 已经被接受，则它对应的一定是当时处在 MEM 提交边界的 older 指令，而不是 wrong-path 指令。

## 第5章 precise trap、interrupt 和 memory wait

### 5.1 发 request 前的同步 exception

有些 exception 在发 request 前就能确定：

| exception | 是否发 request |
|---|---|
| 前级已经发现 illegal/ECALL/EBREAK 等 | 不发 |
| load/store address misaligned | 不发 |
| CSR illegal | 不发 data request |

这些 exception 不依赖 data bus response，仍可按既有 precise trap 路径进入 handler。

这里的原则是：

```text
一条已经带 exception 的指令，不再产生新的 data 副作用。
```

### 5.2 delayed access fault

访问错误在本阶段分为两类：

| 类型 | 发现时机 |
|---|---|
| misaligned | request 前，本地同步发现 |
| access fault | response error 返回时发现 |

response error 到来时，当前 MEM 指令仍被 hold 在 MEM 边界，因此可以生成精确 trap：

```text
trap_pc   = 当前 MEM 指令 PC
mcause    = load/store access fault
mtval     = faulting address
kill      = younger instruction
WB        = 不写 rd
副作用   = error transaction 不产生成功副作用
```

这样 delayed access fault 与固定响应 access fault 的软件可见结果一致，只是发生周期更晚。

### 5.3 response error 与 interrupt 的优先级

如果 memory response error 和 interrupt pending 同时出现，应按同步 exception 优先：

```text
response error -> load/store access fault
interrupt pending 保持，handler 处理完 exception 后再由软件/硬件状态决定是否进入 interrupt
```

原因是 response error 属于当前 older memory instruction 的同步异常结果；interrupt 是异步事件，不能抢在当前指令异常之前。

### 5.4 memory wait 期间的 interrupt

interrupt pending 可以在 MEM 等待 memory response 期间变成 1。

但硬件不应在 outstanding transaction 未完成时立刻接受 interrupt。否则会出现：

- 当前 load/store 尚未知道成功还是失败。
- store/MMIO write 尚未完成，软件现场不精确。
- interrupt `mepc` 很难定义为哪条未提交指令。

因此本阶段定义：

```text
interrupt pending 可以记录在 mip；
core 只能在当前 MEM 指令到达 completion 边界时接受 interrupt。
```

具体情况：

| 场景 | 处理 |
|---|---|
| memory wait 中 pending interrupt | 不接受，继续等待 response |
| response error 同拍 pending interrupt | access fault exception 优先 |
| response OK 同拍 pending interrupt | 当前 load/store 完成后，可按既有 interrupt 规则在同一精确边界接受 interrupt |
| 非访存指令到 MEM 且 pending interrupt | 按 0833 已定义的普通 interrupt 规则处理 |

这保持了 interrupt “发生在指令边界”的口径。

### 5.5 CSR 写同拍 interrupt 与 memory wait

0833 已经定义：

```text
CSR 写先提交；
用 CSR 写提交后的视图判断是否同拍接受 interrupt。
```

0834 不改变这条规则。

memory wait 对 CSR 写同拍 interrupt 的影响只有一个：

```text
若 CSR 写前面有 older memory instruction 尚未完成，CSR 写作为 younger instruction 被 backpressure 保持；
直到 older memory 完成后，CSR 写才会到达 MEM/commit 边界。
```

也就是说，memory wait 不改变 CSR 写和 interrupt 的相对语义，只可能延迟 younger CSR 指令到达提交边界的时间。

### 5.6 MRET 同拍 interrupt 与 memory wait

0833 已经定义：

```text
MRET 先恢复 mstatus；
若恢复后允许 interrupt 且 pending/enable 有效，则同拍进入 interrupt handler；
interrupt mepc 使用 MRET 原本要返回的 mepc。
```

0834 也不改变这条规则。

若 MRET 前面有 older memory transaction 未完成，MRET 会被 backpressure 保持在年轻阶段，不能越过 older memory instruction。

### 5.7 trap/MRET/interrupt 与 outstanding request

一个已接受的 outstanding request 不能被 younger flush/redirect 随意取消。

第一版可采用保守规则：

```text
outstanding request 必须等待 response；
response 返回后再决定普通完成或 trap；
在此之前，不接受 younger redirect，不接受 interrupt entry。
```

reset 是例外。复位会重新初始化整个系统，outstanding transaction 的仿真状态也应被清空。

### 5.8 commit trace 口径

可变延迟后，commit trace 不应记录“request 发出”的时刻作为 load/store 提交。

建议概念上区分：

| 事件 | 含义 |
|---|---|
| request accepted | data subsystem 接收了事务 |
| response OK | load/store 成功完成，可进入提交路径 |
| response error | load/store 产生 access fault trap |
| commit | 指令完成架构提交 |

对软件和 directed test 来说，真正关心的是 commit/trap 事件，而不是 request 被接收的周期。

## 第6章 MMIO 和外设副作用语义

### 6.1 外设寄存器 ABI 不变

0834 不改变 GPIO/UART/TIMER32 的寄存器 ABI。

软件仍然通过原地址图和原寄存器定义访问外设：

```text
GPIO0_BASE
TIMER0_BASE
UART0_BASE
```

变化只在硬件时序层面：

```text
一次 MMIO read/write 可能需要等待 response；
软件可见寄存器语义不变。
```

### 6.2 unknown offset 变成 response error

当前三个外设的 `access_fault_o` 仅检测未知 offset。

在可变延迟阶段，这个语义迁移为：

```text
访问已实现外设窗口，但 offset 未定义；
外设或 data subsystem 返回 response.error = 1；
CPU 产生 load/store access fault。
```

未知 offset 不应产生任何寄存器写、副作用或 pending 清除。

### 6.3 W1C 写副作用

GPIO/UART 等 pending/status 类寄存器可能有 W1C 语义。

可变延迟下，W1C 必须满足：

```text
一次成功 write transaction 最多清一次；
error response 不清；
valid 保持多拍但未 handshake 时不清；
request accepted 后等待 response 期间不重复清。
```

这条规则防止 CPU 因为 `ready=0` 或 response 延迟而反复写同一个 W1C mask。

### 6.4 读副作用

某些寄存器可能受读副作用影响，例如 UART RX 数据读出后清 RX pending。

可变延迟下，读副作用应与成功 read completion 绑定：

```text
read response OK 返回对应数据；
同一个 read transaction 最多触发一次读副作用；
error response 不触发读副作用。
```

如果 request accepted 与 response OK 分离，外设需要明确内部状态采样点：

| 策略 | 特点 |
|---|---|
| request accepted 时采样读数据，response 时返回 | 请求视角稳定，等待期间外设新事件不影响本次读值 |
| response 生成时采样读数据 | 更接近“完成时读”，但等待期间状态变化会影响返回值 |

第一版建议选择一种并在外设手册中说明。对于教学核，通常“request accepted 时采样，response OK 时提交读副作用”更容易验证：同一事务的读值固定，副作用仍只发生一次。

### 6.5 UART TX event

当前 UART 是简化模型，不是真实串口收发器。

在可变延迟下，写 TX DATA 的 `tx_valid` 事件必须与成功 write transaction 绑定：

```text
一次成功写 TX DATA -> 一个 TX event；
等待期间不重复产生 TX event；
error response 不产生 TX event。
```

这样 testbench 看到的 UART 输出仍然和软件写寄存器次数一一对应。

### 6.6 TIMER32 计数与 bus wait

TIMER32 的 `mtime` 计数不应因为 CPU 访问等待而暂停，除非软件正在写对应计数寄存器且外设规格明确规定写同拍行为。

也就是说：

```text
bus wait 只影响 CPU 访问完成时间；
timer 自身仍按 clk_i 或配置 tick 推进。
```

因此，加入 memory wait 后，软件用 TIMER32 测量代码时间时会自然包含 stall 周期。这是合理的。

### 6.7 GPIO 输入同步与 bus wait

GPIO 输入同步器和中断触发逻辑仍按外设时钟运行。

CPU 对 GPIO 寄存器的慢 read/write 不应阻塞 GPIO 输入同步本身。

这意味着：

- GPIO 输入可以在 CPU 等待其它 memory response 时继续变化。
- GPIO IRQ pending 可以在 CPU stall 期间置位。
- core 只有在精确提交边界才接受由 GPIO 汇总成的 MEIP。

## 第7章 控制优先级规划

### 7.1 需要新增的控制关系

0833 之前，主要控制关系是：

```text
trap/MRET/interrupt > EX redirect > load-use/CSR-use stall
```

0834 加入 memory wait 后，要多考虑：

```text
MEM outstanding transaction
request accepted / response OK / response error
younger EX redirect during MEM wait
interrupt pending during MEM wait
```

因此，控制优先级不能只看“当前有没有 redirect”，还要看 MEM 是否已经到达可完成边界。

### 7.2 推荐优先级口径

概念上可以采用下面的优先级：

```text
reset
> MEM completion 上的同步 exception / delayed access fault
> MEM completion 上的 MRET+interrupt / CSR写+interrupt / interrupt
> MEM completion 上的 MRET
> MEM response OK 后允许的 younger EX redirect
> MEM wait backpressure
> 普通 EX redirect
> load-use/CSR-use stall
> normal advance
```

这不是逐信号实现顺序，而是语义约束。

关键点是：

- delayed access fault 是当前 older 指令的同步异常，优先于 interrupt 和 younger redirect。
- memory wait 期间，younger redirect 不能越过 older memory instruction。
- memory response OK 后，如果没有 trap/interrupt，younger redirect 才能按普通控制流生效。
- load-use/CSR-use 是局部 data hazard，不能覆盖全流水线 memory wait。

### 7.3 response OK 同拍的复杂情况

如果某拍 memory response OK，同时 EX 阶段保存的 younger branch 也满足 redirect 条件，需要区分：

| 同拍事件 | 语义 |
|---|---|
| response OK + no interrupt + younger redirect | older memory 指令完成，younger redirect 可以生效 |
| response OK + interrupt accepted | interrupt 是 MEM 边界事件，kill younger，younger redirect 不生效 |
| response error + younger redirect | access fault exception 优先，younger redirect 不生效 |

这样可以同时保持：

- older instruction 精确完成。
- younger branch 不越过 older fault。
- interrupt 仍然在定义好的提交边界接受。

### 7.4 memory wait 和 pipeline register 保持

memory wait 时，流水线寄存器应保持对齐。

概念上需要保证：

```text
EX/MEM 中的 MEM 指令不丢失；
ID/EX 中的 younger 指令不重复进入 EX/MEM；
IF/ID 中的指令不被新取指覆盖；
PC 不继续前进。
```

如果只 stall PC/IF/ID，而 EX/MEM 继续前进，就会丢失 outstanding transaction 对应的指令。

如果只 stall MEM，而 EX 继续产生新结果，就会让 younger instruction 覆盖或越过 older memory instruction。

### 7.5 kill 与 outstanding transaction

`kill` 用于 MEM 边界 trap/MRET/interrupt 清理 younger 指令。

对 outstanding transaction，应遵守：

```text
kill 不取消当前已经 accepted 的 older memory transaction；
当前 memory transaction 等 response 后再决定是否产生 trap 或完成。
```

被 kill 的是更年轻的 IF/ID、ID/EX、EX/MEM 路径，而不是已经作为 MEM 指令发出的当前 transaction。

如果后续支持可取消 transaction，则需要额外的 cancel/flush 协议和 slave 侧规则。0834 第一版不做。

## 第8章 软件可见行为

### 8.1 软件 ABI 不变

0834 不改变：

- 指令集。
- CSR 地址和语义。
- MMIO 地址图。
- GPIO/UART/TIMER32 寄存器 ABI。
- trap handler 的基本写法。
- `platform.h` 的寄存器常量。

软件仍然执行普通 load/store 访问 memory/MMIO。不同的是硬件可能让某条 load/store 多等待几拍。

### 8.2 程序不应依赖 MMIO 固定周期

加入 wait-state 后，软件不应假设：

```text
写一个 MMIO 寄存器一定下一拍完成；
读一个 MMIO 寄存器一定固定 N 拍后返回；
timer 周期与指令条数严格一一对应。
```

软件可以依赖的是：

```text
load/store 指令完成后，软件可见结果已经符合寄存器语义；
trap/interrupt handler 看到的是精确状态；
MMIO 副作用不会重复发生。
```

### 8.3 timer 测量会包含 stall

如果 TIMER32 按 `clk_i` 计数，那么 memory wait 增加的周期会被 timer 计入。

这不是 bug，而是硬件真实行为：

```text
程序执行时间 = 指令执行周期 + memory/MMIO wait 周期
```

因此，后续测试如果用 timer 测量周期，应把 wait-state 作为可变因素，而不是仍然期待固定指令周期。

### 8.4 FENCE 暂时仍可保持 NOP

当前核是：

- 单 hart。
- 单发射顺序流水线。
- 单 outstanding data transaction。
- 无 cache。
- 无 write buffer/store buffer。
- MMIO write 等 response 后才完成。

在这个约束下，普通程序顺序已经足够强，`FENCE` 仍可暂按 NOP 处理。

但这条结论依赖当前边界。若后续加入 write buffer、cache、DMA、多个 master 或可并发 outstanding，`FENCE` 就需要重新定义。

## 第9章 测试和验证关注点

### 9.1 directed test 方向

0834 完成后，应增加或扩展 directed test 覆盖：

| 场景 | 关注点 |
|---|---|
| 慢 load 后紧跟 RAW consumer | consumer 等到 load response 后再使用数据 |
| 慢 store | store 不重复写，完成后 memory 值正确 |
| 慢 MMIO write | UART TX/GPIO/TIMER write 副作用最多一次 |
| 慢 MMIO read | 读数据稳定，读副作用最多一次 |
| delayed load access fault | `mcause/mepc/mtval` 精确 |
| delayed store access fault | 失败 store 不产生成功副作用 |
| memory wait 期间 interrupt pending | response 完成前不接受；完成边界按优先级接受 |
| memory wait 期间 younger branch | branch redirect 不越过 older memory instruction |
| 随机 wait-state regression | 现有 RV32I/trap/MMIO/interrupt tests 仍 PASS |

这些测试属于阶段实现后的验证方向，不是本文的执行步骤。

### 9.2 SVA 方向

0835 会正式做 SVA 和 UVM 入门 demo，但 0834 需要提前明确哪些性质值得断言：

| 性质 | 说明 |
|---|---|
| single outstanding | request accepted 后 response 前不再接受第二笔 |
| payload stable | `valid=1 && ready=0` 时 request payload 保持 |
| response matched | 每个 response 必须对应一个 outstanding transaction |
| no duplicate side effect | 一笔 store/MMIO write 最多产生一次副作用 |
| stall hold | memory wait 期间关键 pipeline register 保持 |
| no wrong-path request | invalid/kill/wrong-path 指令不发起 request |
| error no writeback | error response 不写 rd，不产生成功写副作用 |
| interrupt boundary | outstanding 未完成时不接受 interrupt |

这些性质是后续 UVM 和 assertion 的桥梁。

### 9.3 覆盖方向

后续 coverage 可以围绕：

- read/write。
- DMEM/GPIO/UART/TIMER32/unknown address。
- response delay = 0、1、多拍。
- OK/error response。
- byte/half/word 访问。
- wait 期间 interrupt pending。
- wait 期间 younger redirect。
- W1C 和读副作用寄存器。

本阶段不要求立即建立完整 coverage 模型，但规划时要避免接口语义让这些覆盖点不可观察。

## 第10章 预计影响的工程对象

### 10.1 RTL 影响范围

本阶段预计会影响以下 RTL 概念边界：

| 对象 | 影响 |
|---|---|
| core LSU 侧接口 | 从固定 `rdata/access_fault` 过渡到 request/response |
| MEM 阶段 | 从组合访存变成能等待 transaction completion 的提交边界 |
| hazard/control | 新增 memory wait backpressure，与 load-use、redirect、trap/interrupt 协调 |
| pipeline register 控制 | hold/bubble/flush/kill 的优先级需要覆盖 memory wait |
| data subsystem | 从固定响应地址译码层变成 simple data bus responder |
| simple RAM/MMIO 外设 | 支持可配置 wait-state，并把 unknown offset 转为 response error |
| testbench 观察 | 需要区分 request accepted、response、commit/trap |

这只是影响范围说明，不是逐文件修改清单。

### 10.2 软件影响范围

软件 ABI 理论上不需要变化。

可能需要调整的是测试思路：

| 对象 | 影响 |
|---|---|
| asm/C directed test | 不能假设 MMIO 固定周期 |
| timer 相关测试 | 周期测量要考虑 wait-state |
| trap 测试 | delayed access fault 仍检查相同 cause/tval/mepc |
| interrupt 测试 | pending 到接受之间可能因 memory wait 延迟 |

`platform.h` 和外设寄存器手册无需因为 0834 改变寄存器 ABI。

### 10.3 文档影响范围

0834 完成后，文档需要更新的方向包括：

- README 当前特性中说明 data-side 支持 wait-state/backpressure。
- `rtl/periph/readme.md` 若外设读副作用采样点有明确变化，需要补充。
- `sw/asm/readme.md`、`sw/c/readme.md` 可补充 wait-state directed test 分类。
- 后续 `0835` 规划应基于本阶段稳定接口写 SVA/UVM demo。

## 第11章 和后续阶段的关系

### 11.1 和 0835 验证收口的关系

0835 会把本阶段新增机制转化为验证资产：

- wait-state directed tests。
- SVA。
- simple-bus/peripheral UVM demo。
- scoreboard 和 coverage 的第一版组织。

因此 0834 的接口语义必须足够清楚。否则 0835 会变成“验证一个不断变动的设计”，UVM 环境也会频繁重构。

### 11.2 和 0836 AXI-Lite 的关系

0836 不应推翻 0834 的 CPU 内部接口，而应包装它：

```text
core internal simple data bus
  -> simple_bus_to_axi_lite
  -> AXI-Lite interconnect/decoder
  -> memory/peripheral slaves
```

0834 的单 outstanding、request/response、error、byte enable 语义可以自然映射到 AXI-Lite：

| simple data bus | AXI-Lite 对应 |
|---|---|
| read request | `ARVALID/ARREADY` |
| read response | `RVALID/RDATA/RRESP` |
| write request | `AWVALID/AWREADY` + `WVALID/WREADY` |
| write response | `BVALID/BRESP` |
| `be` | `WSTRB` |
| `error` | `SLVERR/DECERR` |

第一版不需要让 CPU 直接理解 AXI-Lite 的五个通道。

### 11.3 和 accelerator/NPU 专题的关系

0834 本身不做 accelerator。

但它是后续 accelerator 控制面需要的基础之一：

- CPU 能等待慢响应寄存器。
- CPU 能处理 accelerator 控制寄存器的 access fault。
- CPU 能在 accelerator interrupt 到来时保持精确提交。
- 后续 AXI-Lite control window 可以复用本阶段 data bus completion 语义。

按照 0830 总规划，0836 完成 AXI-Lite 控制窗口定义后，就可以提醒并单独展开 accelerator/NPU 的选择与设计。

### 11.4 和 cache/完整 AXI4 的关系

0834 不是 cache 阶段，也不是完整 AXI4 阶段。

但它会建立几个重要前提：

- pipeline 能被 memory 系统 backpressure。
- memory response error 能精确进入 trap。
- MMIO 副作用不会因等待或 retry 被重复触发。
- 软件不依赖固定 memory latency。

这些能力都是后续 cache miss、AXI4 burst、DMA 或多 master interconnect 的基础。

如果未来进入 cache/完整 AXI4，需要重新讨论：

- 多 outstanding request。
- response ID 匹配。
- load/store replay。
- store buffer 和 FENCE。
- device memory 与 cacheable memory 属性。
- DMA 与 CPU 一致性。

这些都不属于 0834 第一版。

## 第12章 本阶段完成标准

本阶段完成后，应能用一句话描述：

```text
当前 RV32I SoC 的 LSU 数据侧已经不依赖固定一拍响应；
load/store/MMIO 通过单 outstanding request/response 完成；
MEM wait 能正确 backpressure 流水线；
delayed error、trap、interrupt 和 MMIO 副作用仍保持精确语义。
```

更具体地说，应满足：

| 标准 | 判断 |
|---|---|
| 功能正确 | 现有 directed regression 在 0 wait-state 下行为不退化 |
| 可变延迟正确 | DMEM/MMIO 插入 wait-state 后 directed tests 仍 PASS |
| 精确异常 | delayed load/store access fault 的 `mepc/mcause/mtval` 正确 |
| 副作用正确 | MMIO write/read 副作用不重复、不越权、不在 error 时生效 |
| interrupt 正确 | memory wait 期间 pending interrupt 延迟到精确边界接受 |
| 控制正确 | younger redirect 不越过 older outstanding memory instruction |
| 后续可扩展 | simple data bus 可自然包装为 AXI-Lite |

达到这些标准后，第四阶段才算完成。下一阶段 `0835` 再把这些行为沉淀成 SVA、wait-state directed test 和第一版 UVM simple-bus/peripheral demo。
