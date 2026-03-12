/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ALSA SoC Texas Instruments TAS6754 Quad-Channel Audio Amplifier
 *
 * Copyright (C) 2026 Texas Instruments Incorporated - https://www.ti.com/
 *	Author: Sen Wang <sen@ti.com>
 */

#ifndef __TAS6754_H__
#define __TAS6754_H__

/*
 * Book 0, Page 0 — Register Addresses
 */

#define TAS6754_PAGE_SIZE                    256
#define TAS6754_PAGE_REG(page, reg)  ((page) * TAS6754_PAGE_SIZE + (reg))

/* Page Control & Basic Config */
#define TAS6754_PAGE_CTRL_REG                0x00
#define TAS6754_RESET_REG                    0x01
#define TAS6754_OUTPUT_CTRL_REG              0x02
#define TAS6754_STATE_CTRL_CH1_CH2_REG       0x03
#define TAS6754_STATE_CTRL_CH3_CH4_REG       0x04
#define TAS6754_ISENSE_CTRL_REG              0x05
#define TAS6754_DC_DETECT_CTRL_REG           0x06

/* Serial Audio Port */
#define TAS6754_SCLK_INV_CTRL_REG            0x20
#define TAS6754_AUDIO_IF_CTRL_REG            0x21
#define TAS6754_SDIN_CTRL_REG                0x23
#define TAS6754_SDOUT_CTRL_REG               0x25
#define TAS6754_SDIN_OFFSET_MSB_REG          0x27
#define TAS6754_SDIN_AUDIO_OFFSET_REG        0x28
#define TAS6754_SDIN_LL_OFFSET_REG           0x29
#define TAS6754_SDIN_CH_SWAP_REG             0x2A
#define TAS6754_SDOUT_OFFSET_MSB_REG         0x2C
#define TAS6754_VPREDICT_OFFSET_REG          0x2D
#define TAS6754_ISENSE_OFFSET_REG            0x2E
#define TAS6754_SDOUT_EN_REG                 0x31
#define TAS6754_LL_EN_REG                    0x32

/* DSP & Core Audio Control */
#define TAS6754_RTLDG_EN_REG                 0x37
#define TAS6754_DC_BLOCK_BYP_REG             0x39
#define TAS6754_DSP_CTRL_REG                 0x3A
#define TAS6754_PAGE_AUTO_INC_REG            0x3B

/* Volume & Mute */
#define TAS6754_DIG_VOL_CH1_REG              0x40
#define TAS6754_DIG_VOL_CH2_REG              0x41
#define TAS6754_DIG_VOL_CH3_REG              0x42
#define TAS6754_DIG_VOL_CH4_REG              0x43
#define TAS6754_DIG_VOL_RAMP_CTRL_REG        0x44
#define TAS6754_DIG_VOL_COMBINE_CTRL_REG     0x46
#define TAS6754_AUTO_MUTE_EN_REG             0x47
#define TAS6754_AUTO_MUTE_TIMING_CH1_CH2_REG 0x48
#define TAS6754_AUTO_MUTE_TIMING_CH3_CH4_REG 0x49

/* Analog Gain & Power Stage */
#define TAS6754_ANALOG_GAIN_CH1_CH2_REG      0x4A
#define TAS6754_ANALOG_GAIN_CH3_CH4_REG      0x4B
#define TAS6754_ANALOG_GAIN_RAMP_CTRL_REG    0x4E
#define TAS6754_PULSE_INJECTION_EN_REG       0x52
#define TAS6754_CBC_CTRL_REG                 0x54
#define TAS6754_CURRENT_LIMIT_CTRL_REG       0x55
#define TAS6754_DAC_CLK_REG                  0x5A
#define TAS6754_ISENSE_CAL_REG               0x5B

/* Spread Spectrum & PWM Phase */
#define TAS6754_PWM_PHASE_CTRL_REG           0x60
#define TAS6754_SS_CTRL_REG                  0x61
#define TAS6754_SS_RANGE_CTRL_REG            0x62
#define TAS6754_SS_DWELL_CTRL_REG            0x66
#define TAS6754_RAMP_PHASE_CTRL_GPO_REG      0x68
#define TAS6754_PWM_PHASE_M_CTRL_CH1_REG     0x69
#define TAS6754_PWM_PHASE_M_CTRL_CH2_REG     0x6A
#define TAS6754_PWM_PHASE_M_CTRL_CH3_REG     0x6B
#define TAS6754_PWM_PHASE_M_CTRL_CH4_REG     0x6C

/* Status & Reporting */
#define TAS6754_AUTO_MUTE_STATUS_REG         0x71
#define TAS6754_STATE_REPORT_CH1_CH2_REG     0x72
#define TAS6754_STATE_REPORT_CH3_CH4_REG     0x73
#define TAS6754_PVDD_SENSE_REG               0x74
#define TAS6754_TEMP_GLOBAL_REG              0x75
#define TAS6754_FS_MON_REG                   0x76
#define TAS6754_SCLK_MON_REG                 0x77
#define TAS6754_REPORT_ROUTING_1_REG         0x7C

/* Memory Paging & Book Control */
#define TAS6754_SETUP_REG1                   0x7D
#define TAS6754_SETUP_REG2                   0x7E
#define TAS6754_BOOK_CTRL_REG                0x7F

/* Fault Status */
#define TAS6754_POWER_FAULT_STATUS_1_REG     0x7D
#define TAS6754_POWER_FAULT_STATUS_2_REG     0x80
#define TAS6754_OT_FAULT_REG                 0x81
#define TAS6754_OTW_STATUS_REG               0x82
#define TAS6754_CLIP_WARN_STATUS_REG         0x83
#define TAS6754_CBC_WARNING_STATUS_REG       0x85

/* Latched Fault Registers */
#define TAS6754_POWER_FAULT_LATCHED_REG      0x86
#define TAS6754_OTSD_LATCHED_REG             0x87
#define TAS6754_OTW_LATCHED_REG              0x88
#define TAS6754_CLIP_WARN_LATCHED_REG        0x89
#define TAS6754_CLK_FAULT_LATCHED_REG        0x8A
#define TAS6754_RTLDG_OL_SL_FAULT_LATCHED_REG 0x8B
#define TAS6754_CBC_FAULT_WARN_LATCHED_REG   0x8D
#define TAS6754_OC_DC_FAULT_LATCHED_REG      0x8E
#define TAS6754_OTSD_RECOVERY_EN_REG         0x8F

/* Protection & Routing Controls */
#define TAS6754_REPORT_ROUTING_2_REG         0x90
#define TAS6754_REPORT_ROUTING_3_REG         0x91
#define TAS6754_REPORT_ROUTING_4_REG         0x92
#define TAS6754_CLIP_DETECT_CTRL_REG         0x93
#define TAS6754_REPORT_ROUTING_5_REG         0x94

/* GPIO Pin Configuration */
#define TAS6754_GPIO1_OUTPUT_SEL_REG         0x95
#define TAS6754_GPIO2_OUTPUT_SEL_REG         0x96
#define TAS6754_GPIO_INPUT_SLEEP_HIZ_REG     0x9B
#define TAS6754_GPIO_INPUT_PLAY_SLEEP_REG    0x9C
#define TAS6754_GPIO_INPUT_MUTE_REG          0x9D
#define TAS6754_GPIO_INPUT_SYNC_REG          0x9E
#define TAS6754_GPIO_INPUT_SDIN2_REG         0x9F
#define TAS6754_GPIO_CTRL_REG                0xA0
#define TAS6754_GPIO_INVERT_REG              0xA1

/* Load Diagnostics Config */
#define TAS6754_DC_LDG_CTRL_REG              0xB0
#define TAS6754_DC_LDG_LO_CTRL_REG           0xB1
#define TAS6754_DC_LDG_TIME_CTRL_REG         0xB2
#define TAS6754_DC_LDG_SL_CH1_CH2_CTRL_REG   0xB3
#define TAS6754_DC_LDG_SL_CH3_CH4_CTRL_REG   0xB4
#define TAS6754_AC_LDG_CTRL_REG              0xB5
#define TAS6754_TWEETER_DETECT_CTRL_REG      0xB6
#define TAS6754_TWEETER_DETECT_THRESH_REG    0xB7
#define TAS6754_AC_LDG_FREQ_CTRL_REG         0xB8
#define TAS6754_TEMP_CH1_CH2_REG             0xBB
#define TAS6754_TEMP_CH3_CH4_REG             0xBC
#define TAS6754_WARN_OT_MAX_FLAG_REG         0xBD

/* DC Load Diagnostic Reports */
#define TAS6754_DC_LDG_REPORT_CH1_CH2_REG    0xC0
#define TAS6754_DC_LDG_REPORT_CH3_CH4_REG    0xC1
#define TAS6754_DC_LDG_RESULT_REG            0xC2
#define TAS6754_AC_LDG_REPORT_CH1_R_REG      0xC3
#define TAS6754_AC_LDG_REPORT_CH1_I_REG      0xC4
#define TAS6754_AC_LDG_REPORT_CH2_R_REG      0xC5
#define TAS6754_AC_LDG_REPORT_CH2_I_REG      0xC6
#define TAS6754_AC_LDG_REPORT_CH3_R_REG      0xC7
#define TAS6754_AC_LDG_REPORT_CH3_I_REG      0xC8
#define TAS6754_AC_LDG_REPORT_CH4_R_REG      0xC9
#define TAS6754_AC_LDG_REPORT_CH4_I_REG      0xCA
#define TAS6754_TWEETER_REPORT_REG           0xCB

/* RTLDG Impedance */
#define TAS6754_CH1_RTLDG_IMP_MSB_REG        0xD1
#define TAS6754_CH1_RTLDG_IMP_LSB_REG        0xD2
#define TAS6754_CH2_RTLDG_IMP_MSB_REG        0xD3
#define TAS6754_CH2_RTLDG_IMP_LSB_REG        0xD4
#define TAS6754_CH3_RTLDG_IMP_MSB_REG        0xD5
#define TAS6754_CH3_RTLDG_IMP_LSB_REG        0xD6
#define TAS6754_CH4_RTLDG_IMP_MSB_REG        0xD7
#define TAS6754_CH4_RTLDG_IMP_LSB_REG        0xD8

/* DC Load Diagnostic Resistance */
#define TAS6754_DC_LDG_DCR_MSB_REG           0xD9
#define TAS6754_CH1_DC_LDG_DCR_LSB_REG       0xDA
#define TAS6754_CH2_DC_LDG_DCR_LSB_REG       0xDB
#define TAS6754_CH3_DC_LDG_DCR_LSB_REG       0xDC
#define TAS6754_CH4_DC_LDG_DCR_LSB_REG       0xDD

/* Over-Temperature Warning */
#define TAS6754_OTW_CTRL_CH1_CH2_REG         0xE2
#define TAS6754_OTW_CTRL_CH3_CH4_REG         0xE3

/* RESET_REG (all bits auto-clear) */
#define TAS6754_DEVICE_RESET                 BIT(4)
#define TAS6754_FAULT_CLEAR                  BIT(3)
#define TAS6754_REGISTER_RESET               BIT(0)

/* STATE_CTRL and STATE_REPORT — Channel state values */
#define TAS6754_STATE_DEEPSLEEP              0x00
#define TAS6754_STATE_LOAD_DIAG              0x01
#define TAS6754_STATE_SLEEP                  0x02
#define TAS6754_STATE_HIZ                    0x03
#define TAS6754_STATE_PLAY                   0x04

/* Additional STATE_REPORT values */
#define TAS6754_STATE_FAULT                  0x05
#define TAS6754_STATE_AUTOREC                0x06

/* Combined values for both channel pairs in one register */
#define TAS6754_STATE_DEEPSLEEP_BOTH         ((TAS6754_STATE_DEEPSLEEP << 4) | TAS6754_STATE_DEEPSLEEP)
#define TAS6754_STATE_LOAD_DIAG_BOTH         ((TAS6754_STATE_LOAD_DIAG << 4) | TAS6754_STATE_LOAD_DIAG)
#define TAS6754_STATE_SLEEP_BOTH             ((TAS6754_STATE_SLEEP << 4) | TAS6754_STATE_SLEEP)
#define TAS6754_STATE_HIZ_BOTH               ((TAS6754_STATE_HIZ << 4) | TAS6754_STATE_HIZ)
#define TAS6754_STATE_PLAY_BOTH              ((TAS6754_STATE_PLAY << 4) | TAS6754_STATE_PLAY)
#define TAS6754_STATE_FAULT_BOTH             ((TAS6754_STATE_FAULT << 4) | TAS6754_STATE_FAULT)

/* SCLK_INV_CTRL_REG */
#define TAS6754_SCLK_INV_TX_BIT             BIT(5)
#define TAS6754_SCLK_INV_RX_BIT             BIT(4)
#define TAS6754_SCLK_INV_MASK               (TAS6754_SCLK_INV_TX_BIT | TAS6754_SCLK_INV_RX_BIT)

/* AUDIO_IF_CTRL_REG */
#define TAS6754_TDM_EN_BIT                   BIT(4)
#define TAS6754_SAP_FMT_MASK                 GENMASK(3, 2)
#define TAS6754_SAP_FMT_I2S                  (0x00 << 2)
#define TAS6754_SAP_FMT_TDM                  (0x01 << 2)
#define TAS6754_SAP_FMT_RIGHT_J              (0x02 << 2)
#define TAS6754_SAP_FMT_LEFT_J               (0x03 << 2)
#define TAS6754_FS_PULSE_MASK                GENMASK(1, 0)
#define TAS6754_FS_PULSE_SHORT               0x01

/* SDIN_CTRL_REG */
#define TAS6754_SDIN_AUDIO_WL_MASK           GENMASK(3, 2)
#define TAS6754_SDIN_LL_WL_MASK              GENMASK(1, 0)
#define TAS6754_SDIN_WL_MASK                 (TAS6754_SDIN_AUDIO_WL_MASK | TAS6754_SDIN_LL_WL_MASK)

/* SDOUT_CTRL_REG */
#define TAS6754_SDOUT_SELECT_MASK            GENMASK(7, 4)
#define TAS6754_SDOUT_SELECT_TDM_SDOUT1      0x00
#define TAS6754_SDOUT_SELECT_NON_TDM         0x10
#define TAS6754_SDOUT_VP_WL_MASK             GENMASK(3, 2)
#define TAS6754_SDOUT_IS_WL_MASK             GENMASK(1, 0)
#define TAS6754_SDOUT_WL_MASK                (TAS6754_SDOUT_VP_WL_MASK | TAS6754_SDOUT_IS_WL_MASK)

/* Word length values (shared by SDIN_CTRL and SDOUT_CTRL) */
#define TAS6754_WL_16BIT                     0x00
#define TAS6754_WL_20BIT                     0x01
#define TAS6754_WL_24BIT                     0x02
#define TAS6754_WL_32BIT                     0x03

/* SDIN_OFFSET_MSB_REG */
#define TAS6754_SDIN_AUDIO_OFF_MSB_MASK      GENMASK(7, 6)
#define TAS6754_SDIN_LL_OFF_MSB_MASK         GENMASK(5, 4)

/* SDOUT_OFFSET_MSB_REG */
#define TAS6754_SDOUT_VP_OFF_MSB_MASK        GENMASK(7, 6)
#define TAS6754_SDOUT_IS_OFF_MSB_MASK        GENMASK(5, 4)

/* RTLDG_EN_REG */
#define TAS6754_RTLDG_CLIP_MASK_BIT          BIT(4)
#define TAS6754_RTLDG_CH_EN_MASK             GENMASK(3, 0)

/* DC_LDG_CTRL_REG */
#define TAS6754_LDG_ABORT_BIT                BIT(7)
#define TAS6754_LDG_BUFFER_WAIT_MASK         GENMASK(6, 5)
#define TAS6754_LDG_WAIT_BYPASS_BIT          BIT(2)
#define TAS6754_SLOL_DISABLE_BIT             BIT(1)
#define TAS6754_LDG_BYPASS_BIT               BIT(0)

/* DC_LDG_TIME_CTRL_REG */
#define TAS6754_LDG_RAMP_SLOL_MASK           GENMASK(7, 6)
#define TAS6754_LDG_SETTLING_SLOL_MASK       GENMASK(5, 4)
#define TAS6754_LDG_RAMP_S2PG_MASK           GENMASK(3, 2)
#define TAS6754_LDG_SETTLING_S2PG_MASK       GENMASK(1, 0)

/* AC_LDG_CTRL_REG */
#define TAS6754_AC_DIAG_GAIN_BIT             BIT(4)
#define TAS6754_AC_DIAG_START_MASK           GENMASK(3, 0)

/* DC_LDG_RESULT_REG */
#define TAS6754_DC_LDG_LO_RESULT_MASK        GENMASK(7, 4)
#define TAS6754_DC_LDG_PASS_MASK             GENMASK(3, 0)

/* Load Diagnostics Timing Constants */
#define TAS6754_POLL_INTERVAL_US             10000
#define TAS6754_STATE_TRANSITION_TIMEOUT_US  50000
#define TAS6754_DC_LDG_TIMEOUT_US            300000
#define TAS6754_AC_LDG_TIMEOUT_US            400000

/* GPIO_CTRL_REG */
#define TAS6754_GPIO1_OUTPUT_EN              BIT(7)
#define TAS6754_GPIO2_OUTPUT_EN              BIT(6)
#define TAS6754_GPIO_CTRL_RSTVAL             0x22

/* GPIO output select values */
#define TAS6754_GPIO_SEL_LOW                 0x00
#define TAS6754_GPIO_SEL_AUTO_MUTE_ALL       0x02
#define TAS6754_GPIO_SEL_AUTO_MUTE_CH4       0x03
#define TAS6754_GPIO_SEL_AUTO_MUTE_CH3       0x04
#define TAS6754_GPIO_SEL_AUTO_MUTE_CH2       0x05
#define TAS6754_GPIO_SEL_AUTO_MUTE_CH1       0x06
#define TAS6754_GPIO_SEL_SDOUT2              0x08
#define TAS6754_GPIO_SEL_SDOUT1              0x09
#define TAS6754_GPIO_SEL_WARN                0x0A
#define TAS6754_GPIO_SEL_FAULT               0x0B
#define TAS6754_GPIO_SEL_CLOCK_SYNC          0x0E
#define TAS6754_GPIO_SEL_INVALID_CLK         0x0F
#define TAS6754_GPIO_SEL_HIGH                0x13

/* GPIO input function encoding (flag bit | function ID) */
#define TAS6754_GPIO_FUNC_INPUT              0x100

/* Function IDs — index into tas6754_gpio_input_table[] */
#define TAS6754_GPIO_IN_ID_MUTE              0
#define TAS6754_GPIO_IN_ID_PHASE_SYNC        1
#define TAS6754_GPIO_IN_ID_SDIN2             2
#define TAS6754_GPIO_IN_ID_DEEP_SLEEP        3
#define TAS6754_GPIO_IN_ID_HIZ               4
#define TAS6754_GPIO_IN_ID_PLAY              5
#define TAS6754_GPIO_IN_ID_SLEEP             6
#define TAS6754_GPIO_IN_NUM                  7

#define TAS6754_GPIO_IN_MUTE                 (TAS6754_GPIO_FUNC_INPUT | TAS6754_GPIO_IN_ID_MUTE)
#define TAS6754_GPIO_IN_PHASE_SYNC           (TAS6754_GPIO_FUNC_INPUT | TAS6754_GPIO_IN_ID_PHASE_SYNC)
#define TAS6754_GPIO_IN_SDIN2                (TAS6754_GPIO_FUNC_INPUT | TAS6754_GPIO_IN_ID_SDIN2)
#define TAS6754_GPIO_IN_DEEP_SLEEP           (TAS6754_GPIO_FUNC_INPUT | TAS6754_GPIO_IN_ID_DEEP_SLEEP)
#define TAS6754_GPIO_IN_HIZ                  (TAS6754_GPIO_FUNC_INPUT | TAS6754_GPIO_IN_ID_HIZ)
#define TAS6754_GPIO_IN_PLAY                 (TAS6754_GPIO_FUNC_INPUT | TAS6754_GPIO_IN_ID_PLAY)
#define TAS6754_GPIO_IN_SLEEP                (TAS6754_GPIO_FUNC_INPUT | TAS6754_GPIO_IN_ID_SLEEP)

/* GPIO input 3-bit mux field masks */
#define TAS6754_GPIO_IN_MUTE_MASK            GENMASK(2, 0)
#define TAS6754_GPIO_IN_SYNC_MASK            GENMASK(2, 0)
#define TAS6754_GPIO_IN_SDIN2_MASK           GENMASK(6, 4)
#define TAS6754_GPIO_IN_DEEP_SLEEP_MASK      GENMASK(6, 4)
#define TAS6754_GPIO_IN_HIZ_MASK             GENMASK(2, 0)
#define TAS6754_GPIO_IN_PLAY_MASK            GENMASK(6, 4)
#define TAS6754_GPIO_IN_SLEEP_MASK           GENMASK(2, 0)

/* Book addresses for tas6754_select_book() */
#define TAS6754_BOOK_DEFAULT                 0x00
#define TAS6754_BOOK_DSP                     0x8C

/* DSP memory addresses (DSP Book) */
#define TAS6754_DSP_PAGE_RTLDG               0x22
#define TAS6754_DSP_RTLDG_OL_THRESH_REG      0x98
#define TAS6754_DSP_RTLDG_SL_THRESH_REG      0x9C

/* Setup Mode Entry/Exit*/
#define TAS6754_SETUP_ENTER_VAL1             0x11
#define TAS6754_SETUP_ENTER_VAL2             0xFF
#define TAS6754_SETUP_EXIT_VAL               0x00

enum tas67xx_type {
	TAS6754,
};

struct tas6754_priv {
	struct device *dev;
	struct regmap *regmap;
	enum tas67xx_type dev_type;
	struct mutex io_lock;

	struct gpio_desc *pd_gpio;
	struct gpio_desc *stby_gpio;
	struct regulator_bulk_data supplies[3];

	bool fast_boot;

	int audio_slot;
	int llp_slot;
	int vpredict_slot;
	int isense_slot;
	int bclk_offset;
	int slot_width;

	unsigned int tx_mask;
	unsigned int rx_mask;

	int gpio1_func;
	int gpio2_func;

	unsigned long active_playback_dais;
	unsigned long active_capture_dais;
	unsigned int rate;
	unsigned int saved_rtldg_en;

	/* Fault monitor - Disabled when Fault IRQ is used */
	struct delayed_work fault_check_work;
#define TAS6754_NUM_FAULT_REGS	8
	unsigned int last_status[TAS6754_NUM_FAULT_REGS];
};

#endif /* __TAS6754_H__ */
