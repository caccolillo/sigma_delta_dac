// =============================================================================
// sdm_cifb_2nd.h
// Header for 2nd-order CIFB Sigma-Delta Modulator HLS module
// =============================================================================

#ifndef SDM_CIFB_2ND_H
#define SDM_CIFB_2ND_H

#include <ap_int.h>

// 13-bit signed audio input (range -4096 to +4095)
typedef ap_int<13> input_t;

// Single-bit PDM output
typedef ap_uint<1> pdm_t;

// Sample valid strobe
typedef ap_uint<1> tick_t;

pdm_t sdm_cifb_2nd(input_t u, tick_t sample_valid);

#endif
