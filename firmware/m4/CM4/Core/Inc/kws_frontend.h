#pragma once

#include <stdint.h>
#include "kws.h"

/* Wraps the microfrontend library.
 *
 * Initialises FrontendState with micro_speech training parameters:
 *   - 30ms Hann window, 20ms stride
 *   - 40 mel channels, 125–7500 Hz
 *   - Noise reduction + PCAN gain control + log scale
 *
 * kws_frontend_process() accepts a stream of 16kHz mono int16 samples
 * and returns one feature frame (40 int8 values) whenever the frontend
 * has consumed enough samples to advance by one stride (320 samples).
 */

/* Call once before the KWS task starts. Returns 0 on error. */
int kws_frontend_init(void);

/* Feed 16kHz mono samples.  Internally calls FrontendProcessSamples.
 * When a complete frame is ready, writes KWS_NUM_FEATURES int8 values
 * to out_frame and returns 1.  Returns 0 if more samples are needed. */
int kws_frontend_process(const int16_t *samples, size_t n_samples,
                         int8_t *out_frame);

/* Reset the frontend sliding window (call when starting a new detection
 * session or after a long silence). */
void kws_frontend_reset(void);
