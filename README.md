# Third-Order Sigma-Delta DAC — A Multi-Tool Design Flow

A third-order CIFB sigma-delta digital-to-analog converter for telephony-band voice
(300 Hz – 3.4 kHz), designed end-to-end through MATLAB, Simulink, Vitis HLS, and
LTspice. The repository documents the **multi-tool flow itself** as much as the
converter, with each stage producing a tangible artefact that is consumed by the next.

> **Scope.** This is a training exercise in mixed-signal design flow. The 13-bit ENOB
> figure used as the design target throughout drives every decision in the flow, but
> the simulations performed here do not constitute a formal end-to-end demonstration
> that this performance is achieved in practice. The principal deliverable of the
> project is the demonstrated tool flow, of which the contents of this repository are
> the technical record.

---

## Design at a glance

| Parameter                       | Value                                                  |
|---------------------------------|--------------------------------------------------------|
| Modulator order                 | 3                                                      |
| Topology                        | CIFB with one local resonator feedback                 |
| Quantiser                       | 1-bit                                                  |
| Audio sample rate               | 8 kHz, 13-bit signed input                             |
| PDM rate                        | 5 MHz                                                  |
| Oversampling ratio              | 625                                                    |
| Target voice band               | 300 Hz – 3.4 kHz (G.711)                               |
| Lee-criterion peak NTF gain     | 1.5                                                    |
| Maximum stable input (uₘₐₓ)     | ≈ 0.75                                                 |
| Floating-point reference SNR    | ≈ 104 dB                                               |
| Coefficient / integrator widths | 16-bit (proposed by Fixed-Point Designer)              |
| Target FPGA family              | Xilinx Artix-7 (default `xc7a35tcpg236-1`)             |
| HLS clock target                | 100 MHz                                                |
| Reconstruction filter           | Active 4th-order Sallen-Key Butterworth, fc = 4 kHz    |

---

## Repository layout

```
.
├── DOCS/                             Reference papers (6 PDFs)
│
├── FIXED_POINT/THIRD_ORDER/
│   ├── DESIGN_THIRD_ORDER.m          MATLAB design script (NTF synthesis)
│   ├── SDM_fcn.m                     Floating-point golden reference (auto-generated)
│   ├── FLOATINGPOINT_THIRD_ORDER_SIGMADELTA.slx   Simulink model (FP variant)
│   ├── FIXEDPOINT_THIRD_ORDER_SIGMADELTA.slx      Simulink model (FxP variant)
│   └── FIXEDPOINT_THIRD_ORDER_SIGMADELTA_sfun.mexa64
│
├── HLS/THIRD_ORDER/
│   ├── sdm_cifb_3rd.h                Public interface
│   ├── sdm_cifb_3rd.cpp              Synthesisable modulator (ap_fixed)
│   ├── sdm_cifb_3rd_tb.cpp           C-simulation testbench (writes PWL)
│   ├── run_hls.tcl                   Vitis HLS automation script
│   ├── run.sh                        Bash driver for run_hls.tcl
│   └── sinad.py                      SINAD / ENOB analyser for LTspice output
│
├── .gitignore                        Excludes build artefacts (*.log, *.pwl, slprj/, hdlsrc/)
└── README.md                         (this file)
```

Each folder represents one stage of the flow. The handoffs between stages are
single, versioned artefacts:

- `DESIGN_THIRD_ORDER.m` produces **`SDM_fcn.m`** — a floating-point golden reference
  consumed by Simulink.
- The Simulink Fixed-Point Tool produces a bit-true variant of `SDM_fcn` consumed by
  the HLS implementation.
- The HLS testbench produces **`pdm_output.pwl`** — a PWL file consumed by LTspice
  for analog reconstruction.

The `.gitignore` deliberately excludes the heavy build outputs (`*.pwl`, `*.log`,
`hdlsrc/`, `slprj/`, `*.fda`) so the repository contains only the source.

---

## The multi-tool flow

```
                ┌─────────────────────────────────────────────────────────────────┐
                │                                                                 │
   Architecture │   MATLAB + Schreier Delta-Sigma Toolbox                         │
                │     • synthesizeNTF, realizeNTF, scaleABCD, simulateDSM         │
                │     • produces  SDM_fcn.m  (floating-point reference)           │
                │                                                                 │
                ├─────────────────────────────────────────────────────────────────┤
                │                                                                 │
   Bit-true     │   Simulink + Fixed-Point Designer                               │
                │     • observes runtime ranges from a Simulink test stimulus     │
                │     • proposes fi() types for every variable                    │
                │     • produces a fixed-point variant of SDM_fcn                 │
                │                                                                 │
                ├─────────────────────────────────────────────────────────────────┤
                │                                                                 │
   Hardware     │   Vitis HLS                                                     │
                │     • C++ implementation in ap_fixed types                      │
                │     • #pragma HLS PIPELINE II=1, ap_none interfaces             │
                │     • produces  pdm_output.pwl  via the testbench               │
                │                                                                 │
                ├─────────────────────────────────────────────────────────────────┤
                │                                                                 │
   Analog       │   LTspice  +  sinad.py                                          │
                │     • PWL voltage source feeds reconstruction filter            │
                │     • 4th-order Sallen-Key Butterworth at 4 kHz                 │
                │     • LTspice FFT, then sinad.py for SINAD / ENOB measurement   │
                │                                                                 │
                └─────────────────────────────────────────────────────────────────┘
```

The discipline of choosing the right tool for each stage — and managing the handoffs
through tangible deliverables — is the principal skill the project exercises. No
single tool can verify a mixed-signal design end-to-end.

---

## Stage 1 — MATLAB design and golden-reference generation

Located in `FIXED_POINT/THIRD_ORDER/`.

### What it does

`DESIGN_THIRD_ORDER.m` synthesises the noise transfer function for a third-order
CIFB modulator at OSR = 625 with H∞ = 1.5, scales the dynamic range, runs a
behavioural simulation to establish the floating-point SNR ceiling, verifies
stability (NTF poles, Lee criterion, input headroom), plots the NTF magnitude
response, and writes the floating-point reference function `SDM_fcn.m`.

### Requirements

- MATLAB R2021b or later
- [Schreier's Delta-Sigma Toolbox](https://uk.mathworks.com/matlabcentral/fileexchange/19-delta-sigma-toolbox)
  on the MATLAB path
- (Optional) Control System Toolbox for `tf` and `pole`

### Run it

```matlab
>> cd FIXED_POINT/THIRD_ORDER
>> DESIGN_THIRD_ORDER
```

The script prints the synthesised coefficients, integrator peak swings, predicted
SNR, and stability checks, then (re)writes `SDM_fcn.m` in the same folder and
displays the NTF magnitude plot.

### Output: `SDM_fcn.m`

```matlab
function dac_bit = SDM_fcn(u)  %#codegen
    persistent int1 int2 int3
    if isempty(int1), int1 = 0; int2 = 0; int3 = 0; end

    B1 = 0.172222623529955;
    A1 = 0.172222623529955;   A2 = 0.123562088507108;   A3 = 0.122457379474687;
    C1 = 0.109522886826350;   C2 = 0.357050181625205;
    G1 = 4.245799760022e-5;

    u_norm = max(min(double(u), 4095), -4096) / 4096;

    if int3 >= 0,  dac_bit = true;   v =  1;
    else           dac_bit = false;  v = -1;
    end

    int1 = int1 + B1*u_norm  - A1*v;
    int2 = int2 + C1*int1    - A2*v;
    int3 = int3 + C2*int2 - G1*int3 - A3*v;
end
```

This file is the canonical statement of the modulator's behaviour. Every downstream
stage either consumes it directly or produces an implementation that is verified
against it.

---

## Stage 2 — Simulink mixed-signal model and Fixed-Point Designer conversion

Located in `FIXED_POINT/THIRD_ORDER/`.

### Two parallel Simulink models

| File                                         | Purpose                                                   |
|----------------------------------------------|-----------------------------------------------------------|
| `FLOATINGPOINT_THIRD_ORDER_SIGMADELTA.slx`   | Drives the floating-point `SDM_fcn` directly              |
| `FIXEDPOINT_THIRD_ORDER_SIGMADELTA.slx`      | Holds the Fixed-Point Designer **variant subsystem**      |

Both models share the same surrounding stimulus generator and Simscape-Electrical
analog reconstruction front-end (resistors, capacitors, voltage sensors). The
fixed-point model adds a variant-controlled `MATLAB Function_FixPt` block alongside
the original, allowing the model to switch between floating-point and bit-true
implementations without changing anything else.

The accompanying `FIXEDPOINT_THIRD_ORDER_SIGMADELTA_sfun.mexa64` is a Simulink
S-function generated for Linux (matches the `.mexa64` extension); regenerate it on
your platform if needed by running the model once.

### Conversion settings

| Setting                                | Value                                       |
|----------------------------------------|---------------------------------------------|
| Rounding method                        | Floor                                       |
| Overflow action                        | Wrap                                        |
| Word length (signed integrators)       | 16 bits                                     |
| Word length (unsigned coefficients)    | 16 bits                                     |
| Fraction lengths                       | Per-variable, proposed by the tool          |

The Floor + Wrap combination matches the eventual HLS `AP_TRN` + `AP_WRAP` settings,
ensuring exact bit-equivalence between Simulink and HLS. Wrapping (rather than
saturating) the integrator accumulators is the correct behaviour for a sigma-delta
loop, since saturating integrators would change the modulator's nonlinear dynamics.

### Run it

Open either `.slx` model in Simulink. Use the Fixed-Point Tool from the Apps menu
to re-run the conversion against your stimulus, or simply press *Run* to simulate
the currently active variant.

---

## Stage 3 — Vitis HLS implementation

Located in `HLS/THIRD_ORDER/`.

### Files

| File                  | Role                                                                |
|-----------------------|---------------------------------------------------------------------|
| `sdm_cifb_3rd.h`      | Public interface (13-bit signed input, 1-bit PDM output, sample-valid strobe) |
| `sdm_cifb_3rd.cpp`    | Synthesisable modulator (`ap_fixed` types, `II=1` pipelined function) |
| `sdm_cifb_3rd_tb.cpp` | C-simulation testbench; writes `pdm_output.pwl` for LTspice         |
| `run_hls.tcl`         | Vitis HLS automation: csim → csynth → cosim → export IP catalog     |
| `run.sh`              | Bash driver around `run_hls.tcl`, with `--clean` and `--csim-only`  |
| `sinad.py`            | Post-LTspice SINAD / ENOB analyser (Python + NumPy + matplotlib)    |

### Type definitions

The widths and integer-bit counts come directly from Fixed-Point Designer's
proposals:

```cpp
typedef ap_fixed<16,  1, AP_TRN, AP_WRAP> int1_t;     // ±1.0
typedef ap_fixed<16,  0, AP_TRN, AP_WRAP> int2_t;     // ±0.5
typedef ap_fixed<16, -1, AP_TRN, AP_WRAP> int3_t;     // ±0.25

typedef ap_ufixed<16,  -2, AP_TRN, AP_WRAP> coef_18f_t;   // 18 frac → B1, A1, A2
typedef ap_ufixed<16,  -3, AP_TRN, AP_WRAP> coef_19f_t;   // 19 frac → A3, C1
typedef ap_ufixed<16,  -1, AP_TRN, AP_WRAP> coef_17f_t;   // 17 frac → C2
typedef ap_ufixed<16, -14, AP_TRN, AP_WRAP> coef_30f_t;   // 30 frac → G1
```

The resonator coefficient `G1 ≈ 4.25 × 10⁻⁵` uses 14 negative integer bits to place
the binary point above its magnitude, preserving roughly 16 bits of relative
precision. Rounding `G1` to zero would collapse the resonator and destabilise the
NTF.

### Run it

`run.sh` is the simplest entry point. It checks that `vitis_hls` is on PATH (or
sources `settings64.sh` from the default install location), confirms all source
files are present, runs `run_hls.tcl`, copies the resulting PWL file out of the
build tree, and prints next steps.

```bash
cd HLS/THIRD_ORDER

./run.sh                # full flow: csim → csynth → cosim → export IP
./run.sh --clean        # remove the project before running
./run.sh --csim-only    # quick path: C-simulation only, no synthesis
```

The default Vitis install path inside `run.sh` is
`/tools/Xilinx/Vitis_HLS/2023.2`. Edit the `VITIS_DEFAULT` variable at the top of
the script if your installation is elsewhere. The script has been used with Vitis
HLS 2023.2; other recent versions (2022.2 onwards) should also work since the C++
features and pragmas used are not version-specific.

After a successful run, `pdm_output.pwl` is copied to the working directory ready
for LTspice.

> **Note.** The `--csim-only` branch in `run.sh` currently generates a Tcl script
> that references `sdm_cifb_2nd` (a leftover from a 2nd-order template). For the
> 3rd-order project, prefer the full `./run.sh` invocation, or edit the inline
> heredoc to use `sdm_cifb_3rd` if you only want C-simulation.

### Synthesis target

| Setting                | Value                                                   |
|------------------------|---------------------------------------------------------|
| Top function           | `sdm_cifb_3rd`                                          |
| Default target part    | `xc7a35tcpg236-1` (Artix-7, Cmod A7 / Arty A7 35T)      |
| Clock period           | 10 ns (100 MHz)                                         |
| Initiation interval    | 1 (one sample per clock)                                |
| Export format          | IP Catalog, Verilog RTL                                 |

To target a different device, edit the `set_part` line in `run_hls.tcl`. Several
common alternatives are listed in the comments above the line (Artix-7 Arty A7
100T, Zynq-7000 Zybo Z7-20, Zynq UltraScale+).

After C-synthesis the IP is exported as a Vivado IP Catalog package under
`sdm_hls_project/solution1/impl/ip/` and can be added directly to a Vivado IP
Integrator block design.

---

## Stage 4 — LTspice analog reconstruction and SINAD measurement

The HLS testbench emits `pdm_output.pwl`, a PWL file that captures the 1-bit
modulator output as `(time, voltage)` pairs at 0 V / 3.3 V. PWL points are written
only at PDM transitions (with a 1 ns rise/fall), keeping a 25 ms / 5 MHz simulation
to roughly 100 000 points rather than the quarter-million the worst case would
require.

Open your reconstruction-filter LTspice schematic, point its PWL voltage source at
`pdm_output.pwl`, and run the transient:

```
.tran 0 25m 5m 1u
```

The 5 ms pre-roll is discarded to avoid filter start-up transients. After the run,
use *View → FFT* on the filter output node to inspect the recovered audio, the
modulator's shaped quantisation noise, and the filter's roll-off.

### sinad.py — voice-band SINAD / ENOB

`sinad.py` reads an LTspice voltage trace exported as a tab-separated text file,
resamples to a uniform 1 MHz grid, applies a Blackman-Harris window, integrates
signal and noise power across the 300 Hz – 3.4 kHz voice band, and reports SINAD
and ENOB. It also writes a `spectrum.png` plot.

```bash
# In LTspice: select waveform → File → Export → save as vout_data.txt
cd HLS/THIRD_ORDER
python3 sinad.py
```

Default configuration is at the top of the script:

```python
DATA_FILE     = 'vout_data.txt'
F_SIG         = 1000.0      # test tone frequency (Hz)
F_BAND_LOW    = 300.0       # voice band low edge (Hz)
F_BAND_HIGH   = 3400.0      # voice band high edge (Hz)
INPUT_FS_DBFS = -6.0        # input level (used for full-scale ENOB extrapolation)
```

Edit these to match your test tone and input level. The script reports SINAD,
ENOB at the actual input level, and the equivalent ENOB at full scale.

Python dependencies: `numpy`, `scipy`, `matplotlib`. Install with
`pip install numpy scipy matplotlib`.

### Reconstruction filter

Two candidate networks were evaluated:

- **Passive 2nd-order RC** — R1 = 1.62 kΩ, C1 = 22 nF, R2 = 16.2 kΩ, C2 = 2.2 nF.
  Simple but ~5 dB rejection at the 7.5 kHz audio-rate image is insufficient for
  high-fidelity reconstruction.
- **Active 4th-order Sallen-Key Butterworth** — two cascaded unity-gain stages,
  R = 5.62 kΩ throughout, capacitor pairs (8.2 / 6.8 nF) and (18 / 2.7 nF) setting
  Q₁ = 0.541 and Q₂ = 1.307 respectively. LT1677 op-amps. ~24 dB rejection at the
  same image frequency, dramatically better passband flatness.

The active filter was selected as the preferred topology. Both can be driven from
the same `pdm_output.pwl` for direct comparison.

---

## DOCS/

The `DOCS/` folder contains six reference papers used during the design:

- `sigma_delta_book.pdf`
- `A_third_order_sigma-delta_modulator (1).pdf`
- `Implementation_and_verification_of_MASH_1-1-1_for_fractional-N_frequency_synthesizer_in_Zynq-7000_series_SoC_platform.pdf`
- `Performance_evaluation_of_3rd_order_sigma-delta__spl_Sigma_-_spl_utri__modulators_via_FPGA_implementation.pdf`
- `The_design_of_a_high_speed_and_high_precision_sigma-delta_modulator.pdf`
- `The_design_of_a_multi-bit_sigma-delta_ADC_modulator.pdf`

Together they cover the theoretical foundations, practical FPGA implementation
considerations, and worked examples that informed the architecture and verification
choices made in this project.

---

## Honest performance summary

| Stage                                             | Result                          | Notes                              |
|---------------------------------------------------|---------------------------------|------------------------------------|
| Floating-point reference SNR (MATLAB simulateDSM) | ≈ 104 dB                        | Theoretical ceiling                |
| Fixed-point loss (Simulink bit-true)              | < 0.5 dB                        | Within conversion budget           |
| HLS C-simulation bitstream                        | bit-equivalent to Simulink FxP  | Verified by C/RTL co-simulation    |
| LTspice end-to-end SINAD (voice band)             | ≈ 50 dB                         | Bounded by simulation environment  |
| Target                                            | 80 dB (≈ 13 ENOB)               | **Not formally demonstrated** end-to-end |

The gap between the modulator's intrinsic capability (~104 dB at the floating-point
level) and the measured end-to-end SINAD (~50 dB through LTspice) is bounded by:

- **8 kHz audio-rate images** at multiples of 8 kHz ± fₛᵢgₙₐₗ that no analog filter
  alone can fully suppress;
- **LTspice analog measurement floor** set by op-amp noise models, solver
  tolerances, and PWL stimulus quality;
- **Limit-cycle artefacts** from rational-ratio test stimuli without dither.

Closing the gap would principally require a digital interpolation filter to push
the audio-rate images out of the analog band, and direct MATLAB FFT analysis of
the bitstream to verify the modulator's intrinsic SNDR independent of the LTspice
signal chain.

---

## References

- Schreier, R., and Temes, G. C. *Understanding Delta-Sigma Data Converters*
  (2nd ed.). Wiley-IEEE Press, 2017.
- Schreier, R. *Delta-Sigma Toolbox for MATLAB*. MATLAB Central File Exchange,
  Listing 19. <https://uk.mathworks.com/matlabcentral/fileexchange/19-delta-sigma-toolbox>
- Additional references in `DOCS/`.

---

## Licence

This repository does not yet specify a licence. Add your licence of choice (e.g.
MIT, Apache-2.0, CC-BY-4.0) before sharing, otherwise default copyright applies
and others cannot legally reuse the code.
