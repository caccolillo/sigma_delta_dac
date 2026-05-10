#!/usr/bin/env python3
"""
sinad.py — compute SINAD and ENOB from LTspice exported voltage data
"""

import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import windows

# ----------------------------------------------------------------
#  CONFIGURATION
# ----------------------------------------------------------------
DATA_FILE     = 'vout_data.txt'
F_SIG         = 1000.0      # test tone frequency (Hz)
F_BAND_LOW    = 300.0       # voice band low edge (Hz)
F_BAND_HIGH   = 3400.0      # voice band high edge (Hz)
INPUT_FS_DBFS = -6.0        # input level relative to full scale (dB)

# ----------------------------------------------------------------
#  LOAD DATA
#  LTspice CSV export: time and voltage columns separated by tab
# ----------------------------------------------------------------
print(f"Loading {DATA_FILE}...")
data = np.loadtxt(DATA_FILE, skiprows=1)
t = data[:, 0]
v = data[:, 1]

# Subtract DC midpoint so FFT shows AC content cleanly
v_ac = v - np.mean(v)

# ----------------------------------------------------------------
#  RESAMPLE TO UNIFORM GRID (LTspice exports non-uniform timesteps)
# ----------------------------------------------------------------
fs_target = 1.0e6   # 1 MHz analysis sample rate
t_uniform = np.arange(t[0], t[-1], 1.0 / fs_target)
v_uniform = np.interp(t_uniform, t, v_ac)
N = len(v_uniform)

print(f"Loaded {N} samples at {fs_target/1e6:.1f} MHz")
print(f"Duration: {t_uniform[-1]*1000:.1f} ms")

# ----------------------------------------------------------------
#  FFT WITH WINDOW
# ----------------------------------------------------------------
window = windows.blackmanharris(N)
window_gain = np.sum(window) / N    # for amplitude correction
window_pwr  = np.sum(window**2) / N # for power correction

V = np.fft.rfft(v_uniform * window)
freqs = np.fft.rfftfreq(N, 1.0/fs_target)

# Power spectral density (V²)
P = (np.abs(V)**2) / (N**2 * window_pwr)

# ----------------------------------------------------------------
#  IDENTIFY SIGNAL AND NOISE BINS
# ----------------------------------------------------------------
# Bin spacing
df = freqs[1] - freqs[0]
print(f"FFT bin width: {df:.2f} Hz")

# Signal bin: find the peak nearest to F_SIG
sig_bin_center = int(round(F_SIG / df))
# Use a small window around the peak to capture all signal energy
sig_bins = range(max(1, sig_bin_center - 5),
                 min(len(P), sig_bin_center + 6))
P_signal = np.sum(P[list(sig_bins)])

# Find the actual peak frequency (in case of small drift)
local_peak = sig_bin_center - 5 + np.argmax(P[sig_bin_center-5:sig_bin_center+6])
f_peak = freqs[local_peak]
print(f"Signal peak at: {f_peak:.2f} Hz (expected {F_SIG} Hz)")

# Noise bins: in-band, excluding the signal
noise_low_bin  = int(np.ceil(F_BAND_LOW / df))
noise_high_bin = int(np.floor(F_BAND_HIGH / df))
noise_bins = [b for b in range(noise_low_bin, noise_high_bin + 1)
              if b not in sig_bins]
P_noise_distortion = np.sum(P[noise_bins])

# ----------------------------------------------------------------
#  COMPUTE SINAD AND ENOB
# ----------------------------------------------------------------
SINAD = 10 * np.log10(P_signal / P_noise_distortion)

# ENOB at this input level
ENOB_at_input = (SINAD - 1.76) / 6.02

# ENOB equivalent at full scale
ENOB_full_scale = ENOB_at_input - INPUT_FS_DBFS / 6.02

print()
print("=" * 60)
print(f"  SINAD (in {F_BAND_LOW:.0f} Hz - {F_BAND_HIGH:.0f} Hz band):"
      f" {SINAD:.2f} dB")
print(f"  ENOB at {INPUT_FS_DBFS:.0f} dBFS input:           "
      f" {ENOB_at_input:.2f} bits")
print(f"  ENOB equivalent at full scale:    "
      f" {ENOB_full_scale:.2f} bits")
print("=" * 60)
print()

# ----------------------------------------------------------------
#  PLOT SPECTRUM
# ----------------------------------------------------------------
P_db = 10 * np.log10(P / np.max(P) + 1e-30)

fig, ax = plt.subplots(figsize=(12, 6))
ax.semilogx(freqs[1:], P_db[1:], 'b', linewidth=0.7)
ax.axvspan(F_BAND_LOW, F_BAND_HIGH, alpha=0.1, color='green',
           label=f'Voice band ({F_BAND_LOW:.0f}-{F_BAND_HIGH:.0f} Hz)')
ax.axvline(f_peak, color='r', linestyle='--',
           label=f'Signal {f_peak:.0f} Hz')
ax.set_xlabel('Frequency (Hz)')
ax.set_ylabel('Magnitude (dB, normalised)')
ax.set_title(f'Output spectrum   |   SINAD = {SINAD:.1f} dB   |   '
             f'ENOB = {ENOB_at_input:.2f} bits @ {INPUT_FS_DBFS:.0f} dBFS')
ax.set_xlim(10, fs_target/2)
ax.set_ylim(-140, 5)
ax.grid(which='both', alpha=0.4)
ax.legend()
plt.tight_layout()
plt.savefig('spectrum.png', dpi=120)
plt.show()
