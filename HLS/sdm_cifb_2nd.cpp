// =============================================================================
// sdm_cifb_2nd.cpp
// 2nd-order CIFB Sigma-Delta Modulator for Vitis HLS
//
// Translated from MATLAB Fixed-Point Designer auto-generated code.
// Coefficients from Schreier Delta-Sigma Toolbox:
//   order = 2, OSR = 625, nlev = 2, form = 'CIFB', umax = 0.5
//
// Word-length choices match the MATLAB fi types from auto-conversion:
//   u_norm  : signed 16-bit, 14 fractional bits  (ap_fixed<16,2>)
//   int1    : signed 16-bit, 12 fractional bits  (ap_fixed<16,4>)
//   int2    : signed 16-bit, 11 fractional bits  (ap_fixed<16,5>)
//   B1, A1  : unsigned 16-bit, 16 fractional bits (ap_ufixed<16,0>)
//   C1      : unsigned 16-bit, 20 fractional bits (ap_ufixed<16,-4>)
//   A2      : unsigned 16-bit, 18 fractional bits (ap_ufixed<16,-2>)
//
// Interface:
//   u            : 13-bit signed audio sample (held by host)
//   sample_valid : pulse high for one clock cycle to advance the SDM
//   ap_return    : current PDM bit (held between valid pulses)
//
// The SDM is rate-agnostic — sample_valid timing is set by the host.
// =============================================================================

#include "sdm_cifb_2nd.h"
#include <ap_fixed.h>

// ----------------------------------------------------------------
//  TYPE DEFINITIONS
// ----------------------------------------------------------------
typedef ap_fixed<16, 2,  AP_TRN, AP_WRAP> u_norm_t;
typedef ap_fixed<16, 4,  AP_TRN, AP_WRAP> int1_t;
typedef ap_fixed<16, 5,  AP_TRN, AP_WRAP> int2_t;

typedef ap_ufixed<16, 0,  AP_TRN, AP_WRAP> coef_unity_t;
typedef ap_ufixed<16, -4, AP_TRN, AP_WRAP> coef_C1_t;
typedef ap_ufixed<16, -2, AP_TRN, AP_WRAP> coef_A2_t;

// ----------------------------------------------------------------
//  COEFFICIENTS — match Verilog Q16 integer values
// ----------------------------------------------------------------
static const coef_unity_t B1 = 51138.0 / 65536.0;     // ≈ 0.7803
static const coef_unity_t A1 = 51138.0 / 65536.0;     // ≈ 0.7803
static const coef_C1_t    C1 =  3493.0 / 65536.0;     // ≈ 0.0533
static const coef_A2_t    A2 =  9765.0 / 65536.0;     // ≈ 0.1490

// Saturation limits — match MATLAB ±8.0
static const int1_t INT_SAT_MAX  =  7.999755859375;
static const int1_t INT_SAT_MIN  = -8.0;
static const int2_t INT2_SAT_MAX =  7.99951171875;
static const int2_t INT2_SAT_MIN = -8.0;

// ----------------------------------------------------------------
//  TOP-LEVEL FUNCTION
// ----------------------------------------------------------------
pdm_t sdm_cifb_2nd(input_t u, tick_t sample_valid) {
    #pragma HLS PIPELINE II=1
    #pragma HLS INTERFACE ap_none port=u
    #pragma HLS INTERFACE ap_none port=sample_valid
    #pragma HLS INTERFACE ap_ctrl_none port=return

    // Persistent state — preserved across function calls
    static int1_t int1     = 0;
    static int2_t int2     = 0;
    static pdm_t  pdm_held = 0;

    // Only update SDM when sample_valid is asserted
    if (sample_valid == 1) {

        // Input clamping
        input_t u_clamped;
        if (u > input_t(4095))       u_clamped = 4095;
        else if (u < input_t(-4096)) u_clamped = -4096;
        else                          u_clamped = u;

        // Normalise to [-1, +1]: divide by 4096 = right shift 12
        u_norm_t u_norm = u_norm_t(u_clamped) >> 12;

        // Quantizer — sign of int2
        pdm_t  dac_bit;
        int1_t dac_val;

        if (int2 >= int2_t(0)) {
            dac_bit = 1;
            dac_val = int1_t(1.0);
        } else {
            dac_bit = 0;
            dac_val = int1_t(-1.0);
        }

        // Integrator 1: int1[n] = B1*u_norm[n] + int1[n-1] - A1*dac_val
        int1_t b1_u     = int1_t(B1 * u_norm);
        int1_t a1_dac   = int1_t(A1 * dac_val);
        int1_t int1_new = int1 + b1_u - a1_dac;

        if (int1_new > INT_SAT_MAX)      int1 = INT_SAT_MAX;
        else if (int1_new < INT_SAT_MIN) int1 = INT_SAT_MIN;
        else                              int1 = int1_new;

        // Integrator 2: int2[n] = C1*int1[n] + int2[n-1] - A2*dac_val
        int2_t c1_x     = int2_t(C1 * int1);
        int2_t a2_dac   = int2_t(A2 * dac_val);
        int2_t int2_new = int2 + c1_x - a2_dac;

        if (int2_new > INT2_SAT_MAX)      int2 = INT2_SAT_MAX;
        else if (int2_new < INT2_SAT_MIN) int2 = INT2_SAT_MIN;
        else                               int2 = int2_new;

        // Latch the new PDM bit
        pdm_held = dac_bit;
    }

    // Return the held value (updated only on valid pulses)
    return pdm_held;
}
