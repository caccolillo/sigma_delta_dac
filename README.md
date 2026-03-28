# 13-bit Sigma-Delta DAC — FPGA Project

100 MHz clock | 8 kHz sample rate | 300 Hz – 3.4 kHz voice band (G.711)

---

## File listing

| File | Description |
|---|---|
| `sd_dac_8k.v` | 4th-order MASH 1-1-1-1 sigma-delta DAC with Bresenham interpolation and PRBS dither |
| `sine_gen.v` | 256-entry LUT sine generator, sweeps 9 voice-band frequencies at 8 kHz |
| `top.v` | Top-level wrapper connecting sine generator to DAC |
| `tb_sd_dac.sv` | SystemVerilog testbench — writes CSV, calls `plot_dac.py` automatically |
| `plot_dac.py` | Hardware-matched IIR filter, SINAD/ENOB/SNR/THD measurement, voice band sweep plot |

---

## DAC architecture

### Modulator — 4th-order MASH 1-1-1-1

Four cascaded first-order sigma-delta accumulators. Unconditionally stable (MASH property). Noise shaping pushes quantisation noise above the voice band.

```
OSR = 100 MHz / (2 × 4 kHz) = 12,500
Theoretical in-band SNR > 300 dB (limited in practice by op-amp noise, ~80 dB)
```

MASH combiner:
```
y = c1 + (c2 − c2z) + (c3 − 2c3z + c3zz) + (c4 − 3c4z + 3c4zz − c4zzz)
```

### Input interpolation — Bresenham linear ramp

Replaces the original zero-order hold. Ramps the output from the previous sample to the current sample over exactly 12,500 clock cycles using a Bresenham accumulator — no fixed-point multipliers, no approximation error. Suppresses ZOH images at 8 kHz, 16 kHz, etc. by ~40 dB compared to a plain hold.

```verilog
// Per-clock step: err += |delta|
// When err >= 12500: err -= 12500, interp += sign(delta)
```

### Dither — 16-bit PRBS LFSR

Polynomial: x¹⁶ + x¹⁵ + x¹³ + x⁴ + 1, period 65,535. Adds 0 or 1 LSB each cycle. Breaks deterministic idle tones on constant or slow-moving inputs. Inaudible in the voice band.

---

## Simulation

### Requirements

```bash
pip install pandas numpy scipy matplotlib
```

### Vivado xsim

```bash
xvlog --sv tb_sd_dac.sv
xvlog sd_dac_8k.v sine_gen.v top.v
xelab -debug typical tb_sd_dac -s tb_sim
xsim tb_sim -runall
```

**Important — edit paths in `tb_sd_dac.sv` before running:**

```systemverilog
localparam CSV_PATH = "/your/path/pdm_output.csv";
localparam PLOT_CMD = "python3 /your/path/plot_dac.py";
```

### Icarus Verilog

```bash
iverilog -g2012 -o sim tb_sd_dac.sv sd_dac_8k.v sine_gen.v top.v
vvp sim
```

### Questa / ModelSim

```bash
vlog -sv tb_sd_dac.sv sd_dac_8k.v sine_gen.v top.v
vsim -c tb_sd_dac -do "run -all; quit"
```

After simulation completes, `plot_dac.py` is called automatically via `$system`.
If your simulator does not support `$system`, run manually:

```bash
python3 plot_dac.py
```

---

## Simulation parameters

The testbench sweeps 9 voice-band frequencies, 500 ms each:

| Index | Frequency | Phase inc |
|---|---|---|
| 0 | 312.5 Hz | 10 |
| 1 | 500.0 Hz | 16 |
| 2 | 812.5 Hz | 26 |
| 3 | 1000.0 Hz | 32 |
| 4 | 1500.0 Hz | 48 |
| 5 | 2000.0 Hz | 64 |
| 6 | 2500.0 Hz | 80 |
| 7 | 3000.0 Hz | 96 |
| 8 | 3406.3 Hz | 109 |

Total simulation: **450,000,000 cycles (4.5 seconds)**. Expect 5–15 minutes in xsim depending on hardware.

The CSV is written at the 8 kHz sample rate only (one row per `sample_valid` pulse), keeping the file to ~36,000 rows rather than 450 million.

### Known limitation at 3.4 kHz

At 8 kHz sample rate, 3.4 kHz has only 2.35 samples per cycle. The sine generator produces a staircase rather than a sine wave at this frequency, which degrades the simulated SINAD measurement. This is a **test generator limitation**, not a DAC defect. The 300 Hz–3 kHz results (SINAD 77–81 dB, ENOB 12.5–13.2 bits) accurately characterise the DAC. The 3.4 kHz point should be verified on real hardware with a spectrum analyser.

---

## Measured performance (simulation)

| Frequency | SINAD | ENOB | SNR | Notes |
|---|---|---|---|---|
| 312 Hz | 77 dB | 12.5 b | ~80 dB | Near HPF edge |
| 500 Hz | 78 dB | 12.7 b | ~80 dB | |
| 812 Hz | 79 dB | 12.8 b | ~80 dB | |
| 1 kHz | 81 dB | 13.2 b | ~81 dB | |
| 1.5 kHz | 78 dB | 12.7 b | ~80 dB | |
| 2 kHz | 81 dB | 13.2 b | ~81 dB | |
| 2.5 kHz | 77 dB | 12.5 b | ~79 dB | |
| 3 kHz | 79 dB | 12.9 b | ~80 dB | |
| 3.4 kHz | — | — | — | Test generator aliased — see above |

---

## Watchdog note (xsim)

Do **not** use a single large `#delay` in the testbench watchdog with xsim. A value exceeding 2³¹ − 1 ns (≈ 2.15 seconds) overflows xsim's 32-bit delay register and fires at t = 0, killing the simulation immediately. The testbench uses `repeat(600) #100_000_000` (600 × 100 ms chunks) as a safe equivalent to a 60-second timeout.

---

## FPGA constraints (Xilinx XDC)

```tcl
set_property PACKAGE_PIN  <your_pin>  [get_ports dout]
set_property IOSTANDARD   LVCMOS33    [get_ports dout]
set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ */dout_reg}]
create_clock -name clk -period 10.0 [get_ports clk]
```

Place the output register in the IOB to minimise clock-to-pad jitter. Jitter on `dout` aliases directly into SINAD.

---

## Analogue reconstruction filter (external hardware)

```
FPGA dout
  |
 33 Ω          series resistor — limits FPGA output current, reduces ground bounce
  |
  +-- HPF:     R = 5.6 kΩ, C = 100 nF, unity-gain buffer       fc = 284 Hz (−3 dB)
  |
  +-- LPF 1:   R = 3.9 kΩ, C = 10 nF, unity-gain buffer        fc = 4.08 kHz (−3 dB)
  |
  +-- LPF 2:   Sallen-Key  R1=R2=3.9 kΩ, C1=C2=10 nF           fc = 4.08 kHz
               Rg = Rf = 10 kΩ  →  K = 2, Q = 1 (Butterworth)
  |
 Vout
```

### Why 3.9 kΩ (not the original 4.7 kΩ)

Setting fc at 3.4 kHz (the G.711 upper edge) puts 3.4 kHz at the −3 dB point, degrading ENOB at the top of the band. Raising fc to 4.08 kHz keeps 3.4 kHz at −0.96 dB in the passband while still giving −17.3 dB image rejection at 8 kHz — the best E24 trade-off.

| R value | fc | @ 3.4 kHz | @ 8 kHz |
|---|---|---|---|
| 4.7 kΩ (original) | 3.39 kHz | −2.78 dB | −22.1 dB |
| 3.6 kΩ | 4.42 kHz | −0.52 dB | −15.3 dB |
| **3.9 kΩ (current)** | **4.08 kHz** | **−0.96 dB** | **−17.3 dB** |

### Component notes

- Use **1% metal film** resistors for all filter resistors.
- Use **C0G/NP0 ceramic** capacitors for all filter capacitors. X7R and Y5V have voltage- and temperature-dependent capacitance that shifts the cutoff frequency.
- Match R1/R2 and C1/C2 in the Sallen-Key stage from the same batch for best Q accuracy.
- Op-amp: **MCP6002** (1.8–5.5 V single supply, rail-to-rail) or **TL072** (±8–18 V dual supply). GBW > 340 kHz required — any general-purpose op-amp exceeds this.
- Decouple each op-amp supply pin with 100 nF ceramic + 10 µF electrolytic within 2 mm of the pin.
