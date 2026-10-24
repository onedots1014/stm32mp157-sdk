/*
 * WM8960 audio codec driver
 *
 * Clock assumption (this board):
 *   SAI1_K (~49.15 MHz) → MCKDIV=2 → MCLK = 12.288 MHz = 256 × 48 kHz
 *   WM8960 configured as I2S slave; MCLK used directly as SYSCLK (no PLL).
 *
 * Board-specific notes:
 *   - J15 combo jack: MIC pin → LINPUT1 (AC-coupled), HP_L/HP_R ← LOUT1/ROUT1
 *   - ADCLRC/GPIO1 pin not connected; ALRCGPIO=1 routes DACLRC as ADC frame sync
 */

#include "wm8960.h"
#include "cmsis_os.h"
#include <stdio.h>

#define I2C_TIMEOUT_MS  100

/* I2C handle supplied at wm8960_init() */
static I2C_HandleTypeDef *s_hi2c;

/* Shadow register cache (WM8960 registers are write-only) */
static uint16_t s_regs[WM8960_NUM_REGS];

/* Register write entry used in init sequences */
typedef struct { uint8_t addr; uint16_t val; } reg_entry_t;

/* --------------------------------------------------------------------------
 * Low-level I2C helpers
 * -------------------------------------------------------------------------- */

/* Write one 9-bit WM8960 register: [addr(7)|val[8]] [val[7:0]] */
static int wm8960_write(uint8_t addr, uint16_t val)
{
    uint8_t buf[2] = {
        (addr << 1) | ((val >> 8) & 0x01),
        val & 0xFF,
    };
    if (HAL_I2C_Master_Transmit(s_hi2c, WM8960_I2C_ADDR, buf, 2, I2C_TIMEOUT_MS) != HAL_OK) {
        printf("[wm8960] write failed addr=0x%02x\r\n", addr);
        return WM8960_ERR;
    }
    s_regs[addr] = val;
    return WM8960_OK;
}

/* Read-modify-write using shadow cache */
static int wm8960_update(uint8_t addr, uint16_t mask, uint16_t val)
{
    return wm8960_write(addr, (s_regs[addr] & ~mask) | (val & mask));
}

/* Write a sequence of register entries; stop on first error */
static int wm8960_write_seq(const reg_entry_t *seq, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        if (wm8960_write(seq[i].addr, seq[i].val) != WM8960_OK)
            return WM8960_ERR;
    }
    return WM8960_OK;
}

#define SEQ_LEN(s) (sizeof(s) / sizeof((s)[0]))

/* --------------------------------------------------------------------------
 * Input-source init sequences
 * -------------------------------------------------------------------------- */

/* Line-in: LINPUT2/RINPUT2 at 0 dB, no mic bias */
static const reg_entry_t s_linein_seq[] = {
    { WM8960_REG_POWER1,  (0x03<<7)|(1<<6)|(1<<5)|(1<<4)|(1<<3)|(1<<2) },
    { WM8960_REG_POWER3,  (1<<3)|(1<<2) },
    { WM8960_REG_LINPATH, 0x0000 },
    { WM8960_REG_RINPATH, 0x0000 },
    { WM8960_REG_INBMIX1, 0x05 },  /* LIN2BOOST = 0 dB */
    { WM8960_REG_INBMIX2, 0x05 },
};

/* Mic: LINPUT1 single-ended, +13 dB boost, mic bias enabled */
static const reg_entry_t s_mic_seq[] = {
    { WM8960_REG_POWER1,  (0x03<<7)|(1<<6)|(1<<5)|(1<<4)|(1<<3)|(1<<2)|(1<<1) },
    { WM8960_REG_POWER3,  (1<<5)|(1<<4)|(1<<3)|(1<<2) },
    { WM8960_REG_LINPATH, (1<<8)|(0x01<<4)|(1<<3) },  /* LMN1, +13 dB boost, to boost mixer */
    { WM8960_REG_RINPATH, (1<<8)|(0x01<<4)|(1<<3) },
    { WM8960_REG_INBMIX1, 0x0000 },
    { WM8960_REG_INBMIX2, 0x0000 },
};

/* --------------------------------------------------------------------------
 * Common init sequence (runs after input-source sequence)
 * -------------------------------------------------------------------------- */
static const reg_entry_t s_common_seq[] = {
    /* ALRCGPIO=1: use DACLRC (driven by SAI master) as ADC frame clock.
     * The ADCLRC/GPIO1 pin is unconnected on this board. */
    { WM8960_REG_IFACE2,   (1<<6) },

    /* DAC power: DACL, DACR, LOUT1, ROUT1 (Class-D off to avoid noise) */
    { WM8960_REG_POWER2,   (1<<8)|(1<<7)|(1<<6)|(1<<5) },

    /* Input PGA volume: 0 dB, both channels latched (IPVU=1 on right write) */
    { WM8960_REG_LINVOL,   (1<<8)|(0x1F) },
    { WM8960_REG_RINVOL,   (1<<8)|(0x1F) },

    /* ALC: disabled */
    { WM8960_REG_ALC1,     0x0000 },
    { WM8960_REG_ALC2,     0x0000 },
    { WM8960_REG_ALC3,     0x0000 },

    /* ADC volume: 0 dB, latch both channels (ADCVU=1 on right write) */
    { WM8960_REG_LADC,     0x00C3 },
    { WM8960_REG_RADC,     (1<<8)|0xC3 },

    /* Output mix: DAC only → headphone.
     * LI2LO/RI2RO (analog mic bypass) is intentionally disabled: the board
     * has two separate mic inputs (LINPUT1=headset, RINPUT1=board mic), so
     * the bypass would only play audio in one earphone when a single mic is
     * used.  All audio goes through the ADC→DAC digital path instead. */
    { WM8960_REG_LOUTMIX,  (1<<8) },   /* LD2LO=1: DAC L to LOUT1 */
    { WM8960_REG_ROUTMIX,  (1<<8) },   /* RD2RO=1: DAC R to ROUT1 */

    /* DAC: unmuted */
    { WM8960_REG_DACCTL1,  0x0000 },

    /* Headphone volume: -6 dB (reg 0x73) */
    { WM8960_REG_LOUT1,    (1<<8)|0x73 },
    { WM8960_REG_ROUT1,    (1<<8)|0x73 },

    /* Class-D: disabled */
    { WM8960_REG_CLASSD1,  0x0037 },

    /* Audio interface: I2S slave, 16-bit */
    { WM8960_REG_IFACE1,   (0x00<<2)|(0x02) },

    /* Clocking: SYSCLK = MCLK directly (no PLL, SYSCLKDIV=1) */
    { WM8960_REG_CLOCKING1, 0x0000 },

    /* ADDCTL1: thermal shutdown, VSEL=2.7 V bias, output enable */
    { WM8960_REG_ADDCTL1,  (1<<8)|(0x01<<6)|(1<<0) },

    /* ADDCTL2: LRCM=1 (ADCLRC internally tied to DACLRC) */
    { WM8960_REG_ADDCTL2,  (1<<2) },

    /* ADDCTL4: HPSEL=10 (headphone always connected, no jack detect) */
    { WM8960_REG_ADDCTL4,  (0x02<<2) },
};

/* --------------------------------------------------------------------------
 * Public API
 * -------------------------------------------------------------------------- */

int wm8960_init(I2C_HandleTypeDef *hi2c, eWm8960InputSrc src)
{
    s_hi2c = hi2c;

    if (wm8960_write(WM8960_REG_RESET, 0x0000) != WM8960_OK)
        return WM8960_ERR;

    /* Set audio format before powering ADC/DAC so ADCLRC is valid on power-up */
    if (wm8960_write(WM8960_REG_IFACE1,   (0x00<<2)|(0x02)) != WM8960_OK) return WM8960_ERR;
    if (wm8960_write(WM8960_REG_ADDCTL2,  (1<<2))            != WM8960_OK) return WM8960_ERR;
    if (wm8960_write(WM8960_REG_CLOCKING1, 0x0000)           != WM8960_OK) return WM8960_ERR;

    /* Input-source specific config (powers up VMID at 5 kΩ fast-charge) */
    const reg_entry_t *seq = (src == WM8960_INPUT_LINEIN) ? s_linein_seq : s_mic_seq;
    uint32_t           len = (src == WM8960_INPUT_LINEIN) ? SEQ_LEN(s_linein_seq) : SEQ_LEN(s_mic_seq);
    if (wm8960_write_seq(seq, len) != WM8960_OK)
        return WM8960_ERR;

    /* Wait for VMID rail to stabilise (5 kΩ fast-charge, ~100 ms typical) */
    osDelay(200);

    /* Switch VMID to 50 kΩ (normal operating impedance) */
    uint16_t pwr1 = (src == WM8960_INPUT_MIC)
        ? (0x01<<7)|(1<<6)|(1<<5)|(1<<4)|(1<<3)|(1<<2)|(1<<1)
        : (0x01<<7)|(1<<6)|(1<<5)|(1<<4)|(1<<3)|(1<<2);
    if (wm8960_write(WM8960_REG_POWER1, pwr1) != WM8960_OK)
        return WM8960_ERR;

    if (wm8960_write_seq(s_common_seq, SEQ_LEN(s_common_seq)) != WM8960_OK)
        return WM8960_ERR;

    /* Mic mode: set PGA to max (+6 dB) */
    if (src == WM8960_INPUT_MIC) {
        if (wm8960_write(WM8960_REG_LINVOL, (1<<8)|0x1F) != WM8960_OK) return WM8960_ERR;
        if (wm8960_write(WM8960_REG_RINVOL, (1<<8)|0x1F) != WM8960_OK) return WM8960_ERR;
    }

    printf("[wm8960] init ok (src=%s)\r\n", src == WM8960_INPUT_MIC ? "mic" : "linein");
    return WM8960_OK;
}

int wm8960_set_input(eWm8960InputSrc src)
{
    const reg_entry_t *seq = (src == WM8960_INPUT_LINEIN) ? s_linein_seq : s_mic_seq;
    uint32_t           len = (src == WM8960_INPUT_LINEIN) ? SEQ_LEN(s_linein_seq) : SEQ_LEN(s_mic_seq);
    if (wm8960_write_seq(seq, len) != WM8960_OK)
        return WM8960_ERR;
    if (src == WM8960_INPUT_MIC) {
        if (wm8960_write(WM8960_REG_LINVOL, (1<<8)|0x1F) != WM8960_OK) return WM8960_ERR;
        if (wm8960_write(WM8960_REG_RINVOL, (1<<8)|0x1F) != WM8960_OK) return WM8960_ERR;
    }
    return WM8960_OK;
}

int wm8960_set_hp_vol(int32_t vol_db)
{
    uint8_t reg;
    if (vol_db <= WM8960_VOL_MUTE) {
        reg = 0x00;  /* below minimum audible → hardware mute */
    } else {
        if (vol_db > WM8960_VOL_MAX) vol_db = WM8960_VOL_MAX;
        if (vol_db < WM8960_VOL_MIN) vol_db = WM8960_VOL_MIN;
        reg = (uint8_t)(vol_db + 73 + 0x30);
    }
    if (wm8960_write(WM8960_REG_LOUT1, (1<<8)|reg) != WM8960_OK) return WM8960_ERR;
    return wm8960_write(WM8960_REG_ROUT1, (1<<8)|reg);
}

int wm8960_set_spk_vol(int32_t vol_db)
{
    if (vol_db <= WM8960_VOL_MUTE)
        return wm8960_update(WM8960_REG_CLASSD1, (0x03<<6), 0);

    if (vol_db > WM8960_VOL_MAX) vol_db = WM8960_VOL_MAX;
    if (vol_db < WM8960_VOL_MIN) vol_db = WM8960_VOL_MIN;
    uint8_t reg = (uint8_t)(vol_db + 73 + 0x30);

    if (wm8960_update(WM8960_REG_CLASSD1, (0x03<<6), (0x03<<6)) != WM8960_OK) return WM8960_ERR;
    if (wm8960_write(WM8960_REG_LOUT2, (1<<8)|reg) != WM8960_OK) return WM8960_ERR;
    return wm8960_write(WM8960_REG_ROUT2, (1<<8)|reg);
}

int wm8960_set_loopback(int enable)
{
    /* IFACE2 bit0 = LOOPBACK: routes ADC output directly to DAC input */
    return wm8960_update(WM8960_REG_IFACE2, (1<<0), enable ? (1<<0) : 0);
}
