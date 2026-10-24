/*
 * WM8960 audio codec driver
 *
 * Control interface : I2C (9-bit register protocol)
 * Audio interface   : I2S slave, 16-bit stereo, 48 kHz
 * Platform          : STM32MP1 HAL (pass I2C handle at init)
 */

#ifndef __WM8960_H__
#define __WM8960_H__

#ifdef __cplusplus
extern "C" {
#endif

#include "stm32mp1xx_hal.h"
#include <stdint.h>

/* WM8960 I2C address (7-bit, left-shifted for HAL) */
#define WM8960_I2C_ADDR         (0x1A << 1)

/* Register addresses */
#define WM8960_REG_LINVOL       0x00
#define WM8960_REG_RINVOL       0x01
#define WM8960_REG_LOUT1        0x02
#define WM8960_REG_ROUT1        0x03
#define WM8960_REG_CLOCKING1    0x04
#define WM8960_REG_DACCTL1      0x05
#define WM8960_REG_DACCTL2      0x06
#define WM8960_REG_IFACE1       0x07
#define WM8960_REG_CLOCKING2    0x08
#define WM8960_REG_IFACE2       0x09
#define WM8960_REG_LDAC         0x0A
#define WM8960_REG_RDAC         0x0B
#define WM8960_REG_RESET        0x0F
#define WM8960_REG_3D           0x10
#define WM8960_REG_ALC1         0x11
#define WM8960_REG_ALC2         0x12
#define WM8960_REG_ALC3         0x13
#define WM8960_REG_NOISEG       0x14
#define WM8960_REG_LADC         0x15
#define WM8960_REG_RADC         0x16
#define WM8960_REG_ADDCTL1      0x17
#define WM8960_REG_ADDCTL2      0x18
#define WM8960_REG_POWER1       0x19
#define WM8960_REG_POWER2       0x1A
#define WM8960_REG_ADDCTL3      0x1B
#define WM8960_REG_APOP1        0x1C
#define WM8960_REG_APOP2        0x1D
#define WM8960_REG_LINPATH      0x20
#define WM8960_REG_RINPATH      0x21
#define WM8960_REG_LOUTMIX      0x22
#define WM8960_REG_ROUTMIX      0x25
#define WM8960_REG_MONOMIX1     0x26
#define WM8960_REG_MONOMIX2     0x27
#define WM8960_REG_LOUT2        0x28
#define WM8960_REG_ROUT2        0x29
#define WM8960_REG_MONOOUT      0x2A
#define WM8960_REG_INBMIX1      0x2B
#define WM8960_REG_INBMIX2      0x2C
#define WM8960_REG_BYPASS1      0x2D
#define WM8960_REG_BYPASS2      0x2E
#define WM8960_REG_POWER3       0x2F
#define WM8960_REG_ADDCTL4      0x30
#define WM8960_REG_CLASSD1      0x31
#define WM8960_REG_CLASSD3      0x33
#define WM8960_REG_PLL1         0x34
#define WM8960_REG_PLL2         0x35
#define WM8960_REG_PLL3         0x36
#define WM8960_REG_PLL4         0x37

#define WM8960_NUM_REGS         56

/* Input source */
typedef enum {
    WM8960_INPUT_LINEIN = 0,
    WM8960_INPUT_MIC    = 1,
} eWm8960InputSrc;

/* Headphone / speaker volume range.
 * Pass WM8960_VOL_MUTE (or any value below VOL_MIN) to mute. */
#define WM8960_VOL_MIN          (-73)   /* dB, minimum audible */
#define WM8960_VOL_MAX          (  6)   /* dB */
#define WM8960_VOL_MUTE         (-74)   /* dB, triggers hardware mute */

/* Return codes */
#define WM8960_OK               ( 0)
#define WM8960_ERR              (-1)

/*
 * Initialize the codec.
 * hi2c : I2C bus handle (must already be initialized by HAL_I2C_Init)
 * src  : initial input source
 */
int wm8960_init(I2C_HandleTypeDef *hi2c, eWm8960InputSrc src);

/* Switch input source after init */
int wm8960_set_input(eWm8960InputSrc src);

/* Headphone output volume, vol_db in [WM8960_VOL_MIN, WM8960_VOL_MAX] */
int wm8960_set_hp_vol(int32_t vol_db);

/* Speaker (Class-D) output volume */
int wm8960_set_spk_vol(int32_t vol_db);

/* Internal ADC-to-DAC loopback (bypass I2S) */
int wm8960_set_loopback(int enable);

#ifdef __cplusplus
}
#endif

#endif /* __WM8960_H__ */
