// =============================================================================
// sdm_cifb_2nd.cpp
// 2nd-order CIFB Sigma-Delta Modulator for Vitis HLS
//
// Architecture:
//   - 2nd-order CIFB topology from Schreier Delta-Sigma Toolbox
//   - OSR = 625 (5 MHz PDM rate, 8 kHz audio sample rate)
//   - Coefficients matching Verilog Q16 implementation:
//       B1 = A1 = 51138/65536 ≈ 0.7803
//       C1 = 3493/65536       ≈ 0.0533
//       A2 = 9765/65536       ≈ 0.1490
//
// Word lengths (matched to MATLAB Fixed-Point Designer output):
//   u_norm  : ap_fixed<16, 2>      signed, 14 fractional bits  range ±2.0
//   int1    : ap_fixed<16, 4>      signed, 12 fractional bits  range ±8.0
//   int2    : ap_fixed<16, 5>      signed, 11 fractional bits  range ±16.0
//   B1, A1  : ap_ufixed<16, 0>     unsigned, 16 fractional bits
//   C1      : ap_ufixed<16, -4>    unsigned, 20 fractional bits
//   A2      : ap_ufixed<16, -2>    unsigned, 18 fractional bits
//
// Interface (rate-agnostic via sample_valid strobe):
//   u            : 13-bit signed audio sample (held by host)
//   sample_valid : 1 = update SDM this cycle, 0 = hold previous output
//   ap_return    : 1-bit PDM output, latched between valid pulses
//
// Pipeline target: II=1 at 100 MHz host clock
// =============================================================================

#include "sdm_cifb_2nd.h"
#include <ap_fixed.h>

// ----------------------------------------------------------------
//  TYPE DEFINITIONS
// ----------------------------------------------------------------
typedef ap_fixed<16, 2,  AP_TRN, AP_WRAP> u_norm_t;
typedef ap_fixed<16, 4,  AP_TRN, AP_WRAP> int1_t;
typedef ap_fixed<16, 5,  AP_TRN, AP_WRAP> int2_t;

typedef ap_ufixed<16,  0, AP_TRN, AP_WRAP> coef_unity_t;
typedef ap_ufixed<16, -4, AP_TRN, AP_WRAP> coef_C1_t;
typedef ap_ufixed<16, -2, AP_TRN, AP_WRAP> coef_A2_t;

// Wide intermediate type for converting int13 input to fixed-point.
// 28-bit total with 14 integer bits comfortably holds the int13 range
// (±4096) while having matching fractional precision for the >> 12 shift
// that follows.
typedef ap_fixed<28, 14, AP_TRN, AP_WRAP> u_wide_t;

// ----------------------------------------------------------------
//  COEFFICIENTS — match Verilog Q16 integer values exactly
// ----------------------------------------------------------------
static const coef_unity_t B1 = 51138.0 / 65536.0;     // ≈ 0.7803
static const coef_unity_t A1 = 51138.0 / 65536.0;     // ≈ 0.7803
static const coef_C1_t    C1 =  3493.0 / 65536.0;     // ≈ 0.0533
static const coef_A2_t    A2 =  9765.0 / 65536.0;     // ≈ 0.1490

// Saturation limits — match MATLAB ±8.0 saturation
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

    // ----------------------------------------------------------------
    //  PERSISTENT STATE — preserved across function calls
    // ----------------------------------------------------------------
    static int1_t int1     = 0;
    static int2_t int2     = 0;
    static pdm_t  pdm_held = 0;

    // ----------------------------------------------------------------
    //  Only update SDM when sample_valid is asserted
    // ----------------------------------------------------------------
    if (sample_valid == 1) {

        // ----------------------------------------------------------------
        //  INPUT CLAMPING — guarantee 13-bit signed range
        // ----------------------------------------------------------------
        input_t u_clamped;
        if (u > input_t(4095))       u_clamped = 4095;
        else if (u < input_t(-4096)) u_clamped = -4096;
        else                          u_clamped = u;

        // ----------------------------------------------------------------
        //  INPUT NORMALISATION  — convert int13 to [-1, +1]
        //
        //  Step 1: cast int13 to a wide fixed-point type that preserves
        //          the integer interpretation (u_wide_t has 14 integer
        //          bits which holds ±4096 cleanly)
        //  Step 2: arithmetic right-shift by 12 = divide by 4096
        //
        //  Example:
        //    u_clamped = 1024
        //    u_as_int  = 1024.0  (in u_wide_t, 14 integer bits)
        //    u_norm    = 0.25    (in u_norm_t, 2 integer bits, after >>12)
        // ----------------------------------------------------------------
        u_wide_t u_as_int = u_clamped;
        u_norm_t u_norm   = u_as_int >> 12;

        // ----------------------------------------------------------------
        //  QUANTIZER — sign of int2
        // ----------------------------------------------------------------
        pdm_t  dac_bit;
        int1_t dac_val;

        if (int2 >= int2_t(0)) {
            dac_bit = 1;
            dac_val = int1_t(1.0);
        } else {
            dac_bit = 0;
            dac_val = int1_t(-1.0);
        }

        // ----------------------------------------------------------------
        //  INTEGRATOR 1: int1[n] = B1*u_norm[n] + int1[n-1] - A1*dac_val
        // ----------------------------------------------------------------
        int1_t b1_u     = int1_t(B1 * u_norm);
        int1_t a1_dac   = int1_t(A1 * dac_val);
        int1_t int1_new = int1 + b1_u - a1_dac;

        if (int1_new > INT_SAT_MAX)      int1 = INT_SAT_MAX;
        else if (int1_new < INT_SAT_MIN) int1 = INT_SAT_MIN;
        else                              int1 = int1_new;

        // ----------------------------------------------------------------
        //  INTEGRATOR 2: int2[n] = C1*int1[n] + int2[n-1] - A2*dac_val
        // ----------------------------------------------------------------
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
