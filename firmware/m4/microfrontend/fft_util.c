/* FFT state population for microfrontend.
 *
 * Replaces the original fft_util.cc (which depended on kiss_fft C++).
 * Scratch size is determined by FftScratchSize() declared in fft.h,
 * so fft.c and fft_util.c are always consistent.
 */

#include "fft_util.h"
#include "fft.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int FftPopulateState(struct FftState *state, size_t input_size)
{
    state->input_size = input_size;

    /* fft_size = next power of 2 >= input_size */
    state->fft_size = 1;
    while (state->fft_size < state->input_size)
        state->fft_size <<= 1;

    state->input = malloc(state->fft_size * sizeof(*state->input));
    if (!state->input) {
        fprintf(stderr, "FftPopulateState: alloc input failed\n");
        return 0;
    }
    memset(state->input, 0, state->fft_size * sizeof(*state->input));

    state->output = malloc((state->fft_size / 2 + 1) * sizeof(*state->output));
    if (!state->output) {
        fprintf(stderr, "FftPopulateState: alloc output failed\n");
        return 0;
    }

    state->scratch_size = FftScratchSize(state->fft_size);
    state->scratch = malloc(state->scratch_size);
    if (!state->scratch) {
        fprintf(stderr, "FftPopulateState: alloc scratch failed\n");
        return 0;
    }
    memset(state->scratch, 0, state->scratch_size);

    FftInit(state);
    return 1;
}

void FftFreeStateContents(struct FftState *state)
{
    free(state->input);
    free(state->output);
    free(state->scratch);
}
