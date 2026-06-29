# Copyright (C) 1991-2013 Altera Corporation
# Your use of Altera Corporation's design tools, logic functions 
# and other software and tools, and its AMPP partner logic 
# functions, and any output files from any of the foregoing 
# (including device programming or simulation files), and any 
# associated documentation or information are expressly subject 
# to the terms and conditions of the Altera Program License 
# Subscription Agreement, Altera MegaCore Function License 
# Agreement, or other applicable license agreement, including, 
# without limitation, that your use is for the sole purpose of 
# programming logic devices manufactured by Altera and sold by 
# Altera or its authorized distributors.  Please refer to the 
# applicable agreement for further details.

# Quartus II 64-Bit Version 13.1.0 Build 162 10/23/2013 SJ Full Version
# Generated on: Sun Apr 11 20:36:59 2021

package require ::quartus::project
#时钟复位
set_location_assignment PIN_E1 -to sys_clk
set_location_assignment PIN_M1 -to sys_rst_n
#LED灯
set_location_assignment PIN_B5 -to led[1]
set_location_assignment PIN_A4 -to led[0]
#按键
set_location_assignment PIN_E15 -to key[1]
set_location_assignment PIN_E16 -to key[0]
#SDRAM
set_location_assignment PIN_B14 -to sdram_clk
set_location_assignment PIN_G11 -to sdram_ba[0]
set_location_assignment PIN_F13 -to sdram_ba[1]
set_location_assignment PIN_J12 -to sdram_cas_n
set_location_assignment PIN_F16 -to sdram_cke
set_location_assignment PIN_K11 -to sdram_ras_n
set_location_assignment PIN_J13 -to sdram_we_n
set_location_assignment PIN_K10 -to sdram_cs_n
set_location_assignment PIN_J14 -to sdram_dqm[0]
set_location_assignment PIN_G15 -to sdram_dqm[1]
set_location_assignment PIN_F11 -to sdram_addr[0]
set_location_assignment PIN_E11 -to sdram_addr[1]
set_location_assignment PIN_D14 -to sdram_addr[2]
set_location_assignment PIN_C14 -to sdram_addr[3]
set_location_assignment PIN_A14 -to sdram_addr[4]
set_location_assignment PIN_A15 -to sdram_addr[5]
set_location_assignment PIN_B16 -to sdram_addr[6]
set_location_assignment PIN_C15 -to sdram_addr[7]
set_location_assignment PIN_C16 -to sdram_addr[8]
set_location_assignment PIN_D15 -to sdram_addr[9]
set_location_assignment PIN_F14 -to sdram_addr[10]
set_location_assignment PIN_D16 -to sdram_addr[11]
set_location_assignment PIN_F15 -to sdram_addr[12]
set_location_assignment PIN_P14 -to sdram_data[0]
set_location_assignment PIN_M12 -to sdram_data[1]
set_location_assignment PIN_N14 -to sdram_data[2]
set_location_assignment PIN_L12 -to sdram_data[3]
set_location_assignment PIN_L13 -to sdram_data[4]
set_location_assignment PIN_L14 -to sdram_data[5]
set_location_assignment PIN_L11 -to sdram_data[6]
set_location_assignment PIN_K12 -to sdram_data[7]
set_location_assignment PIN_G16 -to sdram_data[8]
set_location_assignment PIN_J11 -to sdram_data[9]
set_location_assignment PIN_J16 -to sdram_data[10]
set_location_assignment PIN_J15 -to sdram_data[11]
set_location_assignment PIN_K16 -to sdram_data[12]
set_location_assignment PIN_K15 -to sdram_data[13]
set_location_assignment PIN_L16 -to sdram_data[14]
set_location_assignment PIN_L15 -to sdram_data[15]
#LCD显示屏
set_location_assignment PIN_P1 -to lcd_bl
set_location_assignment PIN_J6 -to lcd_de
set_location_assignment PIN_N1 -to lcd_hs
set_location_assignment PIN_N2 -to lcd_vs
set_location_assignment PIN_T2 -to lcd_rst
set_location_assignment PIN_L2 -to lcd_pclk
set_location_assignment PIN_A2 -to lcd_rgb[23]
set_location_assignment PIN_D4 -to lcd_rgb[22]
set_location_assignment PIN_B3 -to lcd_rgb[21]
set_location_assignment PIN_C2 -to lcd_rgb[20]
set_location_assignment PIN_A3 -to lcd_rgb[19]
set_location_assignment PIN_C3 -to lcd_rgb[18]
set_location_assignment PIN_B4 -to lcd_rgb[17]
set_location_assignment PIN_D5 -to lcd_rgb[16]
set_location_assignment PIN_G5 -to lcd_rgb[15]
set_location_assignment PIN_F5 -to lcd_rgb[14]
set_location_assignment PIN_F3 -to lcd_rgb[13]
set_location_assignment PIN_F2 -to lcd_rgb[12]
set_location_assignment PIN_E5 -to lcd_rgb[11]
set_location_assignment PIN_D1 -to lcd_rgb[10]
set_location_assignment PIN_D3 -to lcd_rgb[9]
set_location_assignment PIN_B1 -to lcd_rgb[8]
set_location_assignment PIN_L1 -to lcd_rgb[7]
set_location_assignment PIN_K2 -to lcd_rgb[6]
set_location_assignment PIN_K1 -to lcd_rgb[5]
set_location_assignment PIN_J2 -to lcd_rgb[4]
set_location_assignment PIN_J1 -to lcd_rgb[3]
set_location_assignment PIN_G1 -to lcd_rgb[2]
set_location_assignment PIN_G2 -to lcd_rgb[1]
set_location_assignment PIN_L7 -to lcd_rgb[0]
#双目摄像头
set_location_assignment PIN_K8 -to cam0_data[7]
set_location_assignment PIN_P9 -to cam0_data[6]
set_location_assignment PIN_L8 -to cam0_data[5]
set_location_assignment PIN_M8 -to cam0_data[4]
set_location_assignment PIN_N8 -to cam0_data[3]
set_location_assignment PIN_P8 -to cam0_data[2]
set_location_assignment PIN_M7 -to cam0_data[1]
set_location_assignment PIN_M6 -to cam0_data[0]
set_location_assignment PIN_N5 -to cam0_href
set_location_assignment PIN_L10 -to cam0_pclk
set_location_assignment PIN_P11 -to cam0_pwdn
set_location_assignment PIN_P6 -to  cam0_rst_n
set_location_assignment PIN_T11 -to cam0_scl
set_location_assignment PIN_N6 -to  cam0_sda
set_location_assignment PIN_R11 -to cam0_vsync
set_location_assignment PIN_N15 -to cam1_data[7]
set_location_assignment PIN_P16 -to cam1_data[6]
set_location_assignment PIN_R16 -to cam1_data[5]
set_location_assignment PIN_T15 -to cam1_data[4]
set_location_assignment PIN_T14 -to cam1_data[3]
set_location_assignment PIN_R13 -to cam1_data[2]
set_location_assignment PIN_T13 -to cam1_data[1]
set_location_assignment PIN_R12 -to cam1_data[0]
set_location_assignment PIN_R14 -to cam1_href
set_location_assignment PIN_N16 -to cam1_pclk
set_location_assignment PIN_M11 -to cam1_pwdn
set_location_assignment PIN_T12 -to cam1_rst_n
set_location_assignment PIN_N13 -to cam1_scl
set_location_assignment PIN_P15 -to cam1_sda
set_location_assignment PIN_N12 -to cam1_vsync
#交通灯
set_location_assignment PIN_N16 -to led[5]
set_location_assignment PIN_N15 -to led[2]
set_location_assignment PIN_P16 -to led[4]
set_location_assignment PIN_R16 -to led[1]
set_location_assignment PIN_T15 -to led[3]
set_location_assignment PIN_T14 -to led[0]
set_location_assignment PIN_E1 -to sys_clk
set_location_assignment PIN_M1 -to sys_rst_n
set_location_assignment PIN_R13 -to seg_led[0]
set_location_assignment PIN_T13 -to seg_led[1]
set_location_assignment PIN_R12 -to seg_led[2]
set_location_assignment PIN_T12 -to seg_led[3]
set_location_assignment PIN_P15 -to seg_led[4]
set_location_assignment PIN_R14 -to seg_led[5]
set_location_assignment PIN_N13 -to seg_led[6]
set_location_assignment PIN_N12 -to seg_led[7]
set_location_assignment PIN_M11 -to sel[0]
set_location_assignment PIN_P11 -to sel[1]
set_location_assignment PIN_L10 -to sel[2]
set_location_assignment PIN_K8 -to sel[3]
#串口
set_location_assignment PIN_B13 -to uart_rxd
set_location_assignment PIN_A13 -to uart_txd
#ADDA
set_location_assignment PIN_N16 -to ad_data[0]
set_location_assignment PIN_N15 -to ad_data[1]
set_location_assignment PIN_P16 -to ad_data[2]
set_location_assignment PIN_R16 -to ad_data[3]
set_location_assignment PIN_T15 -to ad_data[4]
set_location_assignment PIN_T14 -to ad_data[5]
set_location_assignment PIN_R13 -to ad_data[6]
set_location_assignment PIN_T13 -to ad_data[7]
set_location_assignment PIN_R12 -to ad_otr
set_location_assignment PIN_T12 -to ad_clk
set_location_assignment PIN_R14 -to da_clk
set_location_assignment PIN_N13 -to da_data[7]
set_location_assignment PIN_N12 -to da_data[6]
set_location_assignment PIN_M11 -to da_data[5]
set_location_assignment PIN_P11 -to da_data[4]
set_location_assignment PIN_L10 -to da_data[3]
set_location_assignment PIN_K8 -to da_data[2]
set_location_assignment PIN_P9 -to da_data[1]
set_location_assignment PIN_L8 -to da_data[0]
#双路DA
set_location_assignment PIN_N15 -to da_clk
set_location_assignment PIN_P16 -to da_data[9]
set_location_assignment PIN_R16 -to da_data[8]
set_location_assignment PIN_T15 -to da_data[7]
set_location_assignment PIN_T14 -to da_data[6]
set_location_assignment PIN_R13 -to da_data[5]
set_location_assignment PIN_T13 -to da_data[4]
set_location_assignment PIN_R12 -to da_data[3]
set_location_assignment PIN_T12 -to da_data[2]
set_location_assignment PIN_P15 -to da_data[1]
set_location_assignment PIN_R14 -to da_data[0]
set_location_assignment PIN_P11 -to da_clk1
set_location_assignment PIN_L10 -to da_data1[9]
set_location_assignment PIN_K8 -to da_data1[8]
set_location_assignment PIN_P9 -to da_data1[7]
set_location_assignment PIN_L8 -to da_data1[6]
set_location_assignment PIN_M8 -to da_data1[5]
set_location_assignment PIN_N8 -to da_data1[4]
set_location_assignment PIN_P8 -to da_data1[3]
set_location_assignment PIN_M7 -to da_data1[2]
set_location_assignment PIN_M6 -to da_data1[1]
set_location_assignment PIN_P6 -to da_data1[0]
#双路AD
set_location_assignment PIN_N15 -to ad0_data[0]
set_location_assignment PIN_N16 -to ad0_data[1]
set_location_assignment PIN_R16 -to ad0_data[2]
set_location_assignment PIN_P16 -to ad0_data[3]
set_location_assignment PIN_T14 -to ad0_data[4]
set_location_assignment PIN_T15 -to ad0_data[5]
set_location_assignment PIN_T13 -to ad0_data[6]
set_location_assignment PIN_R13 -to ad0_data[7]
set_location_assignment PIN_T12 -to ad0_data[8]
set_location_assignment PIN_R12 -to ad0_data[9]
set_location_assignment PIN_P15 -to ad0_oe
set_location_assignment PIN_R14 -to ad0_otr
set_location_assignment PIN_N12 -to ad0_clk
set_location_assignment PIN_P11 -to ad1_data[0]
set_location_assignment PIN_M11 -to ad1_data[1]
set_location_assignment PIN_K8 -to ad1_data[2]
set_location_assignment PIN_L10 -to ad1_data[3]
set_location_assignment PIN_L8 -to ad1_data[4]
set_location_assignment PIN_P9 -to ad1_data[5]
set_location_assignment PIN_N8 -to ad1_data[6]
set_location_assignment PIN_M8 -to ad1_data[7]
set_location_assignment PIN_M7 -to ad1_data[8]
set_location_assignment PIN_P8 -to ad1_data[9]
set_location_assignment PIN_M6 -to ad1_oe
set_location_assignment PIN_P6 -to ad1_otr
set_location_assignment PIN_N5 -to ad1_clk
























