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
    parameter logic [11:0]               GPIO_OUT_OFFSET    = 12'h000;
    parameter logic [11:0]               GPIO_IN_OFFSET     = 12'h004;
    parameter logic [11:0]               GPIO_OE_OFFSET     = 12'h008;

    parameter logic [core_pkg::XLEN-1:0] GPIO0_BASE         = GPIO_BASE;
    parameter logic [core_pkg::XLEN-1:0] GPIO0_SIZE_BYTES   = GPIO_STRIDE;

    // TIMER 预留 6 个
    parameter logic [core_pkg::XLEN-1:0] TIMER_BASE         = 32'h0008_1000;
    parameter logic [core_pkg::XLEN-1:0] TIMER_SIZE_BYTES   = 32'h0000_0600;
    parameter logic [core_pkg::XLEN-1:0] TIMER_STRIDE       = 32'h0000_0100;
    parameter int unsigned               TIMER_NUM          = 6;

    parameter logic [core_pkg::XLEN-1:0] TIMER0_BASE        = TIMER_BASE;
    parameter logic [core_pkg::XLEN-1:0] TIMER0_SIZE_BYTES  = TIMER_STRIDE;

    // UART 预留 6 个
    parameter logic [core_pkg::XLEN-1:0] UART_BASE          = 32'h0008_2000;
    parameter logic [core_pkg::XLEN-1:0] UART_SIZE_BYTES    = 32'h0000_0600;
    parameter logic [core_pkg::XLEN-1:0] UART_STRIDE        = 32'h0000_0100;
    parameter int unsigned               UART_NUM           = 6;
        // UART 外设的共有寄存器。
    parameter logic [11:0]               UART_TXDATA_OFFSET = 12'h000;
    parameter logic [11:0]               UART_STATUS_OFFSET = 12'h004;
    parameter logic [11:0]               UART_CTRL_OFFSET   = 12'h008;

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