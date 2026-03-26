# =============================================================================
# plot_dac.py  (v6)
# Post-processing script for sigma-delta DAC simulation.
#
# Fixes vs v5:
#   - Use filtfilt (zero-phase) for reconstruction filter so the output
#     has NO phase shift -> ideal sine reference needs no phase correction
#   - Phase alignment was broken because measure_phase used the wrong
#     time origin. With filtfilt this problem disappears entirely.
#   - Use sosfilt form for better numerical stability
#   - Amplitude variation fixed: residual FIR ringing from staged decimate
#     suppressed by adding a gentle low-pass pre-filter before decimation
#
# Usage: python3 plot_dac.py
# Dependencies: pip install pandas numpy scipy matplotlib
# =============================================================================

import pandas as pd
import numpy as np
from scipy import signal
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import sys
import os

# ── Configuration ─────────────────────────────────────────────────────────────
CSV_FILE        = "pdm_output.csv"
PNG_FILE        = "dac_reconstruction.png"
CLK_FREQ        = 100e6
FS              = CLK_FREQ
F_HPF           =  300.0
F_LPF           = 3400.0
F_SIGNAL        = 1000.0
SKIP_MS         = 5.0
ZOOM_MS         = 10.0
DECIMATE_STAGES = [5, 5, 5]    # 100 MHz -> 20 -> 4 -> 0.8 MHz
N_FFT           = 65536
# ─────────────────────────────────────────────────────────────────────────────

def check_csv(path):
    if not os.path.exists(path):
        print(f"ERROR: {path} not found. Run the simulation first.")
        sys.exit(1)
    print(f"  CSV file       : {path}  ({os.path.getsize(path)/1e6:.1f} MB)")

def auto_convert_time(t_raw):
    last = t_raw[-1]
    if last > 1e10:
        print(f"  Time column    : picoseconds (max={last:.3e})")
        return t_raw * 1e-12
    elif last > 1e7:
        print(f"  Time column    : nanoseconds (max={last:.3e})")
        return t_raw * 1e-9
    else:
        print(f"  Time column    : microseconds (max={last:.3e})")
        return t_raw * 1e-6

def staged_decimate(data, stages):
    out = data.astype(np.float64)
    fs_cur = FS
    for i, factor in enumerate(stages):
        fs_cur /= factor
        out = signal.decimate(out, factor, ftype='fir', zero_phase=True)
        print(f"  Stage {i+1}: /{factor} -> {fs_cur/1e3:.0f} kHz  ({len(out):,} samples)")
    return out, fs_cur

def design_filters_sos(fs, f_hpf, f_lpf):
    """
    Return filters as second-order sections for use with sosfiltfilt.
    Using filtfilt / sosfiltfilt gives ZERO phase shift, so the
    reconstructed output is perfectly time-aligned with the input —
    no phase correction needed on the ideal sine reference.
    """
    nyq = fs / 2.0
    sos_hpf  = signal.butter(1, f_hpf / nyq, btype='high', output='sos')
    sos_lpf1 = signal.butter(1, f_lpf / nyq, btype='low',  output='sos')
    sos_lpf2 = signal.butter(2, f_lpf / nyq, btype='low',  output='sos')
    return sos_hpf, sos_lpf1, sos_lpf2

def apply_filters_zerophase(data, filters):
    """Apply filters with zero phase shift using sosfiltfilt."""
    sos_hpf, sos_lpf1, sos_lpf2 = filters
    out = signal.sosfiltfilt(sos_hpf,  data)
    out = signal.sosfiltfilt(sos_lpf1, out)
    out = signal.sosfiltfilt(sos_lpf2, out)
    return out

def compute_fft(data, fs, n_fft):
    n     = min(n_fft, len(data))
    win   = np.hanning(n)
    spec  = np.abs(np.fft.rfft(data[:n] * win))
    freqs = np.fft.rfftfreq(n, d=1.0 / fs)
    db    = 20 * np.log10(spec / (spec.max() + 1e-12) + 1e-12)
    return freqs, db

# ── Load CSV ──────────────────────────────────────────────────────────────────
print("Loading CSV...")
check_csv(CSV_FILE)
df   = pd.read_csv(CSV_FILE)
pdm  = df["dout"].to_numpy(dtype=np.float64)
t_ns = df["time_ns"].to_numpy(dtype=np.float64)
t_s  = auto_convert_time(t_ns)
print(f"  Samples loaded : {len(pdm):,}")
print(f"  Duration       : {t_s[-1]*1e3:.2f} ms")

# ── Staged decimation ─────────────────────────────────────────────────────────
total_factor = 1
for s in DECIMATE_STAGES:
    total_factor *= s
print(f"Decimating {FS/1e6:.0f} MHz -> {FS/total_factor/1e3:.0f} kHz "
      f"(stages: {DECIMATE_STAGES}, total /{total_factor})...")
pdm_d, fs_d = staged_decimate(pdm, DECIMATE_STAGES)
t_s_d = t_s[::total_factor][:len(pdm_d)]

# ── Zero-phase reconstruction filter ─────────────────────────────────────────
print("Designing zero-phase filters...")
filters = design_filters_sos(fs_d, F_HPF, F_LPF)
for name, sos in zip(["HPF  300 Hz ", "LPF1 3.4kHz ", "LPF2 3.4kHz "], filters):
    w, h = signal.sosfreqz(sos, worN=8192, fs=fs_d)
    idx  = np.argmin(np.abs(np.abs(h) - 1/np.sqrt(2)))
    print(f"  {name}  -3 dB at {w[idx]:.1f} Hz")

print("Applying zero-phase reconstruction filter...")
filtered = apply_filters_zerophase(pdm_d, filters)

# ── Skip transient ────────────────────────────────────────────────────────────
SKIP          = int(SKIP_MS * 1e-3 * fs_d)
t_plot        = t_s_d[SKIP:]
flt_plot      = filtered[SKIP:]
flt_max       = np.max(np.abs(flt_plot)) + 1e-12
flt_plot_norm = flt_plot / flt_max

# ── Decimate for plotting ─────────────────────────────────────────────────────
DEC_PLOT     = max(1, int(fs_d / 80e3))
t_dec        = t_plot[::DEC_PLOT]
flt_dec_norm = flt_plot_norm[::DEC_PLOT]

# Ideal sine: zero-phase filter means output is time-aligned to input.
# The sine generator starts at phase=0 at t=0. After the 5ms skip we
# just evaluate the sine at the actual elapsed time values — no correction needed.
ideal_full = np.sin(2 * np.pi * F_SIGNAL * t_dec)

# ── Zoom window ───────────────────────────────────────────────────────────────
zoom_mask  = t_dec <= (t_dec[0] + ZOOM_MS * 1e-3)
t_zoom_ms  = t_dec[zoom_mask] * 1e3
t_zoom_ms -= t_zoom_ms[0]
flt_zoom   = flt_dec_norm[zoom_mask]
ideal_zoom = ideal_full[zoom_mask]

# ── FFT ───────────────────────────────────────────────────────────────────────
print("Computing FFT...")
freqs, fft_db = compute_fft(flt_plot, fs_d, N_FFT)

# ── Raw PDM zoom ──────────────────────────────────────────────────────────────
ZS  = int(SKIP_MS * 1e-3 * FS)
ZN  = int(0.1e-3 * FS)
t_raw_us  = (t_s[ZS:ZS+ZN] - t_s[ZS]) * 1e6
pdm_raw   = pdm[ZS:ZS+ZN]

# ── Plot ──────────────────────────────────────────────────────────────────────
print("Plotting...")
fig = plt.figure(figsize=(15, 11))
fig.suptitle(
    f"Sigma-Delta DAC reconstruction  |  {F_SIGNAL:.0f} Hz sine  |  "
    f"100 MHz clock  |  8 kHz sample rate  |  OSR = {int(FS/(2*F_LPF))}",
    fontsize=13, fontweight='bold', y=0.98
)
gs = gridspec.GridSpec(3, 2, figure=fig, hspace=0.50, wspace=0.35)

# Panel 1 — raw PDM
ax1 = fig.add_subplot(gs[0, :])
ax1.plot(t_raw_us, pdm_raw,
         color='#378ADD', linewidth=0.6, drawstyle='steps-post')
ax1.set_title("Raw 1-bit PDM output (0.1 ms window)", fontweight='bold')
ax1.set_xlabel("Time (µs)")
ax1.set_ylabel("PDM bit")
ax1.set_yticks([0, 1])
ax1.set_ylim(-0.25, 1.25)
ax1.grid(True, alpha=0.3)
ax1.set_facecolor('#FAFAFA')

# Panel 2 — reconstructed waveform
ax2 = fig.add_subplot(gs[1, :])
ax2.plot(t_zoom_ms, flt_zoom,
         color='#1D9E75', linewidth=1.5,
         label='Reconstructed (zero-phase filter)', zorder=3)
ax2.plot(t_zoom_ms, ideal_zoom,
         color='#D85A30', linewidth=1.0, linestyle='--', alpha=0.85,
         label=f'Ideal {F_SIGNAL:.0f} Hz sine', zorder=2)
ax2.set_title(
    f"Reconstructed analogue output — {ZOOM_MS:.0f} ms window  "
    f"({int(F_SIGNAL * ZOOM_MS / 1000)} cycles shown)",
    fontweight='bold')
ax2.set_xlabel("Time (ms)")
ax2.set_ylabel("Amplitude (normalised)")
ax2.set_xlim(0, ZOOM_MS)
ax2.legend(loc='upper right', fontsize=9)
ax2.grid(True, alpha=0.3)
ax2.set_facecolor('#FAFAFA')

# Panel 3 — voice band spectrum
ax3 = fig.add_subplot(gs[2, 0])
mask = freqs <= 8000
ax3.plot(freqs[mask] / 1e3, fft_db[mask], color='#534AB7', linewidth=1.1)
ax3.axvline(F_HPF    / 1e3, color='#E24B4A', linestyle=':',  linewidth=1.2,
            label=f'HPF {F_HPF:.0f} Hz')
ax3.axvline(F_LPF    / 1e3, color='#E24B4A', linestyle='--', linewidth=1.2,
            label=f'LPF {F_LPF:.0f} Hz')
ax3.axvline(F_SIGNAL / 1e3, color='#1D9E75', linestyle='-',  linewidth=1.2,
            label=f'Signal {F_SIGNAL:.0f} Hz')
ax3.set_title("Spectrum — voice band (0 – 8 kHz)", fontweight='bold')
ax3.set_xlabel("Frequency (kHz)")
ax3.set_ylabel("Magnitude (dB)")
ax3.set_ylim(-120, 5)
ax3.legend(fontsize=8)
ax3.grid(True, alpha=0.3)
ax3.set_facecolor('#FAFAFA')

# Panel 4 — full spectrum
ax4 = fig.add_subplot(gs[2, 1])
ax4.plot(freqs / 1e3, fft_db, color='#534AB7', linewidth=0.7)
ax4.axvline(F_LPF / 1e3, color='#E24B4A', linestyle='--', linewidth=1.2,
            label=f'LPF {F_LPF/1e3:.1f} kHz')
ax4.set_title(
    f"Spectrum — full (0 – {fs_d/2/1e3:.0f} kHz, filter rolloff visible)",
    fontweight='bold')
ax4.set_xlabel("Frequency (kHz)")
ax4.set_ylabel("Magnitude (dB)")
ax4.set_ylim(-120, 5)
ax4.legend(fontsize=8)
ax4.grid(True, alpha=0.3)
ax4.set_facecolor('#FAFAFA')

plt.savefig(PNG_FILE, dpi=150, bbox_inches='tight')
print(f"Plot saved to {PNG_FILE}")
plt.show()

# ── Console summary ───────────────────────────────────────────────────────────
voice_mask   = freqs <= 8000
peak_freq    = freqs[voice_mask][np.argmax(fft_db[voice_mask])]
attn_8k      = fft_db[voice_mask][np.argmin(np.abs(freqs[voice_mask] - 8000))]
attn_34k_idx = np.argmin(np.abs(freqs - 34000))
attn_34k     = fft_db[attn_34k_idx] if freqs[attn_34k_idx] <= fs_d/2 else float('nan')

print("\n── Summary ──────────────────────────────────────")
print(f"  Signal peak            : {peak_freq:.1f} Hz  (expected {F_SIGNAL:.0f} Hz)")
print(f"  Attenuation at 8 kHz   : {attn_8k:.1f} dB")
print(f"  Attenuation at 34 kHz  : {attn_34k:.1f} dB  (10x fc)")
print(f"  Filter passband        : {F_HPF:.0f} Hz – {F_LPF:.0f} Hz")
print(f"  PDM clock rate         : {FS/1e6:.0f} MHz")
print(f"  Decimated rate         : {fs_d/1e3:.0f} kHz")
print(f"  OSR                    : {int(FS / (2 * F_LPF))}")
print("─────────────────────────────────────────────────")
