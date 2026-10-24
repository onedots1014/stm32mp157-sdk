#pragma once

#include <stdint.h>
#include "kws.h"

/* Lock-free SPSC ring buffer for 16kHz mono PCM.
 *
 * Producer: kws_audio_push_stereo_48k() — called from SAI DMA ISR.
 *           Takes interleaved stereo int16 at 48kHz, decimates 3:1,
 *           mixes to mono, writes 16kHz samples to the ring buffer.
 *
 * Consumer: kws_audio_pop() — called from kws_task (thread context).
 */

void     kws_audio_init(void);

/* Push n_stereo interleaved stereo int16 samples captured at 48kHz.
 * Call from HAL_SAI_RxHalfCpltCallback / HAL_SAI_RxCpltCallback. */
void     kws_audio_push_stereo_48k(const int16_t *buf, uint32_t n_stereo);

/* Number of 16kHz mono samples currently available. */
uint32_t kws_audio_available(void);

/* Pop up to n 16kHz mono samples into out[].
 * Returns the number of samples actually copied. */
uint32_t kws_audio_pop(int16_t *out, uint32_t n);

/* Ring overrun event count (producer lapped consumer) — diagnostics. */
uint32_t kws_audio_overruns(void);

/* Monotonic count of 16kHz samples produced — diagnostics (rate check). */
uint32_t kws_audio_total_produced(void);

/* SAI DMA half-buffer delivery count (defined in app_freertos.c).
 * Expected rate at 48kHz stereo, 256 frames/half: 187.5/s. */
uint32_t audio_dma_halves(void);
