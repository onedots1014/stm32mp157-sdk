#include "kws_frontend.h"

#include <string.h>
#include <stdio.h>

/* microfrontend library (TFLite Micro) */
#include "frontend.h"
#include "frontend_util.h"

static struct FrontendState  g_state;
static int                   g_initialized = 0;

/* --------------------------------------------------------------------------
 * Initialisation
 *
 * Parameters match the micro_speech model's training configuration.
 * If you change any of these, you must retrain the model.
 * -------------------------------------------------------------------------- */
int kws_frontend_init(void)
{
    struct FrontendConfig cfg;
    FrontendFillConfigWithDefaults(&cfg);

    /* Window */
    cfg.window.size_ms      = KWS_WINDOW_MS;   /* 30 ms */
    cfg.window.step_size_ms = KWS_STRIDE_MS;   /* 20 ms */

    /* Mel filterbank */
    cfg.filterbank.num_channels      = KWS_NUM_FEATURES;  /* 40 */
    cfg.filterbank.lower_band_limit  = 125.0f;
    cfg.filterbank.upper_band_limit  = 7500.0f;

    /* Noise reduction */
    cfg.noise_reduction.smoothing_bits      = 10;
    cfg.noise_reduction.even_smoothing      = 0.025f;
    cfg.noise_reduction.odd_smoothing       = 0.06f;
    cfg.noise_reduction.min_signal_remaining = 0.05f;

    /* PCAN gain control */
    cfg.pcan_gain_control.enable_pcan = 1;
    cfg.pcan_gain_control.strength    = 0.95f;
    cfg.pcan_gain_control.offset      = 80.0f;
    cfg.pcan_gain_control.gain_bits   = 21;

    /* Log scale */
    cfg.log_scale.enable_log  = 1;
    cfg.log_scale.scale_shift = 6;

    if (!FrontendPopulateState(&cfg, &g_state, (int)KWS_SAMPLE_RATE)) {
        printf("[kws_frontend] FrontendPopulateState failed\r\n");
        return 0;
    }

    g_initialized = 1;
    printf("[kws_frontend] init ok (window=%dms stride=%dms channels=%d)\r\n",
           KWS_WINDOW_MS, KWS_STRIDE_MS, KWS_NUM_FEATURES);
    return 1;
}

/* --------------------------------------------------------------------------
 * Per-frame processing
 *
 * Feed raw 16kHz mono samples.  The microfrontend maintains its own
 * internal overlap buffer - just keep calling this function with whatever
 * new samples are available.
 *
 * Returns 1 and fills out_frame[KWS_NUM_FEATURES] when a frame is ready.
 * Returns 0 when more samples are needed (call again).
 * -------------------------------------------------------------------------- */
int kws_frontend_process(const int16_t *samples, size_t n_samples,
                         int8_t *out_frame)
{
    if (!g_initialized) return 0;

    size_t samples_read = 0;
    struct FrontendOutput output =
        FrontendProcessSamples(&g_state, samples, n_samples, &samples_read);

    (void)samples_read;  /* caller feeds by stride, don't need to loop */

    if (output.size == 0 || output.values == NULL) {
        return 0;  /* frame not ready yet */
    }

    /* Convert uint16 log-mel output to int8 model input.
     *
     * The microfrontend (scale_shift=6) outputs uint16 in [0, ~64].
     * These values map directly to the float domain the model was trained on.
     *
     * Quantisation (from qua.py: scale=0.10171568, zero_point=-128):
     *   int8 = round(uint16 / 0.10171568) + (-128)
     *        = (uint16 * 9831 + 500) / 1000 - 128
     *
     * Clamped to [-128, 127]:
     *   uint16=0  → -128,  uint16=13 → ~0,  uint16=26 → ~127 (sat)
     */
    for (size_t i = 0; i < output.size && i < KWS_NUM_FEATURES; i++) {
        int32_t v = ((int32_t)output.values[i] * KWS_IN_SCALE_INV_x1000 + 500)
                    / 1000 + KWS_IN_ZERO_PT;
        if      (v < -128) v = -128;
        else if (v >  127) v =  127;
        out_frame[i] = (int8_t)v;
    }
    return 1;
}

void kws_frontend_reset(void)
{
    if (g_initialized) FrontendReset(&g_state);
}
