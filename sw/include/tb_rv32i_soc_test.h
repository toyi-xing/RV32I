#ifndef RV32I_TB_RV32I_SOC_TEST_H
#define RV32I_TB_RV32I_SOC_TEST_H

/*
 * include guard 防止本文件被重复展开。platform.h 也有自己的 guard，
 * 因此 C/ASM 测试可以同时 include platform.h 和本文件。
 */
#include "platform.h"
    
    /*
     * tb_rv32i_soc.sv 定向测试 mailbox。
     *
     * 这些地址是 testbench 约定，不是硬件 MMIO ABI。测试程序对这些地址发起
     * 普通 DMEM store，tb_rv32i_soc.sv 观察到后驱动外部激励。
     */
    #define TB_CMD_BASE              (DMEM_BASE + RV32I_U32_C(0x00000180))  /* mailbox 基地址，所有 TB 命令地址由此偏移。 */
    #define TB_GPIO0_SET_MASK_ADDR   (TB_CMD_BASE + RV32I_U32_C(0x00))  /* 写 mask，TB 驱动对应 GPIO 输入为高。 */
    #define TB_GPIO0_CLR_MASK_ADDR   (TB_CMD_BASE + RV32I_U32_C(0x04))  /* 写 mask，TB 驱动对应 GPIO 输入为低。 */
    #define TB_GPIO0_PULSE_CMD_ADDR  (TB_CMD_BASE + RV32I_U32_C(0x08))  /* 写 packed command，TB 在指定 GPIO 输入上产生脉冲。 */
    #define TB_UART0_RX_ADDR         (TB_CMD_BASE + RV32I_U32_C(0x0c))  /* 写 byte[7:0]，TB 向 UART0 注入一个 RX 字节。 */
    #define TB_RESP_DELAY_CFG0_ADDR  (TB_CMD_BASE + RV32I_U32_C(0x10))  /* 写 packed config，TB 配置四个 data response 延迟源。 */
    #define TB_RESP_DELAY_RESET_CFG  RV32I_U32_C(0x00000001)  /* 与 tb_rv32i_soc.sv 复位默认 delay config 保持一致。 */
    
    #define TB_GPIO0_FAST_PERIODIC_BIT   RV32I_U32_C(30)  /* 快速周期翻转 GPIO 的 bit 号。 */
    #define TB_GPIO0_SLOW_PERIODIC_BIT   RV32I_U32_C(31)  /* 慢速周期翻转 GPIO 的 bit 号。 */
    #define TB_GPIO0_FAST_PERIODIC_MASK  (RV32I_U32_C(1) << TB_GPIO0_FAST_PERIODIC_BIT)  /* 快速周期翻转 GPIO 的 bit mask。 */
    #define TB_GPIO0_SLOW_PERIODIC_MASK  (RV32I_U32_C(1) << TB_GPIO0_SLOW_PERIODIC_BIT)  /* 慢速周期翻转 GPIO 的 bit mask。 */
    
    /* tb_rv32i_soc.sv 固有周期输入。软件只使用这些常量识别 bit 和周期，不负责生成。 */
    #define TB_GPIO0_FAST_TOGGLE_CYCLES  RV32I_U32_C(200)  /* 快速周期翻转半周期拍数。 */
    #define TB_GPIO0_SLOW_TOGGLE_CYCLES  RV32I_U32_C(2000)  /* 慢速周期翻转半周期拍数。 */

    #ifndef __ASSEMBLER__

        #include <stdbool.h>
        
        /* 请求 TB 驱动 mask 中 1 对应的 GPIO0 输入拉高（其他 bit 不变）。
         * bit[31:30] 由 TB 固定驱动，软件写入自动清除。 */
        static inline void tb_gpio0_set_mask(uint32_t mask)
        {
            mask &= ~(TB_GPIO0_FAST_PERIODIC_MASK | TB_GPIO0_SLOW_PERIODIC_MASK);
            mmio_write32(TB_GPIO0_SET_MASK_ADDR, mask);
        }
        
        /* 请求 TB 驱动 mask 中 1 对应的 GPIO0 输入拉低（其他 bit 不变）。
         * bit[31:30] 由 TB 固定驱动，软件写入自动清除。 */
        static inline void tb_gpio0_clear_mask(uint32_t mask)
        {
            mask &= ~(TB_GPIO0_FAST_PERIODIC_MASK | TB_GPIO0_SLOW_PERIODIC_MASK);
            mmio_write32(TB_GPIO0_CLR_MASK_ADDR, mask);
        }
        
        /* 在 gpio_idx bit 上产生脉冲。pulse_level = 1 高脉冲、0 低脉冲，
         * pulse_cycles 为持续拍数。按 packed command 格式打包后写
         * TB_GPIO0_PULSE_CMD_ADDR。bit[31:30] 由 TB 固定驱动，不允许脉冲。 */
        static inline void tb_gpio0_pulse(uint32_t gpio_idx, uint8_t pulse_cycles, bool pulse_level)
        {
            if (gpio_idx == TB_GPIO0_FAST_PERIODIC_BIT ||
                gpio_idx == TB_GPIO0_SLOW_PERIODIC_BIT) {
                return;
            }
            uint32_t cmd = ((pulse_cycles & 0xffu) << 16)
                         | ((pulse_level  & 0x01u) <<  8)
                         | ( gpio_idx     & 0x1fu);
            mmio_write32(TB_GPIO0_PULSE_CMD_ADDR, cmd);
        }
        
        /* 请求 TB 向 UART0 注入一个 RX 字节。 */
        static inline void tb_uart0_rx(uint8_t data)
        {
            mmio_write32(TB_UART0_RX_ADDR, (uint32_t)data);
        }

        /*
         * 打包单个 response delay 配置字节。
         *
         * random_en = false 时为固定延迟模式，cycles_or_max[6:0] 是固定延迟拍数。
         * random_en = true  时为随机延迟模式，cycles_or_max[6:0] 是随机上限，
         * TB 会为后续 transaction 生成 0..cycles_or_max 的具体延迟拍数。
         */
        static inline uint8_t tb_pack_resp_delay_cfg(bool random_en, uint8_t cycles_or_max)
        {
            return (uint8_t)((random_en ? 0x80u : 0x00u) | (cycles_or_max & 0x7fu));
        }

        /*
         * response delay 配置 shadow。
         *
         * TB_RESP_DELAY_CFG0_ADDR 是只写 mailbox 命令，不是真实可读寄存器。
         * 因此单独配置某一个 target 时，软件侧用 shadow 保留其他 target 的
         * 最近配置，再写回完整 32-bit packed config。
         */
        static inline uint32_t *tb_resp_delay_cfg0_shadow_ptr(void)
        {
            static uint32_t cfg = TB_RESP_DELAY_RESET_CFG;
            return &cfg;
        }

        /* 同时配置 DMEM/GPIO0/UART0/TIMER0 四个 response delay 源。 */
        static inline void tb_set_resp_delay(bool dmem_random_en,   uint8_t dmem_cycles_or_max,
                                             bool gpio0_random_en,  uint8_t gpio0_cycles_or_max,
                                             bool uart0_random_en,  uint8_t uart0_cycles_or_max,
                                             bool timer0_random_en, uint8_t timer0_cycles_or_max)
        {
            uint32_t cfg = ((uint32_t)tb_pack_resp_delay_cfg(dmem_random_en,   dmem_cycles_or_max)       )
                         | ((uint32_t)tb_pack_resp_delay_cfg(gpio0_random_en,  gpio0_cycles_or_max)  <<  8)
                         | ((uint32_t)tb_pack_resp_delay_cfg(uart0_random_en,  uart0_cycles_or_max)  << 16)
                         | ((uint32_t)tb_pack_resp_delay_cfg(timer0_random_en, timer0_cycles_or_max) << 24);
            *tb_resp_delay_cfg0_shadow_ptr() = cfg;
            mmio_write32(TB_RESP_DELAY_CFG0_ADDR, cfg);
        }

        /* 只配置 DMEM response delay，不改变 GPIO0/UART0/TIMER0 的当前配置。 */
        static inline void tb_set_dmem_resp_delay(bool random_en, uint8_t cycles_or_max)
        {
            uint32_t cfg = (*tb_resp_delay_cfg0_shadow_ptr() & ~UINT32_C(0x000000ff))
                         |  (uint32_t)tb_pack_resp_delay_cfg(random_en, cycles_or_max);
            *tb_resp_delay_cfg0_shadow_ptr() = cfg;
            mmio_write32(TB_RESP_DELAY_CFG0_ADDR, cfg);
        }

        /* 只配置 GPIO0 response delay，不改变 DMEM/UART0/TIMER0 的当前配置。 */
        static inline void tb_set_gpio0_resp_delay(bool random_en, uint8_t cycles_or_max)
        {
            uint32_t cfg = (*tb_resp_delay_cfg0_shadow_ptr() & ~UINT32_C(0x0000ff00))
                         | ((uint32_t)tb_pack_resp_delay_cfg(random_en, cycles_or_max) << 8);
            *tb_resp_delay_cfg0_shadow_ptr() = cfg;
            mmio_write32(TB_RESP_DELAY_CFG0_ADDR, cfg);
        }

        /* 只配置 UART0 response delay，不改变 DMEM/GPIO0/TIMER0 的当前配置。 */
        static inline void tb_set_uart0_resp_delay(bool random_en, uint8_t cycles_or_max)
        {
            uint32_t cfg = (*tb_resp_delay_cfg0_shadow_ptr() & ~UINT32_C(0x00ff0000))
                         | ((uint32_t)tb_pack_resp_delay_cfg(random_en, cycles_or_max) << 16);
            *tb_resp_delay_cfg0_shadow_ptr() = cfg;
            mmio_write32(TB_RESP_DELAY_CFG0_ADDR, cfg);
        }

        /* 只配置 TIMER0 response delay，不改变 DMEM/GPIO0/UART0 的当前配置。 */
        static inline void tb_set_timer0_resp_delay(bool random_en, uint8_t cycles_or_max)
        {
            uint32_t cfg = (*tb_resp_delay_cfg0_shadow_ptr() & ~UINT32_C(0xff000000))
                         | ((uint32_t)tb_pack_resp_delay_cfg(random_en, cycles_or_max) << 24);
            *tb_resp_delay_cfg0_shadow_ptr() = cfg;
            mmio_write32(TB_RESP_DELAY_CFG0_ADDR, cfg);
        }
        
    #endif  // __ASSEMBLER__

#endif
