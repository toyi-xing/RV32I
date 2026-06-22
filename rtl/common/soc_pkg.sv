//------------------------------------------------------------------------------
// 文件      : rtl/common/soc_pkg.sv
// 用途      : RV32I 教学核的 soc 平台公共常量和类型定义。
//
// 规范：
//   - RTL 使用 SystemVerilog，优先采用 logic、always_comb、always_ff 风格。
//   - soc 平台 MMIO 地址分配集中放在这里，避免在核心里散落硬编码常量。
//------------------------------------------------------------------------------

package soc_pkg;

    // 当前平台的 MMIO 容量。ADDR_WIDTH 表示 32-bit word index 宽度。
    parameter int unsigned MMIO_ADDR_WIDTH = 14;

    // MMIO 起始地址与大小
    parameter logic [core_pkg::XLEN-1:0] MMIO_BASE       = 32'h0008_0000;
    parameter logic [core_pkg::XLEN-1:0] MMIO_SIZE_BYTES = 32'h0001_0000;

    //-----------------------------------------------
    // MMIO 外设寄存器地址分配
    //-----------------------------------------------

    // MMIO 子地址图：
    // | 区域 | 起始地址 | 结束地址 | 规划容量 |
    // |---|---:|---:|---:|
    // | GPIO window  | `0x0008_0000` | `0x0008_03FF` | 4 个 GPIO，每个 `0x100` |
    // | reserved     | `0x0008_0400` | `0x0008_0FFF` | GPIO 页内预留 |
    // | TIMER window | `0x0008_1000` | `0x0008_15FF` | 6 个 timer，每个 `0x100` |
    // | UART window  | `0x0008_2000` | `0x0008_25FF` | 6 个 UART，每个 `0x100` |
    // | reserved     | `0x0008_3000` | `0x0008_7FFF` | 后续普通外设扩展 |
    // | ACCEL window | `0x0008_8000` | `0x0008_BFFF` | 4 个 accelerator，每个 `0x1000` |
    // | reserved     | `0x0008_C000` | `0x0008_FFFF` | 后续大块扩展 |

    // GPIO 预留 4 个
    parameter logic [core_pkg::XLEN-1:0] GPIO_BASE          = 32'h0008_0000;
    parameter logic [core_pkg::XLEN-1:0] GPIO_SIZE_BYTES    = 32'h0000_0400;
    parameter logic [core_pkg::XLEN-1:0] GPIO_STRIDE        = 32'h0000_0100;
    parameter int unsigned               GPIO_NUM           = 4;
        // GPIO 外设的共有寄存器。
    parameter logic [11:0]               GPIO_OUT_OFFSET         = 12'h000;   // RW
    parameter logic [11:0]               GPIO_IN_OFFSET          = 12'h004;   // RO
    parameter logic [11:0]               GPIO_OE_OFFSET          = 12'h008;   // RW
    parameter logic [11:0]               GPIO_IRQ_EN_OFFSET      = 12'h00c;   // RW
    parameter logic [11:0]               GPIO_IRQ_RISE_EN_OFFSET = 12'h010;   // RW，上升沿中断使能
    parameter logic [11:0]               GPIO_IRQ_FALL_EN_OFFSET = 12'h014;   // RW，下降沿中断使能
    parameter logic [11:0]               GPIO_IRQ_HIGH_EN_OFFSET = 12'h018;   // RW，高电平中断使能
    parameter logic [11:0]               GPIO_IRQ_LOW_EN_OFFSET  = 12'h01c;   // RW，低电平中断使能
    parameter logic [11:0]               GPIO_IRQ_PENDING_OFFSET = 12'h020;   // R/W1C
    parameter logic [11:0]               GPIO_IRQ_STATUS_OFFSET  = 12'h024;   // RO，中断状态

    parameter logic [core_pkg::XLEN-1:0] GPIO0_BASE         = GPIO_BASE;
    parameter logic [core_pkg::XLEN-1:0] GPIO0_SIZE_BYTES   = GPIO_STRIDE;

    // TIMER 预留 6 个
    parameter logic [core_pkg::XLEN-1:0] TIMER_BASE         = 32'h0008_1000;
    parameter logic [core_pkg::XLEN-1:0] TIMER_SIZE_BYTES   = 32'h0000_0600;
    parameter logic [core_pkg::XLEN-1:0] TIMER_STRIDE       = 32'h0000_0100;
    parameter int unsigned               TIMER_NUM          = 6;

        // TIMER0 地址
    parameter logic [core_pkg::XLEN-1:0] TIMER0_BASE        = TIMER_BASE;
    parameter logic [core_pkg::XLEN-1:0] TIMER0_SIZE_BYTES  = TIMER_STRIDE;
        // TIMER0 寄存器
    parameter logic [11:0]               TIMER0_MTIME_OFFSET    = 12'h000;  // RW，计数值
    parameter logic [11:0]               TIMER0_MTIMECMP_OFFSET = 12'h004;  // RW，比较值
    parameter logic [11:0]               TIMER0_CTRL_OFFSET     = 12'h008;  // RW
    parameter int unsigned               TIMER0_CTRL_EN_BIT     = 0;        // CTRL[0] 定时器使能
    parameter logic [11:0]               TIMER0_STATUS_OFFSET   = 12'h00c;  // RO
    parameter int unsigned               TIMER0_STATUS_MTIP_BIT = 0;        // STATUS[0] 中断状态

    // UART 预留 6 个
    parameter logic [core_pkg::XLEN-1:0] UART_BASE          = 32'h0008_2000;
    parameter logic [core_pkg::XLEN-1:0] UART_SIZE_BYTES    = 32'h0000_0600;
    parameter logic [core_pkg::XLEN-1:0] UART_STRIDE        = 32'h0000_0100;
    parameter int unsigned               UART_NUM           = 6;
        // UART 外设的共有寄存器。
    parameter logic [11:0]               UART_TXDATA_OFFSET         = 12'h000;  // WO
    parameter logic [11:0]               UART_STATUS_OFFSET         = 12'h004;  // RO
    parameter int unsigned               UART_STATUS_TX_READY_BIT   = 0;        // STATUS[0] tx_ready（当前单拍发送，固定为 1）
    parameter int unsigned               UART_STATUS_RX_VALID_BIT   = 1;        // STATUS[1] rx_valid
    parameter int unsigned               UART_STATUS_IRQ_PENDING_BIT= 2;        // STATUS[2] irq_pending 是 IRQ_PENDING[0] 的只读镜像，二者恒等
    parameter logic [11:0]               UART_CTRL_OFFSET           = 12'h008;  // RW
    parameter int unsigned               UART_CTRL_TX_EN_BIT        = 0;        // CTRL[0] tx_enable
    parameter int unsigned               UART_CTRL_RX_IRQ_EN_BIT    = 1;        // CTRL[1] rx_irq_enable
    parameter logic [11:0]               UART_RXDATA_OFFSET         = 12'h00c;  // RO
    parameter logic [11:0]               UART_IRQ_PENDING_OFFSET    = 12'h010;  // R/W1C
    parameter int unsigned               UART_IRQ_PENDING_BIT       = 0;        // IRQ_PENDING[0]

    parameter logic [core_pkg::XLEN-1:0] UART0_BASE         = UART_BASE;
    parameter logic [core_pkg::XLEN-1:0] UART0_SIZE_BYTES   = UART_STRIDE;

    // ACCEL 预留 4 个
    parameter logic [core_pkg::XLEN-1:0] ACCEL_BASE         = 32'h0008_8000;
    parameter logic [core_pkg::XLEN-1:0] ACCEL_SIZE_BYTES   = 32'h0000_4000;
    parameter logic [core_pkg::XLEN-1:0] ACCEL_STRIDE       = 32'h0000_1000;
    parameter int unsigned               ACCEL_NUM          = 4;

    parameter logic [core_pkg::XLEN-1:0] ACCEL0_BASE        = ACCEL_BASE;
    parameter logic [core_pkg::XLEN-1:0] ACCEL0_SIZE_BYTES  = ACCEL_STRIDE;

endpackage