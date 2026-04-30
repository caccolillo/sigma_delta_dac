// =============================================================================
// sdm_cifb_2nd_tb.cpp
//
// Vitis HLS testbench for the 2nd-order CIFB SDM.
//
// Generates a 440 Hz sine at 8 kHz audio rate (held between samples),
// runs the SDM at 5 MHz via sample_valid strobe (1 in 20 host cycles),
// captures the PDM output to an LTspice-ready PWL file.
//
// Output: pdm_output.pwl
//   - Time-voltage pairs with 1 ns rise/fall time
//   - 0V for PDM=0, 3.3V for PDM=1
//   - Ready for direct import into LTspice via voltage source PWL FILE
// =============================================================================

#include "sdm_cifb_2nd.h"
#include <iostream>
#include <fstream>
#include <iomanip>
#include <cmath>

int main() {

    // ----------------------------------------------------------------
    //  TEST PARAMETERS
    // ----------------------------------------------------------------
    const double FS_CLK     = 100.0e6;     // 100 MHz host clock
    const int    CLK_DIV    = 20;          // 100 MHz / 20 = 5 MHz PDM rate
    const double FS_PDM     = FS_CLK / CLK_DIV;
    const double T_CLK      = 1.0 / FS_CLK;

    const double FS_AUDIO   = 8000.0;      // 8 kHz audio sample rate
    const double F_SIG      = 440.0;       // 440 Hz test tone (musical A4)
    const double AMP        = 1024.0;      // 25% full scale (= -12 dBFS)

    const double SIM_TIME_S = 25.0e-3;     // 25 ms simulation
    const int    TOTAL_CLOCKS = (int)(SIM_TIME_S * FS_CLK);

    const double V_HIGH     = 3.3;         // PDM high level
    const double V_LOW      = 0.0;         // PDM low level
    const double T_EDGE     = 1.0e-9;      // 1 ns rise/fall time

    const int CLOCKS_PER_AUDIO = (int)(FS_CLK / FS_AUDIO);   // 12500

    // ----------------------------------------------------------------
    //  PRINT CONFIGURATION
    // ----------------------------------------------------------------
    std::cout << "===== SDM HLS testbench =====" << std::endl;
    std::cout << "Host clock:          " << FS_CLK / 1e6     << " MHz" << std::endl;
    std::cout << "PDM rate:            " << FS_PDM / 1e6     << " MHz" << std::endl;
    std::cout << "Audio sample rate:   " << FS_AUDIO         << " Hz"  << std::endl;
    std::cout << "Test tone:           " << F_SIG            << " Hz"  << std::endl;
    std::cout << "Amplitude:           " << AMP              << " LSB" << std::endl;
    std::cout << "Amplitude in dBFS:   " 
              << 20.0*std::log10(AMP/4096.0) << " dB"        << std::endl;
    std::cout << "Simulation time:     " << SIM_TIME_S * 1000 << " ms" << std::endl;
    std::cout << "Total host clocks:   " << TOTAL_CLOCKS                << std::endl;
    std::cout << "Clocks per audio:    " << CLOCKS_PER_AUDIO            << std::endl;
    std::cout << std::endl;

    // ----------------------------------------------------------------
    //  OPEN OUTPUT FILE
    // ----------------------------------------------------------------
    std::ofstream pwl("pdm_output.pwl");
    if (!pwl.is_open()) {
        std::cerr << "ERROR: could not open pdm_output.pwl for writing" << std::endl;
        return 1;
    }
    pwl << std::scientific << std::setprecision(9);

    // Initial point at t=0
    pwl << "0.0 " << V_LOW << "\n";

    // ----------------------------------------------------------------
    //  SIMULATION LOOP
    // ----------------------------------------------------------------
    int     audio_hold  = 0;
    int     audio_idx   = 0;
    input_t u_curr      = 0;
    int     pdm_div     = 0;

    pdm_t pdm_prev = 0;
    int   transitions = 0;
    int   ones  = 0;
    int   zeros = 0;

    int u_min =  100000;
    int u_max = -100000;

    for (int n = 0; n < TOTAL_CLOCKS; n++) {

        // Update audio sample at 8 kHz
        if (audio_hold == 0) {
            double t = audio_idx / FS_AUDIO;
            double sine_val = AMP * std::sin(2.0 * M_PI * F_SIG * t);
            int u_int = (int)sine_val;

            u_curr = input_t(u_int);

            if (u_int < u_min) u_min = u_int;
            if (u_int > u_max) u_max = u_int;

            // Print first few samples for verification
            if (audio_idx < 5) {
                std::cout << "audio[" << audio_idx 
                          << "] t=" << std::fixed << std::setprecision(6) << t 
                          << "s sine=" << std::setprecision(2) << sine_val 
                          << " u_curr=" << (int)u_curr 
                          << std::scientific << std::endl;
            }

            audio_idx++;
        }
        audio_hold = (audio_hold + 1) % CLOCKS_PER_AUDIO;

        // Generate sample_valid pulse at 5 MHz (1 cycle high every 20)
        tick_t valid = (pdm_div == 0) ? tick_t(1) : tick_t(0);
        pdm_div = (pdm_div + 1) % CLK_DIV;

        // Run the SDM
        pdm_t pdm = sdm_cifb_2nd(u_curr, valid);

        // Detect edge: only write to PWL on transitions
        if (valid == 1) {
            if (pdm == 1) ones++;
            else          zeros++;

            if (pdm != pdm_prev) {
                double t_edge = n * T_CLK;
                double v_old  = (pdm_prev == 1) ? V_HIGH : V_LOW;
                double v_new  = (pdm        == 1) ? V_HIGH : V_LOW;

                pwl << (t_edge - T_EDGE) << " " << v_old << "\n";
                pwl << t_edge            << " " << v_new << "\n";

                transitions++;
                pdm_prev = pdm;
            }
        }
    }

    // Final point — extend last value to end of simulation
    double t_end = TOTAL_CLOCKS * T_CLK;
    double v_end = (pdm_prev == 1) ? V_HIGH : V_LOW;
    pwl << t_end << " " << v_end << "\n";
    pwl.close();

    // ----------------------------------------------------------------
    //  REPORT
    // ----------------------------------------------------------------
    std::cout << std::endl;
    std::cout << "===== Simulation complete =====" << std::endl;
    std::cout << "Audio samples:       " << audio_idx << std::endl;
    std::cout << "Audio range:         [" << u_min << ", " << u_max << "]" << std::endl;
    std::cout << "Total PDM ticks:     " << (ones + zeros) << std::endl;
    std::cout << "Ones:                " << ones  << " ("
              << 100.0 * ones / (ones + zeros)  << "%)" << std::endl;
    std::cout << "Zeros:               " << zeros << " ("
              << 100.0 * zeros / (ones + zeros) << "%)" << std::endl;
    std::cout << "Transitions:        " << transitions << std::endl;
    std::cout << "Avg toggle rate:    " << transitions / SIM_TIME_S / 1e6 
              << " MHz" << std::endl;
    std::cout << "Output file:        pdm_output.pwl" << std::endl;
    std::cout << std::endl;

    // Sanity check
    if (ones == 0 || zeros == 0) {
        std::cerr << "FAIL: PDM stuck at one level" << std::endl;
        return 1;
    }
    if (u_max <= 0 && u_min >= 0) {
        std::cerr << "FAIL: audio input did not vary" << std::endl;
        return 1;
    }

    std::cout << "PASS: SDM operating normally" << std::endl;
    std::cout << std::endl;
    std::cout << "===== LTspice usage =====" << std::endl;
    std::cout << "1. Place a voltage source (V) in your schematic" << std::endl;
    std::cout << "2. Right-click → Advanced → tick PWL FILE" << std::endl;
    std::cout << "3. Browse to pdm_output.pwl" << std::endl;
    std::cout << "4. Connect to your RC reconstruction filter" << std::endl;
    std::cout << "5. Run: .tran 0 25m 5m 1u" << std::endl;
    std::cout << "6. View → FFT for spectrum analysis" << std::endl;

    return 0;
}
