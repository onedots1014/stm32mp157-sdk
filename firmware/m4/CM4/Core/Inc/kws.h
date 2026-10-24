#pragma once

#include <stdint.h>
#include <stddef.h>

/* --------------------------------------------------------------------------
 * Audio capture parameters
 * -------------------------------------------------------------------------- */
#define KWS_SAI_SAMPLE_RATE    48000u   /* SAI hardware sample rate (Hz) */
#define KWS_DECIMATION         3u       /* 48kHz / 3 = 16kHz */
#define KWS_SAMPLE_RATE        16000u   /* KWS model sample rate (Hz) */

/* Ring buffer: power-of-2 so we can use bitwise masking.
 * 4096 samples = 256ms @ 16kHz, enough margin for FreeRTOS scheduling. */
#define KWS_RING_BUF_SIZE      4096u

/* --------------------------------------------------------------------------
 * Microfrontend / model parameters  (must match training config)
 * -------------------------------------------------------------------------- */
#define KWS_WINDOW_MS          30u      /* Hann window length */
#define KWS_STRIDE_MS          20u      /* Frame step */
#define KWS_NUM_FRAMES         49u      /* Frames per inference */
#define KWS_NUM_FEATURES       40u      /* Mel channels */

#define KWS_WINDOW_SAMPLES     ((KWS_WINDOW_MS  * KWS_SAMPLE_RATE) / 1000u)  /* 480 */
#define KWS_STRIDE_SAMPLES     ((KWS_STRIDE_MS  * KWS_SAMPLE_RATE) / 1000u)  /* 320 */

/* Input quantisation parameters — from Python script (qua.py):
 *   Input  scale=0.10171568  zero_point=-128
 *   Output scale=0.00390625  zero_point=-128
 *
 * The microfrontend (scale_shift=6) outputs uint16 in range [0, ~64].
 * These values are used directly as "float" by the training pipeline.
 * Conversion: int8 = round(uint16 / KWS_IN_SCALE) + KWS_IN_ZERO_PT
 *
 * Integer implementation (avoids float on M4):
 *   int8 = (uint16 * KWS_IN_SCALE_INV_x1000 + 500) / 1000 + KWS_IN_ZERO_PT
 */
#define KWS_IN_SCALE_INV_x1000   9831  /* round(1000 / 0.10171568) */
#define KWS_IN_ZERO_PT           (-128)

/* Output: scale=1/256, zero_point=-128
 * float_prob = (int8 - zero_pt) * scale = (int8 + 128) / 256
 * confidence% = (int8 + 128) * 100 / 256  */
#define KWS_OUT_ZERO_PT          (-128)
#define KWS_OUT_SCALE_DIV        256

/* --------------------------------------------------------------------------
 * Inference result
 * -------------------------------------------------------------------------- */
#define KWS_CLASS_SILENCE   0u
#define KWS_CLASS_UNKNOWN   1u
#define KWS_CLASS_YES       2u
#define KWS_CLASS_NO        3u
#define KWS_NUM_CLASSES     4u

/* Minimum confidence (0-100) required to report a detection */
#define KWS_DETECT_THRESHOLD  70u

/* Inference cadence: run the network every Nth stride. One inference takes
 * ~32ms on the 209MHz M4 (measured), which overruns a single 20ms stride —
 * running every stride starves the audio ring (~4k dropped samples/s) and
 * shreds the feature window. 3 strides = 60ms budget, ~50% headroom. */
#define KWS_INFER_STRIDE_DIV  3u

/* Refractory period after a detection: block re-triggering while the same
 * utterance is still inside the sliding feature window. */
#define KWS_SUPPRESS_MS       2000u

/* Temporal confirmation: require this many consecutive smoothed decisions
 * of "yes" above threshold before waking. Ambient noise produces isolated
 * single-round spikes; a spoken "yes" spans several decision rounds
 * (~180ms each), so 2 rounds cuts false wakes without hurting detection. */
#define KWS_CONFIRM_ROUNDS    3u

typedef struct {
    uint8_t  keyword_id;   /* KWS_CLASS_* */
    uint8_t  confidence;   /* 0-100 */
    uint32_t timestamp_ms;
} kws_event_t;

/* --------------------------------------------------------------------------
 * RPMsg binary protocol
 *
 * M4 → CA7:
 *   MSG_WAKE (1): wake word detected — 3-byte header only, no payload
 *   MSG_PCM  (2): PCM audio frame   — header + int16_t samples
 *
 * CA7 → M4:
 *   MSG_ASR_DONE (3): ASR finished, stop forwarding — 1 byte
 *
 * Wire format: [ type:u8 | len:u16_le | data[len] ]
 * MSG_WAKE and MSG_ASR_DONE have len=0.
 * -------------------------------------------------------------------------- */
#define KWS_MSG_WAKE      1u
#define KWS_MSG_PCM       2u
#define KWS_MSG_ASR_DONE  3u

/* Maximum PCM samples per MSG_PCM message.
 * DMA half-buffer: 256 stereo 48kHz samples → ~85 mono 16kHz samples after
 * decimation.  Round up to 96 for a small margin (192 bytes payload). */
#define KWS_PCM_FRAME_SAMPLES  96u
#define KWS_PCM_FRAME_BYTES    (KWS_PCM_FRAME_SAMPLES * 2u)

/* Total wire size of one MSG_PCM message */
#define KWS_MSG_PCM_SIZE   (3u + KWS_PCM_FRAME_BYTES)  /* header + payload */

typedef struct __attribute__((packed)) {
    uint8_t  type;   /* KWS_MSG_* */
    uint16_t len;    /* payload bytes (little-endian) */
} KwsMsgHdr;

/* --------------------------------------------------------------------------
 * RPMsg channel (shared with rpmsg task)
 * -------------------------------------------------------------------------- */
#define KWS_RPMSG_PREFIX    "KWS:"   /* legacy ASCII prefix (unused after protocol upgrade) */

/* PCM forwarding state — set by kws_task when wake word detected,
 * cleared by rpmsg_task when MSG_ASR_DONE received from CA7.
 * Declared extern so both tasks can access it without a separate header. */
extern volatile int g_pcm_forward_active;
extern volatile uint32_t g_pcm_forward_start_ms;

/* Stop PCM forwarding if the CA7 never answers with ASR_DONE — without
 * this the forwarder drains the ring forever and starves KWS detection. */
#define KWS_FORWARD_TIMEOUT_MS  6000u
