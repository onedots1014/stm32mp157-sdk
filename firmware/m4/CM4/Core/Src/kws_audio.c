#include "kws_audio.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* --------------------------------------------------------------------------
 * Lock-free SPSC ring buffer
 *
 * head: written only by consumer (kws_audio_pop)
 * tail: written only by producer (kws_audio_push_stereo_48k, called from ISR)
 *
 * Invariant: (tail - head) <= KWS_RING_BUF_SIZE
 * Both indices are unsigned 32-bit and wrap naturally; masking with
 * (KWS_RING_BUF_SIZE - 1) gives the slot index.
 * -------------------------------------------------------------------------- */
static int16_t  ring_buf[KWS_RING_BUF_SIZE];
static volatile uint32_t ring_head;   /* next read position  */
static volatile uint32_t ring_tail;   /* next write position */

/* Decimation carry: accumulator for partial sums across DMA half-buffers.
 * We average KWS_DECIMATION consecutive samples to form one 16kHz sample. */
static int32_t  decim_accum;          /* sum of current group */
static uint32_t decim_count;          /* samples accumulated so far */

/* Count of overrun events (tail would lap head) - for debugging */
static volatile uint32_t ring_overrun_cnt;

void kws_audio_init(void)
{
    ring_head      = 0;
    ring_tail      = 0;
    decim_accum    = 0;
    decim_count    = 0;
    ring_overrun_cnt = 0;
    memset(ring_buf, 0, sizeof(ring_buf));
}

/* Called from ISR - must be fast, no blocking. */
void kws_audio_push_stereo_48k(const int16_t *buf, uint32_t n_stereo)
{
    for (uint32_t i = 0; i < n_stereo; i += 2) {
        /* Mono-mix: average L and R channels */
        int32_t mono = ((int32_t)buf[i] + (int32_t)buf[i + 1]) >> 1;

        decim_accum += mono;
        decim_count++;

        if (decim_count == KWS_DECIMATION) {
            /* Emit one 16kHz sample (average of KWS_DECIMATION 48kHz samples) */
            int16_t sample = (int16_t)(decim_accum / (int32_t)KWS_DECIMATION);

            uint32_t next_tail = ring_tail + 1;
            if ((next_tail - ring_head) > KWS_RING_BUF_SIZE) {
                /* Buffer full - drop the oldest sample to make room */
                ring_head++;
                ring_overrun_cnt++;
            }
            ring_buf[ring_tail & (KWS_RING_BUF_SIZE - 1)] = sample;
            ring_tail = next_tail;

            decim_accum = 0;
            decim_count = 0;
        }
    }
}

uint32_t kws_audio_available(void)
{
    return ring_tail - ring_head;
}

uint32_t kws_audio_pop(int16_t *out, uint32_t n)
{
    uint32_t avail = kws_audio_available();
    if (n > avail) n = avail;

    for (uint32_t i = 0; i < n; i++) {
        out[i] = ring_buf[ring_head & (KWS_RING_BUF_SIZE - 1)];
        ring_head++;
    }
    return n;
}

uint32_t kws_audio_overruns(void)
{
    return ring_overrun_cnt;
}

uint32_t kws_audio_total_produced(void)
{
    return ring_tail;   /* monotonic 16kHz-sample counter */
}
