# MMIO 外设中断架构说明

GPIO/UART/TIMER0 三个外设的中断 pending/status/irq 架构不同，由各自的中断来源类型决定。

## 外设对比

| | GPIO | UART | TIMER0 |
|--|------|------|--------|
| 中断来源 | **事件**（引脚边沿/电平变化） | **事件**（RX 数据到达） | **电平**（MTIME ≥ MTIMECMP 比较） |
| PENDING | R/W1C，raw 事件 flop，不使能门控 | R/W1C，pending flop | **无**：连续比较无事件需要记录 |
| STATUS | RO，`PENDING & IRQ_EN`（已使能的视图） | RO，pending flop 的镜像 | RO，比较结果 `(MTIME ≥ MTIMECMP)` |
| 清中断 | 写 PENDING W1C | 读 RXDATA 或写 PENDING W1C | 写 MTIMECMP 使比较不成立 |

## GPIO：事件 + 多 bit，PENDING ≠ STATUS

GPIO 有 32 bit 的独立中断源。PENDING 记录 raw 事件（不受 IRQ_EN 影响），STATUS 是已使能的视图。软件读 STATUS 确定待处理 bit，写 PENDING 逐个 acknowledge。

## UART：事件 + 单 bit，PENDING = STATUS

UART 只有一个中断源（RX）。PENDING 和 STATUS 指向同一个 pending flop，只是访问地址不同（PENDING 用于 W1C 清除，STATUS 用于轮询）。IRQ 输出受 CTRL[1] 门控。

## TIMER0：电平，无 PENDING

TIMER0 的中断是连续比较结果 `enable && (MTIME ≥ MTIMECMP)`，不是一闪而过的事件。条件成立则 irq 保持高，不成立则自动恢复低。软件清中断的方式是写 MTIMECMP 到未来值，不需要 acknowledge 任何 flop。
