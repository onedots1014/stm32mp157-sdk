#pragma once
#include <stdint.h>
/* Canonical micro_speech "yes" clip stored as int8 PCM (16kHz mono).
 * Runtime expands <<8. Silence test input is synthesized (all zeros). */
extern const int8_t   kws_selftest_yes_pcm8[];
extern const uint32_t kws_selftest_yes_pcm8_len;
