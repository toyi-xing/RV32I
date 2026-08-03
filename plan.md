# 0836 AXI-Lite adapter、interconnect 与 APB 外设桥执行计划

当前主线基线为 v7.0，已经完成：

- RV32I 五级流水线、M-mode CSR/trap/interrupt 和最小 SoC。
- GPIO0、UART0、TIMER0 与稳定的软件可见寄存器 ABI。
- data-side single-outstanding simple request/response bus。
- MEM wait/backpressure、delayed response/error 和精确提交语义。
- Verilator ASM/C 程序自检回归。
- v6.0 `data_subsystem` 独立 UVM/SVA 验证工作区和 DUT RTL 快照。

本计划承接 `docs/08xx/0836 AXI-Lite adapter、interconnect与APB外设桥规划.md`，目标是在不修改 CPU 内部 LSU 事务语义的前提下，把 SoC 数据侧升级为 AXI4-Lite + APB4：

```text
core LSU
  -> internal simple data bus
  -> simple_bus_to_axi_lite
  -> single-master AXI-Lite router
       -> AXI-Lite DMEM slave
       -> AXI-Lite-to-APB4 bridge
            -> APB4 GPIO0/UART0/TIMER0
       -> reserved ACCEL0 control window
       -> default error response
```

本计划以 RTL 功能落地为主。验证部分目前只定义层次、对象和收口方向；等 RTL 结构稳定后，再根据真实接口覆盖为详细验证计划。

## 0. 执行方式和固定边界 `已确认`

### 0.1 执行方式

- 每一章是一个可单独审查和确认的实现节点。
- 开始某一章前，先确认上一章的接口和职责没有遗留分歧。
- 每章完成后先检查语法、elaboration、接口方向、状态机边界和注释，再决定是否进入下一章。
- 当前计划描述文件、模块职责、连接结构和完成条件，不提前写逐行实现方案。
- 实现允许参考成熟开源 AXI/APB 项目，但关键模块按本项目 single-outstanding 边界独立实现。
- 若直接复制任何第三方源码，必须先确认许可证、固定来源版本并单独记录；默认只参考，不整仓引入。
- 不修改 `uvm/v6_0/data_subsystem` 已冻结工作区，它继续绑定 v6.0 simple bus DUT 快照。

### 0.2 固定协议边界

本阶段固定：

| 项目 | 边界 |
|---|---|
| CPU data-side | 保留现有 `data_bus_pkg` simple request/response |
| AXI 协议 | AXI4-Lite，保留 AW/W/B/AR/R 五通道独立握手 |
| 数据宽度 | 32 bit |
| 地址宽度 | 32 bit byte address |
| byte enable | simple bus `be` -> AXI `WSTRB` -> APB4 `PSTRB` |
| outstanding | 系统全局最多一笔未完成 read 或 write |
| 顺序 | in-order completion，无 transaction ID |
| 时钟 | CPU、AXI-Lite、APB4 和当前外设使用同一时钟域 |
| reset | 延续当前 active-low reset |
| IMEM | 保持现有固定响应接口，不纳入 0836 |
| DMEM | 改为 AXI-Lite slave 接入 |
| MMIO | GPIO0/UART0/TIMER0 通过 AXI-Lite-to-APB4 接入 |
| ACCEL0 | 只保留 direct AXI-Lite control slot，未实现时返回 DECERR |
| AXI4/burst/DMA | 不属于本阶段 |

### 0.3 固定目录方向

本阶段新增 RTL 原则上放入：

```text
rtl/
  common/
    axi_lite_pkg.sv
    apb_pkg.sv
  bus/
    axi_lite/
      simple_bus_to_axi_lite.sv
      axi_lite_error_slave.sv
      axi_lite_router.sv
    bridge/
      axi_lite_to_apb.sv
    apb/
      apb_mux.sv
      apb_to_reg_adapter.sv
  mem/
    axi_lite_ram.sv
  soc/
    data_subsystem.sv
    rv32i_soc.sv
```

开发过程中允许新旧 data subsystem 短期并行，但最终主线只保留一个 `data_subsystem` 集成边界。验证专用 driver、delay model 和 assertion 不放进上述可综合目录。

## 1. AXI-Lite/APB4 公共类型和目录骨架 `已完成`

### 1.1 新增文件 `已完成`

新增：

- `rtl/common/axi_lite_pkg.sv`
- `rtl/common/apb_pkg.sv`
- `rtl/bus/axi_lite/`
- `rtl/bus/bridge/`
- `rtl/bus/apb/`

### 1.2 `axi_lite_pkg.sv` 职责 `已完成`

统一定义本项目 AXI4-Lite 的：

- address/data/strobe/protection/response 宽度。
- AXI response 编码，包括 OKAY、SLVERR 和 DECERR。
- master-to-slave request 聚合类型。
- slave-to-master response 聚合类型。
- AW、W、B、AR、R 五通道的标准 payload。
- 空闲默认值和必要的公共辅助类型。

AXI-Lite 在 RTL 内优先使用 packed struct 聚合，而不是让每一级模块重复展开几十个离散端口。结构体只负责表达标准 channel，不携带本项目 target、delay 或验证状态。

建议采用两组总线方向类型：

| 类型职责 | 内容 |
|---|---|
| master -> slave | AW valid/payload、W valid/payload、B ready、AR valid/payload、R ready |
| slave -> master | AW ready、W ready、B valid/payload、AR ready、R valid/payload |

类型名称在执行本步时统一确定，后续模块不得重新定义同义结构。

### 1.3 `apb_pkg.sv` 职责 `已完成`

统一定义 APB4 的：

- 32-bit address/data 和 4-bit `PSTRB`。
- APB master-to-slave request 类型。
- APB slave-to-master response 类型。
- `PSEL/PENABLE/PWRITE/PADDR/PWDATA/PSTRB/PPROT`。
- `PREADY/PRDATA/PSLVERR`。

APB 类型不包含 GPIO/UART/TIMER 专用信号，外设 sideband 继续由 SoC integration 单独连接。

### 1.4 本步完成条件 `已完成`

- 两个 package 能被 VCS、Verilator 和当前综合语法路径独立解析。
- 类型方向清楚，不存在同一信号在 request/response 两侧重复定义。
- AXI-Lite 保留完整五通道握手字段，没有因为 single outstanding 删除标准 channel。
- APB 使用 APB4 byte strobe，不退回无法表达 byte write 的 APB3 最小子集。
- 文件头、注释和命名符合当前 RTL 风格。

## 2. Simple bus 到 AXI-Lite master adapter `已完成`

### 2.1 新增文件 `已完成`

新增：

- `rtl/bus/axi_lite/simple_bus_to_axi_lite.sv`

### 2.2 模块定位 `已完成`

该模块是 CPU 内部 LSU transaction 与标准 AXI-Lite 五通道之间的唯一转换边界。

上游继续使用：

- `data_bus_pkg::data_req_t`
- 离散 request ready
- `data_bus_pkg::data_resp_t`

下游使用第 1 章定义的 AXI-Lite request/response struct。

CPU、`mem_stage`、`pipeline_ctrl` 和 hazard 网络不感知 AW/W/B/AR/R。

### 2.3 功能结构 `已完成`

adapter 按全局 single-outstanding 组织为 read/write 两条受控路径：

- idle 时接受一笔 simple request并锁存 payload。
- read request 独立完成 AR handshake，再等待 R response。
- write request 同时准备 AW 和 W，但分别记录二者是否握手。
- AW 与 W 允许同拍、AW 先或 W 先完成。
- B response 只能在 AW 与 W 都被接受后结束本笔 write。
- R/B response 被接受时转换成唯一一次 simple response。
- AXI OKAY 映射为 `error=0`。
- AXI SLVERR/DECERR 映射为 `error=1`。
- transaction 完成后回到 idle，才允许下一笔 simple request。

第一版不追求 simple request 到 AXI request 的组合直通。adapter 使用清晰的注册状态保存 transaction，优先避免 CPU ready、AXI ready 和下游 slave 形成长组合路径。

### 2.4 Reset 和保护边界 `已完成`

- reset 清除所有 channel valid、握手完成标志和 pending transaction。
- stalled AXI channel 的 valid/payload 必须保持。
- simple request accepted 后不再依赖上游继续保持 payload。
- adapter 不生成第二笔 outstanding transaction。
- 不允许 B/R orphan response 被转换为 simple response。
- `AWPROT/ARPROT` 第一版使用固定、明确的合法值。

### 2.5 本步完成条件 `已完成`

- 模块接口只连接 simple bus 与 AXI-Lite，不包含地址译码、外设或 RAM。
- read/write 状态职责清楚。
- AW/W handshake 独立，不要求 `AWREADY && WREADY` 同拍。
- R/B stalled 时不会重复完成 simple response。
- 语法/elaboration 通过。
- 本步先做有限的结构检查；独立 channel delay 的完整功能验证留到 RTL 主线完成后统一规划。

## 3. AXI-Lite default error slave `已完成`

### 3.1 新增文件 `已完成`

新增：

- `rtl/bus/axi_lite/axi_lite_error_slave.sv`

### 3.2 模块定位 `已完成`

该模块为没有实际 target 的地址提供标准 AXI-Lite终止响应，避免 router 对未映射访问永久不返回。

### 3.3 功能结构 `已完成`

- read address 被接受后返回单笔 R response。
- write address和 write data分别被接受后返回单笔 B response。
- response code 默认使用 DECERR。
- AW/W 接受顺序不固定。
- B/R 在上游 ready 前保持有效和 payload 稳定。
- 同一时刻只保存一笔 read 或 write，遵守本项目 single-outstanding 边界。
- 不产生 memory/MMIO 副作用。

ACCEL0 未实现期间可以复用该模块返回 DECERR，不需要伪造一个读零写丢弃的 accelerator slave。

### 3.4 本步完成条件 `已完成`

- 任意合法单笔 read/write 都能结束，不会 hang。
- AW/W 任意顺序均能得到一次 B response。
- response stall 时保持稳定。
- reset 后没有残留 response。
- 模块不依赖 SoC 地址常量，可被 router 的任意 default route 复用。

## 4. Single-master AXI-Lite router `已完成`

### 4.1 新增文件 `已完成`

新增：

- `rtl/bus/axi_lite/axi_lite_router.sv`

### 4.2 模块定位 `已完成`

该模块是单 AXI-Lite master 的 address decoder 和 response router，不是多 master crossbar。

第一版至少包含以下逻辑目标：

| 目标 | 路由 |
|---|---|
| DMEM | 下游 AXI-Lite DMEM port |
| GPIO0/UART0/TIMER0 | 下游 AXI-Lite-to-APB bridge port |
| ACCEL0 | 预留下游 slot；未接入时走 DECERR |
| 其它地址 | default DECERR |

具体地址继续来自 `core_pkg.sv/soc_pkg.sv`，router 不重新硬编码一套地址图。

### 4.3 Write 路由结构 `已完成`

write 路径必须处理 W channel 没有地址的问题：

- 根据 AWADDR 选择并保存 target。
- 在 target 未确定前，不把 W transaction错误路由到其它 slave。
- 允许 AW/W 同拍或分拍到达。
- 保存本笔 write 的 AW/W 完成状态和 target。
- B response 完成前不覆盖 route state。
- 只允许被选中的 slave观察到有效 transaction。

第一版可以采用明确的内部缓冲或握手限制来处理 W 先到达，但不能依赖 master 永远 AW 先到达，也不能形成 AW/W 相互等待的死锁。

### 4.4 Read 路由结构 `已完成`

- AR handshake 时确定并保存 target。
- 只有被选中 slave 接收 AR。
- 只有该 slave 的 R response 能返回上游。
- R transaction 完成前不接受会覆盖 route state 的下一笔 read。

### 4.5 Read/write admission `已完成`

当前 adapter 不会同时发起 read/write，但 router 仍要防止同拍错误接受两笔而只保存一份状态。

第一版采用固定、可说明的 admission/优先级策略；不能服务的一侧通过 READY backpressure，不把吞掉请求作为简化方式。

### 4.6 本步完成条件 `已完成`

- router 只负责路由，不包含 RAM、APB状态机或外设寄存器逻辑。
- DMEM/MMIO/ACCEL/default 地址边界明确。
- AW/W/B route 生命周期完整。
- AR/R route 生命周期完整。
- default error slave 正确接入。
- 未选中的 slave 不产生误握手。
- single-outstanding 状态不会被第二笔请求覆盖。
- 语法/elaboration 通过。

## 5. AXI-Lite DMEM slave `已完成`

### 5.1 新增文件 `已完成`

新增：

- `rtl/mem/axi_lite_ram.sv`

### 5.2 模块定位 `已完成`

该模块提供可综合的 32-bit AXI-Lite RAM slave，用于 Verilator/VCS harness 和后续 FPGA wrapper。它替代主线 testbench 中 simple data bus 直连的 `simple_ram`，但不把程序镜像加载逻辑塞进 SoC。

`axi_lite_ram` 保持独立，最终由 testbench 或 FPGA wrapper 实例化并连接 SoC 透出的 DMEM AXI-Lite port。

### 5.3 功能结构 `已完成`

- 参数化 RAM word depth，地址映射与现有 DMEM window 一致。
- 支持 AXI-Lite read。
- 支持 AXI-Lite write。
- AW/W 独立接受并在两者均具备后提交一次写操作。
- `WSTRB[3:0]` 逐 byte lane 更新。
- read 返回完整 32-bit aligned word。
- B/R response 为注册响应，并支持上游 backpressure。
- 地址越界返回 SLVERR，不访问非法数组索引。
- RAM 存储数组允许 testbench 通过层级或已有加载流程写入，但模块本体不解析 plusarg、不实现 mailbox、不随机延迟。

### 5.4 与现有 `simple_ram` 的关系 `已完成`

- 本步不立即删除 `rtl/mem/simple_ram.sv`。
- 新旧模块在 SoC 切换完成前可以并存。
- v7.0 UVM snapshot 中的 `simple_ram` 不修改。
- 主线所有 filelist 和 testbench 切换到 AXI-Lite RAM 后，再决定根目录旧 `simple_ram` 是否仍被 FPGA/其它路径使用。

### 5.5 本步完成条件 `已完成`

- word/byte lane 地址语义与当前 CPU 保持一致。
- `WSTRB` 任意非零组合都按 lane 更新。
- read-after-write 能返回更新后的完整 word。
- AW/W/B 和 AR/R 均符合 stalled payload 保持规则。
- 越界访问得到明确 response。
- 无 testbench-only 行为进入可综合功能路径。

## 6. AXI-Lite-to-APB4 bridge `已完成`

### 6.1 新增文件 `已完成`

新增：

- `rtl/bus/bridge/axi_lite_to_apb.sv`

### 6.2 模块定位 `已完成`

该模块上游是一个 AXI-Lite slave port，下游是一个 APB4 master port。它集中吸收 AXI 五通道复杂性，让低速寄存器外设只面对 APB setup/access。

### 6.3 Write 路径结构 `已完成`

- 独立接受并保存 AW 和 W。
- 两者都完成后启动一次 APB write。
- APB write 使用 AXI address、data、strobe 和 protection 信息。
- APB ACCESS 完成后生成 AXI B response。
- `PSLVERR=0` 返回 OKAY。
- `PSLVERR=1` 返回 SLVERR。
- BREADY 未到时保持 BVALID/BRESP。

### 6.4 Read 路径结构 `已完成`

- 接受并保存 AR。
- 启动一次 APB read。
- APB ACCESS 完成后保存 PRDATA/PSLVERR。
- 返回 AXI RDATA 和 OKAY/SLVERR。
- RREADY 未到时保持 RVALID/RDATA/RRESP。

### 6.5 APB 状态边界 `已完成`

- 每笔 APB transaction 必须经历 SETUP 和 ACCESS。
- SETUP 后才能拉高 PENABLE。
- PREADY 为 0 时保持 PSEL、PENABLE、地址、方向和 payload 稳定。
- access completion 后撤销 PSEL/PENABLE。
- 每笔 AXI transaction 最多产生一次 APB transaction。
- bridge 同一时刻只处理一笔 read 或 write。
- read/write 同时到达时采用固定 admission 策略，不同时吞下两笔。

### 6.6 本步完成条件 `已完成`

- AW/W 任意顺序不会丢失 write。
- APB zero-wait 和 multi-cycle wait 结构均成立。
- PSLVERR 能准确映射到对应 B/R response。
- AXI response backpressure 不会重复 APB side effect。
- reset 清除 AXI pending 和 APB state。
- 模块不包含具体 GPIO/UART/TIMER 地址译码。

## 7. APB mux 与现有外设适配 `已完成`

### 7.1 新增文件 `已完成`

新增：

- `rtl/bus/apb/apb_mux.sv`
- `rtl/bus/apb/apb_to_reg_adapter.sv`

现有以下寄存器模块原则上保留内部寄存器和 side effect 逻辑：

- `rtl/periph/mmio_gpio.sv`
- `rtl/periph/mmio_uart.sv`
- `rtl/periph/mmio_timer32.sv`

### 7.2 `apb_mux.sv` 职责 `已完成`

- 根据 APB PADDR 选择 GPIO0、UART0 或 TIMER0。
- 对每个外设产生独立、one-hot 的 APB slave request。
- mux 被选中外设的 PREADY、PRDATA 和 PSLVERR。
- APB 地址未命中任何实现外设时返回错误并正常结束，不永久等待。
- ACCEL0 不进入 APB mux，它属于预留 direct AXI-Lite control slot。

### 7.3 `apb_to_reg_adapter.sv` 职责 `已完成`

该模块把 APB4 access completion 转换为现有外设寄存器接口：

- APB write/read 转换为现有 valid/we/be/addr/wdata。
- `PSTRB` 映射为外设 byte enable。
- 外设 rdata 映射为 PRDATA。
- 外设 access fault 映射为 PSLVERR。
- 当前固定响应寄存器块可使用 `PREADY=1`。
- 只有真正 APB ACCESS completion 才产生一次外设访问脉冲。

同一 adapter 可以参数化复用，不为 GPIO/UART/TIMER 复制三套相同 APB握手逻辑。

### 7.4 外设 side effect 边界 `已完成`

接入后必须保持：

- GPIO W1C 只执行一次。
- UART TX event 只产生一次。
- UART RX read side effect 只执行一次。
- TIMER register write 只执行一次。
- APB SETUP 不触发寄存器访问。
- APB ACCESS 等待期间不重复触发寄存器访问。
- 未定义 register offset 返回 PSLVERR。

### 7.5 本步完成条件 `已完成`

- APB mux 的地址译码与 one-hot 选择正确。
- 地址图和现有软件 ABI 不变。
- 三个现有外设无需重复实现 AXI-Lite 五通道。
- APB fixed-ready 外设路径功能闭合。
- 非法外设地址和非法 register offset 的错误层次清楚。
- side effect 触发点统一为 APB completion。

## 8. 新 AXI data subsystem 集成 `已完成`

### 8.1 集成策略 `已完成`

开发期间先让新 AXI data subsystem 与当前 `rtl/soc/data_subsystem.sv` 并行，避免在 adapter/router/bridge 尚未连通时破坏现有 SoC。

本步并行实现使用 `rtl/soc/axi_data_subsystem.sv` 和 `axi_data_subsystem` 模块名，后续在 SoC 切换与旧实现清理节点统一名称。

新模块稳定后，最终主线仍保留一个通用名称 `data_subsystem`；旧 response-delay wrapper 实现由 v7.0 tag 和 UVM DUT snapshot 保存，不在主线长期保留两套同名职责。

### 8.2 集成内容 `已完成`

新的 data subsystem 负责实例化和连接：

- simple-bus-to-AXI-Lite adapter。
- AXI-Lite router。
- default error slave。
- AXI-Lite-to-APB4 bridge。
- APB mux。
- 三个 APB-to-register adapter。
- GPIO0、UART0、TIMER0 寄存器模块。

它对外保留：

- core-side simple request/response。
- downstream DMEM AXI-Lite port。
- GPIO/UART 外部 sideband。
- GPIO/UART/TIMER interrupt。
- 必要的 transaction/target 观察信号。

它不再包含：

- `*_resp_delay_cycles_i`。
- response-delay counter wrapper。
- simple RAM 固定响应端口。
- testbench mailbox 或随机延迟配置。

### 8.3 地址和 target 语义 `已完成`

- DMEM 送往外部 AXI-Lite DMEM port。
- GPIO0/UART0/TIMER0 送往 APB bridge。
- ACCEL0 未实现时走 DECERR。
- 完全未映射地址走 DECERR。
- APB 外设 window 内未定义 offset 走 SLVERR。
- 保留区分 DMEM/MMIO/undefined 的观察能力；若新增 target enum，应同步 `soc_pkg.sv`，但不修改已冻结 UVM snapshot。

### 8.4 中断和 sideband `已完成`

- GPIO/UART/TIMER interrupt 仍直接汇总到 SoC/core，不经过 AXI/APB transaction channel。
- GPIO pin、UART RX/TX event 仍是独立 sideband。
- 总线改造不改变中断 pending、enable、trap entry 或 MRET 语义。

### 8.5 本步完成条件 `已完成`

- 新 data subsystem 可以作为独立 elaboration top。
- core request 能到达正确 AXI target。
- AXI response 能回到唯一一次 simple response。
- APB 外设路径完成连接。
- error 分层符合 DECERR/SLVERR 规划。
- response-delay wrapper 已从新实现中消失。
- 模块职责以集成为主，没有重新塞回多个重复协议状态机。

## 9. `rv32i_soc` 切换到新 data subsystem `已完成`

### 9.1 修改文件 `已完成`

主要修改：

- `rtl/soc/rv32i_soc.sv`
- `tb/sv/tb_rv32i_soc.sv`
- Verilator/VCS 当前 SoC 顶层使用的必要 package 和 filelist。

本步在切换 SoC RTL 的同时完成最小 testbench 端口迁移，保证当前仿真 top 不因接口变化而失去编译能力；不在同一节点展开随机 delay、完整 scoreboard 或专项 testcase。

### 9.2 SoC 顶层变化 `已完成`

- core 与 data subsystem 之间的 simple bus 接线保持不变。
- 旧离散 DMEM we/be/addr/wdata/rdata 端口替换为 downstream DMEM AXI-Lite port。
- 删除四路 `*_resp_delay_cycles_i` SoC 端口。
- GPIO/UART sideband 和 interrupt 端口保持。
- commit/trap/mem_wait 观察口保持。
- data transaction 观察口根据新层次更新注释和语义。

### 9.3 最小 testbench 迁移 `已完成`

- `tb_rv32i_soc.sv` 改接新的 downstream DMEM AXI-Lite port。
- testbench 实例化第 5 章完成的 `axi_lite_ram`，继续承担程序数据镜像和 PASS/FAIL 状态 RAM。
- 第一版 TB 只使用固定、无额外 backpressure 的 AXI-Lite RAM 响应配置，使 SoC 切换后先恢复可编译、可运行的基线。
- simple ROM、程序镜像加载、commit/trap trace、PASS/FAIL、GPIO/UART 外部激励和非 delay mailbox 功能继续保留。
- 旧四路 `*_resp_delay_cycles_i` 连接与 TB 状态只能在新 AXI RAM 接线完成后删除，不能留下新 SoC 配旧 TB 的中间状态。
- 当前 ASM/C 仿真入口使用的 filelist 同步加入 AXI/APB packages 和 RTL 模块。

本步不提供内部 APB `PREADY` 注入。当前 GPIO0/UART0/TIMER0 在 SoC 集成中固定 `PREADY=1`，APB multi-cycle wait 由第 11 章的 bridge 模块级 testbench 验证。

### 9.4 CPU RTL 边界 `已完成`

原则上不修改：

- `mem_stage.sv` 的 LSU request/response 结构。
- `pipeline_ctrl.sv` 的 MEM wait 规则。
- trap/interrupt 精确提交逻辑。

若集成时发现必须修改 CPU RTL，应先判断是接口适配遗漏还是现有 bug，不因 AXI 五通道方便而把 channel 状态引入 CPU。

### 9.5 本步完成条件 `已完成`

- `rv32i_soc` 能完整 elaboration。
- `tb_rv32i_soc` 能连接新 SoC、AXI-Lite RAM 和现有 ROM/sideband，不引用已经删除的端口。
- `sim/soc_asm`、`sim/soc_c` 使用的 Verilator top 和 filelist 至少能完成编译/elaboration。
- CPU 侧接口和流水线控制没有 AXI channel 信号。
- downstream DMEM 使用标准 AXI-Lite结构。
- MMIO 通过 APB 路径实例化。
- 所有删除或新增端口在注释中准确反映。
- 未引入悬空 AXI/APB channel。

## 10. 主线切换、旧 wrapper 清理与 RTL 收口 `已完成`

### 10.1 主线文件收敛 `已完成`

完成新 SoC RTL 切换后：

- 新 AXI data subsystem 成为正式 `rtl/soc/data_subsystem.sv`。
- 删除开发期间的临时并行模块或重复顶层。
- 清理旧 response-delay wrapper 逻辑。
- 清理主线 RTL 中已经过时的固定响应、wrapper 和 delay input 注释。
- 保留 v7.0 tag 与 `uvm/v6_0/data_subsystem/dut/rtl` 快照，不回写旧验证资产。

### 10.2 `simple_ram` 和旧接口清理 `已完成`

- 根目录 `simple_ram.sv` 保留为 simple bus 独立场景和历史教学参考，并在头注释中明确标记 legacy。
- SoC 主线 testbench 已切换为 `axi_lite_ram`，不再实例化 `simple_ram`。
- 旧 SoC 离散 DMEM 端口和 TB delay 配置不能半切换；主线 RTL 与后续 testbench 必须采用一致边界。

### 10.3 静态检查 `已完成`

RTL 功能阶段先完成：

- VCS/Verilator 语法解析。
- package/filelist 编译顺序。
- top-level elaboration。
- `default_nettype none` 下无隐式 net。
- 无未驱动、多驱动和明显宽度错误。
- 基本 lint/Yosys elaboration 能通过的部分。
- 对照开源参考重新检查 AW/W/B、AR/R 和 APB 状态生命周期。

这些检查只说明 RTL 结构闭合，不代替后续动态协议验证。

### 10.4 本步完成条件 `已完成`

- 主线只有一个 data subsystem 实现。
- 旧 wrapper 不再参与主线 AXI/APB transaction。
- AXI/APB RTL 目录和模块职责稳定。
- SoC、packages、filelists 和注释同步。
- RTL 能作为下一阶段详细验证计划的固定 DUT。

## 11. SoC 集成级定向验证与问题收口 `已完成`

### 11.1 验证策略与结论边界 `已完成`

0836 不新增协议级 testbench、UVM 环境或 SVA 文件，继续使用现有 Verilator SoC testbench、mailbox 外部激励和 38 个程序自检用例验证主线切换。该方案能够证明当前 CPU、adapter、router、AXI-Lite RAM、AXI-Lite-to-APB bridge、APB mux 和固定响应外设组合在实际程序访问下功能闭合，但不等价于 AXI4-Lite/APB4 完整协议合规验证。

本章可以确认当前固定实现中的读写、byte strobe、地址路由、错误传播、流水线 backpressure、精确 trap/interrupt 和外设副作用；不能据此声称已经动态覆盖 AW/W 任意先后、各 channel 长时间 backpressure、B/R response stall 或多周期 `PREADY`。

### 11.2 旧 wait-state 测试迁移 `已完成`

- 删除 `tb_rv32i_soc_test.h` 中已经失效的 response-delay mailbox 地址、配置打包和 C helper，TB mailbox 只保留 PASS/FAIL、GPIO 输入控制和 UART RX 激励职责。
- 删除 0801、0802、0804、0805、0853、0856 中对旧 delay mailbox 的无效写入，避免用例无声通过却继续声称覆盖旧 wrapper 延迟。
- 保留原测试文件名和编号以维持回归入口稳定；文件头和内部注释改为当前实际覆盖的 AXI-Lite DMEM 固定多周期访问、固定 `PREADY` APB 外设、错误传播和混合路由语义。
- 没有把旧统一 `resp_delay` 人工映射到某个 AXI channel，也没有为验证重新向可综合 RTL 添加 delay 配置端口。

### 11.3 复用测试与集成证据 `已完成`

| 验证面 | 主要既有用例 | 当前能够证明的行为 |
|---|---|---|
| AXI-Lite DMEM 数据语义 | `0104_load_store`、`0801_dmem_wait_basic`、`0802_dmem_wait_forwarding` | word/byte/halfword、`WSTRB` lane、外部 RAM 读写、load-use/forwarding 与 MEM backpressure |
| APB 外设与副作用 | `0602_uart_tx`、`0603_gpio_rw`、`0651/0652`、`0751`～`0754`、`0853_mmio_wait_basic` | GPIO/UART/TIMER 寄存器 ABI、W1C/读清/TX event exactly once、固定 `PREADY` 端到端访问 |
| 总线错误传播 | `0604_mmio_access_fault`、`0804_mmio_wait_access_fault` | router 未映射地址的 AXI `DECERR` 与 APB `PSLVERR` 转 AXI `SLVERR`，最终形成精确 load/store access fault |
| kill 与精确提交 | `0605_mmio_misaligned_priority`、`0606_wrong_path_mmio`、`0705/0706`、`0805_wait_interrupt_boundary` | misaligned 优先级、wrong-path 无副作用、CSR/MRET 同拍中断和 older DMEM 访问完成后再接受 interrupt |
| DMEM/MMIO 路由切换 | `0856_wait_mixed_random_smoke` | 同一程序在外部 AXI-Lite DMEM 与内部 APB GPIO/UART/TIMER 路径间交替访问且不死锁、不串响应 |

没有为 0836 新增测试程序。既有用例已经覆盖本次 SoC 集成需要的功能路径，新建协议级测试平台带来的文件与维护成本高于当前阶段收益；更完整的标准协议验证留给独立的后续版本化验证工作区。

### 11.4 REG-002 修复 `已完成`

`0757_gpio_periodic_irq` 原先使用 200 拍的 bit30 翻转周期，短于 AXI-Lite/APB 接入后完整 C trap handler 的实际处理时间，导致 GPIO pending 合并并测得约 299 拍。修复将快速翻转周期改为 500 拍，慢速周期仍为 2000 拍；软件检查范围由共享常量按 ±10% 推导，预期比值自动推导为 4。

修复后日志记录 `B30 CNT=21 AVG=500`、`B31 CNT=6 AVG=2000`、`RATIO(B31/B30)=4 (expect 4)` 并 PASS。该问题属于测试吞吐前提失效，不是 GPIO、TIMER0、trap 或 AXI/APB RTL 功能错误；`docs/known_issues.md` 中 REG-002 已更新为 `Fixed`。

### 11.5 回归结果 `已完成`

- `sim/soc_asm/run_all.sh`：25 passed，0 failed。
- `sim/soc_c/run_all.sh`：13 passed，0 failed。
- `git diff --check`：本章代码和注释变更无 whitespace error。
- 代表性日志确认 0804 的 6 次 APB 外设非法 offset trap、0805 的 older load/interrupt 边界和 0757 的周期测量均实际发生，不只依据脚本退出码判断。

### 11.6 明确保留的验证缺口 `已确认`

- 当前 `axi_lite_ram` 和 CPU adapter 的实际流量通常同拍给出 AW/W，尚未用独立 master/slave model 动态覆盖 AW/W 任意先后。
- 尚未注入 AWREADY/WREADY/ARREADY、BVALID/RVALID 的随机或长时间 backpressure，也未验证上游主动拉低 BREADY/RREADY 的组合。
- 正式 GPIO/UART/TIMER 路径固定 `PREADY=1`，`axi_lite_to_apb` 对多周期 `PREADY=0` 的保持能力仅由 RTL 结构实现，未在本章动态验证。
- v6.0 `data_subsystem` UVM/SVA 工作区保持冻结，不混编新的 AXI/APB 主线 RTL。

以上缺口不阻塞 0836 的 SoC 功能集成收口；后续若继续投入协议验证，应在新的版本化 AXI-Lite/APB 验证工作区单独处理，不回写 v6.0 simple bus UVM。

## 12. 文档与阶段收口 `已完成`

本章清单依据当前工作区与 `v7.0-docs-dut-snapshot` 的 RTL、TB、脚本和文档差异整理。当前主线文档已同步，版本号、tag 和提交号仍需在正式 release 后回填。

### 12.1 阶段规划与问题记录 `已完成`

- 更新 `docs/08xx/0836 AXI-Lite adapter、interconnect与APB外设桥规划.md`：保留现有 AXI-Lite/APB 功能边界和原理说明，补充实际模块名与连接关系、实现完成状态、固定响应延迟来源、未做 request 直通优化、SoC 程序回归结果和第 11.6 节验证缺口。
- 将 0836 原计划中的“模块级协议 TB/SVA 必须完成”改为后续可选增强，明确本阶段实际采用 38 个 Verilator 程序自检完成 SoC 集成级验证，不能表述为完整协议合规验证。
- 更新 0836 的开源参考说明：本阶段代码为项目内独立实现，没有直接复制第三方 RTL；`cocotbext-axi` 只作为 AXI/AXI-Lite 可选参考，APB 若后续验证需使用独立 APB model/package，不能继续声称该包提供 APB VIP。
- 更新 `docs/08xx/0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md`：把 0836 标记为已完成，按实际实现修正 accelerator 仅预留地址/端口的边界，并把 0837 AXI-Lite 协议深化保留为可选后续而非当前完成条件。
- `docs/known_issues.md` 的 REG-002 已在第 11 章更新为 `Fixed`；正式 release 后只需补最终版本/tag，不再改写原失败日志和根因证据。

### 12.2 根目录 `README.md` `已完成`

- 更新“当前特性”和“验证能力”：主线 data-side 改为 CPU 内部 single-outstanding simple bus，经 adapter 接 AXI4-Lite router，DMEM 走外置 AXI-Lite RAM，GPIO/UART/TIMER 走 AXI-Lite-to-APB4 bridge；删除主线仍有 response-delay wrapper 和 delay mailbox 的过时描述。
- 重画系统架构图，明确 `simple_rom` 仍在 TB，`axi_lite_ram` 在 TB/上层 wrapper，`data_subsystem` 内含 adapter/router/bridge/APB mux/register adapter，避免继续显示 `simple_ram + decoder + response delay wrapper`。
- 更新目录结构和 RTL 文件说明，加入 `rtl/bus/axi_lite`、`rtl/bus/bridge`、`rtl/bus/apb`、`axi_lite_pkg.sv`、`apb_pkg.sv` 和 `axi_lite_ram.sv`；`simple_ram.sv` 标为 legacy simple bus 参考。
- 更新 0801/0802/0804/0805/0853/0856 的测试描述、TB mailbox 边界和 38 个 directed tests 的覆盖结论，记录 ASM 25/25、C 13/13 以及 REG-002 修复后的 0757 证据。
- 在项目时间戳中新增 0836 AXI-Lite/APB 主线 release 行；版本号、tag 和提交号在正式提交后填写，不能提前猜测。
- 保留 v5.1 FPGA 与 v6.0 UVM 的入口，但明确二者是冻结的版本化工作区，不代表当前 AXI/APB 主线 RTL。

### 12.3 当前主线配套文档 `已完成`

- 更新 `rtl/periph/readme.md`：外设寄存器 ABI 和 word-aligned offset 规则不变；把旧 simple bus delay wrapper 描述替换为 `apb_to_reg_adapter` 在 APB ACCESS completion 产生一次寄存器访问、当前固定 `PREADY=1`、`access_fault_o -> PSLVERR -> SLVERR` 的实际路径。
- 更新 `sw/asm/readme.md`：第 8 章改为 AXI-Lite/APB 集成测试分类，删除 `TB_RESP_DELAY_CFG0_ADDR` 和固定 delay 配置说明，保留旧文件名只是稳定测试编号/入口的说明。
- 更新 `sw/c/readme.md`：0757 改为 500/2000 拍和 4:1 结果；0853/0856 改为固定 `PREADY` 外设副作用与 AXI DMEM/APB MMIO 混合访问；删除全部 delay helper、`0x190` mailbox 命令和随机 response-delay 流程。
- 更新 `sw/include/readme.md`：明确 mailbox 只包含 GPIO 输入和 UART RX 激励，并记录 bit30/bit31 的 500/2000 拍共享周期常量；不再出现 response-delay 配置接口。
- 更新 `sw/linker/readme.md`：IMEM 仍由 `simple_rom` 加载，DMEM 镜像改由 TB 中的 `axi_lite_ram.mem` 加载；地址图和 linker layout 不变，`simple_ram` 只作为 legacy 检查项保留或移出当前主线同步清单。
- 更新 `docs/simulation_flow_asm.md` 和 `docs/simulation_flow_c.md`：仿真拓扑从 `simple_rom/simple_ram` 改为 `simple_rom/axi_lite_ram + AXI-Lite/APB`，文件收集目录加入三个 `rtl/bus` 子目录；C 文档的超时值同步为 TB 当前 30010 拍，并补全当前 13 个 C 用例入口。
- 不新增 `rtl/bus/readme.md`：当前总架构入口由根 README 提供，协议规划、实现边界和模块关系由 0836 文档提供，各 RTL 文件头已经说明单模块职责，避免重复维护第三份同类说明。

### 12.4 明确保留不动的版本化/历史文档 `已确认`

- 不修改 `uvm/v6_0/data_subsystem` 下的 spec、verification report、DUT docs 和 RTL 快照；它们记录 v6.0/v7.0 simple bus + response-delay wrapper 验证结果。
- 不修改 `fpga/project_v5.1_original_to_fpga` 内的 RTL、readme 和迁移文档；该工作区固定描述 v5.1 FPGA 上板实现。
- 不批量改写 `docs/08xx/0831`～`0835` 和早期 080x/082x 教学文档中的历史阶段接口；这些内容按各自阶段阅读。只在根 README、0830 和 0836 建立当前主线入口与版本边界。

### 12.5 最终收口检查 `已完成`

- 完成上述文档后，用全文搜索确认当前主线入口不再声称存在 response-delay wrapper、delay mailbox、外置 `simple_ram` DMEM 或随机 MMIO delay。
- 检查文档链接、module/file 名、地址图、错误语义、测试数量和命令与仓库实际一致。
- 再运行 `git diff --check`，并保留第 11 章 ASM 25/25、C 13/13 的结果作为 release 证据。
- 正式提交后回填 release 版本、tag 和提交号，再按 `docs/08xx/0836 AXI-Lite adapter、interconnect与APB外设桥规划.md` 的最终完成标准确认 0836 收口。
