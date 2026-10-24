#include "main.h"
#include "cmsis_os.h"
#include "kws.h"
#include "kws_audio.h"
#include "kws_frontend.h"
#include "kws_selftest_data.h"

#include <string.h>
#include <stdio.h>

/* --------------------------------------------------------------------------
 * X-CUBE-AI / STAI includes
 * Adjust these paths to match what X-CUBE-AI generated in your project.
 * -------------------------------------------------------------------------- */
#include "network.h"
#include "network_data.h"

/* --------------------------------------------------------------------------
 * FreeRTOS task attributes
 * Stack is larger than loopback task: frontend uses malloc at init,
 * inference activation buffer (~12 KB) is on-stack during run.
 * -------------------------------------------------------------------------- */
static osThreadId_t          kws_task_handle;
static const osThreadAttr_t  kws_task_attrs = {
    .name       = "kws",
    .stack_size = 8 * 1024,
    .priority   = osPriorityNormal,
};

/* --------------------------------------------------------------------------
 * Feature matrix: 49 frames × 40 channels = 1960 int8
 * Stored as a circular-shift ring (shift left by one frame on each update).
 * The model input buffer is 1964 bytes (1960 + 4-byte alignment padding).
 * -------------------------------------------------------------------------- */
#define FEAT_BUF_SIZE   (KWS_NUM_FRAMES * KWS_NUM_FEATURES)  /* 1960 */

static int8_t  feat_matrix[FEAT_BUF_SIZE];  /* sliding feature window   */
static uint32_t feat_frame_count;           /* frames accumulated so far */

/* Temporary buffer: one stride worth of 16kHz samples fetched per loop */
static int16_t pcm_chunk[KWS_STRIDE_SAMPLES];

/* --------------------------------------------------------------------------
 * Inference result smoothing
 * Average scores over KWS_SMOOTH_FRAMES consecutive inferences to reduce
 * false positives.
 * -------------------------------------------------------------------------- */
#define KWS_SMOOTH_FRAMES  3u

static int32_t score_accum[KWS_NUM_CLASSES];
static uint32_t smooth_count;

/* RPMsg send provided by app_freertos.c (keeps rpmsg_ept encapsulated) */
extern int rpmsg_send_kws(const void *data, size_t len);

/* --------------------------------------------------------------------------
 * STAI inference wrapper
 *
 * TODO: verify these calls against your generated network.h.
 * X-CUBE-AI 9.x uses the stai_* prefix API shown below.
 * Older versions (ai_* prefix) use a different call sequence.
 * -------------------------------------------------------------------------- */
static uint8_t  net_ctx_buf[STAI_NETWORK_CONTEXT_SIZE]         __attribute__((aligned(8)));
static uint8_t  net_act_buf[STAI_NETWORK_ACTIVATIONS_SIZE]     __attribute__((aligned(4)));
static int8_t   net_input[STAI_NETWORK_IN_SIZE_BYTES]          __attribute__((aligned(4)));
static int8_t   net_output[STAI_NETWORK_OUT_SIZE_BYTES]        __attribute__((aligned(4)));

static int inference_init(void)
{
    stai_return_code rc = stai_network_init((stai_ptr)net_ctx_buf);
    if (rc != STAI_SUCCESS) {
        printf("[kws] stai_network_init failed: %d\r\n", (int)rc);
        return 0;
    }

    /* Bind activation buffer (required: STAI_FLAG_ACTIVATIONS not set in STAI_NETWORK_FLAGS) */
    const stai_ptr activations[] = { (stai_ptr)net_act_buf };
    stai_network_set_activations((stai_ptr)net_ctx_buf, activations, 1);

    /* Bind static I/O buffers */
    const stai_ptr inputs[]  = { (stai_ptr)net_input  };
    const stai_ptr outputs[] = { (stai_ptr)net_output };
    stai_network_set_inputs ((stai_ptr)net_ctx_buf, inputs,  1);
    stai_network_set_outputs((stai_ptr)net_ctx_buf, outputs, 1);

    printf("[kws] inference init ok\r\n");
    return 1;
}

/* Returns class index with highest score, or KWS_CLASS_SILENCE if
 * the top score is below the confidence threshold. */
static uint8_t inference_run(const int8_t *features, uint8_t *confidence_out)
{
    /* Copy feature matrix into the network input buffer.
     * The model expects [1, 49, 40, 1] in row-major order which is exactly
     * the layout of feat_matrix. */
    memcpy(net_input, features, FEAT_BUF_SIZE);
    /* Remaining bytes (1964 - 1960 = 4) are padding - leave as zero. */

    stai_return_code rc = stai_network_run((stai_ptr)net_ctx_buf, STAI_MODE_SYNC);
    if (rc != STAI_SUCCESS) {
        printf("[kws] stai_network_run failed: %d\r\n", (int)rc);
    }

    /* net_output[i] is int8 quantised score for class i */
    int8_t best_score = net_output[0];
    uint8_t best_class = 0;
    for (uint8_t i = 1; i < KWS_NUM_CLASSES; i++) {
        if (net_output[i] > best_score) {
            best_score  = net_output[i];
            best_class  = i;
        }
    }

    /* Dequantise output (scale=1/256, zero_point=-128):
     * float_prob = (int8 + 128) / 256
     * confidence% = (int8 + 128) * 100 / 256 */
    int32_t conf = ((int32_t)best_score - KWS_OUT_ZERO_PT) * 100 / KWS_OUT_SCALE_DIV;
    *confidence_out = (uint8_t)(conf < 0 ? 0 : conf > 100 ? 100 : conf);

    return best_class;
}

/* --------------------------------------------------------------------------
 * Notification to CA7 via RPMsg
 * Sends MSG_WAKE (binary header) then enables PCM forwarding.
 * -------------------------------------------------------------------------- */
static void notify_ca7(const kws_event_t *evt)
{
    /* Send MSG_WAKE: [ type=1 | len=0 (2 bytes LE) ] */
    uint8_t wake_msg[3] = { KWS_MSG_WAKE, 0, 0 };
    rpmsg_send_kws(wake_msg, sizeof(wake_msg));

    /* Enable PCM forwarding — app_freertos loopback task will drain the
     * KWS ring buffer and send MSG_PCM frames until MSG_ASR_DONE arrives. */
    g_pcm_forward_start_ms = osKernelGetTickCount();
    g_pcm_forward_active = 1;

    printf("[kws] WAKE: class=%u conf=%u%% t=%lums — PCM forwarding started\r\n",
           (unsigned)evt->keyword_id,
           (unsigned)evt->confidence,
           (unsigned long)evt->timestamp_ms);
}

/* --------------------------------------------------------------------------
 * Boot self-test: run the frontend + model on canonical micro_speech clips,
 * bypassing the mic entirely. Bisects "capture path" vs "frontend/model":
 * expected result is yes → class 2, silence → class 0.
 * -------------------------------------------------------------------------- */
static void selftest_clip(const char *name, const int8_t *pcm8, uint32_t n)
{
    kws_frontend_reset();
    memset(feat_matrix, 0, sizeof(feat_matrix));
    uint32_t frames = 0;
    int8_t frame[KWS_NUM_FEATURES];

    for (uint32_t off = 0; off + KWS_STRIDE_SAMPLES <= n;
         off += KWS_STRIDE_SAMPLES) {
        /* Expand stored int8 PCM (or NULL = synthetic silence) to s16 */
        for (uint32_t i = 0; i < KWS_STRIDE_SAMPLES; i++)
            pcm_chunk[i] = pcm8 ? ((int16_t)pcm8[off + i] << 8) : 0;
        if (!kws_frontend_process(pcm_chunk, KWS_STRIDE_SAMPLES, frame))
            continue;
        memmove(feat_matrix, feat_matrix + KWS_NUM_FEATURES,
                (KWS_NUM_FRAMES - 1) * KWS_NUM_FEATURES);
        memcpy(feat_matrix + (KWS_NUM_FRAMES - 1) * KWS_NUM_FEATURES,
               frame, KWS_NUM_FEATURES);
        if (++frames < KWS_NUM_FRAMES) continue;

        uint8_t conf = 0;
        uint8_t klass = inference_run(feat_matrix, &conf);
        printf("[kws] selftest %s: class=%u conf=%u%%\r\n",
               name, (unsigned)klass, (unsigned)conf);
    }
    if (frames < KWS_NUM_FRAMES)
        printf("[kws] selftest %s: clip too short (%lu frames)\r\n",
               name, (unsigned long)frames);
}

/* --------------------------------------------------------------------------
 * KWS task
 * -------------------------------------------------------------------------- */
static void kws_task_fn(void *argument)
{
    (void)argument;

    /* Initialise subsystems */
    kws_audio_init();

    if (!kws_frontend_init()) {
        printf("[kws] frontend init failed — task exit\r\n");
        osThreadExit();
    }

    if (!inference_init()) {
        printf("[kws] inference init failed — task exit\r\n");
        osThreadExit();
    }

    /* Model/frontend self-test on canonical clips (mic path not involved) */
    selftest_clip("yes",     kws_selftest_yes_pcm8, kws_selftest_yes_pcm8_len);
    selftest_clip("silence", NULL,                  16000u);

    /* Reset everything the self-test touched before going live */
    kws_frontend_reset();
    kws_audio_init();
    memset(feat_matrix,  0, sizeof(feat_matrix));
    memset(score_accum,  0, sizeof(score_accum));
    feat_frame_count = 0;
    smooth_count     = 0;

    printf("[kws] running (window=%dms stride=%dms frames=%d)\r\n",
           KWS_WINDOW_MS, KWS_STRIDE_MS, KWS_NUM_FRAMES);

    for (;;) {
        /* Wait until we have one full stride worth of new samples */
        while (kws_audio_available() < KWS_STRIDE_SAMPLES) {
            osDelay(5);
        }
        uint32_t got = kws_audio_pop(pcm_chunk, KWS_STRIDE_SAMPLES);
        if (got < KWS_STRIDE_SAMPLES) continue;

        /* --- raw-PCM diagnostics: 1 line per second on the trace log ---
         * Reports what the model actually hears, independent of any
         * transport. Quiet room expectation: peak < ~500, meanabs < ~100. */
        {
            static uint32_t diag_absum, diag_n, diag_strides;
            static int32_t  diag_sum;
            static int16_t  diag_peak;
            for (uint32_t i = 0; i < KWS_STRIDE_SAMPLES; i++) {
                int16_t a = pcm_chunk[i] < 0 ? -pcm_chunk[i] : pcm_chunk[i];
                diag_absum += a;
                diag_sum   += pcm_chunk[i];
                if (a > diag_peak) diag_peak = a;
            }
            diag_n += KWS_STRIDE_SAMPLES;
            if (++diag_strides >= 50u) {   /* 50 × 20ms = 1s */
                /* Measured ring production rate vs the nominal 16000/s:
                 * a deviation means the SAI capture clock is not 48kHz. */
                static uint32_t last_prod, last_tick, last_halves;
                uint32_t now_prod   = kws_audio_total_produced();
                uint32_t now_halves = audio_dma_halves();
                uint32_t now_tick   = osKernelGetTickCount();
                uint32_t elapsed    = now_tick - last_tick;
                uint32_t rate = 0, dma_rate = 0;
                if (last_tick != 0 && elapsed != 0) {
                    rate     = (uint32_t)((uint64_t)(now_prod - last_prod)
                                          * 1000u / elapsed);
                    dma_rate = (uint32_t)((uint64_t)(now_halves - last_halves)
                                          * 1000u / elapsed);
                }
                last_prod = now_prod; last_halves = now_halves;
                last_tick = now_tick;
                printf("[kws] pcm: peak=%d meanabs=%lu dc=%ld ovr=%lu rate=%lu/s dma=%lu/s\r\n",
                       diag_peak, (unsigned long)(diag_absum / diag_n),
                       (long)(diag_sum / (int32_t)diag_n),
                       (unsigned long)kws_audio_overruns(),
                       (unsigned long)rate, (unsigned long)dma_rate);
                diag_absum = 0; diag_n = 0; diag_strides = 0; diag_peak = 0;
                diag_sum = 0;
            }
        }

        /* Extract one feature frame (timed — budget is ~9ms/stride, see
         * the real-time note at KWS_INFER_STRIDE_DIV) */
        int8_t new_frame[KWS_NUM_FEATURES];
        uint32_t f0 = osKernelGetTickCount();
        int frame_ready = kws_frontend_process(pcm_chunk, KWS_STRIDE_SAMPLES,
                                               new_frame);
        {
            static uint32_t fe_max, fe_sum, fe_cnt;
            uint32_t fdt = osKernelGetTickCount() - f0;
            fe_sum += fdt; fe_cnt++;
            if (fdt > fe_max) fe_max = fdt;
            if (fe_cnt >= 150u) {
                printf("[kws] frontend: avg=%lums max=%lums\r\n",
                       (unsigned long)(fe_sum / fe_cnt),
                       (unsigned long)fe_max);
                fe_sum = 0; fe_cnt = 0; fe_max = 0;
            }
        }
        if (!frame_ready) continue;

        /* Slide the feature matrix: drop oldest frame, append new one */
        memmove(feat_matrix,
                feat_matrix + KWS_NUM_FEATURES,
                (KWS_NUM_FRAMES - 1) * KWS_NUM_FEATURES);
        memcpy(feat_matrix + (KWS_NUM_FRAMES - 1) * KWS_NUM_FEATURES,
               new_frame, KWS_NUM_FEATURES);

        feat_frame_count++;

        /* Only run inference once we have a full window of frames */
        if (feat_frame_count < KWS_NUM_FRAMES) continue;

        /* Inference cadence limiter — see KWS_INFER_STRIDE_DIV in kws.h */
        {
            static uint32_t stride_cnt;
            if (++stride_cnt < KWS_INFER_STRIDE_DIV) continue;
            stride_cnt = 0;
        }

        /* Run inference (timed: real-time budget is one stride = 20ms) */
        uint32_t t0 = osKernelGetTickCount();
        uint8_t conf  = 0;
        uint8_t klass = inference_run(feat_matrix, &conf);
        {
            static uint32_t inf_max, inf_sum, inf_cnt;
            uint32_t dt = osKernelGetTickCount() - t0;
            inf_sum += dt; inf_cnt++;
            if (dt > inf_max) inf_max = dt;
            if (inf_cnt >= 50u) {
                printf("[kws] infer: avg=%lums max=%lums\r\n",
                       (unsigned long)(inf_sum / inf_cnt),
                       (unsigned long)inf_max);
                inf_sum = 0; inf_cnt = 0; inf_max = 0;
            }
        }

        /* Accumulate scores for smoothing */
        for (uint8_t i = 0; i < KWS_NUM_CLASSES; i++) {
            score_accum[i] += (int8_t)net_output[i];
        }
        smooth_count++;

        if (smooth_count < KWS_SMOOTH_FRAMES) continue;

        /* Find class with highest averaged score */
        int32_t best_avg   = score_accum[0];
        uint8_t best_class = 0;
        for (uint8_t i = 1; i < KWS_NUM_CLASSES; i++) {
            if (score_accum[i] > best_avg) {
                best_avg   = score_accum[i];
                best_class = i;
            }
        }

        /* Map smoothed score to confidence (scale=1/256, zero_point=-128) */
        int32_t avg_score = best_avg / (int32_t)KWS_SMOOTH_FRAMES;
        int32_t avg_conf_i = ((avg_score - KWS_OUT_ZERO_PT) * 100) / KWS_OUT_SCALE_DIV;
        uint8_t avg_conf  = (uint8_t)(avg_conf_i < 0 ? 0 : avg_conf_i > 100 ? 100 : avg_conf_i);
        printf("[kws] class=%d(%s) conf=%d%% score=%d\r\n",
               best_class,
               best_class == KWS_CLASS_SILENCE ? "silence" :
               best_class == KWS_CLASS_UNKNOWN ? "unknown" :
               best_class == KWS_CLASS_YES     ? "yes"     : "no",
               avg_conf, avg_score);
        memset(score_accum, 0, sizeof(score_accum));
        smooth_count = 0;

        (void)klass; (void)conf;  /* single-frame values unused after smoothing */

        // if (best_class != KWS_CLASS_SILENCE &&
        //     best_class != KWS_CLASS_UNKNOWN &&
        //     avg_conf   >= KWS_DETECT_THRESHOLD) {
        {
            static uint32_t yes_rounds;
            if (best_class == KWS_CLASS_YES &&
                avg_conf   >= KWS_DETECT_THRESHOLD) {
                yes_rounds++;
            } else {
                yes_rounds = 0;
            }

            if (yes_rounds >= KWS_CONFIRM_ROUNDS) {
                static uint32_t last_wake_ms;
                uint32_t now = osKernelGetTickCount();
                if (last_wake_ms == 0 ||
                    (now - last_wake_ms) >= KWS_SUPPRESS_MS) {
                    last_wake_ms = now;
                    yes_rounds = 0;
                    kws_event_t evt = {
                        .keyword_id   = best_class,
                        .confidence   = avg_conf,
                        .timestamp_ms = now,
                    };
                    notify_ca7(&evt);
                }
            }
        }
    }
}

/* --------------------------------------------------------------------------
 * Public init (called from main.c or app_freertos.c)
 * -------------------------------------------------------------------------- */
int kws_task_init(void)
{
    kws_task_handle = osThreadNew(kws_task_fn, NULL, &kws_task_attrs);
    return (kws_task_handle != NULL) ? 1 : 0;
}
