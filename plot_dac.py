# =============================================================================
# plot_dac.py  (v8 - hardware matched)
# Post-processing script for sigma-delta DAC simulation.
#
# Models the EXACT analogue reconstruction filter on the board:
#
#   Signal chain:
#     FPGA dout
#       -> 33 ohm series resistor  (modelled as wire, negligible at audio)
#       -> HPF: R=5.6kohm, C=100nF, unity-gain op-amp buffer  (fc=284 Hz)
#       -> LPF stage 1: R=4.7kohm, C=10nF, unity-gain buffer  (fc=3386 Hz)
#       -> LPF stage 2: Sallen-Key, R1=R2=4.7kohm, C1=C2=10nF,
#                       Rg=Rf=10kohm (gain K=2, Q=1)           (fc=3386 Hz)
#       -> Vout
#
#   All three stages are modelled as bilinear-transform IIR filters derived
#   from the exact component values, NOT from a generic Butterworth prototype.
#   This means the simulation reflects what you will actually measure on the
#   board with those specific E24 resistor and C0G capacitor values.
#
#   The phase shift shown in the plot is REAL — it is what the op-amp filter
#   will impose on the signal. For a voice band DAC this is perfectly normal
#   and acceptable. The FFT panel is the primary quality indicator: a clean
#   single spike at the signal frequency with >60dB rejection at 10x fc.
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
F_SIGNAL        = 1000.0       # Hz — match FREQ_HZ in sine_gen.v
SKIP_MS         = 5.0          # discard modulator startup transient
ZOOM_MS         = 10.0         # waveform panel window length
DECIMATE_STAGES = [5, 5, 5]    # 100MHz->20MHz->4MHz->800kHz (avoids FIR ringing)
N_FFT           = 65536

# ── Exact board component values ──────────────────────────────────────────────
# HPF stage
R_HPF   = 5.6e3                # 5.6 kohm (E24)
C_HPF   = 100e-9               # 100 nF   (C0G)
FC_HPF  = 1 / (2 * np.pi * R_HPF * C_HPF)   # 284.2 Hz

# LPF stage 1 (1st order RC + unity gain buffer)
R_LPF1  = 4.7e3                # 4.7 kohm (E24)
C_LPF1  = 10e-9                # 10 nF    (C0G)
FC_LPF1 = 1 / (2 * np.pi * R_LPF1 * C_LPF1) # 3386 Hz

# LPF stage 2 (Sallen-Key, equal R equal C, K=2 -> Q=1)
R_SK    = 4.7e3                # R1 = R2
C_SK    = 10e-9                # C1 = C2
K_SK    = 2.0                  # gain = 1 + Rf/Rg = 1 + 10k/10k
# For equal-R equal-C Sallen-Key:
#   omega0 = 1/(R*C),  Q = 1/(3-K)
OMEGA0_SK = 1 / (R_SK * C_SK)
Q_SK      = 1 / (3 - K_SK)    # = 1.0 for K=2
FC_SK     = OMEGA0_SK / (2 * np.pi)  # 3386 Hz
# ─────────────────────────────────────────────────────────────────────────────

def check_csv(path):
    if not os.path.exists(path):
        print(f"ERROR: {path} not found.")
        sys.exit(1)
    print(f"  CSV file       : {path}  ({os.path.getsize(path)/1e6:.1f} MB)")

def auto_convert_time(t_raw):
    last = t_raw[-1]
    if last > 1e10:
        print(f"  Time column    : picoseconds -> seconds")
        return t_raw * 1e-12
    elif last > 1e7:
        print(f"  Time column    : nanoseconds -> seconds")
        return t_raw * 1e-9
    else:
        print(f"  Time column    : microseconds -> seconds")
        return t_raw * 1e-6

def staged_decimate(data, stages):
    out = data.copy()
    fs_cur = FS
    for i, factor in enumerate(stages):
        fs_cur /= factor
        out = signal.decimate(out, factor, ftype='fir', zero_phase=True)
        print(f"  Stage {i+1}: /{factor} -> {fs_cur/1e3:.0f} kHz  "
              f"({len(out):,} samples)")
    return out, fs_cur

def build_hardware_filters(fs_d):
    """
    Build bilinear-transform IIR filters from exact component values.
    Each stage is derived independently so you can swap components and
    immediately see the effect on the simulated frequency response.
    """
    # ── HPF: 1st order RC ─────────────────────────────────────────────────────
    # Analogue prototype: H(s) = s*tau / (1 + s*tau),  tau = R*C
    tau_hpf = R_HPF * C_HPF
    # Bilinear transform: s = 2*fs*(z-1)/(z+1)
    b_hpf, a_hpf = signal.bilinear(
        [tau_hpf, 0],           # numerator:   tau*s
        [tau_hpf, 1],           # denominator: tau*s + 1
        fs=fs_d
    )

    # ── LPF stage 1: 1st order RC ─────────────────────────────────────────────
    # Analogue prototype: H(s) = 1 / (1 + s*tau)
    tau_lpf1 = R_LPF1 * C_LPF1
    b_lpf1, a_lpf1 = signal.bilinear(
        [1],
        [tau_lpf1, 1],
        fs=fs_d
    )

    # ── LPF stage 2: Sallen-Key 2nd order ────────────────────────────────────
    # Analogue prototype for equal-R equal-C Sallen-Key with gain K:
    # H(s) = K*omega0^2 / (s^2 + (3-K)*omega0*s + omega0^2)
    # With K=2, Q=1: H(s) = 2*omega0^2 / (s^2 + omega0*s + omega0^2)
    w0 = OMEGA0_SK
    b_sk, a_sk = signal.bilinear(
        [K_SK * w0**2],                  # numerator
        [1, (3 - K_SK) * w0, w0**2],     # denominator: s^2 + (3-K)*w0*s + w0^2
        fs=fs_d
    )

    return (b_hpf, a_hpf), (b_lpf1, a_lpf1), (b_sk, a_sk)

def apply_hardware_filters(data, filters):
    hpf, lpf1, sk = filters
    out = signal.lfilter(*hpf,  data)
    out = signal.lfilter(*lpf1, out)
    out = signal.lfilter(*sk,   out)
    return out

def filter_frequency_response(filters, fs_d, n_points=4096):
    """Combined frequency response of the full analogue filter chain."""
    freqs = np.fft.rfftfreq(n_points * 2, d=1.0 / fs_d)[:n_points]
    H_combined = np.ones(n_points, dtype=complex)
    for b, a in filters:
        _, H = signal.freqz(b, a, worN=freqs, fs=fs_d)
        H_combined *= H
    db = 20 * np.log10(np.abs(H_combined) + 1e-12)
    db -= db[:10].mean()   # normalise to passband
    phase_deg = np.degrees(np.unwrap(np.angle(H_combined)))
    return freqs, db, phase_deg

def compute_fft(data, fs, n_fft):
    n     = min(n_fft, len(data))
    win   = np.hanning(n)
    spec  = np.abs(np.fft.rfft(data[:n] * win))
    freqs = np.fft.rfftfreq(n, d=1.0 / fs)
    db    = 20 * np.log10(spec / (spec.max() + 1e-12) + 1e-12)
    return freqs, db

def find_phase_offset(reconstructed, t, f_signal, fs_d):
    """Brute-force phase search over one period."""
    period_samples = int(round(fs_d / f_signal))
    seg  = reconstructed[:period_samples]
    seg  = seg / (np.max(np.abs(seg)) + 1e-12)
    t_seg = np.arange(period_samples) / fs_d
    best_phi, best_score = 0.0, -np.inf
    for phi in np.linspace(-np.pi, np.pi, 2000):
        score = np.dot(seg, np.sin(2 * np.pi * f_signal * t_seg + phi))
        if score > best_score:
            best_score, best_phi = score, phi
    return best_phi

# ── Load CSV ──────────────────────────────────────────────────────────────────
print("Loading CSV...")
check_csv(CSV_FILE)
df   = pd.read_csv(CSV_FILE)
pdm  = df["dout"].to_numpy(dtype=np.float64)
t_ns = df["time_ns"].to_numpy(dtype=np.float64)
t_s  = auto_convert_time(t_ns)
print(f"  Samples loaded : {len(pdm):,}  |  Duration: {t_s[-1]*1e3:.2f} ms")

# ── Staged decimation ─────────────────────────────────────────────────────────
total_factor = 1
for s in DECIMATE_STAGES:
    total_factor *= s
print(f"\nDecimating {FS/1e6:.0f} MHz -> {FS/total_factor/1e3:.0f} kHz ...")
pdm_d, fs_d = staged_decimate(pdm, DECIMATE_STAGES)
t_s_d = t_s[::total_factor][:len(pdm_d)]

# ── Build and apply hardware-matched filters ──────────────────────────────────
print(f"\nBuilding hardware-matched filters at {fs_d/1e3:.0f} kHz ...")
print(f"  HPF  fc = {FC_HPF:.1f} Hz  (R={R_HPF/1e3:.1f}k, C={C_HPF*1e9:.0f}nF)")
print(f"  LPF1 fc = {FC_LPF1:.1f} Hz  (R={R_LPF1/1e3:.1f}k, C={C_LPF1*1e9:.0f}nF)")
print(f"  SK   fc = {FC_SK:.1f} Hz  (R={R_SK/1e3:.1f}k, C={C_SK*1e9:.0f}nF, "
      f"K={K_SK:.0f}, Q={Q_SK:.2f})")

filters = build_hardware_filters(fs_d)
print("Applying filters...")
filtered = apply_hardware_filters(pdm_d, filters)

# ── Skip transient ────────────────────────────────────────────────────────────
SKIP          = int(SKIP_MS * 1e-3 * fs_d)
flt_plot      = filtered[SKIP:]
t_plot        = t_s_d[SKIP:]
flt_max       = np.max(np.abs(flt_plot)) + 1e-12
flt_plot_norm = flt_plot / flt_max

# ── Display decimation ────────────────────────────────────────────────────────
DEC_PLOT     = max(1, int(fs_d / 80e3))
t_dec        = t_plot[::DEC_PLOT]
flt_dec_norm = flt_plot_norm[::DEC_PLOT]
fs_disp      = fs_d / DEC_PLOT

# ── Phase alignment ───────────────────────────────────────────────────────────
print("\nFinding phase offset...")
best_phi = find_phase_offset(flt_dec_norm, t_dec, F_SIGNAL, fs_disp)
print(f"  Phase offset   : {np.degrees(best_phi):.1f} deg at {F_SIGNAL:.0f} Hz")
print(f"  (This is the real phase shift introduced by the op-amp filter)")
ideal_full = np.sin(2 * np.pi * F_SIGNAL * (t_dec - t_dec[0]) + best_phi)

# ── Zoom window ───────────────────────────────────────────────────────────────
zoom_mask  = t_dec <= (t_dec[0] + ZOOM_MS * 1e-3)
t_zoom_ms  = (t_dec[zoom_mask] - t_dec[0]) * 1e3
flt_zoom   = flt_dec_norm[zoom_mask]
ideal_zoom = ideal_full[zoom_mask]

# ── FFT ───────────────────────────────────────────────────────────────────────
print("Computing FFT...")
sig_freqs, sig_fft_db = compute_fft(flt_plot, fs_d, N_FFT)

# ── Filter frequency and phase response ──────────────────────────────────────
fr_freqs, fr_db, fr_phase = filter_frequency_response(filters, fs_d)

# ── Raw PDM zoom ──────────────────────────────────────────────────────────────
Z0 = int(SKIP_MS * 1e-3 * FS)
ZN = int(0.1e-3 * FS)
t_raw_zoom    = t_s[Z0 : Z0 + ZN]
pdm_raw_zoom  = pdm[Z0 : Z0 + ZN]
t_raw_zoom_us = (t_raw_zoom - t_raw_zoom[0]) * 1e6

# ── Measure key filter attenuation points ─────────────────────────────────────
def attn_at(f, freqs, db):
    return db[np.argmin(np.abs(freqs - f))]

a_8k   = attn_at(8000,  fr_freqs, fr_db)
a_34k  = attn_at(34000, fr_freqs, fr_db)
a_3k4  = attn_at(3400,  fr_freqs, fr_db)
a_300  = attn_at(300,   fr_freqs, fr_db)
ph_1k  = fr_phase[np.argmin(np.abs(fr_freqs - F_SIGNAL))]

# ── Plot ──────────────────────────────────────────────────────────────────────
print("Plotting...")
fig = plt.figure(figsize=(15, 14))
fig.suptitle(
    f"Sigma-Delta DAC — hardware-matched analogue filter model\n"
    f"HPF {FC_HPF:.0f} Hz + LPF {FC_LPF1:.0f} Hz (3rd order Butterworth Sallen-Key)  |  "
    f"{F_SIGNAL:.0f} Hz sine  |  100 MHz / 8 kHz",
    fontsize=12, fontweight='bold', y=0.99
)
gs = gridspec.GridSpec(4, 2, figure=fig, hspace=0.58, wspace=0.35)

# Panel 1: Raw PDM
ax1 = fig.add_subplot(gs[0, :])
ax1.plot(t_raw_zoom_us, pdm_raw_zoom,
         color='#378ADD', linewidth=0.6, drawstyle='steps-post')
ax1.set_title("Raw 1-bit PDM output (0.1 ms window)", fontweight='bold')
ax1.set_xlabel("Time (µs)")
ax1.set_ylabel("PDM bit")
ax1.set_yticks([0, 1])
ax1.set_ylim(-0.25, 1.25)
ax1.grid(True, alpha=0.3)
ax1.set_facecolor('#FAFAFA')

# Panel 2: Reconstructed waveform
ax2 = fig.add_subplot(gs[1, :])
ax2.plot(t_zoom_ms, flt_zoom,
         color='#1D9E75', linewidth=1.5, label='Reconstructed output', zorder=3)
ax2.plot(t_zoom_ms, ideal_zoom,
         color='#D85A30', linewidth=1.0, linestyle='--', alpha=0.85,
         label=f'Ideal {F_SIGNAL:.0f} Hz (phase-aligned to output)', zorder=2)
ax2.set_title(
    f"Reconstructed output — {ZOOM_MS:.0f} ms / "
    f"{int(F_SIGNAL * ZOOM_MS / 1000)} cycles  |  "
    f"filter phase = {ph_1k:.1f}° at {F_SIGNAL:.0f} Hz  "
    f"(real hardware phase shift)",
    fontweight='bold')
ax2.set_xlabel("Time (ms)")
ax2.set_ylabel("Amplitude (normalised)")
ax2.set_xlim(0, ZOOM_MS)
ax2.legend(loc='upper right', fontsize=9)
ax2.grid(True, alpha=0.3)
ax2.set_facecolor('#FAFAFA')

# Panel 3a: Filter magnitude response
ax3 = fig.add_subplot(gs[2, 0])
ax3.plot(fr_freqs / 1e3, fr_db, color='#534AB7', linewidth=1.3)
ax3.axvline(300  / 1e3, color='#E24B4A', linestyle=':', linewidth=1,
            label=f'HPF {FC_HPF:.0f} Hz ({a_300:.1f} dB)')
ax3.axvline(3400 / 1e3, color='#E24B4A', linestyle='--', linewidth=1,
            label=f'LPF {FC_LPF1:.0f} Hz ({a_3k4:.1f} dB)')
ax3.axvline(8000 / 1e3, color='#BA7517', linestyle='--', linewidth=1,
            label=f'8 kHz ({a_8k:.1f} dB)')
# Mark component-accurate -3dB points
for fc, label in [(FC_HPF, 'HPF -3dB'), (FC_LPF1, 'LPF -3dB')]:
    ax3.axhline(-3, color='gray', linestyle=':', linewidth=0.8)
ax3.set_title("Filter magnitude response (from component values)",
              fontweight='bold')
ax3.set_xlabel("Frequency (kHz)")
ax3.set_ylabel("Magnitude (dB)")
ax3.set_xlim(0, 20)
ax3.set_ylim(-100, 5)
ax3.legend(fontsize=8)
ax3.grid(True, alpha=0.3)
ax3.set_facecolor('#FAFAFA')

# Panel 3b: Filter phase response
ax4 = fig.add_subplot(gs[2, 1])
mask_ph = fr_freqs <= 8000
ax4.plot(fr_freqs[mask_ph] / 1e3, fr_phase[mask_ph],
         color='#D85A30', linewidth=1.3)
ax4.axvline(F_SIGNAL / 1e3, color='#1D9E75', linestyle='-', linewidth=1,
            label=f'{F_SIGNAL:.0f} Hz: {ph_1k:.1f}°')
ax4.axvline(300  / 1e3, color='#E24B4A', linestyle=':', linewidth=1,
            label='HPF 300 Hz')
ax4.axvline(3400 / 1e3, color='#E24B4A', linestyle='--', linewidth=1,
            label='LPF 3.4 kHz')
ax4.set_title("Filter phase response (IIR — non-linear, real hardware)",
              fontweight='bold')
ax4.set_xlabel("Frequency (kHz)")
ax4.set_ylabel("Phase (degrees)")
ax4.set_xlim(0, 8)
ax4.legend(fontsize=8)
ax4.grid(True, alpha=0.3)
ax4.set_facecolor('#FAFAFA')

# Panel 4a: Output spectrum — voice band
ax5 = fig.add_subplot(gs[3, 0])
mask_vb = sig_freqs <= 8000
ax5.plot(sig_freqs[mask_vb] / 1e3, sig_fft_db[mask_vb],
         color='#534AB7', linewidth=1.1)
ax5.axvline(300      / 1e3, color='#E24B4A', linestyle=':',  linewidth=1.2,
            label=f'HPF {FC_HPF:.0f} Hz')
ax5.axvline(3400     / 1e3, color='#E24B4A', linestyle='--', linewidth=1.2,
            label=f'LPF {FC_LPF1:.0f} Hz')
ax5.axvline(F_SIGNAL / 1e3, color='#1D9E75', linestyle='-',  linewidth=1.2,
            label=f'Signal {F_SIGNAL:.0f} Hz')
ax5.set_title("Output spectrum — voice band (0 – 8 kHz)", fontweight='bold')
ax5.set_xlabel("Frequency (kHz)")
ax5.set_ylabel("Magnitude (dB)")
ax5.set_ylim(-120, 5)
ax5.legend(fontsize=8)
ax5.grid(True, alpha=0.3)
ax5.set_facecolor('#FAFAFA')

# Panel 4b: Output spectrum — full
ax6 = fig.add_subplot(gs[3, 1])
ax6.plot(sig_freqs / 1e3, sig_fft_db, color='#534AB7', linewidth=0.7)
ax6.axvline(3400 / 1e3, color='#E24B4A', linestyle='--', linewidth=1.2,
            label=f'LPF {FC_LPF1:.0f} Hz')
ax6.set_title(f"Output spectrum — full (0 – {fs_d/2/1e3:.0f} kHz)",
              fontweight='bold')
ax6.set_xlabel("Frequency (kHz)")
ax6.set_ylabel("Magnitude (dB)")
ax6.set_ylim(-120, 5)
ax6.legend(fontsize=8)
ax6.grid(True, alpha=0.3)
ax6.set_facecolor('#FAFAFA')

plt.savefig(PNG_FILE, dpi=150, bbox_inches='tight')
print(f"\nPlot saved to {PNG_FILE}")
plt.show()

# ── Console summary ───────────────────────────────────────────────────────────
voice_mask = sig_freqs <= 8000
peak_freq  = sig_freqs[voice_mask][np.argmax(sig_fft_db[voice_mask])]

print("\n── Hardware filter summary ───────────────────────")
print(f"  HPF  R={R_HPF/1e3:.1f}k C={C_HPF*1e9:.0f}nF  fc={FC_HPF:.1f} Hz")
print(f"  LPF1 R={R_LPF1/1e3:.1f}k C={C_LPF1*1e9:.0f}nF  fc={FC_LPF1:.1f} Hz")
print(f"  SK   R={R_SK/1e3:.1f}k C={C_SK*1e9:.0f}nF  fc={FC_SK:.1f} Hz  "
      f"K={K_SK:.0f}  Q={Q_SK:.2f}")
print(f"\n── Signal quality ────────────────────────────────")
print(f"  Signal peak            : {peak_freq:.1f} Hz  (expected {F_SIGNAL:.0f} Hz)")
print(f"  Phase at {F_SIGNAL:.0f} Hz     : {ph_1k:.1f} deg  (real hardware phase)")
print(f"  Filter at 300 Hz       : {a_300:.1f} dB")
print(f"  Filter at 3.4 kHz      : {a_3k4:.1f} dB")
print(f"  Filter at 8 kHz        : {a_8k:.1f} dB")
print(f"  Filter at 34 kHz       : {a_34k:.1f} dB  (10x fc)")
print(f"  PDM clock              : {FS/1e6:.0f} MHz")
print(f"  OSR                    : {int(FS / (2 * 3400))}")
print("─────────────────────────────────────────────────")
