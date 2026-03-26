# 13-bit Sigma-Delta DAC — FPGA Project

100 MHz clock | 8 kHz sample rate | 300 Hz – 3.4 kHz voice band (G.711)

---

## File listing

| File | Description |
|---|---|
| `sd_dac_8k.v` | 3rd-order MASH 1-1-1 sigma-delta modulator |
| `sine_gen.v` | 256-entry LUT sine generator, 8 kHz output |
| `top.v` | Top-level wrapper connecting sine gen to DAC |
| `tb_sd_dac.sv` | SystemVerilog testbench, writes CSV, calls Python |
| `plot_dac.py` | Applies reconstruction filter and plots waveform |

---

## Simulation

### Requirements
```
pip install pandas numpy scipy matplotlib
```

### Icarus Verilog
```bash
iverilog -g2012 -o sim tb_sd_dac.sv sd_dac_8k.v sine_gen.v
vvp sim
```

### Questa / ModelSim
```bash
vlog -sv tb_sd_dac.sv sd_dac_8k.v sine_gen.v
vsim -c tb_sd_dac -do "run -all; quit"
```

### Vivado xsim
```bash
xvlog --sv tb_sd_dac.sv
xvlog sd_dac_8k.v sine_gen.v
xelab -debug typical tb_sd_dac -s tb_sim
xsim tb_sim -runall
```

After simulation completes, `plot_dac.py` is called automatically via `$system`.
If your simulator does not support `$system`, run it manually:
```bash
python3 plot_dac.py
```

---

## Changing the sine frequency

Edit `sine_gen.v` and change `FREQ_HZ`:

```verilog
localparam FREQ_HZ = 1000;   // change this value
```

| FREQ_HZ | PHASE_INC | Actual frequency |
|---|---|---|
| 300 | 10 | 312.5 Hz |
| 500 | 16 | 500.0 Hz |
| 1000 | 32 | 1000.0 Hz |
| 1500 | 48 | 1500.0 Hz |
| 2000 | 64 | 2000.0 Hz |
| 2500 | 80 | 2500.0 Hz |
| 3000 | 96 | 3000.0 Hz |
| 3400 | 109 | 3406.3 Hz |

Also update `F_SIGNAL` in `plot_dac.py` to match.

---

## FPGA constraints (Xilinx XDC)

```tcl
set_property PACKAGE_PIN  <your_pin>  [get_ports dout]
set_property IOSTANDARD   LVCMOS33    [get_ports dout]
set_property IOB TRUE [get_cells -hierarchical -filter {NAME =~ */dout_reg}]
create_clock -name clk -period 10.0 [get_ports clk]
```

---

## Analog filter (external)

```
FPGA dout
  |
 33 Ω  (series, reduces ground bounce)
  |
  +-- HPF: R=5.6kΩ, C=100nF  (fc = 284 Hz, -3dB)
  |
  +-- LPF stage 1: R=4.7kΩ, C=10nF + unity-gain buffer  (fc = 3.39 kHz)
  |
  +-- LPF stage 2: Sallen-Key  R1=R2=4.7kΩ, C1=C2=10nF, Rg=Rf=10kΩ (K=2, Q=1)
  |
 Vout (analogue voice signal)
```

Op-amp: MCP6002 (3.3V single supply) or TL072 (±12V dual supply).
