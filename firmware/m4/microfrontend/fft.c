/* FFT backend for microfrontend — pure C float implementation.
 *
 * Uses the Cortex-M4 hardware FPU (fpv4-sp-d16) via float arithmetic.
 * No CMSIS-DSP dependency; no arm_math.h required.
 *
 * Scaling matches the TFLite Micro fixed-point kiss_fft behaviour:
 * each butterfly stage divides by 2, giving an overall factor of 1/N.
 * This is what the pre-trained micro_speech model expects.
 */

#include "fft.h"

#include <math.h>
#include <string.h>
#include <stddef.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ── Radix-2 DIT FFT ────────────────────────────────────────────────────── */

static void bit_reverse(float *data, size_t n)
{
    size_t j = 0;
    for (size_t i = 1; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1)
            j ^= bit;
        j ^= bit;
        if (i < j) {
            float tr = data[2*i];     float ti = data[2*i+1];
            data[2*i]   = data[2*j]; data[2*i+1] = data[2*j+1];
            data[2*j]   = tr;         data[2*j+1] = ti;
        }
    }
}

/* In-place complex FFT. data[2k]=real, data[2k+1]=imag, length n (power-of-2). */
static void cfft(float *data, size_t n)
{
    bit_reverse(data, n);
    for (size_t len = 2; len <= n; len <<= 1) {
        double ang = -2.0 * M_PI / (double)len;
        float wdr = (float)cos(ang);
        float wdi = (float)sin(ang);
        for (size_t i = 0; i < n; i += len) {
            float wr = 1.0f, wi = 0.0f;
            for (size_t j = 0; j < len / 2; j++) {
                size_t u = i + j;
                size_t v = i + j + len / 2;
                float ur = data[2*u], ui = data[2*u+1];
                float vr = data[2*v]*wr - data[2*v+1]*wi;
                float vi = data[2*v]*wi + data[2*v+1]*wr;
                data[2*u]   = ur + vr;  data[2*u+1] = ui + vi;
                data[2*v]   = ur - vr;  data[2*v+1] = ui - vi;
                float nwr = wr*wdr - wi*wdi;
                wi = wr*wdi + wi*wdr;
                wr = nwr;
            }
        }
    }
}

/* ── FftState API ───────────────────────────────────────────────────────── */

void FftInit(struct FftState *state)
{
    (void)state;  /* twiddle factors computed on-the-fly; nothing to precompute */
}

void FftCompute(struct FftState *state, const int16_t *input,
                int input_scale_shift)
{
    const size_t fft_size   = state->fft_size;
    const size_t input_size = state->input_size;

    /* Use scratch buffer as temporary complex float workspace */
    float *buf = (float *)state->scratch;

    /* Load scaled real input; imaginary parts = 0 */
    for (size_t i = 0; i < input_size; i++) {
        buf[2*i]   = (float)(int16_t)((uint16_t)input[i] << input_scale_shift);
        buf[2*i+1] = 0.0f;
    }
    for (size_t i = input_size; i < fft_size; i++) {
        buf[2*i] = 0.0f;  buf[2*i+1] = 0.0f;
    }

    cfft(buf, fft_size);

    /* Scale by 1/N: matches fixed-point kiss_fft (log2(N) stages each dividing by 2)
     * so filterbank energy values are in the range the model was trained on. */
    const float scale = 1.0f / (float)fft_size;
    struct complex_int16_t *out = state->output;
    for (size_t i = 0; i <= fft_size / 2; i++) {
        float re = buf[2*i]   * scale;
        float im = buf[2*i+1] * scale;
        if (re >  32767.0f) re =  32767.0f;
        if (re < -32768.0f) re = -32768.0f;
        if (im >  32767.0f) im =  32767.0f;
        if (im < -32768.0f) im = -32768.0f;
        out[i].real = (int16_t)re;
        out[i].imag = (int16_t)im;
    }
}

void FftReset(struct FftState *state)
{
    memset(state->input,  0, state->fft_size * sizeof(*state->input));
    memset(state->output, 0, (state->fft_size / 2 + 1) * sizeof(*state->output));
}

/* Scratch is used as float[fft_size * 2] during FftCompute */
size_t FftScratchSize(size_t fft_size)
{
    return fft_size * 2 * sizeof(float);
}
