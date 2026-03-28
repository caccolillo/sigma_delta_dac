# =============================================================================
# plot_dac.py  (v11 - matched to 500ms dwell, 2048-pt FFT)
# =============================================================================

import pandas as pd
import numpy as np
from scipy import signal
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import sys, os

CSV_FILE  = "pdm_output.csv"
PNG_FILE  = "dac_sweep.png"
FS_SAMP   = 8000.0
SKIP_MS   = 20.0          # skip first 20ms of each segment (filter settle)
N_FFT     = 2048          # fits within 4000 - 160 = 3840 remaining samples

R_HPF, C_HPF = 5.6e3, 100e-9
R_LPF, C_LPF = 3.9e3,  10e-9
R_SK,  C_SK  = 3.9e3,  10e-9
K_SK         = 2.0

FREQ_TABLE = [
    (0, 312.5,  "300 Hz"),
    (1, 500.0,  "500 Hz"),
    (2, 812.5,  "800 Hz"),
    (3, 1000.0, "1 kHz"),
    (4, 1500.0, "1.5 kHz"),
    (5, 2000.0, "2 kHz"),
    (6, 2500.0, "2.5 kHz"),
    (7, 3000.0, "3 kHz"),
    (8, 3406.3, "3.4 kHz"),
]

def build_filters(fs):
    tau_h = R_HPF * C_HPF
    tau_l = R_LPF * C_LPF
    w0    = 1.0 / (R_SK * C_SK)
    bh, ah  = signal.bilinear([tau_h, 0], [tau_h, 1], fs=fs)
    bl, al  = signal.bilinear([1], [tau_l, 1], fs=fs)
    bs, as_ = signal.bilinear([K_SK*w0**2], [1,(3-K_SK)*w0,w0**2], fs=fs)
    return (bh, ah), (bl, al), (bs, as_)

def apply_filters(data, filt):
    out = data.copy()
    for b, a in filt:
        out = signal.lfilter(b, a, out)
    return out

def measure_all(data, fs, f_sig, n_fft=N_FFT, n_harmonics=5):
    n    = min(n_fft, len(data))
    win  = np.hanning(n)
    spec = np.abs(np.fft.rfft(data[:n] * win)) * 2.0 / win.sum()
    pwr  = spec**2
    freq = np.fft.rfftfreq(n, d=1.0/fs)
    bw   = freq[1]

    sig_b    = int(round(f_sig / bw))
    sig_b    = np.clip(sig_b, 1, len(pwr)-1)
    sig_bins = set(range(max(1, sig_b-2), min(len(pwr), sig_b+3)))

    harm_bins = set()
    for h in range(2, n_harmonics+1):
        hb = int(round(f_sig * h / bw))
        if hb < len(pwr):
            for b in range(max(1,hb-1), min(len(pwr),hb+2)):
                harm_bins.add(b)

    vb_set    = set(np.where((freq >= 200) & (freq <= 4000))[0].tolist())
    sig_pwr   = sum(pwr[b] for b in sig_bins)
    harm_pwr  = sum(pwr[b] for b in harm_bins if b in vb_set)
    noise_pwr = sum(pwr[b] for b in vb_set if b not in sig_bins and b not in harm_bins)
    total_nd  = harm_pwr + noise_pwr

    sinad = 10*np.log10(sig_pwr / (total_nd  + 1e-30))
    snr   = 10*np.log10(sig_pwr / (noise_pwr + 1e-30))
    thd   = 10*np.log10(harm_pwr / (sig_pwr  + 1e-30))
    enob  = (sinad - 1.76) / 6.02
    db    = 20*np.log10(spec / (spec.max()+1e-12) + 1e-12)
    return sinad, snr, thd, enob, freq, db

def align_phase(sig, fs, f):
    n   = min(int(round(fs/f)), len(sig))
    seg = sig[:n] / (np.max(np.abs(sig[:n]))+1e-12)
    t   = np.arange(n)/fs
    best_phi, best = 0.0, -np.inf
    for phi in np.linspace(-np.pi, np.pi, 500):
        s = np.dot(seg, np.sin(2*np.pi*f*t+phi))
        if s > best: best, best_phi = s, phi
    return best_phi

# ── Load ──────────────────────────────────────────────────────────────────────
print("Loading CSV...")
if not os.path.exists(CSV_FILE):
    print(f"ERROR: {CSV_FILE} not found"); sys.exit(1)
df    = pd.read_csv(CSV_FILE)
t_raw = df["time_ns"].to_numpy(dtype=np.float64)
last  = t_raw[-1]
t_s   = t_raw * (1e-12 if last>1e10 else 1e-9 if last>1e7 else 1e-6)
print(f"  Rows: {len(df):,}  |  Duration: {t_s[-1]:.2f} s")
print(f"  Samples per segment (est): {len(df)//9:,}")

filters  = build_filters(FS_SAMP)
SKIP_S   = int(SKIP_MS * 1e-3 * FS_SAMP)

results = []
print(f"\n  {'Freq':>8}  {'SINAD':>7}  {'ENOB':>6}  {'SNR':>7}  {'THD':>7}  {'N':>5}")
print(f"  {'-'*8}  {'-'*7}  {'-'*6}  {'-'*7}  {'-'*7}  {'-'*5}")

for idx, f_actual, f_label in FREQ_TABLE:
    seg = df[df["freq_idx"] == idx]["din"].to_numpy(dtype=np.float64)
    needed = SKIP_S + N_FFT
    if len(seg) < needed:
        print(f"  {f_label:>8}  (skipped — {len(seg)} samples, need {needed})")
        continue

    filt_seg = apply_filters(seg, filters)[SKIP_S:]
    filt_seg = filt_seg / (np.max(np.abs(filt_seg))+1e-12)

    sinad, snr, thd, enob, freq, fft_db = measure_all(filt_seg, FS_SAMP, f_actual)
    phi = align_phase(filt_seg, FS_SAMP, f_actual)

    print(f"  {f_label:>8}  {sinad:>7.1f}  {enob:>6.2f}  {snr:>7.1f}  {thd:>7.1f}  {len(seg):>5}")
    results.append(dict(idx=idx, f=f_actual, label=f_label,
                        filtered=filt_seg, freq=freq, fft_db=fft_db,
                        sinad=sinad, snr=snr, thd=thd, enob=enob, phi=phi))

if not results:
    print("ERROR: no segments processed")
    print(f"Segment sizes: { {i: (df['freq_idx']==i).sum() for i in range(9)} }")
    sys.exit(1)

# ── Plot ──────────────────────────────────────────────────────────────────────
print("\nPlotting...")
n   = len(results)
col = plt.cm.viridis(np.linspace(0.15, 0.85, n))

fig = plt.figure(figsize=(17, 15))
fig.suptitle(
    "Sigma-Delta DAC — G.711 voice band sweep\n"
    "4th-order MASH 1-1-1-1  |  Bresenham interpolation  |  PRBS dither  |  "
    "100 MHz / 8 kHz  |  LPF fc = 4.08 kHz  (R=3.9 kΩ, C=10 nF)",
    fontsize=11, fontweight='bold', y=0.995)

gs = gridspec.GridSpec(4, 3, figure=fig, hspace=0.60, wspace=0.38)

for i, r in enumerate(results[:9]):
    row, c = divmod(i, 3)
    ax = fig.add_subplot(gs[row, c])
    n_show = min(int(5 * FS_SAMP / r["f"]), len(r["filtered"]))
    t_ms   = np.arange(n_show) / FS_SAMP * 1e3
    sig    = r["filtered"][:n_show]
    ideal  = np.sin(2*np.pi*r["f"]*np.arange(n_show)/FS_SAMP + r["phi"])
    ax.plot(t_ms, sig,   color=col[i], linewidth=1.3, zorder=3, label='Output')
    ax.plot(t_ms, ideal, color='#D85A30', linewidth=0.8,
            linestyle='--', alpha=0.65, zorder=2, label='Ideal')
    ax.set_title(
        f"{r['label']}  SINAD {r['sinad']:.0f} dB  ENOB {r['enob']:.1f} b",
        fontsize=8.5, fontweight='bold')
    ax.set_xlabel("Time (ms)", fontsize=7.5)
    ax.set_ylabel("Amplitude", fontsize=7.5)
    ax.set_ylim(-1.3, 1.3)
    ax.set_xlim(0, t_ms[-1])
    ax.tick_params(labelsize=7)
    ax.grid(True, alpha=0.3)
    ax.set_facecolor('#FAFAFA')

ax_m = fig.add_subplot(gs[3, 0:2])
f_v     = [r["f"]     for r in results]
sinad_v = [r["sinad"] for r in results]
snr_v   = [r["snr"]   for r in results]
thd_v   = [r["thd"]   for r in results]
enob_v  = [r["enob"]  for r in results]

ax_m.plot(f_v, sinad_v, color='#1D9E75', marker='o', linewidth=1.8,
          markersize=6, label='SINAD (dB)', zorder=4)
ax_m.plot(f_v, snr_v,   color='#378ADD', marker='s', linewidth=1.3,
          markersize=5, linestyle='--', label='SNR (dB)', zorder=3)
ax_m.plot(f_v, thd_v,   color='#D85A30', marker='^', linewidth=1.3,
          markersize=5, linestyle=':', label='THD (dBc)', zorder=3)
ax_m.axhline(-60, color='#534AB7', linewidth=0.8, linestyle='--',
             alpha=0.5, label='–60 dB ref')
ax_m.axvspan(300, 3400, alpha=0.06, color='#1D9E75')
for f, s in zip(f_v, sinad_v):
    ax_m.annotate(f'{s:.0f}', (f, s),
                  textcoords="offset points", xytext=(0,7),
                  fontsize=7.5, ha='center', color='#1D9E75', fontweight='bold')
ax_m.set_title("SINAD, SNR and THD vs frequency", fontweight='bold')
ax_m.set_xlabel("Frequency (Hz)")
ax_m.set_ylabel("dB")
ax_m.set_xscale('log')
ax_m.set_xlim(250, 4500)
ax_m.legend(fontsize=8.5, loc='lower left')
ax_m.grid(True, alpha=0.3, which='both')
ax_m.set_facecolor('#FAFAFA')

ax_e = fig.add_subplot(gs[3, 2])
ax_e.plot(f_v, enob_v, color='#534AB7', marker='D', linewidth=1.8,
          markersize=6, zorder=4)
ax_e.axhline(13, color='#E24B4A', linewidth=1, linestyle='--', label='13-bit target')
ax_e.axvspan(300, 3400, alpha=0.06, color='#1D9E75')
for f, e in zip(f_v, enob_v):
    ax_e.annotate(f'{e:.1f}', (f, e),
                  textcoords="offset points", xytext=(0,7),
                  fontsize=7.5, ha='center', color='#534AB7', fontweight='bold')
ax_e.set_title("ENOB vs frequency", fontweight='bold')
ax_e.set_xlabel("Frequency (Hz)")
ax_e.set_ylabel("Effective bits")
ax_e.set_xscale('log')
ax_e.set_xlim(250, 4500)
ax_e.legend(fontsize=8.5)
ax_e.grid(True, alpha=0.3, which='both')
ax_e.set_facecolor('#FAFAFA')

plt.savefig(PNG_FILE, dpi=150, bbox_inches='tight')
print(f"Plot saved to {PNG_FILE}")
plt.show()

print("\n── Filter component change ───────────────────────────")
for label, r in [("Old (4.7 kOhm)", 4.7e3), ("New (3.6 kOhm)", 3.6e3)]:
    fc_val = 1/(2*np.pi*r*10e-9)
    a34 = 20*np.log10(1/np.sqrt(1+(3400/fc_val)**2))
    a8k = 20*np.log10(1/np.sqrt(1+(8000/fc_val)**2))
    print(f"  {label}  fc={fc_val:.0f} Hz  @3.4kHz={a34:.1f} dB  @8kHz={a8k:.1f} dB")
print("──────────────────────────────────────────────────────")
print("\n── Voice band SINAD summary ──────────────────────────")
print(f"  {'Freq':>8}  {'SINAD':>7}  {'ENOB':>6}  {'SNR':>7}  {'THD':>8}")
print(f"  {'-'*8}  {'-'*7}  {'-'*6}  {'-'*7}  {'-'*8}")
for r in results:
    print(f"  {r['label']:>8}  {r['sinad']:>6.1f} dB"
          f"  {r['enob']:>5.2f} b"
          f"  {r['snr']:>6.1f} dB"
          f"  {r['thd']:>7.1f} dBc")
if results:
    print(f"\n  Worst-case SINAD : {min(r['sinad'] for r in results):.1f} dB")
    print(f"  Worst-case ENOB  : {min(r['enob']  for r in results):.2f} bits")
print("──────────────────────────────────────────────────────")
