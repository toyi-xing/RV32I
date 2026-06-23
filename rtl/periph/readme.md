# MMIO 外设寄存器手册

本文面向软件开发者描述 `rtl/periph` 下 MMIO 外设 module 的寄存器 ABI。只要系统实例化同一个外设 module，寄存器 offset、bit 定义、访问属性和软件可见副作用就应保持一致。具体实例基地址、SoC 地址译码窗口和中断汇总方式不属于本手册范围，应查对应 SoC 的 MMIO 地址图。

本文中的 offset 都是相对该外设实例 `BASE_ADDR` 的 byte offset：

```text
software_address = instance_BASE_ADDR + register_offset
```

当前三个外设都是固定响应 register block，没有软件可见 wait state 或 backpressure。`access_fault_o` 当前只检测未知 offset：访问未定义 offset 时拉高；写 RO、读 WO、写保留 bit 等访问类型或字段错误当前不额外触发 fault。

通用访问属性：

| 属性 | 含义 |
|---|---|
| `RW` | 软件可读可写。写入时按 byte enable 更新被选中的 byte，未选 byte 保持原值。 |
| `RO` | 软件只读。写入当前忽略，不触发 `access_fault_o`。 |
| `WO` | 软件只写。读取当前返回 0，不触发 `access_fault_o`。 |
| `R/W1C` | 软件可读；写 1 清除对应 bit，写 0 保持。store byte enable 未选中的 byte 不参与清除。 |
| `*` | 不是访问属性；附在属性后表示该寄存器除访问属性本身外，还参与额外访问副作用，可能是触发方，也可能是被影响方。具体方向见寄存器列表的 `副作用` 列。 |

寄存器列表中的 `副作用` 列用于说明访问寄存器时产生或承受的软件可见变化。`-` 表示没有额外访问副作用，不代表寄存器值不会被硬件事件更新。

保留 bit 应由软件写 0，读回值不应被软件依赖。当前部分 RW 配置寄存器会保留写入的保留 bit，后续扩展时可能重新定义这些 bit，因此软件不应依赖这种读回结果。

## 1. `mmio_gpio`

`mmio_gpio` 是可参数化宽度的 GPIO MMIO 外设。寄存器宽度保持 XLEN，低 `GPIO_WIDTH` bit 对实际 GPIO 有意义；高 bit 为保留 bit。

`gpio_in_i` 可能来自 SoC 外部或 testbench。模块内部会先把它两级同步到 `clk_i` 域，软件读到的 `IN` 和中断触发检测都使用同步后的输入视图，因此相对外部真实电平通常会有约两个 `clk_i` 周期延迟。

`mmio_gpio` 把 `OUT`、`OE`、`IN` 分离为普通端口，不在外设内部实现真实 tri-state pad。`OE` 只表示输出使能配置，不参与输入采样和中断 mask。输出模式下是否回读 pad、电平如何进入 `gpio_in_i`，由 SoC 顶层或 pad wrapper 决定。

参数：

| 参数 | 说明 |
|---|---|
| `BASE_ADDR` | 外设实例基地址，用于计算寄存器 offset。 |
| `GPIO_WIDTH` | GPIO bit 数，当前应保持在 1..XLEN。 |

### GPIO 寄存器列表

| offset | 名称 | 属性 | reset | 副作用 | 说明 |
|---:|---|---|---:|---|---|
| `0x000` | `OUT` | `RW` | `0x0000_0000` | - | GPIO 输出数据。 |
| `0x004` | `IN` | `RO` | `0x0000_0000` | - | 同步后的 GPIO 输入值。 |
| `0x008` | `OE` | `RW` | `0x0000_0000` | - | GPIO 输出使能。 |
| `0x00C` | `IRQ_EN` | `RW` | `0x0000_0000` | - | 每 bit 中断总使能。 |
| `0x010` | `IRQ_RISE_EN` | `RW` | `0x0000_0000` | - | 每 bit 上升沿触发使能。 |
| `0x014` | `IRQ_FALL_EN` | `RW` | `0x0000_0000` | - | 每 bit 下降沿触发使能。 |
| `0x018` | `IRQ_HIGH_EN` | `RW` | `0x0000_0000` | - | 每 bit 高电平触发使能。 |
| `0x01C` | `IRQ_LOW_EN` | `RW` | `0x0000_0000` | - | 每 bit 低电平触发使能。 |
| `0x020` | `IRQ_PENDING` | `R/W1C` | `0x0000_0000` | 同拍触发时硬件 set 优先。 | 每 bit interrupt pending。 |
| `0x024` | `IRQ_STATUS` | `RO` | `0x0000_0000` | - | 已使能 pending 视图。 |

### GPIO 数据寄存器

`OUT[GPIO_WIDTH-1:0]` 是每个 GPIO bit 的输出数据，直接对应 `gpio_out_o`。当系统外层实现真实 GPIO pad 时，通常只有 `OE[bit]=1` 的 bit 才会被驱动到外部引脚。

`IN[GPIO_WIDTH-1:0]` 返回同步后的 `gpio_in_i`。`IN` 不受 `OUT` 或 `OE` 影响。

`OE[GPIO_WIDTH-1:0]` 是每个 GPIO bit 的输出使能，直接对应 `gpio_oe_o`。bit 为 1 表示该位按输出使用，bit 为 0 表示该位按输入或高阻使用，具体 pad 行为由外层实现。

### GPIO 中断寄存器

`IRQ_EN` 是每 bit 中断总使能。当前实现中，只有 `IRQ_EN[bit]=1` 时，该 bit 的触发条件才会置 `IRQ_PENDING[bit]`；`IRQ_EN=0` 时发生的历史事件不会被 pending 记录。

`IRQ_RISE_EN`、`IRQ_FALL_EN`、`IRQ_HIGH_EN`、`IRQ_LOW_EN` 配置每个 GPIO bit 的触发类型：

| 寄存器 | bit 为 1 时的含义 |
|---|---|
| `IRQ_RISE_EN` | 同步后输入从 0 到 1 时触发。 |
| `IRQ_FALL_EN` | 同步后输入从 1 到 0 时触发。 |
| `IRQ_HIGH_EN` | 同步后输入为 1 时持续触发。 |
| `IRQ_LOW_EN` | 同步后输入为 0 时持续触发。 |

同一个 GPIO bit 可以同时打开多个触发类型。边沿触发使用同步后的输入历史值；电平触发只要同步后的输入保持在触发电平，就会持续产生触发条件。

`IRQ_PENDING` 是 R/W1C pending 寄存器。软件读出当前 pending；软件写 1 清除对应 bit，写 0 保持。硬件触发和软件 W1C 清除在同一个时钟沿发生时，硬件置位优先。因此电平触发条件仍然成立时，软件写 1 清 pending 后该 bit 可能保持为 1 或立即再次变为 1，这是预期行为。

`IRQ_STATUS` 是 `IRQ_PENDING & IRQ_EN` 的只读视图。`gpio_irq_o` 是 level interrupt 输出，只要 `IRQ_STATUS` 任意 bit 为 1 就为 1。handler 通常读 `IRQ_STATUS` 判断有效中断源，再向 `IRQ_PENDING` 写 1 清除已处理 bit。

## 2. `mmio_timer32`

`mmio_timer32` 是 32-bit 教学用 timer 外设。它提供 `MTIME` 计数器、`MTIMECMP` 比较值、`CTRL` 使能和 `STATUS` 观察口。`timer32_irq_o` 是 level pending，不是 pulse。

这个 module 的命名明确包含 `32`，表示当前寄存器和计数比较语义是 32-bit。后续如果增加 64-bit timer，应该作为新的 timer 规格或扩展规格处理，不应悄悄改变 `mmio_timer32` 的软件可见 ABI。

参数：

| 参数 | 说明 |
|---|---|
| `BASE_ADDR` | 外设实例基地址，用于计算寄存器 offset。 |

### TIMER32 寄存器列表

| offset | 名称 | 属性 | reset | 副作用 | 说明 |
|---:|---|---|---:|---|---|
| `0x000` | `MTIME` | `RW` | `0x0000_0000` | 写 `MTIME` 的同拍不自增。 | 32-bit 计数值。 |
| `0x004` | `MTIMECMP` | `RW` | `0x0000_0000` | - | 32-bit 比较值。 |
| `0x008` | `CTRL` | `RW` | `0x0000_0000` | - | timer 控制寄存器。 |
| `0x00C` | `STATUS` | `RO` | `0x0000_0000` | - | timer 状态寄存器。 |

### `MTIME` 和 `MTIMECMP`

`MTIME` 是 32-bit 计数器。`CTRL.enable=1` 时，`MTIME` 通常每个 `clk_i` 周期加 1。

写 `MTIME` 的时钟沿，写入值生效，本拍不执行自动自增。也就是说，如果软件希望从 0 开始计数，可以先写 `MTIME=0`，该写入周期不会额外加 1。

`MTIMECMP` 是 32-bit 比较值。写 `MTIMECMP` 不阻止 `MTIME` 自增；该时钟沿是否自增取决于写入前的旧 `CTRL.enable`。

### `CTRL` register

```text
31                                                1 0
+-------------------------------------------------+-+
| Reserved                                        |E|
+-------------------------------------------------+-+
```

bit 定义：

| bit | 名称 | 说明 |
|---:|---|---|
| 0 | `enable` | 1 时允许 `MTIME` 自增，并允许比较结果输出到 `timer32_irq_o`。 |
| 31:1 | reserved | 软件写 0，读回值不应依赖。 |

写 `CTRL.enable=1` 后，计数从后续时钟沿开始。写 `CTRL` 的同一时钟沿不暂停 `MTIME`：如果写入前旧 `CTRL.enable=1`，`MTIME` 仍会在该时钟沿自增；如果写入前旧 `CTRL.enable=0`，该时钟沿不自增。

### `STATUS` register

```text
31                                                1 0
+-------------------------------------------------+-+
| Reserved                                        |M|
+-------------------------------------------------+-+
```

bit 定义：

| bit | 名称 | 说明 |
|---:|---|---|
| 0 | `mtip` | `CTRL.enable && (MTIME >= MTIMECMP)`。 |
| 31:1 | reserved | 读 0。 |

timer interrupt 输出 `timer32_irq_o` 与 `STATUS.mtip` 同义，是 level 信号。只要 `CTRL.enable=1` 且 `MTIME >= MTIMECMP`，它就保持为 1；条件不成立时自动为 0。软件清 timer interrupt 的方式不是 acknowledge pending flop，而是让比较条件不成立，例如把 `MTIMECMP` 写到未来值，或关闭 `CTRL.enable`。

## 3. `mmio_uart`

`mmio_uart` 当前是教学用简化 UART MMIO 模型，不是真实串口物理层。TX 和 RX 都按单拍事件建模；当前没有 baud rate、起始位/停止位、采样、FIFO、busy/full 等真实串口逻辑。

后续如果把内部替换成真实串口收发状态机或 FIFO，应尽量保持 `TXDATA/STATUS/CTRL/RXDATA/IRQ_PENDING` 的软件可见语义，使 CPU core、SoC 中断控制和大部分驱动代码不需要感知 UART 内部实现变化。

`rx_valid_i/rx_data_i` 是已经在 `clk_i` 域内的单拍 RX event 接口，不是真实异步串口线。当前 `mmio_uart` 不对 `rx_data_i` 做逐 bit 两级同步；如果后续接真实 UART RX 或其它异步来源，应在 UART RX 前端、握手同步或异步 FIFO 中先转换到 `clk_i` 域，再送入当前寄存器层。

参数：

| 参数 | 说明 |
|---|---|
| `BASE_ADDR` | 外设实例基地址，用于计算寄存器 offset。 |

### UART 寄存器列表

| offset | 名称 | 属性 | reset | 副作用 | 说明 |
|---:|---|---|---:|---|---|
| `0x000` | `TXDATA` | `WO`* | `0x0000_0000` | 写入低 byte 可触发一拍 TX event。 | 发送数据写入口，低 8 bit 有效。 |
| `0x004` | `STATUS` | `RO`* | `0x0000_0001` | 被 `RXDATA` 读副作用影响。 | UART 状态寄存器。 |
| `0x008` | `CTRL` | `RW` | `0x0000_0000` | - | UART 控制寄存器。 |
| `0x00C` | `RXDATA` | `RO`* | `0x0000_0000` | 读出后清 `rx_valid` 和 `irq_pending`。 | 最近一次收到的 RX byte，低 8 bit 有效。 |
| `0x010` | `IRQ_PENDING` | `R/W1C`* | `0x0000_0000` | 被 `RXDATA` 读副作用影响；写 1 清 pending。 | RX interrupt pending。读本寄存器只观察。 |

### `TXDATA` register

`TXDATA[7:0]` 是发送字节。读 `TXDATA` 当前返回 0。

软件写 `TXDATA` 时，只有低 byte 被选中并且 `CTRL.tx_enable=1`，才会产生一拍 TX event。TX event 出现时，`tx_valid_o` 为 1，`tx_data_o` 是本次写入的低 8 bit。

如果 `CTRL.tx_enable=0`，写 `TXDATA` 不发送数据。当前简化模型没有发送 FIFO，也没有 busy/full 状态；`STATUS.tx_ready` 固定为 1。

### `STATUS` register

```text
31                                      3 2 1 0
+---------------------------------------+-+-+-+
| Reserved                              |P|R|T|
+---------------------------------------+-+-+-+
```

bit 定义：

| bit | 名称 | 说明 |
|---:|---|---|
| 0 | `tx_ready` | 当前固定为 1，表示简化 TX 总是可接收一个写入事件。 |
| 1 | `rx_valid` | 1 表示 `RXDATA` 中有尚未被读走的接收字节。 |
| 2 | `irq_pending` | `IRQ_PENDING[0]` 的只读镜像。 |
| 31:3 | reserved | 读 0。 |

读 `STATUS` 只观察状态，不清除 `rx_valid` 或 `irq_pending`。读 `RXDATA` 会影响后续 `STATUS.rx_valid` 和 `STATUS.irq_pending` 的值。

### `CTRL` register

```text
31                                      2 1 0
+---------------------------------------+-+-+
| Reserved                              |R|T|
+---------------------------------------+-+-+
```

bit 定义：

| bit | 名称 | 说明 |
|---:|---|---|
| 0 | `tx_enable` | 1 时，写 `TXDATA` 可产生 TX event；0 时，写 `TXDATA` 不发送。 |
| 1 | `rx_irq_enable` | 1 时，`IRQ_PENDING[0]` 会驱动 `uart_irq_o`；0 时仍可接收 RXDATA，但不输出 UART 中断。 |
| 31:2 | reserved | 软件写 0，读回值不应依赖。 |

### `RXDATA` register

`RXDATA[7:0]` 返回最近一次收到的 RX byte。读 `RXDATA` 会清 `STATUS.rx_valid` 和 `IRQ_PENDING[0]`。读 `RXDATA` 以外的寄存器不会清接收状态。

RX event 到达时，`RXDATA` 更新为新 byte，`STATUS.rx_valid` 置 1，`IRQ_PENDING[0]` 置 1。`IRQ_PENDING[0]` 的置位不受 `CTRL.rx_irq_enable` 门控；`rx_irq_enable` 只决定 pending 是否输出到 `uart_irq_o`。

如果旧 `RXDATA` 尚未被读走时又收到新的 RX event，当前第一版允许新字节覆盖旧字节，不提供 overflow 标志。软件测试应及时读取 `RXDATA`，或在后续真实 UART/FIFO 阶段补充容量和溢出状态。

同一时钟沿同时发生 `RXDATA` 读和 RX event 时，本次 load 返回读边沿前已经保存的 RX byte；边沿后新 RX byte 被保存，`STATUS.rx_valid` 和 `IRQ_PENDING[0]` 保持为 1。也就是说，RX event 对读清副作用有优先级。

### `IRQ_PENDING` register

`IRQ_PENDING[0]` 是 RX interrupt pending。读 `IRQ_PENDING` 本身只观察 pending，不清除。写 `IRQ_PENDING[0]=1` 清 pending；写 0 保持。写 `IRQ_PENDING` 只影响 pending，不清 `RXDATA`，也不清 `STATUS.rx_valid`。

同一时钟沿同时发生 `IRQ_PENDING` W1C 清除和 RX event 时，RX event 置位优先，`IRQ_PENDING[0]` 在该时钟沿后保持为 1。

UART interrupt 输出 `uart_irq_o` 是 level 信号。只要 `CTRL.rx_irq_enable=1` 且 `IRQ_PENDING[0]=1`，它就保持为 1。

# 补充说明：外设中断架构差异

GPIO、UART、TIMER32 的中断 pending/status/irq 架构不同，由各自的中断来源类型决定。

| | GPIO | UART | TIMER32 |
|--|------|------|---------|
| 中断来源 | 事件或电平条件，多 bit | RX 数据到达事件，单 bit | `MTIME >= MTIMECMP` 比较电平 |
| PENDING | `R/W1C`，触发条件经 `IRQ_EN` 门控后置位 | `R/W1C`，RX event 置位 | 无单独 pending flop |
| STATUS | `IRQ_PENDING & IRQ_EN` | `rx_valid` 和 pending 镜像 | 比较结果 |
| 清中断 | 写 `IRQ_PENDING` W1C | 读 `RXDATA` 或写 `IRQ_PENDING` W1C | 写 `MTIMECMP` 到未来值，或关闭 `CTRL.enable` |

GPIO 适合多 bit 独立中断源。软件通常读 `IRQ_STATUS` 确定待处理 bit，写 `IRQ_PENDING` acknowledge。由于 `IRQ_STATUS` 受 `IRQ_EN` mask，禁用某 bit 后该 bit 不再推动 `gpio_irq_o`，但已经置位的 `IRQ_PENDING` 仍可被软件读到并清除。

UART 当前只有 RX 一个中断源。`IRQ_PENDING[0]` 保存 RX pending，`STATUS.irq_pending` 是它的只读镜像。读 `RXDATA` 同时消费数据和清 pending；写 `IRQ_PENDING[0]=1` 只清 pending，适合软件只想撤销中断请求但保留 RXDATA 可读状态的场景。

TIMER32 的中断是连续比较结果，不是一闪而过的事件。条件成立则 `timer32_irq_o` 保持高，不成立则自动恢复低。软件清中断的方式是改变比较条件，不需要 acknowledge pending 寄存器。
