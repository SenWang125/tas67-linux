// SPDX-License-Identifier: GPL-2.0
/*
 * ALSA SoC Texas Instruments TAS6754 Quad-Channel Audio Amplifier
 *
 * Copyright (C) 2026 Texas Instruments Incorporated - https://www.ti.com/
 *	Author: Sen Wang <sen@ti.com>
 */

#include <linux/bitfield.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/i2c.h>
#include <linux/regmap.h>
#include <linux/gpio/consumer.h>
#include <linux/regulator/consumer.h>
#include <linux/delay.h>
#include <linux/property.h>
#include <linux/interrupt.h>
#include <linux/workqueue.h>
#include <linux/pm_runtime.h>
#include <linux/iopoll.h>
#include <sound/soc.h>
#include <sound/tlv.h>
#include <sound/pcm_params.h>

#include "tas6754.h"

#define TAS6754_FAULT_CHECK_INTERVAL_MS  200

static const char * const tas6754_supply_names[] = {
	"dvdd",		/* Digital power supply. 1.8-V or 3.3-V supply. */
	"pvdd",		/* Power stage supply. 4.5-V to 19-V supply. */
	"vbat"		/* Battery supply for Class-D output stage. */
};

/* Page 1 setup initialization defaults */
static const struct reg_sequence tas6754_page1_init[] = {
	REG_SEQ0(TAS6754_PAGE_REG(1, 0xC8), 0x20),	/* Charge pump clock */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0x2F), 0x90),	/* VBAT idle */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0x29), 0x40),	/* OC/CBC threshold */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0x2E), 0x0C),	/* OC/CBC config */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0xC5), 0x02),	/* OC/CBC config */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0xC6), 0x10),	/* OC/CBC config */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0x1F), 0x20),	/* OC/CBC config */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0x16), 0x01),	/* OC/CBC config */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0x1E), 0x04),	/* OC/CBC config */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0xC1), 0x00),	/* CH1 DC fault */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0xC2), 0x04),	/* CH2 DC fault, CP UVLO enable */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0xC3), 0x00),	/* CH3 DC fault */
	REG_SEQ0(TAS6754_PAGE_REG(1, 0xC4), 0x00),	/* CH4 DC fault */
};

static inline const char *tas6754_state_name(unsigned int state)
{
	switch (state & 0x0F) {
	case TAS6754_STATE_DEEPSLEEP:	return "DEEPSLEEP";
	case TAS6754_STATE_LOAD_DIAG:	return "LOAD_DIAG";
	case TAS6754_STATE_SLEEP:	return "SLEEP";
	case TAS6754_STATE_HIZ:		return "HIZ";
	case TAS6754_STATE_PLAY:	return "PLAY";
	case TAS6754_STATE_FAULT:	return "FAULT";
	case TAS6754_STATE_AUTOREC:	return "AUTOREC";
	default:			return "UNKNOWN";
	}
}

static inline int tas6754_set_state_all(struct tas6754_priv *tas, u8 state)
{
	const struct reg_sequence seq[] = {
		REG_SEQ0(TAS6754_STATE_CTRL_CH1_CH2_REG, state),
		REG_SEQ0(TAS6754_STATE_CTRL_CH3_CH4_REG, state),
	};

	return regmap_multi_reg_write(tas->regmap, seq, ARRAY_SIZE(seq));
}

static inline int tas6754_select_book(struct regmap *regmap, u8 book)
{
	int ret;

	/* Reset page to 0 before switching books */
	ret = regmap_write(regmap, TAS6754_PAGE_CTRL_REG, 0x00);
	if (!ret)
		ret = regmap_write(regmap, TAS6754_BOOK_CTRL_REG, book);

	return ret;
}

/* Raw I2C version of tas6754_select_book, must be called with io_lock held */
static inline int __tas6754_select_book(struct tas6754_priv *tas, u8 book)
{
	struct i2c_client *client = to_i2c_client(tas->dev);
	int ret;

	/* Reset page to 0 before switching books */
	ret = i2c_smbus_write_byte_data(client, TAS6754_PAGE_CTRL_REG, 0x00);
	if (ret)
		return ret;

	return i2c_smbus_write_byte_data(client, TAS6754_BOOK_CTRL_REG, book);
}

static int tas6754_dsp_mem_write(struct tas6754_priv *tas, u8 page, u8 reg, u32 val)
{
	struct i2c_client *client = to_i2c_client(tas->dev);
	u8 buf[4];
	int ret;

	/* DSP registers are 24-bit values, zero-padded MSB to 32-bit */
	buf[0] = 0x00;
	buf[1] = (val >> 16) & 0xFF;
	buf[2] = (val >> 8) & 0xFF;
	buf[3] = val & 0xFF;

	/*
	 * DSP regs in a different book, therefore block
	 * regmap access before completion.
	 */
	mutex_lock(&tas->io_lock);

	ret = __tas6754_select_book(tas, TAS6754_BOOK_DSP);
	if (ret)
		goto out;

	ret = i2c_smbus_write_byte_data(client, TAS6754_PAGE_CTRL_REG, page);
	if (ret)
		goto out;

	ret = i2c_smbus_write_i2c_block_data(client, reg, sizeof(buf), buf);

out:
	__tas6754_select_book(tas, TAS6754_BOOK_DEFAULT);
	mutex_unlock(&tas->io_lock);

	return ret;
}

static int tas6754_dsp_mem_read(struct tas6754_priv *tas, u8 page, u8 reg, u32 *val)
{
	struct i2c_client *client = to_i2c_client(tas->dev);
	u8 buf[4];
	int ret;

	/*
	 * DSP regs in a different book, therefore block
	 * regmap access before completion.
	 */
	mutex_lock(&tas->io_lock);

	ret = __tas6754_select_book(tas, TAS6754_BOOK_DSP);
	if (ret)
		goto out;

	ret = i2c_smbus_write_byte_data(client, TAS6754_PAGE_CTRL_REG, page);
	if (ret)
		goto out;

	ret = i2c_smbus_read_i2c_block_data(client, reg, sizeof(buf), buf);
	if (ret == sizeof(buf)) {
		*val = (buf[1] << 16) | (buf[2] << 8) | buf[3];
		ret = 0;
	} else if (ret >= 0) {
		ret = -EIO;
	}

out:
	__tas6754_select_book(tas, TAS6754_BOOK_DEFAULT);
	mutex_unlock(&tas->io_lock);

	return ret;
}

static const struct {
	const char *name;
	int val;
} tas6754_gpio_func_map[] = {
	/* Output functions */
	{ "low",            TAS6754_GPIO_SEL_LOW },
	{ "auto-mute",      TAS6754_GPIO_SEL_AUTO_MUTE_ALL },
	{ "auto-mute-ch4",  TAS6754_GPIO_SEL_AUTO_MUTE_CH4 },
	{ "auto-mute-ch3",  TAS6754_GPIO_SEL_AUTO_MUTE_CH3 },
	{ "auto-mute-ch2",  TAS6754_GPIO_SEL_AUTO_MUTE_CH2 },
	{ "auto-mute-ch1",  TAS6754_GPIO_SEL_AUTO_MUTE_CH1 },
	{ "sdout2",         TAS6754_GPIO_SEL_SDOUT2 },
	{ "sdout1",         TAS6754_GPIO_SEL_SDOUT1 },
	{ "warn",           TAS6754_GPIO_SEL_WARN },
	{ "fault",          TAS6754_GPIO_SEL_FAULT },
	{ "clock-sync",     TAS6754_GPIO_SEL_CLOCK_SYNC },
	{ "invalid-clock",  TAS6754_GPIO_SEL_INVALID_CLK },
	{ "high",           TAS6754_GPIO_SEL_HIGH },
	/* Input functions */
	{ "mute",           TAS6754_GPIO_IN_MUTE },
	{ "phase-sync",     TAS6754_GPIO_IN_PHASE_SYNC },
	{ "sdin2",          TAS6754_GPIO_IN_SDIN2 },
	{ "deep-sleep",     TAS6754_GPIO_IN_DEEP_SLEEP },
	{ "hiz",            TAS6754_GPIO_IN_HIZ },
	{ "play",           TAS6754_GPIO_IN_PLAY },
	{ "sleep",          TAS6754_GPIO_IN_SLEEP },
};

static int tas6754_gpio_func_parse(struct device *dev, const char *propname)
{
	const char *str;
	int i, ret;

	ret = device_property_read_string(dev, propname, &str);
	if (ret)
		return -1;

	for (i = 0; i < ARRAY_SIZE(tas6754_gpio_func_map); i++) {
		if (!strcmp(str, tas6754_gpio_func_map[i].name))
			return tas6754_gpio_func_map[i].val;
	}

	dev_warn(dev, "Invalid %s value '%s'\n", propname, str);
	return -1;
}

static const struct {
	unsigned int reg;
	unsigned int mask;
} tas6754_gpio_input_table[TAS6754_GPIO_IN_NUM] = {
	[TAS6754_GPIO_IN_ID_MUTE] = {
		TAS6754_GPIO_INPUT_MUTE_REG, TAS6754_GPIO_IN_MUTE_MASK },
	[TAS6754_GPIO_IN_ID_PHASE_SYNC] = {
		TAS6754_GPIO_INPUT_SYNC_REG, TAS6754_GPIO_IN_SYNC_MASK },
	[TAS6754_GPIO_IN_ID_SDIN2] = {
		TAS6754_GPIO_INPUT_SDIN2_REG, TAS6754_GPIO_IN_SDIN2_MASK },
	[TAS6754_GPIO_IN_ID_DEEP_SLEEP] = {
		TAS6754_GPIO_INPUT_SLEEP_HIZ_REG, TAS6754_GPIO_IN_DEEP_SLEEP_MASK },
	[TAS6754_GPIO_IN_ID_HIZ] = {
		TAS6754_GPIO_INPUT_SLEEP_HIZ_REG, TAS6754_GPIO_IN_HIZ_MASK },
	[TAS6754_GPIO_IN_ID_PLAY] = {
		TAS6754_GPIO_INPUT_PLAY_SLEEP_REG, TAS6754_GPIO_IN_PLAY_MASK },
	[TAS6754_GPIO_IN_ID_SLEEP] = {
		TAS6754_GPIO_INPUT_PLAY_SLEEP_REG, TAS6754_GPIO_IN_SLEEP_MASK },
};

static void tas6754_config_gpio_pin(struct regmap *regmap, int func_id,
				    unsigned int out_sel_reg,
				    unsigned int pin_idx,
				    unsigned int *gpio_ctrl)
{
	int id;

	if (func_id < 0)
		return;

	if (func_id & TAS6754_GPIO_FUNC_INPUT) {
		/* 3-bit mux: 0 = disabled, 0b1 = GPIO1, 0b10 = GPIO2 */
		id = func_id & ~TAS6754_GPIO_FUNC_INPUT;
		regmap_update_bits(regmap,
				   tas6754_gpio_input_table[id].reg,
				   tas6754_gpio_input_table[id].mask,
				   (pin_idx + 1) << __ffs(tas6754_gpio_input_table[id].mask));
	} else {
		/* Output GPIO, update selection register and enable bit */
		regmap_write(regmap, out_sel_reg, func_id);
		*gpio_ctrl |= pin_idx ? TAS6754_GPIO2_OUTPUT_EN : TAS6754_GPIO1_OUTPUT_EN;
	}
}

struct tas6754_dsp_thresh {
	u8 page;
	u8 reg;
};

static int tas6754_rtldg_thresh_info(struct snd_kcontrol *kcontrol,
				     struct snd_ctl_elem_info *uinfo)
{
	uinfo->type = SNDRV_CTL_ELEM_TYPE_INTEGER;
	uinfo->count = 1;
	uinfo->value.integer.min = 0;
	/* Accepts 32-bit values, even though 8bit MSB is ignored */
	uinfo->value.integer.max = 0xFFFFFFFF;
	return 0;
}

static int tas6754_set_rtldg_thresh(struct snd_kcontrol *kcontrol,
				    struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *comp = snd_kcontrol_chip(kcontrol);
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(comp);
	const struct tas6754_dsp_thresh *t =
		(const struct tas6754_dsp_thresh *)kcontrol->private_value;
	u32 val = ucontrol->value.integer.value[0];
	int ret;

	ret = tas6754_dsp_mem_write(tas, t->page, t->reg, val);
	/* Return 1 to notify change, or propagate error */
	return ret ? ret : 1;
}

static int tas6754_get_rtldg_thresh(struct snd_kcontrol *kcontrol,
				    struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *comp = snd_kcontrol_chip(kcontrol);
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(comp);
	const struct tas6754_dsp_thresh *t =
		(const struct tas6754_dsp_thresh *)kcontrol->private_value;
	u32 val = 0;
	int ret;

	ret = tas6754_dsp_mem_read(tas, t->page, t->reg, &val);
	if (!ret)
		ucontrol->value.integer.value[0] = val;

	return ret;
}

static const struct tas6754_dsp_thresh tas6754_rtldg_ol_thresh = {
	TAS6754_DSP_PAGE_RTLDG, TAS6754_DSP_RTLDG_OL_THRESH_REG
};

static const struct tas6754_dsp_thresh tas6754_rtldg_sl_thresh = {
	TAS6754_DSP_PAGE_RTLDG, TAS6754_DSP_RTLDG_SL_THRESH_REG
};

static int tas6754_set_dcldg_trigger(struct snd_kcontrol *kcontrol,
				      struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *comp = snd_kcontrol_chip(kcontrol);
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(comp);
	unsigned int state, state34;
	int ret;

	if (!ucontrol->value.integer.value[0])
		return 0;

	if (tas->active_playback_dais || tas->active_capture_dais)
		return -EBUSY;

	ret = pm_runtime_get_sync(tas->dev);
	if (ret < 0) {
		pm_runtime_put_noidle(tas->dev);
		return ret;
	}

	/*
	 * Abort automatic DC LDG retry loops (startup or init-after-fault)
	 * and clear faults before manual diagnostics.
	 */
	regmap_update_bits(tas->regmap, TAS6754_DC_LDG_CTRL_REG,
			   TAS6754_LDG_ABORT_BIT | TAS6754_LDG_BYPASS_BIT,
			   TAS6754_LDG_ABORT_BIT | TAS6754_LDG_BYPASS_BIT);
	regmap_write(tas->regmap, TAS6754_RESET_REG, TAS6754_FAULT_CLEAR);

	/* Wait for LOAD_DIAG to exit */
	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH1_CH2_REG,
					state, (state & 0x0F) != TAS6754_STATE_LOAD_DIAG &&
					       (state >> 4) != TAS6754_STATE_LOAD_DIAG,
					TAS6754_POLL_INTERVAL_US,
					TAS6754_STATE_TRANSITION_TIMEOUT_US);

	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH3_CH4_REG,
					state34, (state34 & 0x0F) != TAS6754_STATE_LOAD_DIAG &&
						 (state34 >> 4) != TAS6754_STATE_LOAD_DIAG,
					TAS6754_POLL_INTERVAL_US,
					TAS6754_STATE_TRANSITION_TIMEOUT_US);

	/* Transition to HIZ state */
	ret = tas6754_set_state_all(tas, TAS6754_STATE_HIZ_BOTH);
	if (ret)
		goto out_restore_ldg_ctrl;

	/* Set LOAD_DIAG state for manual DC LDG */
	ret = tas6754_set_state_all(tas, TAS6754_STATE_LOAD_DIAG_BOTH);
	if (ret)
		goto out_restore_ldg_ctrl;

	/* Wait for device to transition to LOAD_DIAG state */
	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH1_CH2_REG,
					state, state == TAS6754_STATE_LOAD_DIAG_BOTH,
					TAS6754_POLL_INTERVAL_US,
					TAS6754_STATE_TRANSITION_TIMEOUT_US);

	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH3_CH4_REG,
					state34, state34 == TAS6754_STATE_LOAD_DIAG_BOTH,
					TAS6754_POLL_INTERVAL_US,
					TAS6754_STATE_TRANSITION_TIMEOUT_US);

	/* Clear ABORT and BYPASS bits to enable manual DC LDG */
	ret = regmap_update_bits(tas->regmap, TAS6754_DC_LDG_CTRL_REG,
				 TAS6754_LDG_ABORT_BIT | TAS6754_LDG_BYPASS_BIT,
				 0);
	if (ret)
		goto out_restore_hiz;

	dev_dbg(tas->dev, "DC LDG: Started\n");

	/* Poll all channels for SLEEP state */
	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH1_CH2_REG,
					state, (state == TAS6754_STATE_SLEEP_BOTH),
					TAS6754_POLL_INTERVAL_US,
					TAS6754_DC_LDG_TIMEOUT_US);
	if (ret) {
		dev_err(tas->dev,
			"DC LDG: CH1/CH2 timeout: %d (state=0x%02x [%s/%s])\n",
			ret, state, tas6754_state_name(state),
			tas6754_state_name(state >> 4));
		goto out_restore_hiz;
	}

	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH3_CH4_REG,
					state34, (state34 == TAS6754_STATE_SLEEP_BOTH),
					TAS6754_POLL_INTERVAL_US,
					TAS6754_DC_LDG_TIMEOUT_US);
	if (ret) {
		dev_err(tas->dev,
			"DC LDG: CH3/CH4 timeout: %d (state=0x%02x [%s/%s])\n",
			ret, state34, tas6754_state_name(state34),
			tas6754_state_name(state34 >> 4));
		goto out_restore_hiz;
	}

	dev_dbg(tas->dev, "DC LDG: Completed successfully (CH1/2=0x%02x, CH3/4=0x%02x)\n",
		state, state34);

out_restore_hiz:
	tas6754_set_state_all(tas, TAS6754_STATE_HIZ_BOTH);

out_restore_ldg_ctrl:
	regmap_update_bits(tas->regmap, TAS6754_DC_LDG_CTRL_REG,
			   TAS6754_LDG_ABORT_BIT | TAS6754_LDG_BYPASS_BIT,
			   0);

	pm_runtime_mark_last_busy(tas->dev);
	pm_runtime_put_autosuspend(tas->dev);

	return ret;
}

static int tas6754_set_acldg_trigger(struct snd_kcontrol *kcontrol,
				      struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *comp = snd_kcontrol_chip(kcontrol);
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(comp);
	unsigned int state, state34;
	int ret;

	if (!ucontrol->value.integer.value[0])
		return 0;

	if (tas->active_playback_dais || tas->active_capture_dais)
		return -EBUSY;

	ret = pm_runtime_get_sync(tas->dev);
	if (ret < 0) {
		pm_runtime_put_noidle(tas->dev);
		return ret;
	}

	/* AC Load Diagnostics requires SLEEP state */
	ret = tas6754_set_state_all(tas, TAS6754_STATE_SLEEP_BOTH);
	if (ret) {
		dev_err(tas->dev, "AC LDG: Failed to set SLEEP state: %d\n", ret);
		goto out;
	}

	/* Start AC LDG on all 4 channels (0x0F) */
	ret = regmap_write(tas->regmap, TAS6754_AC_LDG_CTRL_REG, 0x0F);
	if (ret) {
		dev_err(tas->dev, "AC LDG: Failed to start: %d\n", ret);
		goto out;
	}

	dev_dbg(tas->dev, "AC LDG: Started\n");

	/* Poll all channels for SLEEP state */
	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH1_CH2_REG,
					state, (state == TAS6754_STATE_SLEEP_BOTH),
					TAS6754_POLL_INTERVAL_US,
					TAS6754_AC_LDG_TIMEOUT_US);
	if (ret) {
		dev_err(tas->dev,
			"AC LDG: CH1/CH2 timeout: %d (state=0x%02x [%s/%s])\n",
			ret, state, tas6754_state_name(state),
			tas6754_state_name(state >> 4));
		regmap_write(tas->regmap, TAS6754_AC_LDG_CTRL_REG, 0x00);
		goto out;
	}

	ret = regmap_read_poll_timeout(tas->regmap, TAS6754_STATE_REPORT_CH3_CH4_REG,
					state34, (state34 == TAS6754_STATE_SLEEP_BOTH),
					TAS6754_POLL_INTERVAL_US,
					TAS6754_AC_LDG_TIMEOUT_US);
	if (ret) {
		dev_err(tas->dev,
			"AC LDG: CH3/CH4 timeout: %d (state=0x%02x [%s/%s])\n",
			ret, state34, tas6754_state_name(state34),
			tas6754_state_name(state34 >> 4));
		regmap_write(tas->regmap, TAS6754_AC_LDG_CTRL_REG, 0x00);
		goto out;
	}

	dev_dbg(tas->dev, "AC LDG: Completed successfully (CH1/2=0x%02x, CH3/4=0x%02x)\n",
		state, state34);
	regmap_write(tas->regmap, TAS6754_AC_LDG_CTRL_REG, 0x00);
	ret = 0;

out:
	pm_runtime_mark_last_busy(tas->dev);
	pm_runtime_put_autosuspend(tas->dev);

	return ret;
}

static int tas6754_rtldg_impedance_info(struct snd_kcontrol *kcontrol,
					struct snd_ctl_elem_info *uinfo)
{
	uinfo->type = SNDRV_CTL_ELEM_TYPE_INTEGER;
	uinfo->count = 1;
	uinfo->value.integer.min = 0;
	uinfo->value.integer.max = 0xFFFF;
	return 0;
}

static int tas6754_get_rtldg_impedance(struct snd_kcontrol *kcontrol,
					struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *comp = snd_kcontrol_chip(kcontrol);
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(comp);
	unsigned int msb_reg = (unsigned int)kcontrol->private_value;
	unsigned int msb, lsb;
	int ret;

	ret = regmap_read(tas->regmap, msb_reg, &msb);
	if (ret)
		return ret;

	ret = regmap_read(tas->regmap, msb_reg + 1, &lsb);
	if (ret)
		return ret;

	ucontrol->value.integer.value[0] = (msb << 8) | lsb;
	return 0;
}

static int tas6754_dc_resistance_info(struct snd_kcontrol *kcontrol,
				       struct snd_ctl_elem_info *uinfo)
{
	/* 10-bit: 2-bit MSB + 8-bit LSB, 0.1 ohm/code, 0-102.3 ohm */
	uinfo->type = SNDRV_CTL_ELEM_TYPE_INTEGER;
	uinfo->count = 1;
	uinfo->value.integer.min = 0;
	uinfo->value.integer.max = 1023;
	return 0;
}

static int tas6754_get_dc_resistance(struct snd_kcontrol *kcontrol,
				      struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *comp = snd_kcontrol_chip(kcontrol);
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(comp);
	unsigned int lsb_reg = (unsigned int)kcontrol->private_value;
	unsigned int msb, lsb, shift;
	int ret;

	ret = regmap_read(tas->regmap, TAS6754_DC_LDG_DCR_MSB_REG, &msb);
	if (ret)
		return ret;

	ret = regmap_read(tas->regmap, lsb_reg, &lsb);
	if (ret)
		return ret;

	/* 2-bit MSB: CH1=[7:6], CH2=[5:4], CH3=[3:2], CH4=[1:0] */
	shift = 6 - (lsb_reg - TAS6754_CH1_DC_LDG_DCR_LSB_REG) * 2;
	msb = (msb >> shift) & 0x3;

	ucontrol->value.integer.value[0] = (msb << 8) | lsb;
	return 0;
}

/* Counterparts with read-only access */
#define SOC_SINGLE_RO(xname, xreg, xshift, xmax) \
{	.iface = SNDRV_CTL_ELEM_IFACE_MIXER, \
	.name = xname, \
	.access = SNDRV_CTL_ELEM_ACCESS_READ | SNDRV_CTL_ELEM_ACCESS_VOLATILE, \
	.info = snd_soc_info_volsw, \
	.get = snd_soc_get_volsw, \
	.private_value = SOC_SINGLE_VALUE(xreg, xshift, 0, xmax, 0, 0) }
#define SOC_DC_RESIST_RO(xname, xlsb_reg) \
{	.name = xname, \
	.iface = SNDRV_CTL_ELEM_IFACE_MIXER, \
	.access = SNDRV_CTL_ELEM_ACCESS_READ | SNDRV_CTL_ELEM_ACCESS_VOLATILE, \
	.info = tas6754_dc_resistance_info, \
	.get = tas6754_get_dc_resistance, \
	.private_value = (xlsb_reg) }
#define SOC_RTLDG_IMP_RO(xname, xreg) \
{	.name = xname, \
	.iface = SNDRV_CTL_ELEM_IFACE_MIXER, \
	.access = SNDRV_CTL_ELEM_ACCESS_READ | SNDRV_CTL_ELEM_ACCESS_VOLATILE, \
	.info = tas6754_rtldg_impedance_info, \
	.get = tas6754_get_rtldg_impedance, \
	.private_value = (xreg) }

#define SOC_DSP_THRESH_EXT(xname, xthresh) \
{	.name = xname, \
	.iface = SNDRV_CTL_ELEM_IFACE_MIXER, \
	.info = tas6754_rtldg_thresh_info, \
	.get = tas6754_get_rtldg_thresh, \
	.put = tas6754_set_rtldg_thresh, \
	.private_value = (unsigned long)&(xthresh) }

/*
 * DAC digital volumes. From -103 to 0 dB in 0.5 dB steps, -103.5 dB means mute.
 * DAC analog gain. From -15.5 to 0 dB in 0.5 dB steps, no mute.
 */
static const DECLARE_TLV_DB_SCALE(tas6754_dig_vol_tlv, -10350, 50, 1);
static const DECLARE_TLV_DB_SCALE(tas6754_ana_gain_tlv, -1550, 50, 0);

static const char * const tas6754_ss_texts[] = {
	"Disabled", "Triangle", "Random", "Triangle and Random"
};

static SOC_ENUM_SINGLE_DECL(tas6754_ss_enum, TAS6754_SS_CTRL_REG, 0, tas6754_ss_texts);

static const char * const tas6754_ss_tri_range_texts[] = {
	"6.5%", "13.5%", "5%", "10%"
};

static SOC_ENUM_SINGLE_DECL(tas6754_ss_tri_range_enum,
			    TAS6754_SS_RANGE_CTRL_REG, 0,
			    tas6754_ss_tri_range_texts);

static const char * const tas6754_ss_rdm_range_texts[] = {
	"0.83%", "2.50%", "5.83%", "12.50%", "25.83%"
};

static SOC_ENUM_SINGLE_DECL(tas6754_ss_rdm_range_enum,
			    TAS6754_SS_RANGE_CTRL_REG, 4,
			    tas6754_ss_rdm_range_texts);

static const char * const tas6754_ss_rdm_dwell_texts[] = {
	"1/FSS to 2/FSS", "1/FSS to 4/FSS", "1/FSS to 8/FSS", "1/FSS to 15/FSS"
};

static SOC_ENUM_SINGLE_DECL(tas6754_ss_rdm_dwell_enum,
			    TAS6754_SS_RANGE_CTRL_REG, 2,
			    tas6754_ss_rdm_dwell_texts);

static const char * const tas6754_oc_limit_texts[] = {
	"Level 4", "Level 3", "Level 2", "Level 1"
};
static SOC_ENUM_SINGLE_DECL(tas6754_oc_limit_enum, TAS6754_CURRENT_LIMIT_CTRL_REG,
			    0, tas6754_oc_limit_texts);

static const char * const tas6754_otw_texts[] = {
	"Disabled", ">95C", ">110C", ">125C", ">135C", ">145C", ">155C", ">165C"
};
static SOC_ENUM_SINGLE_DECL(tas6754_ch1_otw_enum,
			    TAS6754_OTW_CTRL_CH1_CH2_REG, 4,
			    tas6754_otw_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch2_otw_enum,
			    TAS6754_OTW_CTRL_CH1_CH2_REG, 0,
			    tas6754_otw_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch3_otw_enum,
			    TAS6754_OTW_CTRL_CH3_CH4_REG, 4,
			    tas6754_otw_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch4_otw_enum,
			    TAS6754_OTW_CTRL_CH3_CH4_REG, 0,
			    tas6754_otw_texts);

static const char * const tas6754_dc_ldg_sl_texts[] = {
	"0.5 Ohm", "1 Ohm", "1.5 Ohm", "2 Ohm", "2.5 Ohm",
	"3 Ohm", "3.5 Ohm", "4 Ohm", "4.5 Ohm", "5 Ohm"
};
static SOC_ENUM_SINGLE_DECL(tas6754_ch1_dc_ldg_sl_enum,
			    TAS6754_DC_LDG_SL_CH1_CH2_CTRL_REG, 4,
			    tas6754_dc_ldg_sl_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch2_dc_ldg_sl_enum,
			    TAS6754_DC_LDG_SL_CH1_CH2_CTRL_REG, 0,
			    tas6754_dc_ldg_sl_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch3_dc_ldg_sl_enum,
			    TAS6754_DC_LDG_SL_CH3_CH4_CTRL_REG, 4,
			    tas6754_dc_ldg_sl_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch4_dc_ldg_sl_enum,
			    TAS6754_DC_LDG_SL_CH3_CH4_CTRL_REG, 0,
			    tas6754_dc_ldg_sl_texts);

static const char * const tas6754_dc_slol_ramp_texts[] = {
	"15 ms", "30 ms", "10 ms", "20 ms"
};
static SOC_ENUM_SINGLE_DECL(tas6754_dc_slol_ramp_enum,
			    TAS6754_DC_LDG_TIME_CTRL_REG, 6,
			    tas6754_dc_slol_ramp_texts);

static const char * const tas6754_dc_slol_settling_texts[] = {
	"10 ms", "5 ms", "20 ms", "15 ms"
};
static SOC_ENUM_SINGLE_DECL(tas6754_dc_slol_settling_enum,
			    TAS6754_DC_LDG_TIME_CTRL_REG, 4,
			    tas6754_dc_slol_settling_texts);

static const char * const tas6754_dc_s2pg_ramp_texts[] = {
	"5 ms", "2.5 ms", "10 ms", "15 ms"
};
static SOC_ENUM_SINGLE_DECL(tas6754_dc_s2pg_ramp_enum,
			    TAS6754_DC_LDG_TIME_CTRL_REG, 2,
			    tas6754_dc_s2pg_ramp_texts);

static const char * const tas6754_dc_s2pg_settling_texts[] = {
	"10 ms", "5 ms", "20 ms", "30 ms"
};
static SOC_ENUM_SINGLE_DECL(tas6754_dc_s2pg_settling_enum,
			    TAS6754_DC_LDG_TIME_CTRL_REG, 0,
			    tas6754_dc_s2pg_settling_texts);

static const char * const tas6754_dsp_mode_texts[] = {
	"Normal", "LLP", "FFLP"
};
static SOC_ENUM_SINGLE_DECL(tas6754_dsp_mode_enum,
			    TAS6754_LL_EN_REG, 0,
			    tas6754_dsp_mode_texts);

static const char * const tas6754_ana_ramp_texts[] = {
	"15us", "60us", "200us", "400us"
};
static SOC_ENUM_SINGLE_DECL(tas6754_ana_ramp_enum,
			    TAS6754_ANALOG_GAIN_RAMP_CTRL_REG, 2,
			    tas6754_ana_ramp_texts);

static const char * const tas6754_ramp_rate_texts[] = {
	"4 FS", "16 FS", "32 FS", "Instant"
};
static SOC_ENUM_SINGLE_DECL(tas6754_ramp_down_rate_enum,
			    TAS6754_DIG_VOL_RAMP_CTRL_REG, 6,
			    tas6754_ramp_rate_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ramp_up_rate_enum,
			    TAS6754_DIG_VOL_RAMP_CTRL_REG, 2,
			    tas6754_ramp_rate_texts);

static const char * const tas6754_ramp_step_texts[] = {
	"4dB", "2dB", "1dB", "0.5dB"
};
static SOC_ENUM_SINGLE_DECL(tas6754_ramp_down_step_enum,
			    TAS6754_DIG_VOL_RAMP_CTRL_REG, 4,
			    tas6754_ramp_step_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ramp_up_step_enum,
			    TAS6754_DIG_VOL_RAMP_CTRL_REG, 0,
			    tas6754_ramp_step_texts);

static const char * const tas6754_vol_combine_ch12_texts[] = {
	"Independent", "CH2 follows CH1", "CH1 follows CH2"
};
static SOC_ENUM_SINGLE_DECL(tas6754_vol_combine_ch12_enum,
			    TAS6754_DIG_VOL_COMBINE_CTRL_REG, 0,
			    tas6754_vol_combine_ch12_texts);

static const char * const tas6754_vol_combine_ch34_texts[] = {
	"Independent", "CH4 follows CH3", "CH3 follows CH4"
};
static SOC_ENUM_SINGLE_DECL(tas6754_vol_combine_ch34_enum,
			    TAS6754_DIG_VOL_COMBINE_CTRL_REG, 2,
			    tas6754_vol_combine_ch34_texts);

static const char * const tas6754_auto_mute_time_texts[] = {
	"11.5ms", "53ms", "106.5ms", "266.5ms",
	"535ms", "1065ms", "2665ms", "5330ms"
};
static SOC_ENUM_SINGLE_DECL(tas6754_ch1_mute_time_enum,
			    TAS6754_AUTO_MUTE_TIMING_CH1_CH2_REG, 4,
			    tas6754_auto_mute_time_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch2_mute_time_enum,
			    TAS6754_AUTO_MUTE_TIMING_CH1_CH2_REG, 0,
			    tas6754_auto_mute_time_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch3_mute_time_enum,
			    TAS6754_AUTO_MUTE_TIMING_CH3_CH4_REG, 4,
			    tas6754_auto_mute_time_texts);
static SOC_ENUM_SINGLE_DECL(tas6754_ch4_mute_time_enum,
			    TAS6754_AUTO_MUTE_TIMING_CH3_CH4_REG, 0,
			    tas6754_auto_mute_time_texts);

/*
 * ALSA Mixer Controls
 *
 * For detailed documentation of each control see:
 * Documentation/sound/codecs/tas6754.rst
 */
static const struct snd_kcontrol_new tas6754_snd_controls[] = {
	/* Volume & Gain Control */
	SOC_DOUBLE_R_TLV("Analog Playback Volume", TAS6754_ANALOG_GAIN_CH1_CH2_REG,
			 TAS6754_ANALOG_GAIN_CH3_CH4_REG, 1, 0x1F, 1, tas6754_ana_gain_tlv),
	SOC_ENUM("Analog Gain Ramp Step", tas6754_ana_ramp_enum),
	SOC_SINGLE_RANGE_TLV("CH1 Digital Playback Volume",
			     TAS6754_DIG_VOL_CH1_REG, 0, 0x30, 0xFF, 1,
			     tas6754_dig_vol_tlv),
	SOC_SINGLE_RANGE_TLV("CH2 Digital Playback Volume",
			     TAS6754_DIG_VOL_CH2_REG, 0, 0x30, 0xFF, 1,
			     tas6754_dig_vol_tlv),
	SOC_SINGLE_RANGE_TLV("CH3 Digital Playback Volume",
			     TAS6754_DIG_VOL_CH3_REG, 0, 0x30, 0xFF, 1,
			     tas6754_dig_vol_tlv),
	SOC_SINGLE_RANGE_TLV("CH4 Digital Playback Volume",
			     TAS6754_DIG_VOL_CH4_REG, 0, 0x30, 0xFF, 1,
			     tas6754_dig_vol_tlv),
	SOC_ENUM("Volume Ramp Down Rate", tas6754_ramp_down_rate_enum),
	SOC_ENUM("Volume Ramp Down Step", tas6754_ramp_down_step_enum),
	SOC_ENUM("Volume Ramp Up Rate", tas6754_ramp_up_rate_enum),
	SOC_ENUM("Volume Ramp Up Step", tas6754_ramp_up_step_enum),
	SOC_ENUM("CH1/2 Volume Combine", tas6754_vol_combine_ch12_enum),
	SOC_ENUM("CH3/4 Volume Combine", tas6754_vol_combine_ch34_enum),

	/* Auto Mute & Silence Detection */
	SOC_SINGLE("CH1 Auto Mute Switch", TAS6754_AUTO_MUTE_EN_REG, 0, 1, 0),
	SOC_SINGLE("CH2 Auto Mute Switch", TAS6754_AUTO_MUTE_EN_REG, 1, 1, 0),
	SOC_SINGLE("CH3 Auto Mute Switch", TAS6754_AUTO_MUTE_EN_REG, 2, 1, 0),
	SOC_SINGLE("CH4 Auto Mute Switch", TAS6754_AUTO_MUTE_EN_REG, 3, 1, 0),
	SOC_SINGLE("Auto Mute Combine Switch", TAS6754_AUTO_MUTE_EN_REG, 4, 1, 0),
	SOC_ENUM("CH1 Auto Mute Time", tas6754_ch1_mute_time_enum),
	SOC_ENUM("CH2 Auto Mute Time", tas6754_ch2_mute_time_enum),
	SOC_ENUM("CH3 Auto Mute Time", tas6754_ch3_mute_time_enum),
	SOC_ENUM("CH4 Auto Mute Time", tas6754_ch4_mute_time_enum),

	/* Clock & EMI Management */
	SOC_ENUM("Spread Spectrum Mode", tas6754_ss_enum),
	SOC_ENUM("SS Triangle Range", tas6754_ss_tri_range_enum),
	SOC_ENUM("SS Random Range", tas6754_ss_rdm_range_enum),
	SOC_ENUM("SS Random Dwell Range", tas6754_ss_rdm_dwell_enum),
	SOC_SINGLE("SS Triangle Dwell Min", TAS6754_SS_DWELL_CTRL_REG, 4, 15, 0),
	SOC_SINGLE("SS Triangle Dwell Max", TAS6754_SS_DWELL_CTRL_REG, 0, 15, 0),

	/* Hardware Protection */
	SOC_SINGLE("OTSD Auto Recovery Switch", TAS6754_OTSD_RECOVERY_EN_REG, 1, 1, 0),
	SOC_ENUM("Overcurrent Limit Level", tas6754_oc_limit_enum),
	SOC_ENUM("CH1 OTW Threshold", tas6754_ch1_otw_enum),
	SOC_ENUM("CH2 OTW Threshold", tas6754_ch2_otw_enum),
	SOC_ENUM("CH3 OTW Threshold", tas6754_ch3_otw_enum),
	SOC_ENUM("CH4 OTW Threshold", tas6754_ch4_otw_enum),

	/* DSP Signal Path & Mode */
	SOC_ENUM("DSP Signal Path Mode", tas6754_dsp_mode_enum),

	/* DC Load Diagnostics */
	{
		.iface = SNDRV_CTL_ELEM_IFACE_MIXER,
		.name = "DC LDG Trigger",
		.access = SNDRV_CTL_ELEM_ACCESS_WRITE,
		.info = snd_ctl_boolean_mono_info,
		.put = tas6754_set_dcldg_trigger,
	},
	SOC_SINGLE("DC LDG Auto Diagnostics Switch", TAS6754_DC_LDG_CTRL_REG, 0, 1, 1),
	SOC_SINGLE("CH1 LO LDG Switch", TAS6754_DC_LDG_LO_CTRL_REG, 3, 1, 0),
	SOC_SINGLE("CH2 LO LDG Switch", TAS6754_DC_LDG_LO_CTRL_REG, 2, 1, 0),
	SOC_SINGLE("CH3 LO LDG Switch", TAS6754_DC_LDG_LO_CTRL_REG, 1, 1, 0),
	SOC_SINGLE("CH4 LO LDG Switch", TAS6754_DC_LDG_LO_CTRL_REG, 0, 1, 0),
	SOC_ENUM("DC LDG SLOL Ramp Time", tas6754_dc_slol_ramp_enum),
	SOC_ENUM("DC LDG SLOL Settling Time", tas6754_dc_slol_settling_enum),
	SOC_ENUM("DC LDG S2PG Ramp Time", tas6754_dc_s2pg_ramp_enum),
	SOC_ENUM("DC LDG S2PG Settling Time", tas6754_dc_s2pg_settling_enum),
	SOC_ENUM("CH1 DC LDG SL Threshold", tas6754_ch1_dc_ldg_sl_enum),
	SOC_ENUM("CH2 DC LDG SL Threshold", tas6754_ch2_dc_ldg_sl_enum),
	SOC_ENUM("CH3 DC LDG SL Threshold", tas6754_ch3_dc_ldg_sl_enum),
	SOC_ENUM("CH4 DC LDG SL Threshold", tas6754_ch4_dc_ldg_sl_enum),
	SOC_SINGLE_RO("DC LDG Result", TAS6754_DC_LDG_RESULT_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH1 DC LDG Report", TAS6754_DC_LDG_REPORT_CH1_CH2_REG, 4, 0x0F),
	SOC_SINGLE_RO("CH2 DC LDG Report", TAS6754_DC_LDG_REPORT_CH1_CH2_REG, 0, 0x0F),
	SOC_SINGLE_RO("CH3 DC LDG Report", TAS6754_DC_LDG_REPORT_CH3_CH4_REG, 4, 0x0F),
	SOC_SINGLE_RO("CH4 DC LDG Report", TAS6754_DC_LDG_REPORT_CH3_CH4_REG, 0, 0x0F),
	SOC_SINGLE_RO("CH1 LO LDG Report", TAS6754_DC_LDG_RESULT_REG, 7, 1),
	SOC_SINGLE_RO("CH2 LO LDG Report", TAS6754_DC_LDG_RESULT_REG, 6, 1),
	SOC_SINGLE_RO("CH3 LO LDG Report", TAS6754_DC_LDG_RESULT_REG, 5, 1),
	SOC_SINGLE_RO("CH4 LO LDG Report", TAS6754_DC_LDG_RESULT_REG, 4, 1),
	SOC_DC_RESIST_RO("CH1 DC Resistance", TAS6754_CH1_DC_LDG_DCR_LSB_REG),
	SOC_DC_RESIST_RO("CH2 DC Resistance", TAS6754_CH2_DC_LDG_DCR_LSB_REG),
	SOC_DC_RESIST_RO("CH3 DC Resistance", TAS6754_CH3_DC_LDG_DCR_LSB_REG),
	SOC_DC_RESIST_RO("CH4 DC Resistance", TAS6754_CH4_DC_LDG_DCR_LSB_REG),

	/* AC Load Diagnostics */
	{
		.iface = SNDRV_CTL_ELEM_IFACE_MIXER,
		.name = "AC LDG Trigger",
		.access = SNDRV_CTL_ELEM_ACCESS_WRITE,
		.info = snd_ctl_boolean_mono_info,
		.put = tas6754_set_acldg_trigger,
	},
	SOC_SINGLE("AC DIAG GAIN", TAS6754_AC_LDG_CTRL_REG, 4, 1, 0),
	SOC_SINGLE("AC LDG Test Frequency", TAS6754_AC_LDG_FREQ_CTRL_REG, 0, 0xFF, 0),
	SOC_SINGLE_RO("CH1 AC LDG Real", TAS6754_AC_LDG_REPORT_CH1_R_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH1 AC LDG Imag", TAS6754_AC_LDG_REPORT_CH1_I_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH2 AC LDG Real", TAS6754_AC_LDG_REPORT_CH2_R_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH2 AC LDG Imag", TAS6754_AC_LDG_REPORT_CH2_I_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH3 AC LDG Real", TAS6754_AC_LDG_REPORT_CH3_R_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH3 AC LDG Imag", TAS6754_AC_LDG_REPORT_CH3_I_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH4 AC LDG Real", TAS6754_AC_LDG_REPORT_CH4_R_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH4 AC LDG Imag", TAS6754_AC_LDG_REPORT_CH4_I_REG, 0, 0xFF),

	/* Temperature and Voltage Monitoring */
	SOC_SINGLE_RO("PVDD Sense", TAS6754_PVDD_SENSE_REG, 0, 0xFF),
	SOC_SINGLE_RO("Global Temperature", TAS6754_TEMP_GLOBAL_REG, 0, 0xFF),
	SOC_SINGLE_RO("CH1 Temperature Range", TAS6754_TEMP_CH1_CH2_REG, 6, 3),
	SOC_SINGLE_RO("CH2 Temperature Range", TAS6754_TEMP_CH1_CH2_REG, 4, 3),
	SOC_SINGLE_RO("CH3 Temperature Range", TAS6754_TEMP_CH3_CH4_REG, 2, 3),
	SOC_SINGLE_RO("CH4 Temperature Range", TAS6754_TEMP_CH3_CH4_REG, 0, 3),

	/* Speaker Protection & Detection */
	SOC_SINGLE("Tweeter Detection Switch", TAS6754_TWEETER_DETECT_CTRL_REG, 0, 1, 1),
	SOC_SINGLE("Tweeter Detect Threshold", TAS6754_TWEETER_DETECT_THRESH_REG, 0, 0xFF, 0),
	SOC_SINGLE_RO("CH1 Tweeter Detect Report", TAS6754_TWEETER_REPORT_REG, 3, 1),
	SOC_SINGLE_RO("CH2 Tweeter Detect Report", TAS6754_TWEETER_REPORT_REG, 2, 1),
	SOC_SINGLE_RO("CH3 Tweeter Detect Report", TAS6754_TWEETER_REPORT_REG, 1, 1),
	SOC_SINGLE_RO("CH4 Tweeter Detect Report", TAS6754_TWEETER_REPORT_REG, 0, 1),

	/*
	 * Unavailable in LLP, available in Normal & FFLP
	 */
	SOC_SINGLE("Thermal Foldback Switch", TAS6754_DSP_CTRL_REG, 0, 1, 0),
	SOC_SINGLE("PVDD Foldback Switch", TAS6754_DSP_CTRL_REG, 4, 1, 0),
	SOC_SINGLE("DC Blocker Bypass Switch", TAS6754_DC_BLOCK_BYP_REG, 0, 1, 0),
	SOC_SINGLE("Clip Detect Switch", TAS6754_CLIP_DETECT_CTRL_REG, 6, 1, 0),
	SOC_SINGLE("Audio SDOUT Switch", TAS6754_DSP_CTRL_REG, 5, 1, 0),

	/*
	 * Unavailable in both FFLP and LLP, Normal mode only
	 */

	/* Real-Time Load Diagnostics */
	SOC_SINGLE("CH1 RTLDG Switch", TAS6754_RTLDG_EN_REG, 3, 1, 0),
	SOC_SINGLE("CH2 RTLDG Switch", TAS6754_RTLDG_EN_REG, 2, 1, 0),
	SOC_SINGLE("CH3 RTLDG Switch", TAS6754_RTLDG_EN_REG, 1, 1, 0),
	SOC_SINGLE("CH4 RTLDG Switch", TAS6754_RTLDG_EN_REG, 0, 1, 0),
	SOC_SINGLE("RTLDG Clip Mask Switch", TAS6754_RTLDG_EN_REG, 4, 1, 0),
	SOC_SINGLE("ISENSE Calibration Switch", TAS6754_ISENSE_CAL_REG, 3, 1, 0),
	SOC_DSP_THRESH_EXT("RTLDG Open Load Threshold", tas6754_rtldg_ol_thresh),
	SOC_DSP_THRESH_EXT("RTLDG Short Load Threshold", tas6754_rtldg_sl_thresh),
	SOC_RTLDG_IMP_RO("CH1 RTLDG Impedance", TAS6754_CH1_RTLDG_IMP_MSB_REG),
	SOC_RTLDG_IMP_RO("CH2 RTLDG Impedance", TAS6754_CH2_RTLDG_IMP_MSB_REG),
	SOC_RTLDG_IMP_RO("CH3 RTLDG Impedance", TAS6754_CH3_RTLDG_IMP_MSB_REG),
	SOC_RTLDG_IMP_RO("CH4 RTLDG Impedance", TAS6754_CH4_RTLDG_IMP_MSB_REG),
	SOC_SINGLE_RO("RTLDG Fault Latched", TAS6754_RTLDG_OL_SL_FAULT_LATCHED_REG, 0, 0xFF),
};

static const struct snd_kcontrol_new tas6754_audio_path_switch =
	SOC_DAPM_SINGLE("Switch", SND_SOC_NOPM, 0, 1, 1);

static const struct snd_kcontrol_new tas6754_anc_path_switch =
	SOC_DAPM_SINGLE("Switch", SND_SOC_NOPM, 0, 1, 1);

static int tas6754_dapm_sleep_event(struct snd_soc_dapm_widget *w,
				    struct snd_kcontrol *kcontrol, int event)
{
	struct snd_soc_component *component = snd_soc_dapm_to_component(w->dapm);

	switch (event) {
	case SND_SOC_DAPM_POST_PMU:
		pm_runtime_get_sync(component->dev);
		break;
	case SND_SOC_DAPM_PRE_PMD:
		pm_runtime_mark_last_busy(component->dev);
		pm_runtime_put_autosuspend(component->dev);
		break;
	}
	return 0;
}

static const struct snd_soc_dapm_widget tas6754_dapm_widgets[] = {
	SND_SOC_DAPM_SUPPLY("Analog Core", SND_SOC_NOPM, 0, 0,
			    tas6754_dapm_sleep_event,
			    SND_SOC_DAPM_POST_PMU | SND_SOC_DAPM_PRE_PMD),
	SND_SOC_DAPM_SUPPLY("SDOUT Vpredict", TAS6754_SDOUT_EN_REG, 0, 0, NULL, 0),
	SND_SOC_DAPM_SUPPLY("SDOUT Isense", TAS6754_SDOUT_EN_REG, 1, 0, NULL, 0),

	SND_SOC_DAPM_DAC("Audio DAC", "Playback", SND_SOC_NOPM, 0, 0),
	SND_SOC_DAPM_DAC("ANC DAC", "ANC Playback", SND_SOC_NOPM, 0, 0),
	SND_SOC_DAPM_ADC("Feedback ADC", "Feedback Capture", SND_SOC_NOPM, 0, 0),

	SND_SOC_DAPM_SWITCH("Audio Path", SND_SOC_NOPM, 0, 0,
			     &tas6754_audio_path_switch),
	SND_SOC_DAPM_SWITCH("ANC Path", SND_SOC_NOPM, 0, 0,
			     &tas6754_anc_path_switch),

	/*
	 * Even though all channels are coupled in terms of power control,
	 * use logical outputs for each channel to allow independent routing
	 * and DAPM controls if needed.
	 */
	SND_SOC_DAPM_OUTPUT("OUT_CH1"),
	SND_SOC_DAPM_OUTPUT("OUT_CH2"),
	SND_SOC_DAPM_OUTPUT("OUT_CH3"),
	SND_SOC_DAPM_OUTPUT("OUT_CH4"),
	SND_SOC_DAPM_INPUT("SPEAKER_LOAD"),
};

static const struct snd_soc_dapm_route tas6754_audio_map[] = {
	{ "Audio DAC", NULL, "Analog Core" },
	{ "Audio Path", "Switch", "Audio DAC" },
	{ "OUT_CH1", NULL, "Audio Path" },
	{ "OUT_CH2", NULL, "Audio Path" },
	{ "OUT_CH3", NULL, "Audio Path" },
	{ "OUT_CH4", NULL, "Audio Path" },

	{ "ANC DAC", NULL, "Analog Core" },
	{ "ANC Path", "Switch", "ANC DAC" },
	{ "OUT_CH1", NULL, "ANC Path" },
	{ "OUT_CH2", NULL, "ANC Path" },
	{ "OUT_CH3", NULL, "ANC Path" },
	{ "OUT_CH4", NULL, "ANC Path" },

	{ "Feedback ADC", NULL, "Analog Core" },
	{ "Feedback ADC", NULL, "SDOUT Vpredict" },
	{ "Feedback ADC", NULL, "SDOUT Isense" },
	{ "Feedback ADC", NULL, "SPEAKER_LOAD" },
};

static void tas6754_program_slot_offsets(struct tas6754_priv *tas,
					 int dai_id, int slot_width)
{
	int offset;

	switch (dai_id) {
	case 0:
	/* Standard Audio on SDIN */
		if (tas->audio_slot >= 0)
			offset = tas->audio_slot * slot_width;
		else if (tas->tx_mask)
			offset = __ffs(tas->tx_mask) * slot_width;
		else
			return;
		offset += tas->bclk_offset;
		regmap_update_bits(tas->regmap, TAS6754_SDIN_OFFSET_MSB_REG,
				   TAS6754_SDIN_AUDIO_OFF_MSB_MASK,
				   FIELD_PREP(TAS6754_SDIN_AUDIO_OFF_MSB_MASK, offset >> 8));
		regmap_write(tas->regmap, TAS6754_SDIN_AUDIO_OFFSET_REG,
			     offset & 0xFF);
		break;
	case 1:
	/*
	 * Low-Latency Playback on SDIN, **only** enabled in LLP mode
	 * and to be mixed with main audio before output amplification
	 * to achieve ANC/RNC.
	 */
		if (tas->llp_slot >= 0)
			offset = tas->llp_slot * slot_width;
		else if (tas->tx_mask)
			offset = __ffs(tas->tx_mask) * slot_width;
		else
			return;
		offset += tas->bclk_offset;
		regmap_update_bits(tas->regmap, TAS6754_SDIN_OFFSET_MSB_REG,
				   TAS6754_SDIN_LL_OFF_MSB_MASK,
				   FIELD_PREP(TAS6754_SDIN_LL_OFF_MSB_MASK, offset >> 8));
		regmap_write(tas->regmap, TAS6754_SDIN_LL_OFFSET_REG,
			     offset & 0xFF);
		break;
	case 2:
	/* SDOUT Data Output (Vpredict + Isense feedback) */
		if (tas->vpredict_slot >= 0)
			offset = tas->vpredict_slot * slot_width;
		else if (tas->rx_mask)
			offset = __ffs(tas->rx_mask) * slot_width;
		else
			return;
		offset += tas->bclk_offset;
		regmap_update_bits(tas->regmap, TAS6754_SDOUT_OFFSET_MSB_REG,
				   TAS6754_SDOUT_VP_OFF_MSB_MASK,
				   FIELD_PREP(TAS6754_SDOUT_VP_OFF_MSB_MASK, offset >> 8));
		regmap_write(tas->regmap, TAS6754_VPREDICT_OFFSET_REG,
			     offset & 0xFF);

		if (tas->isense_slot >= 0)
			offset = tas->isense_slot * slot_width;
		else if (tas->rx_mask)
			offset = (__ffs(tas->rx_mask) + 4) * slot_width;
		else
			break;
		offset += tas->bclk_offset;
		regmap_update_bits(tas->regmap, TAS6754_SDOUT_OFFSET_MSB_REG,
				   TAS6754_SDOUT_IS_OFF_MSB_MASK,
				   FIELD_PREP(TAS6754_SDOUT_IS_OFF_MSB_MASK, offset >> 8));
		regmap_write(tas->regmap, TAS6754_ISENSE_OFFSET_REG,
			     offset & 0xFF);
		break;
	}
}

static int tas6754_hw_params(struct snd_pcm_substream *substream,
			     struct snd_pcm_hw_params *params,
			     struct snd_soc_dai *dai)
{
	struct snd_soc_component *component = dai->component;
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(component);
	unsigned int rate = params_rate(params);
	u8 word_length;

	/*
	 * Single clock domain: SDIN and SDOUT share one SCLK/FSYNC pair,
	 * so all active DAIs must use the same sample rate.
	 */
	if ((tas->active_playback_dais || tas->active_capture_dais) &&
	    tas->rate && tas->rate != rate) {
		dev_err(component->dev,
			"Rate %u conflicts with active rate %u\n",
			rate, tas->rate);
		return -EINVAL;
	}

	switch (params_width(params)) {
	case 16:
		word_length = TAS6754_WL_16BIT;
		break;
	case 20:
		word_length = TAS6754_WL_20BIT;
		break;
	case 24:
		word_length = TAS6754_WL_24BIT;
		break;
	case 32:
		word_length = TAS6754_WL_32BIT;
		break;
	default:
		return -EINVAL;
	}

	if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK) {
		/*
		 * RTLDG is not supported above 96kHz. Auto-disable to
		 * prevent DSP overload and restore when rate drops back.
		 */
		if (params_rate(params) > 96000) {
			unsigned int val;

			regmap_read(component->regmap, TAS6754_RTLDG_EN_REG,
				    &val);
			if (val & TAS6754_RTLDG_CH_EN_MASK) {
				tas->saved_rtldg_en = val;
				dev_dbg(component->dev,
					 "Sample rate %dHz > 96kHz: Auto-disabling RTLDG\n",
					 params_rate(params));
				regmap_update_bits(component->regmap,
						   TAS6754_RTLDG_EN_REG,
						   TAS6754_RTLDG_CH_EN_MASK,
						   0x00);
			}
		} else if (tas->saved_rtldg_en) {
			unsigned int cur;

			/*
			 * Respect overrides and only restore if RTLDG is still auto-disabled
			 */
			regmap_read(component->regmap, TAS6754_RTLDG_EN_REG,
				    &cur);
			if (!(cur & TAS6754_RTLDG_CH_EN_MASK)) {
				dev_dbg(component->dev,
					 "Restoring RTLDG config after high-rate stream\n");
				regmap_update_bits(component->regmap,
						   TAS6754_RTLDG_EN_REG,
						   TAS6754_RTLDG_CH_EN_MASK,
						   TAS6754_RTLDG_CH_EN_MASK &
							tas->saved_rtldg_en);
			}
			tas->saved_rtldg_en = 0;
		}

		/* Set SDIN word length (audio path + low-latency path) */
		regmap_update_bits(component->regmap, TAS6754_SDIN_CTRL_REG,
				   TAS6754_SDIN_WL_MASK,
				   FIELD_PREP(TAS6754_SDIN_AUDIO_WL_MASK, word_length) |
				   FIELD_PREP(TAS6754_SDIN_LL_WL_MASK, word_length));
	} else {
		/* Set SDOUT word length (VPREDICT + ISENSE) for capture */
		regmap_update_bits(component->regmap, TAS6754_SDOUT_CTRL_REG,
				   TAS6754_SDOUT_WL_MASK,
				   FIELD_PREP(TAS6754_SDOUT_VP_WL_MASK, word_length) |
				   FIELD_PREP(TAS6754_SDOUT_IS_WL_MASK, word_length));
	}

	tas6754_program_slot_offsets(tas, dai->id,
				    tas->slot_width ?: params_width(params));

	tas->rate = rate;

	return 0;
}

static int tas6754_set_dai_fmt(struct snd_soc_dai *dai, unsigned int fmt)
{
	struct snd_soc_component *component = dai->component;
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(component);

	/* Enforce Clocking Direction (Codec is strictly a consumer) */
	switch (fmt & SND_SOC_DAIFMT_CLOCK_PROVIDER_MASK) {
	case SND_SOC_DAIFMT_BC_FC:
		break;
	default:
		dev_err(component->dev, "Unsupported clock provider format\n");
		return -EINVAL;
	}

	/* SCLK polarity: NB_NF or IB_NF only (no FSYNC inversion support) */
	switch (fmt & SND_SOC_DAIFMT_INV_MASK) {
	case SND_SOC_DAIFMT_NB_NF:
		regmap_update_bits(component->regmap, TAS6754_SCLK_INV_CTRL_REG,
				   TAS6754_SCLK_INV_MASK, 0x00);
		break;
	case SND_SOC_DAIFMT_IB_NF:
		regmap_update_bits(component->regmap, TAS6754_SCLK_INV_CTRL_REG,
				   TAS6754_SCLK_INV_MASK, TAS6754_SCLK_INV_MASK);
		break;
	default:
		dev_err(component->dev, "Unsupported clock inversion\n");
		return -EINVAL;
	}

	/* Configure Audio Format and TDM Enable */
	switch (fmt & SND_SOC_DAIFMT_FORMAT_MASK) {
	case SND_SOC_DAIFMT_I2S:
		tas->bclk_offset = 0;
		regmap_update_bits(component->regmap, TAS6754_AUDIO_IF_CTRL_REG,
				   TAS6754_TDM_EN_BIT | TAS6754_SAP_FMT_MASK |
				   TAS6754_FS_PULSE_MASK,
				   TAS6754_SAP_FMT_I2S);
		regmap_update_bits(component->regmap, TAS6754_SDOUT_CTRL_REG,
				   TAS6754_SDOUT_SELECT_MASK,
				   TAS6754_SDOUT_SELECT_NON_TDM);
		break;
	case SND_SOC_DAIFMT_RIGHT_J:
		tas->bclk_offset = 0;
		regmap_update_bits(component->regmap, TAS6754_AUDIO_IF_CTRL_REG,
				   TAS6754_TDM_EN_BIT | TAS6754_SAP_FMT_MASK |
				   TAS6754_FS_PULSE_MASK,
				   TAS6754_SAP_FMT_RIGHT_J);
		regmap_update_bits(component->regmap, TAS6754_SDOUT_CTRL_REG,
				   TAS6754_SDOUT_SELECT_MASK,
				   TAS6754_SDOUT_SELECT_NON_TDM);
		break;
	case SND_SOC_DAIFMT_LEFT_J:
		tas->bclk_offset = 0;
		regmap_update_bits(component->regmap, TAS6754_AUDIO_IF_CTRL_REG,
				   TAS6754_TDM_EN_BIT | TAS6754_SAP_FMT_MASK |
				   TAS6754_FS_PULSE_MASK,
				   TAS6754_SAP_FMT_LEFT_J);
		regmap_update_bits(component->regmap, TAS6754_SDOUT_CTRL_REG,
				   TAS6754_SDOUT_SELECT_MASK,
				   TAS6754_SDOUT_SELECT_NON_TDM);
		break;
	case SND_SOC_DAIFMT_DSP_A:
		tas->bclk_offset = 1;
		regmap_update_bits(component->regmap, TAS6754_AUDIO_IF_CTRL_REG,
				   TAS6754_TDM_EN_BIT | TAS6754_SAP_FMT_MASK |
				   TAS6754_FS_PULSE_MASK,
				   TAS6754_TDM_EN_BIT | TAS6754_SAP_FMT_TDM |
				   TAS6754_FS_PULSE_SHORT);
		regmap_update_bits(component->regmap, TAS6754_SDOUT_CTRL_REG,
				   TAS6754_SDOUT_SELECT_MASK,
				   TAS6754_SDOUT_SELECT_TDM_SDOUT1);
		break;
	case SND_SOC_DAIFMT_DSP_B:
		tas->bclk_offset = 0;
		regmap_update_bits(component->regmap, TAS6754_AUDIO_IF_CTRL_REG,
				   TAS6754_TDM_EN_BIT | TAS6754_SAP_FMT_MASK |
				   TAS6754_FS_PULSE_MASK,
				   TAS6754_TDM_EN_BIT | TAS6754_SAP_FMT_TDM |
				   TAS6754_FS_PULSE_SHORT);
		regmap_update_bits(component->regmap, TAS6754_SDOUT_CTRL_REG,
				   TAS6754_SDOUT_SELECT_MASK,
				   TAS6754_SDOUT_SELECT_TDM_SDOUT1);
		break;
	default:
		dev_err(component->dev, "Unsupported DAI format\n");
		return -EINVAL;
	}

	return 0;
}

static int tas6754_set_tdm_slot(struct snd_soc_dai *dai, unsigned int tx_mask,
				unsigned int rx_mask, int slots, int slot_width)
{
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(dai->component);

	if (slots == 0) {
		tas->slot_width = 0;
		tas->tx_mask = 0;
		tas->rx_mask = 0;
		return 0;
	}

	tas->slot_width = slot_width;
	tas->tx_mask = tx_mask;
	tas->rx_mask = rx_mask;
	return 0;
}

static int tas6754_mute_stream(struct snd_soc_dai *dai, int mute, int direction)
{
	struct snd_soc_component *component = dai->component;
	struct tas6754_priv *tas = snd_soc_component_get_drvdata(component);

	if (direction == SNDRV_PCM_STREAM_CAPTURE) {
		if (mute)
			clear_bit(dai->id, &tas->active_capture_dais);
		else
			set_bit(dai->id, &tas->active_capture_dais);
	} else {
		/*
		 * Track which playback DAIs are active,
		 * The TAS67 has two playback DAIs (main audio and llp).
		 * Only transition to Hi-Z when ALL are muted.
		 */
		if (mute)
			clear_bit(dai->id, &tas->active_playback_dais);
		else
			set_bit(dai->id, &tas->active_playback_dais);

		return tas6754_set_state_all(tas,
					     tas->active_playback_dais ?
						TAS6754_STATE_PLAY_BOTH :
						TAS6754_STATE_HIZ_BOTH);
	}

	return 0;
}

static const struct snd_soc_dai_ops tas6754_dai_ops = {
	.hw_params	= tas6754_hw_params,
	.set_fmt	= tas6754_set_dai_fmt,
	.set_tdm_slot	= tas6754_set_tdm_slot,
	.mute_stream	= tas6754_mute_stream,
};

static struct snd_soc_dai_driver tas6754_dais[] = {
	{
		.name = "tas6754-audio",
		.id = 0,
		.playback = {
			.stream_name = "Playback",
			.channels_min = 2,
			.channels_max = 4,
			.rates = SNDRV_PCM_RATE_44100 | SNDRV_PCM_RATE_48000 |
				 SNDRV_PCM_RATE_96000 | SNDRV_PCM_RATE_192000,
			.formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S20_LE |
				   SNDRV_PCM_FMTBIT_S24_LE | SNDRV_PCM_FMTBIT_S32_LE,
		},
		.ops = &tas6754_dai_ops,
	},
	/* Only available when Low Latency Path (LLP) is enabled */
	{
		.name = "tas6754-anc",
		.id = 1,
		.playback = {
			.stream_name = "ANC Playback",
			.channels_min = 2,
			.channels_max = 4,
			.rates = SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_96000,
			.formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S20_LE |
				   SNDRV_PCM_FMTBIT_S24_LE | SNDRV_PCM_FMTBIT_S32_LE,
		},
		.ops = &tas6754_dai_ops,
	},
	{
		.name = "tas6754-feedback",
		.id = 2,
		.capture = {
			.stream_name = "Feedback Capture",
			.channels_min = 2,
			.channels_max = 8,
			.rates = SNDRV_PCM_RATE_48000,
			.formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S20_LE |
				   SNDRV_PCM_FMTBIT_S24_LE | SNDRV_PCM_FMTBIT_S32_LE,
		},
		.ops = &tas6754_dai_ops,
	}
};

/**
 * Hardware power sequencing
 * Handles regulator enable and GPIO deassertion.
 * The device is not be I2C-accessible until boot wait completes.
 */
static int tas6754_hw_enable(struct tas6754_priv *tas)
{
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE(tas->supplies), tas->supplies);
	if (ret) {
		dev_err(tas->dev, "Failed to enable regulators: %d\n", ret);
		return ret;
	}

	if (tas->pd_gpio && tas->stby_gpio) {
		/*
		 * Independent Pin Control
		 * Deassert PD first to boot digital, then STBY for analog.
		 */
		/* Min 4ms digital boot wait */
		gpiod_set_value_cansleep(tas->pd_gpio, 0);
		usleep_range(4000, 5000);

		/* ~2ms analog stabilization */
		gpiod_set_value_cansleep(tas->stby_gpio, 0);
		usleep_range(2000, 3000);
	} else if (tas->pd_gpio) {
		/*
		 * Simultaneous Pin Release
		 * STBY tied to PD or hardwired HIGH.
		 */
		/* 6ms wait for simultaneous release transition */
		gpiod_set_value_cansleep(tas->pd_gpio, 0);
		usleep_range(6000, 7000);
	} else {
		/*
		 * PD hardwired, device in DEEP SLEEP.
		 * Digital core already booted, I2C active.  Deassert STBY
		 * to bring up the analog output stage.
		 */
		/* ~2ms analog stabilization */
		gpiod_set_value_cansleep(tas->stby_gpio, 0);
		usleep_range(2000, 3000);
	}

	return 0;
}

/**
 * Device start-up defaults
 * Must be called after tas6754_hw_enable() and after regcache is enabled.
 */
static int tas6754_init_device(struct tas6754_priv *tas)
{
	struct regmap *regmap = tas->regmap;
	unsigned int val;
	int ret;

	/* Clear POR fault flag to prevent IRQ storm */
	regmap_read(regmap, TAS6754_POWER_FAULT_LATCHED_REG, &val);

	/* Bypass DC Load Diagnostics for fast boot */
	if (tas->fast_boot)
		regmap_update_bits(regmap, TAS6754_DC_LDG_CTRL_REG,
				   TAS6754_LDG_ABORT_BIT | TAS6754_LDG_BYPASS_BIT,
				   TAS6754_LDG_ABORT_BIT | TAS6754_LDG_BYPASS_BIT);

	tas6754_select_book(regmap, TAS6754_BOOK_DEFAULT);

	/* Enter setup mode */
	ret = regmap_write(regmap, TAS6754_SETUP_REG1, TAS6754_SETUP_ENTER_VAL1);
	if (ret)
		goto err;
	ret = regmap_write(regmap, TAS6754_SETUP_REG2, TAS6754_SETUP_ENTER_VAL2);
	if (ret)
		goto err;

	/* Set all channels to Sleep (required before Page 1 config) */
	tas6754_set_state_all(tas, TAS6754_STATE_SLEEP_BOTH);

	/* Set DAC clock per TRM startup script */
	regmap_write(regmap, TAS6754_DAC_CLK_REG, 0x00);

	/*
	 * Switch to Page 1 for safety-critical OC/CBC configuration,
	 * while bypassing regcache. (Regcache bookkeeps book 0 only)
	 */
	regcache_cache_bypass(regmap, true);

	ret = regmap_multi_reg_write(regmap, tas6754_page1_init,
				    ARRAY_SIZE(tas6754_page1_init));

	regcache_cache_bypass(regmap, false);
	if (ret)
		goto err_setup;

	/* Resync regmap's cached page selector */
	regmap_write(regmap, TAS6754_PAGE_CTRL_REG, 0x00);

	/* Exit setup mode */
	regmap_write(regmap, TAS6754_SETUP_REG1, TAS6754_SETUP_EXIT_VAL);
	regmap_write(regmap, TAS6754_SETUP_REG2, TAS6754_SETUP_EXIT_VAL);

	/*
	 * Route fault events to FAULT pin for IRQ handler
	 *
	 * ROUTING_1: latched CP fault, CP UVLO, OUTM soft short
	 * ROUTING_2: non-latching power fault events (+ default OTSD, CBC)
	 * ROUTING_4: OTW, clip warning, protection shutdown, OC, DC
	 * ROUTING_5: clock, CBC warning, RTLDG, clip detect
	 */
	regmap_write(regmap, TAS6754_REPORT_ROUTING_1_REG, 0x70);
	regmap_write(regmap, TAS6754_REPORT_ROUTING_2_REG, 0xA3);
	regmap_write(regmap, TAS6754_REPORT_ROUTING_4_REG, 0x7E);
	regmap_write(regmap, TAS6754_REPORT_ROUTING_5_REG, 0xF3);

	/* Configure GPIO pins if specified in DT */
	if (tas->gpio1_func >= 0 || tas->gpio2_func >= 0) {
		unsigned int gpio_ctrl = TAS6754_GPIO_CTRL_RSTVAL;

		tas6754_config_gpio_pin(regmap, tas->gpio1_func,
					TAS6754_GPIO1_OUTPUT_SEL_REG,
					0, &gpio_ctrl);
		tas6754_config_gpio_pin(regmap, tas->gpio2_func,
					TAS6754_GPIO2_OUTPUT_SEL_REG,
					1, &gpio_ctrl);
		regmap_write(regmap, TAS6754_GPIO_CTRL_REG, gpio_ctrl);
	}

	/* Transition all channels to Hi-Z */
	tas6754_set_state_all(tas, TAS6754_STATE_HIZ_BOTH);

	/* Clear fast boot bits after HIZ transition */
	if (tas->fast_boot)
		regmap_update_bits(regmap, TAS6754_DC_LDG_CTRL_REG,
				   TAS6754_LDG_ABORT_BIT | TAS6754_LDG_BYPASS_BIT,
				   0);

	/* Clear any stale faults from the boot sequence */
	regmap_read(regmap, TAS6754_POWER_FAULT_LATCHED_REG, &val);
	regmap_write(regmap, TAS6754_RESET_REG, TAS6754_FAULT_CLEAR);

	return 0;

err_setup:
	/* Best-effort: exit setup mode */
	regmap_write(regmap, TAS6754_SETUP_REG1, TAS6754_SETUP_EXIT_VAL);
	regmap_write(regmap, TAS6754_SETUP_REG2, TAS6754_SETUP_EXIT_VAL);
err:
	dev_err(tas->dev, "Init device failed: %d\n", ret);
	return ret;
}

static void tas6754_hw_disable(struct tas6754_priv *tas)
{
	if (tas->stby_gpio)
		gpiod_set_value_cansleep(tas->stby_gpio, 1);

	if (tas->pd_gpio)
		gpiod_set_value_cansleep(tas->pd_gpio, 1);

	/*
	 * Hold PD/STBY asserted for at least 10ms
	 * before removing PVDD, VBAT or DVDD.
	 */
	usleep_range(10000, 11000);

	regulator_bulk_disable(ARRAY_SIZE(tas->supplies), tas->supplies);
}

static int __maybe_unused tas6754_runtime_suspend(struct device *dev)
{
	struct tas6754_priv *tas = dev_get_drvdata(dev);

	/* Stop fault polling */
	cancel_delayed_work_sync(&tas->fault_check_work);

	/* Transition to SLEEP*/
	tas6754_set_state_all(tas, TAS6754_STATE_SLEEP_BOTH);

	return 0;
}

static int __maybe_unused tas6754_runtime_resume(struct device *dev)
{
	struct tas6754_priv *tas = dev_get_drvdata(dev);
	unsigned int reg;
	int ret;

	/* Device on latched clock errors may refuse to HIZ transition */
	regmap_read(tas->regmap, TAS6754_CLK_FAULT_LATCHED_REG, &reg);
	if (reg)
		dev_dbg(dev, "Runtime PM: Cleared latched clock fault (0x%02x)\n", reg);

	/* Transition to HIZ */
	ret = tas6754_set_state_all(tas, TAS6754_STATE_HIZ_BOTH);
	if (ret)
		return ret;

	/* Start fault polling if no IRQ */
	if (!to_i2c_client(tas->dev)->irq)
		schedule_delayed_work(&tas->fault_check_work,
				      msecs_to_jiffies(TAS6754_FAULT_CHECK_INTERVAL_MS));

	return 0;
}

static const struct snd_soc_component_driver soc_codec_dev_tas6754 = {
	.controls		= tas6754_snd_controls,
	.num_controls		= ARRAY_SIZE(tas6754_snd_controls),
	.dapm_widgets		= tas6754_dapm_widgets,
	.num_dapm_widgets	= ARRAY_SIZE(tas6754_dapm_widgets),
	.dapm_routes		= tas6754_audio_map,
	.num_dapm_routes	= ARRAY_SIZE(tas6754_audio_map),
	.endianness		= 1,
};

/* Fault register flags */
#define TAS6754_FAULT_CRITICAL	BIT(0)	/* dev_crit, sets is_latched, abort on read error */
#define TAS6754_FAULT_TRACK	BIT(1)	/* track last value, only log on change */
#define TAS6754_FAULT_ACTIVE	BIT(2)	/* skip when no stream is active */

struct tas6754_fault_reg {
	unsigned int reg;
	unsigned int flags;
	const char *name;
};

static const struct tas6754_fault_reg tas6754_fault_table[] = {
	/* Critical */
	{ TAS6754_POWER_FAULT_LATCHED_REG,       TAS6754_FAULT_CRITICAL | TAS6754_FAULT_TRACK,
	  "Power Fault" },
	{ TAS6754_OTSD_LATCHED_REG,              TAS6754_FAULT_CRITICAL | TAS6754_FAULT_TRACK,
	  "Overtemperature Shutdown" },
	{ TAS6754_OC_DC_FAULT_LATCHED_REG,       TAS6754_FAULT_CRITICAL | TAS6754_FAULT_TRACK,
	  "Overcurrent / DC Fault" },
	/* Warning */
	{ TAS6754_RTLDG_OL_SL_FAULT_LATCHED_REG, 0,
	  "Real-Time Load Diagnostic Fault" },
	{ TAS6754_CLK_FAULT_LATCHED_REG,         TAS6754_FAULT_TRACK | TAS6754_FAULT_ACTIVE,
	  "Clock Fault" },
	{ TAS6754_OTW_LATCHED_REG,               TAS6754_FAULT_TRACK,
	  "Overtemperature Warning" },
	{ TAS6754_CLIP_WARN_LATCHED_REG,         0,
	  "Clip Warning" },
	{ TAS6754_CBC_FAULT_WARN_LATCHED_REG,    0,
	  "CBC Fault/Warning" },
};

static_assert(ARRAY_SIZE(tas6754_fault_table) == TAS6754_NUM_FAULT_REGS);

/**
 * Read and log all latched fault registers
 * Shared by both the polled fault_check_work and IRQ handler paths
 * (which are mutually exclusive, only one is active per device).
 *
 * Returns true if any critical fault was detected that needs FAULT_CLEAR.
 */
static bool tas6754_check_faults(struct tas6754_priv *tas)
{
	struct device *dev = tas->dev;
	bool is_latched = false;
	unsigned int reg;
	int i, ret;

	for (i = 0; i < ARRAY_SIZE(tas6754_fault_table); i++) {
		const struct tas6754_fault_reg *f = &tas6754_fault_table[i];

		if ((f->flags & TAS6754_FAULT_ACTIVE) &&
		    !tas->active_playback_dais && !tas->active_capture_dais)
			continue;

		ret = regmap_read(tas->regmap, f->reg, &reg);
		if (ret) {
			if (f->flags & TAS6754_FAULT_CRITICAL) {
				dev_err(dev, "failed to read %s: %d\n", f->name, ret);
				return is_latched;
			}
			continue;
		}

		if ((f->flags & TAS6754_FAULT_CRITICAL) && reg)
			is_latched = true;

		/* Log on change (dedup) or on every non-zero read */
		if (reg && (!(f->flags & TAS6754_FAULT_TRACK) ||
			    reg != tas->last_status[i])) {
			if (f->flags & TAS6754_FAULT_CRITICAL)
				dev_crit(dev, "%s Latched: 0x%02x\n", f->name, reg);
			else
				dev_warn(dev, "%s Latched: 0x%02x\n", f->name, reg);
		}

		if (f->flags & TAS6754_FAULT_TRACK)
			tas->last_status[i] = reg;
	}

	return is_latched;
}

static void tas6754_fault_check_work(struct work_struct *work)
{
	struct tas6754_priv *tas = container_of(work, struct tas6754_priv,
						fault_check_work.work);

	if (tas6754_check_faults(tas))
		regmap_write(tas->regmap, TAS6754_RESET_REG, TAS6754_FAULT_CLEAR);

	schedule_delayed_work(&tas->fault_check_work,
			      msecs_to_jiffies(TAS6754_FAULT_CHECK_INTERVAL_MS));
}

static irqreturn_t tas6754_irq_handler(int irq, void *data)
{
	struct tas6754_priv *tas = data;

	tas6754_check_faults(tas);

	/* Clear the FAULT pin latch as something latched */
	regmap_write(tas->regmap, TAS6754_RESET_REG, TAS6754_FAULT_CLEAR);

	return IRQ_HANDLED;
}

static const struct reg_default tas6754_reg_defaults[] = {
	{ TAS6754_PAGE_CTRL_REG,           0x00 },
	{ TAS6754_OUTPUT_CTRL_REG,         0x00 },
	{ TAS6754_STATE_CTRL_CH1_CH2_REG,  TAS6754_STATE_SLEEP_BOTH },
	{ TAS6754_STATE_CTRL_CH3_CH4_REG,  TAS6754_STATE_SLEEP_BOTH },
	{ TAS6754_ISENSE_CTRL_REG,         0x0F },
	{ TAS6754_DC_DETECT_CTRL_REG,      0x00 },
	{ TAS6754_SCLK_INV_CTRL_REG,       0x00 },
	{ TAS6754_AUDIO_IF_CTRL_REG,       0x00 },
	{ TAS6754_SDIN_CTRL_REG,           0x0A },
	{ TAS6754_SDOUT_CTRL_REG,          0x1A },
	{ TAS6754_SDIN_OFFSET_MSB_REG,     0x00 },
	{ TAS6754_SDIN_AUDIO_OFFSET_REG,   0x00 },
	{ TAS6754_SDIN_LL_OFFSET_REG,      0x60 },
	{ TAS6754_SDIN_CH_SWAP_REG,        0x00 },
	{ TAS6754_SDOUT_OFFSET_MSB_REG,    0xCF },
	{ TAS6754_VPREDICT_OFFSET_REG,     0xFF },
	{ TAS6754_ISENSE_OFFSET_REG,       0x00 },
	{ TAS6754_SDOUT_EN_REG,            0x00 },
	{ TAS6754_LL_EN_REG,               0x00 },
	{ TAS6754_RTLDG_EN_REG,            0x10 },
	{ TAS6754_DC_BLOCK_BYP_REG,        0x00 },
	{ TAS6754_DSP_CTRL_REG,            0x00 },
	{ TAS6754_PAGE_AUTO_INC_REG,       0x00 },
	{ TAS6754_DIG_VOL_CH1_REG,         0x30 },
	{ TAS6754_DIG_VOL_CH2_REG,         0x30 },
	{ TAS6754_DIG_VOL_CH3_REG,         0x30 },
	{ TAS6754_DIG_VOL_CH4_REG,         0x30 },
	{ TAS6754_DIG_VOL_RAMP_CTRL_REG,   0x77 },
	{ TAS6754_DIG_VOL_COMBINE_CTRL_REG, 0x00 },
	{ TAS6754_AUTO_MUTE_EN_REG,        0x00 },
	{ TAS6754_AUTO_MUTE_TIMING_CH1_CH2_REG, 0x00 },
	{ TAS6754_AUTO_MUTE_TIMING_CH3_CH4_REG, 0x00 },
	{ TAS6754_ANALOG_GAIN_CH1_CH2_REG, 0x00 },
	{ TAS6754_ANALOG_GAIN_CH3_CH4_REG, 0x00 },
	{ TAS6754_ANALOG_GAIN_RAMP_CTRL_REG, 0x00 },
	{ TAS6754_PULSE_INJECTION_EN_REG,  0x03 },
	{ TAS6754_CBC_CTRL_REG,            0x07 },
	{ TAS6754_CURRENT_LIMIT_CTRL_REG,  0x00 },
	{ TAS6754_ISENSE_CAL_REG,          0x00 },
	{ TAS6754_PWM_PHASE_CTRL_REG,      0x00 },
	{ TAS6754_SS_CTRL_REG,             0x00 },
	{ TAS6754_SS_RANGE_CTRL_REG,       0x00 },
	{ TAS6754_SS_DWELL_CTRL_REG,       0x00 },
	{ TAS6754_RAMP_PHASE_CTRL_GPO_REG, 0x00 },
	{ TAS6754_PWM_PHASE_M_CTRL_CH1_REG, 0x00 },
	{ TAS6754_PWM_PHASE_M_CTRL_CH2_REG, 0x00 },
	{ TAS6754_PWM_PHASE_M_CTRL_CH3_REG, 0x00 },
	{ TAS6754_PWM_PHASE_M_CTRL_CH4_REG, 0x00 },
	{ TAS6754_DC_LDG_CTRL_REG,         0x00 },
	{ TAS6754_DC_LDG_LO_CTRL_REG,      0x00 },
	{ TAS6754_DC_LDG_TIME_CTRL_REG,    0x00 },
	{ TAS6754_DC_LDG_SL_CH1_CH2_CTRL_REG, 0x11 },
	{ TAS6754_DC_LDG_SL_CH3_CH4_CTRL_REG, 0x11 },
	{ TAS6754_AC_LDG_CTRL_REG,         0x10 },
	{ TAS6754_TWEETER_DETECT_CTRL_REG, 0x08 },
	{ TAS6754_TWEETER_DETECT_THRESH_REG, 0x00 },
	{ TAS6754_AC_LDG_FREQ_CTRL_REG,    0xC8 },
	{ TAS6754_REPORT_ROUTING_1_REG,    0x00 },
	{ TAS6754_OTSD_RECOVERY_EN_REG,    0x00 },
	{ TAS6754_REPORT_ROUTING_2_REG,    0xA2 },
	{ TAS6754_REPORT_ROUTING_3_REG,    0x00 },
	{ TAS6754_REPORT_ROUTING_4_REG,    0x06 },
	{ TAS6754_CLIP_DETECT_CTRL_REG,    0x00 },
	{ TAS6754_REPORT_ROUTING_5_REG,    0x00 },
	{ TAS6754_GPIO1_OUTPUT_SEL_REG,    0x00 },
	{ TAS6754_GPIO2_OUTPUT_SEL_REG,    0x00 },
	{ TAS6754_GPIO_CTRL_REG,           TAS6754_GPIO_CTRL_RSTVAL },
	{ TAS6754_OTW_CTRL_CH1_CH2_REG,    0x11 },
	{ TAS6754_OTW_CTRL_CH3_CH4_REG,    0x11 },
};

static bool tas6754_is_readable_register(struct device *dev, unsigned int reg)
{
	switch (reg) {
	case TAS6754_RESET_REG:
		return false;
	default:
		return true;
	}
}

static bool tas6754_is_volatile_register(struct device *dev, unsigned int reg)
{
	switch (reg) {
	case TAS6754_RESET_REG:
	case TAS6754_BOOK_CTRL_REG:
	case TAS6754_AUTO_MUTE_STATUS_REG:
	case TAS6754_STATE_REPORT_CH1_CH2_REG:
	case TAS6754_STATE_REPORT_CH3_CH4_REG:
	case TAS6754_PVDD_SENSE_REG:
	case TAS6754_TEMP_GLOBAL_REG:
	case TAS6754_TEMP_CH1_CH2_REG:
	case TAS6754_TEMP_CH3_CH4_REG:
	case TAS6754_FS_MON_REG:
	case TAS6754_SCLK_MON_REG:
	case TAS6754_POWER_FAULT_STATUS_1_REG:
	case TAS6754_POWER_FAULT_STATUS_2_REG:
	case TAS6754_OT_FAULT_REG:
	case TAS6754_OTW_STATUS_REG:
	case TAS6754_CLIP_WARN_STATUS_REG:
	case TAS6754_CBC_WARNING_STATUS_REG:
	case TAS6754_POWER_FAULT_LATCHED_REG:
	case TAS6754_OTSD_LATCHED_REG:
	case TAS6754_OTW_LATCHED_REG:
	case TAS6754_CLIP_WARN_LATCHED_REG:
	case TAS6754_CLK_FAULT_LATCHED_REG:
	case TAS6754_RTLDG_OL_SL_FAULT_LATCHED_REG:
	case TAS6754_CBC_FAULT_WARN_LATCHED_REG:
	case TAS6754_OC_DC_FAULT_LATCHED_REG:
	case TAS6754_WARN_OT_MAX_FLAG_REG:
	case TAS6754_DC_LDG_REPORT_CH1_CH2_REG ... TAS6754_TWEETER_REPORT_REG:
	case TAS6754_CH1_RTLDG_IMP_MSB_REG ... TAS6754_CH4_DC_LDG_DCR_LSB_REG:
		return true;
	default:
		return false;
	}
}

static const struct regmap_range_cfg tas6754_ranges[] = {
	{
		.name = "Pages",
		.range_min = 0,
		.range_max = TAS6754_PAGE_SIZE * TAS6754_PAGE_SIZE - 1,
		.selector_reg = TAS6754_PAGE_CTRL_REG,
		.selector_mask = 0xff,
		.selector_shift = 0,
		.window_start = 0,
		.window_len = TAS6754_PAGE_SIZE,
	},
};

static void tas6754_regmap_lock(void *lock_arg)
{
	struct tas6754_priv *tas = lock_arg;

	mutex_lock(&tas->io_lock);
}

static void tas6754_regmap_unlock(void *lock_arg)
{
	struct tas6754_priv *tas = lock_arg;

	mutex_unlock(&tas->io_lock);
}

static const struct regmap_config tas6754_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
	.max_register = TAS6754_PAGE_SIZE * TAS6754_PAGE_SIZE - 1,
	.ranges = tas6754_ranges,
	.num_ranges = ARRAY_SIZE(tas6754_ranges),
	.cache_type = REGCACHE_MAPLE,
	.reg_defaults = tas6754_reg_defaults,
	.num_reg_defaults = ARRAY_SIZE(tas6754_reg_defaults),
	.readable_reg = tas6754_is_readable_register,
	.volatile_reg = tas6754_is_volatile_register,
};

static int tas6754_i2c_probe(struct i2c_client *client)
{
	struct regmap_config regmap_config = tas6754_regmap_config;
	struct tas6754_priv *tas;
	u32 val;
	int i, ret;

	tas = devm_kzalloc(&client->dev, sizeof(*tas), GFP_KERNEL);
	if (!tas)
		return -ENOMEM;

	tas->dev = &client->dev;
	i2c_set_clientdata(client, tas);

	mutex_init(&tas->io_lock);
	regmap_config.lock = tas6754_regmap_lock;
	regmap_config.unlock = tas6754_regmap_unlock;
	regmap_config.lock_arg = tas;
	tas->regmap = devm_regmap_init_i2c(client, &regmap_config);
	if (IS_ERR(tas->regmap))
		return PTR_ERR(tas->regmap);

	tas->dev_type = (enum tas67xx_type)(unsigned long)device_get_match_data(tas->dev);
	tas->fast_boot = device_property_read_bool(tas->dev, "ti,fast-boot");

	tas->audio_slot = -1;
	tas->llp_slot = -1;
	tas->vpredict_slot = -1;
	tas->isense_slot = -1;
	if (!device_property_read_u32(tas->dev, "ti,audio-slot-no", &val))
		tas->audio_slot = val;
	if (!device_property_read_u32(tas->dev, "ti,llp-slot-no", &val))
		tas->llp_slot = val;
	if (!device_property_read_u32(tas->dev, "ti,vpredict-slot-no", &val))
		tas->vpredict_slot = val;
	if (!device_property_read_u32(tas->dev, "ti,isense-slot-no", &val))
		tas->isense_slot = val;

	tas->gpio1_func = tas6754_gpio_func_parse(tas->dev, "ti,gpio1-function");
	tas->gpio2_func = tas6754_gpio_func_parse(tas->dev, "ti,gpio2-function");

	for (i = 0; i < ARRAY_SIZE(tas6754_supply_names); i++)
		tas->supplies[i].supply = tas6754_supply_names[i];

	ret = devm_regulator_bulk_get(tas->dev, ARRAY_SIZE(tas->supplies), tas->supplies);
	if (ret)
		return dev_err_probe(tas->dev, ret, "Failed to request supplies\n");

	tas->pd_gpio = devm_gpiod_get_optional(tas->dev, "pd", GPIOD_OUT_HIGH);
	if (IS_ERR(tas->pd_gpio))
		return dev_err_probe(tas->dev, PTR_ERR(tas->pd_gpio), "Failed pd-gpios\n");

	tas->stby_gpio = devm_gpiod_get_optional(tas->dev, "stby", GPIOD_OUT_HIGH);
	if (IS_ERR(tas->stby_gpio))
		return dev_err_probe(tas->dev, PTR_ERR(tas->stby_gpio), "Failed stby-gpios\n");

	if (!tas->pd_gpio && !tas->stby_gpio)
		return dev_err_probe(tas->dev, -EINVAL,
				     "At least one of pd-gpios or stby-gpios is required\n");

	if (client->irq) {
		ret = devm_request_threaded_irq(tas->dev, client->irq, NULL,
						tas6754_irq_handler,
						IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
						"tas6754-fault", tas);
		if (ret)
			return dev_err_probe(tas->dev, ret, "Failed to request IRQ\n");
	}

	INIT_DELAYED_WORK(&tas->fault_check_work, tas6754_fault_check_work);

	/* Power up hardware */
	ret = tas6754_hw_enable(tas);
	if (ret)
		return ret;

	regcache_cache_only(tas->regmap, false);
	ret = tas6754_init_device(tas);
	if (ret)
		goto err_hw_disable;

	ret = regcache_sync(tas->regmap);
	if (ret)
		goto err_hw_disable;

	/* Enable runtime PM with 2s autosuspend */
	pm_runtime_set_suspended(tas->dev);
	pm_runtime_enable(tas->dev);
	pm_runtime_set_autosuspend_delay(tas->dev, 2000);
	pm_runtime_use_autosuspend(tas->dev);

	ret = pm_runtime_get_sync(tas->dev);
	if (ret < 0) {
		pm_runtime_put_noidle(tas->dev);
		goto err_pm_disable;
	}

	ret = devm_snd_soc_register_component(tas->dev, &soc_codec_dev_tas6754,
					       tas6754_dais, ARRAY_SIZE(tas6754_dais));
	if (ret) {
		pm_runtime_put_noidle(tas->dev);
		goto err_pm_disable;
	}

	pm_runtime_mark_last_busy(tas->dev);
	pm_runtime_put_autosuspend(tas->dev);

	return 0;

err_pm_disable:
	pm_runtime_disable(tas->dev);
err_hw_disable:
	regcache_cache_only(tas->regmap, true);
	tas6754_hw_disable(tas);
	return ret;
}

static void tas6754_i2c_remove(struct i2c_client *client)
{
	struct tas6754_priv *tas = i2c_get_clientdata(client);

	/* Disable runtime PM */
	pm_runtime_disable(tas->dev);
	pm_runtime_set_suspended(tas->dev);

	/* Cancel any pending work */
	cancel_delayed_work_sync(&tas->fault_check_work);

	/* Transition to SLEEP before power-down */
	tas6754_set_state_all(tas, TAS6754_STATE_SLEEP_BOTH);

	regcache_cache_only(tas->regmap, true);
	tas6754_hw_disable(tas);
}

static DEFINE_RUNTIME_DEV_PM_OPS(tas6754_pm_ops,
				 tas6754_runtime_suspend,
				 tas6754_runtime_resume,
				 NULL);

static const struct of_device_id tas6754_of_match[] = {
	{ .compatible = "ti,tas6754", .data = (void *)TAS6754 },
	{ }
};
MODULE_DEVICE_TABLE(of, tas6754_of_match);

static const struct i2c_device_id tas6754_i2c_id[] = {
	{ "tas6754", TAS6754 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, tas6754_i2c_id);

static struct i2c_driver tas6754_i2c_driver = {
	.driver = {
		.name = "tas6754",
		.of_match_table = tas6754_of_match,
		.pm = pm_ptr(&tas6754_pm_ops),
	},
	.probe = tas6754_i2c_probe,
	.remove = tas6754_i2c_remove,
	.id_table = tas6754_i2c_id,
};

module_i2c_driver(tas6754_i2c_driver);

MODULE_AUTHOR("Sen Wang <sen@ti.com>");
MODULE_DESCRIPTION("TAS6754 Audio Amplifier Driver");
MODULE_LICENSE("GPL");
