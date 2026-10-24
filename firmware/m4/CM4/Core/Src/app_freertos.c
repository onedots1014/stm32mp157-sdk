/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * File Name          : app_freertos.c
  * Description        : Code for freertos applications
  ******************************************************************************
  * @attention
  *
  * Copyright (c) 2026 STMicroelectronics.
  * All rights reserved.
  *
  * This software is licensed under terms that can be found in the LICENSE file
  * in the root directory of this software component.
  * If no LICENSE file comes with this software, it is provided AS-IS.
  *
  ******************************************************************************
  */
/* USER CODE END Header */

/* Includes ------------------------------------------------------------------*/
#include "FreeRTOS.h"
#include "task.h"
#include "main.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include "cmsis_os.h"
#include "openamp.h"
#include "wm8960.h"
#include "kws_audio.h"
#include "kws.h"
#include <string.h>
#include <stdio.h>
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define RPMSG_CHANNEL_NAME  "rpmsg-tty-channel"
#define RPMSG_BUF_SIZE      256

/* Audio: stereo 16-bit 48 kHz, double buffer (ping-pong) */
#define AUDIO_BUF_SAMPLES   256                      /* samples per channel per half */
#define AUDIO_BUF_SIZE      (AUDIO_BUF_SAMPLES * 2) /* stereo interleaved */
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/
/* USER CODE BEGIN Variables */
static struct rpmsg_endpoint rpmsg_ept;
static volatile int rpmsg_ready   = 0;  /* set after OPENAMP_Wait_EndPointready */
static volatile int rpmsg_rx_flag = 0;
static char rpmsg_rx_buf[RPMSG_BUF_SIZE];
static int  rpmsg_rx_len = 0;

static int16_t audio_rx_buf[AUDIO_BUF_SIZE * 2];
static int16_t audio_tx_buf[AUDIO_BUF_SIZE * 2];
static volatile uint8_t  rx_half_ready = 0;
static volatile uint8_t  rx_full_ready = 0;
static volatile uint32_t dma_half_cnt  = 0;
static volatile uint32_t dma_full_cnt  = 0;

/* PCM forwarding state: 1 = forward PCM to CA7 via RPMsg, 0 = KWS only */
volatile int g_pcm_forward_active = 0;
volatile uint32_t g_pcm_forward_start_ms = 0;

/* 1 kHz sine table: 48 samples/cycle at 48 kHz, amplitude ~-18 dBFS */
static const int16_t sine_1khz[48] = {
       0,   534,  1060,  1568,  2048,  2494,  2896,  3250,
    3547,  3786,  3958,  4063,  4096,  4063,  3958,  3786,
    3547,  3250,  2896,  2494,  2048,  1568,  1060,   534,
       0,  -534, -1060, -1568, -2048, -2494, -2896, -3250,
   -3547, -3786, -3958, -4063, -4096, -4063, -3958, -3786,
   -3547, -3250, -2896, -2494, -2048, -1568, -1060,  -534,
};
/* USER CODE END Variables */

/* Private function prototypes -----------------------------------------------*/
/* USER CODE BEGIN FunctionPrototypes */

/* USER CODE END FunctionPrototypes */

/* Private application code --------------------------------------------------*/
/* USER CODE BEGIN Application */

/* --------------------------------------------------------------------------
 * RPMsg task
 * -------------------------------------------------------------------------- */
static int rpmsg_recv_cb(struct rpmsg_endpoint *ept, void *data, size_t len,
                         uint32_t src, void *priv)
{
    /* Check for MSG_ASR_DONE (binary, 1 byte = 0x03) */
    if (len >= 1 && ((uint8_t *)data)[0] == KWS_MSG_ASR_DONE) {
        g_pcm_forward_active = 0;
        printf("[rpmsg] ASR_DONE received, stopped PCM forwarding\r\n");
        return 0;
    }
    /* Other messages: echo back (for debugging) */
    if (len > RPMSG_BUF_SIZE - 1)
        len = RPMSG_BUF_SIZE - 1;
    memcpy(rpmsg_rx_buf, data, len);
    rpmsg_rx_buf[len] = '\0';
    rpmsg_rx_len = (int)len;
    rpmsg_rx_flag = 1;
    return 0;
}

/* Send a MSG_PCM frame to CA7.
 * samples: mono 16kHz int16_t, n_samples <= KWS_PCM_FRAME_SAMPLES.
 * Called from task context (not ISR) — safe to call OPENAMP_send. */
static void rpmsg_send_pcm(const int16_t *samples, uint16_t n_samples)
{
    if (!rpmsg_ready || !g_pcm_forward_active) return;

    static uint8_t pcm_msg[3 + KWS_PCM_FRAME_BYTES];
    uint16_t payload_bytes = n_samples * 2u;
    pcm_msg[0] = KWS_MSG_PCM;
    pcm_msg[1] = (uint8_t)(payload_bytes & 0xff);
    pcm_msg[2] = (uint8_t)(payload_bytes >> 8);
    memcpy(pcm_msg + 3, samples, payload_bytes);
    OPENAMP_send(&rpmsg_ept, pcm_msg, 3u + payload_bytes);
}

static void rpmsg_unbind_cb(struct rpmsg_endpoint *ept)
{
    OPENAMP_destroy_ept(ept);
}

void StartRpmsgTask(void *argument)
{
    OPENAMP_create_endpoint(&rpmsg_ept, RPMSG_CHANNEL_NAME, RPMSG_ADDR_ANY,
                            rpmsg_recv_cb, rpmsg_unbind_cb);
    OPENAMP_Wait_EndPointready(&rpmsg_ept);
    rpmsg_ready = 1;
    printf("[rpmsg] endpoint ready\r\n");

    for (;;) {
        OPENAMP_check_for_message();
        if (rpmsg_rx_flag) {
            rpmsg_rx_flag = 0;
            OPENAMP_send(&rpmsg_ept, rpmsg_rx_buf, rpmsg_rx_len);
        }
        osDelay(1);
    }
}

/* --------------------------------------------------------------------------
 * SAI DMA callbacks
 * -------------------------------------------------------------------------- */
extern SAI_HandleTypeDef hsai_BlockA1;
extern SAI_HandleTypeDef hsai_BlockB1;
extern osThreadId_t audioLoopbackTaskHandle;
extern const osThreadAttr_t audioLoopbackTask_attributes;

/* Diagnostics: total DMA half-buffer deliveries (half + full callbacks). */
uint32_t audio_dma_halves(void)
{
    return dma_half_cnt + dma_full_cnt;
}

void HAL_SAI_RxHalfCpltCallback(SAI_HandleTypeDef *hsai)
{
    if (hsai->Instance == SAI1_Block_B) {
        rx_half_ready = 1;
        dma_half_cnt++;
        /* Feed first half of DMA buffer into KWS ring buffer */
        kws_audio_push_stereo_48k(audio_rx_buf, AUDIO_BUF_SIZE);
    }
}

void HAL_SAI_RxCpltCallback(SAI_HandleTypeDef *hsai)
{
    if (hsai->Instance == SAI1_Block_B) {
        rx_full_ready = 1;
        dma_full_cnt++;
        /* Feed second half of DMA buffer into KWS ring buffer */
        kws_audio_push_stereo_48k(audio_rx_buf + AUDIO_BUF_SIZE, AUDIO_BUF_SIZE);
    }
}

/* --------------------------------------------------------------------------
 * Audio loopback task
 *
 * Phase 1 (5 s)  : 1 kHz sine tone to headphones  — verifies DAC path
 * Phase 2 (10 s) : WM8960 internal loopback ON    — verifies mic analog path
 * Phase 3        : STM32 DMA loopback             — mic → SAI_B → DMA → SAI_A → HP
 * -------------------------------------------------------------------------- */
void StartAudioLoopbackTask(void *argument)
{
    extern I2C_HandleTypeDef hi2c1;

    /* Sample ADCDAT idle level before SAI starts (MCLK/BCLK not yet running).
     * Temporarily switch PF6 to GPIO input, then restore AF6 before SAI init. */
    /* Start SAI RX (Block_B master) first so MCLK/BCLK are running before
     * SAI TX (Block_A synchronous slave) begins. */
    memset(audio_tx_buf, 0, sizeof(audio_tx_buf));
    if (HAL_SAI_Receive_DMA(&hsai_BlockB1, (uint8_t *)audio_rx_buf,
                            AUDIO_BUF_SIZE * 2) != HAL_OK) {
        printf("[audio] SAI RX DMA start failed\r\n");
        osThreadExit();
    }
    if (HAL_SAI_Transmit_DMA(&hsai_BlockA1, (uint8_t *)audio_tx_buf,
                             AUDIO_BUF_SIZE * 2) != HAL_OK) {
        printf("[audio] SAI TX DMA start failed\r\n");
        HAL_SAI_DMAStop(&hsai_BlockB1);
        osThreadExit();
    }

    /* Init codec after SAI is running so WM8960 sees a valid MCLK */
    osDelay(10);
    if (wm8960_init(&hi2c1, WM8960_INPUT_MIC) != WM8960_OK) {
        printf("[audio] WM8960 init failed\r\n");
        osThreadExit();
    }

#ifdef AUDIO_LOOPBACK_DEBUG_PHASES
    /* Phase 1: fill TX buffer with 1 kHz sine tone */
    for (int i = 0; i < AUDIO_BUF_SIZE * 2; i += 2) {
        int16_t v = sine_1khz[(i / 2) % 48];
        audio_tx_buf[i]   = v;
        audio_tx_buf[i+1] = v;
    }
    uint32_t phase_start = dma_half_cnt;
    int      phase       = 1;
#endif

    for (;;) {
#ifdef AUDIO_LOOPBACK_DEBUG_PHASES
        uint32_t elapsed = dma_half_cnt - phase_start;

        /* Phase 1 → 2 after ~5 s */
        if (phase == 1 && elapsed >= 937) {
            phase = 2;
            phase_start = dma_half_cnt;
            memset(audio_tx_buf, 0, sizeof(audio_tx_buf));
            wm8960_set_loopback(1);
        }

        /* Phase 2 → 3 after ~10 s */
        if (phase == 2 && elapsed >= 1875) {
            phase = 3;
            phase_start = dma_half_cnt;
            wm8960_set_loopback(0);
        }
#endif /* AUDIO_LOOPBACK_DEBUG_PHASES */

        /* DMA loopback: mic → SAI_B → DMA → SAI_A → HP
         * Duplicate L channel to R so both earphones output audio. */
#ifdef AUDIO_LOOPBACK_DEBUG_PHASES
        if (phase == 3)
#endif
        {
            if (rx_half_ready) {
                rx_half_ready = 0;
                for (int i = 0; i < AUDIO_BUF_SIZE; i += 2) {
                    audio_tx_buf[i]   = audio_rx_buf[i];
                    audio_tx_buf[i+1] = audio_rx_buf[i];
                }
            }
            if (rx_full_ready) {
                rx_full_ready = 0;
                for (int i = 0; i < AUDIO_BUF_SIZE; i += 2) {
                    audio_tx_buf[AUDIO_BUF_SIZE + i]   = audio_rx_buf[AUDIO_BUF_SIZE + i];
                    audio_tx_buf[AUDIO_BUF_SIZE + i+1] = audio_rx_buf[AUDIO_BUF_SIZE + i];
                }
            }
        }

        /* PCM forwarding: drain KWS ring buffer and send to CA7 via RPMsg.
         * Only active after wake word detection (g_pcm_forward_active=1).
         * Send in chunks of KWS_PCM_FRAME_SAMPLES to fit RPMsg MTU. */
        if (g_pcm_forward_active) {
            if ((osKernelGetTickCount() - g_pcm_forward_start_ms)
                    > KWS_FORWARD_TIMEOUT_MS) {
                g_pcm_forward_active = 0;
                printf("[kws] PCM forward timeout (no ASR_DONE) — "
                       "resuming detection\r\n");
            } else {
                static int16_t pcm_fwd_buf[KWS_PCM_FRAME_SAMPLES];
                uint32_t avail = kws_audio_available();
                while (avail >= KWS_PCM_FRAME_SAMPLES) {
                    kws_audio_pop(pcm_fwd_buf, KWS_PCM_FRAME_SAMPLES);
                    rpmsg_send_pcm(pcm_fwd_buf, KWS_PCM_FRAME_SAMPLES);
                    avail -= KWS_PCM_FRAME_SAMPLES;
                }
            }
        }

        osDelay(1);
    }
}

int audioLoopbackTaskInit(void)
{
    audioLoopbackTaskHandle = osThreadNew(StartAudioLoopbackTask, NULL,
                                          &audioLoopbackTask_attributes);
    return 0;
}

/* Shared RPMsg send function — called by kws_task to notify CA7 */
int rpmsg_send_kws(const void *data, size_t len)
{
    if (!rpmsg_ready) {
        printf("[rpmsg] send skipped: endpoint not ready\r\n");
        return -1;
    }
    int rc = OPENAMP_send(&rpmsg_ept, data, len);
    if (rc < 0)
        printf("[rpmsg] send failed: %d\r\n", rc);
    return rc;
}

/* USER CODE END Application */
