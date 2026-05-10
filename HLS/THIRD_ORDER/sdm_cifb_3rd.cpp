// =============================================================================
// sdm_cifb_3rd.cpp
// 3rd-order CIFB Sigma-Delta Modulator for Vitis HLS
//
// Architecture:
//   - 3rd-order CIFB topology from Schreier Delta-Sigma Toolbox
//   - One resonator local feedback (G1) places NTF zeros inside the
//     signal band for improved in-band noise shaping
//   - OSR = 625 (5 MHz PDM rate, 8 kHz audio sample rate)
//
// Coefficients (from MATLAB realizeNTF + scaleABCD, 3rd-order CIFB):
//       B1 ≈ 0.172222623529955
//       A1 ≈ 0.172222623529955
//       A2 ≈ 0.123562088507108
//       A3 ≈ 0.122457379474687
//       C1 ≈ 0.109522886826350
//       C2 ≈ 0.357050181625205
//       G1 ≈ 4.245799760022e-5
//
// Word lengths — taken directly from MATLAB Fixed-Point Designer output:
//   u_norm  : ap_fixed<16,  0>     signed, 16 frac  range ±0.5
//   int1    : ap_fixed<16,  1>     signed, 15 frac  range ±1.0
//   int2    : ap_fixed<16,  0>     signed, 16 frac  range ±0.5
//   int3    : ap_fixed<16, -1>     signed, 17 frac  range ±0.25
//   B1, A1, A2 : ap_ufixed<16, -2>   18 frac
//   A3, C1     : ap_ufixed<16, -3>   19 frac
//   C2         : ap_ufixed<16, -1>   17 frac
//   G1         : ap_ufixed<16, -14>  30 frac (G1 ≈ 4.2e-5)
//   v_dac      : ap_fixed<16,  2>    14 frac, holds ±1
//
// Overflow: AP_WRAP throughout, matching MATLAB's OverflowAction='Wrap'.
// Rounding: AP_TRN, matching MATLAB's RoundingMethod='Floor'.
//
// NOTE: integer ranges are tight. If real-world inputs cause saturation,
//       widen int1/int2/int3 (most likely int3) — see TODO markers below.
//
// Interface (rate-agnostic via sample_valid strobe):
//   u            : 13-bit signed audio sample (held by host)
//   sample_valid : 1 = update SDM this cycle, 0 = hold previous output
//   ap_return    : 1-bit PDM output, latched between valid pulses
//
// Pipeline target: II=1 at 100 MHz host clock
// =============================================================================

#include "sdm_cifb_3rd.h"
#include <ap_fixed.h>

// ----------------------------------------------------------------
//  TYPE DEFINITIONS — match MATLAB Fixed-Point Designer output
// ----------------------------------------------------------------
typedef ap_fixed<16,  0, AP_TRN, AP_WRAP> u_norm_t;   // 16 frac
typedef ap_fixed<16,  1, AP_TRN, AP_WRAP> int1_t;     // 15 frac
typedef ap_fixed<16,  0, AP_TRN, AP_WRAP> int2_t;     // 16 frac
typedef ap_fixed<16, -1, AP_TRN, AP_WRAP> int3_t;     // 17 frac
typedef ap_fixed<16,  2, AP_TRN, AP_WRAP> v_dac_t;    // 14 frac

typedef ap_ufixed<16, -2, AP_TRN, AP_WRAP> coef_18f_t;  // 18 frac → B1, A1, A2
typedef ap_ufixed<16, -3, AP_TRN, AP_WRAP> coef_19f_t;  // 19 frac → A3, C1
typedef ap_ufixed<16, -1, AP_TRN, AP_WRAP> coef_17f_t;  // 17 frac → C2
typedef ap_ufixed<16, -14, AP_TRN, AP_WRAP> coef_30f_t; // 30 frac → G1

// Wide intermediate type for converting int13 input to fixed-point.
// 28-bit total with 14 integer bits comfortably holds the int13 range
// (±4096) while having matching fractional precision for the >> 12 shift.
typedef ap_fixed<28, 14, AP_TRN, AP_WRAP> u_wide_t;

// ----------------------------------------------------------------
//  COEFFICIENTS
// ----------------------------------------------------------------
static const coef_18f_t B1 = 0.172222623529955;
static const coef_18f_t A1 = 0.172222623529955;
static const coef_18f_t A2 = 0.123562088507108;
static const coef_19f_t A3 = 0.122457379474687;
static const coef_19f_t C1 = 0.109522886826350;
static const coef_17f_t C2 = 0.357050181625205;
static const coef_30f_t G1 = 4.245799760022e-5;

// ----------------------------------------------------------------
//  TOP-LEVEL FUNCTION
// ----------------------------------------------------------------
pdm_t sdm_cifb_3rd(input_t u, tick_t sample_valid) {
    #pragma HLS PIPELINE II=1
    #pragma HLS INTERFACE ap_none port=u
    #pragma HLS INTERFACE ap_none port=sample_valid
    #pragma HLS INTERFACE ap_ctrl_none port=return

    // ----------------------------------------------------------------
    //  PERSISTENT STATE — preserved across function calls
    //  TODO: if int3 saturates under real input, widen to ap_fixed<20, 2>
    //        or similar. See range comments at top of file.
    // ----------------------------------------------------------------
    static int1_t int1     = 0;
    static int2_t int2     = 0;
    static int3_t int3     = 0;
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
        //  INPUT NORMALISATION — convert int13 to [-1, +1)
        //
        //  Step 1: cast int13 to a wide fixed-point type that preserves
        //          the integer interpretation (u_wide_t has 14 integer
        //          bits which holds ±4096 cleanly)
        //  Step 2: arithmetic right-shift by 12 = divide by 4096
        // ----------------------------------------------------------------
        u_wide_t u_as_int = u_clamped;
        u_norm_t u_norm   = u_as_int >> 12;

        // ----------------------------------------------------------------
        //  QUANTIZER — sign of int3 (last integrator)
        // ----------------------------------------------------------------
        pdm_t   dac_bit;
        v_dac_t dac_val;

        if (int3 >= int3_t(0)) {
            dac_bit = 1;
            dac_val = v_dac_t(1.0);
        } else {
            dac_bit = 0;
            dac_val = v_dac_t(-1.0);
        }

        // ----------------------------------------------------------------
        //  INTEGRATOR 1: int1[n] = int1[n-1] + B1*u_norm - A1*dac_val
        // ----------------------------------------------------------------
        int1_t b1_u   = int1_t(B1 * u_norm);
        int1_t a1_dac = int1_t(A1 * dac_val);
        int1 = int1 + b1_u - a1_dac;

        // ----------------------------------------------------------------
        //  INTEGRATOR 2: int2[n] = int2[n-1] + C1*int1 - A2*dac_val
        // ----------------------------------------------------------------
        int2_t c1_x   = int2_t(C1 * int1);
        int2_t a2_dac = int2_t(A2 * dac_val);
        int2 = int2 + c1_x - a2_dac;

        // ----------------------------------------------------------------
        //  INTEGRATOR 3 (with resonator local feedback G1):
        //      int3[n] = int3[n-1] + C2*int2 - G1*int3 - A3*dac_val
        //
        //  G1 places the NTF zeros at non-DC frequencies inside the
        //  signal band, improving in-band noise shaping vs a pure
        //  cascade of three differentiators.
        // ----------------------------------------------------------------
        int3_t c2_x   = int3_t(C2 * int2);
        int3_t g1_x   = int3_t(G1 * int3);
        int3_t a3_dac = int3_t(A3 * dac_val);
        int3 = int3 + c2_x - g1_x - a3_dac;

        // Latch the new PDM bit
        pdm_held = dac_bit;
    }

    // Return the held value (updated only on valid pulses)
    return pdm_held;
}
