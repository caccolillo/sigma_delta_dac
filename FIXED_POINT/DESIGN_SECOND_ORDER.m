%% 2nd-Order Sigma-Delta Design, Verification and Fixed-Point Word Length Selection
%% Word length determined automatically using Delta-Sigma Toolbox functions
%% Requires: Delta-Sigma Toolbox
%% MATLAB R2021b compatible

clear; clc;

%% ---------------------------------------------------------------
%  PART 1: DESIGN
% ---------------------------------------------------------------
order = 2;
osr   = 625;    % 5MHz / 8kHz
nlev  = 2;      % 1-bit quantizer
form  = 'CIFB';
input_bits   = 13;                          % signed 13-bit input
input_scale  = 2^(input_bits-1);           % = 4096
input_shift  = input_bits - 1;             % = 12 (arithmetic right shift)
A_input_norm = 0.5;                        % normalised amplitude
A_input_counts = round(A_input_norm * (input_scale-1));  % = 2047 counts

fprintf('Input: %d-bit signed, amplitude=%d counts\n',...
    input_bits, A_input_counts);
%% 1) Synthesize NTF
ntf = synthesizeNTF(order, osr, 1);

%% 2) Realize coefficients
[a, g, b, c] = realizeNTF(ntf, form);

%% 3) Build ABCD matrix
ABCD = stuffABCD(a, g, b, c, form);

%% 4) Scale dynamic range
A_input = 0.5;
[ABCDs, umax] = scaleABCD(ABCD, nlev, [], A_input);

%% 5) Extract scaled floating-point coefficients
[as, gs, bs, cs] = mapABCD(ABCDs, form);

fprintf('Floating point coefficients:\n');
fprintf('B1=%.10f  A1=%.10f  C1=%.10f  A2=%.10f  C2=%.10f\n', ...
        bs(1), as(1), cs(1), as(2), cs(2));

%% ---------------------------------------------------------------
%  PART 2: TOOLBOX-BASED WORD LENGTH SELECTION
% ---------------------------------------------------------------

%% --- Step 1: Integrator peak swings ---
fprintf('\n--- Step 1: Integrator peak swings ---\n');
N        = 2^16;
fs       = 5e6;
bin      = 7;
fin_norm = bin / N;
u        = A_input * sin(2*pi*fin_norm*(0:N-1));

ntf_scaled         = calculateTF(ABCDs);
[v_ref, xn, xmax]  = simulateDSM(u, ntf_scaled, nlev);

fprintf('xmax integrator 1 : %.6f\n', xmax(1));
fprintf('xmax integrator 2 : %.6f\n', xmax(2));
fprintf('umax              : %.6f\n', umax);

headroom = 1.1;
acc_max  = max(xmax) * headroom;
fprintf('Accumulator must cover : +-%.4f (%.0f%% headroom)\n',...
    acc_max, (headroom-1)*100);

%% --- Step 2: Reference SNR ---
fprintf('\n--- Step 2: Reference SNR ---\n');
w_hann  = hann(N).';
V_ref   = fft(v_ref .* w_hann);
bw_bins = floor(N/(2*osr));
hwfft   = V_ref(1:bw_bins);
snr_ref = calculateSNR(hwfft, bin, 1);
fprintf('Reference SNR (float) : %.1f dB\n', snr_ref);

[snr_p, amp_p] = predictSNR(ntf, osr);
snr_predicted  = max(snr_p);
fprintf('Predicted SNR         : %.1f dB\n', snr_predicted);

%% --- Step 3: Coefficient range analysis ---
fprintf('\n--- Step 3: Coefficient range analysis ---\n');
all_coefs  = [bs(1), as(1), cs(1), as(2), cs(2)];
coef_names = {'B1','A1','C1','A2','C2'};

for i = 1:length(all_coefs)
    int_bits_needed = ceil(log2(abs(all_coefs(i)) + 1)) + 1;
    fprintf('%s = %12.6f  requires %d integer bits\n',...
        coef_names{i}, all_coefs(i), int_bits_needed);
end

max_coef_val  = max(abs(all_coefs));
int_bits_coef = ceil(log2(max_coef_val + 1)) + 1;
fprintf('\nMax coefficient value : %.6f\n', max_coef_val);
fprintf('Integer bits required : %d (including sign)\n', int_bits_coef);

%% --- Step 4: Sweep fractional bits ---
fprintf('\n--- Step 4: SNR vs fractional bits sweep ---\n');
fprintf('%8s  %10s  %10s  %8s  %s\n',...
    'N_frac','N_total','SQNR_fp','Loss_dB','Status');

snr_loss_limit = 0.5;
N_frac_min_ok  = NaN;
snr_results    = zeros(1,20);

for N_frac = 8:20
    scale_n     = 2^N_frac;
    N_total     = int_bits_coef + N_frac;

    max_int_val = round(max_coef_val * scale_n);
    if max_int_val >= 2^(N_total-1)
        fprintf('%8d  %8d  %10s  %8s  coefficient overflow\n',...
            N_frac, N_total,'---','---');
        continue;
    end

    as_q = round(as * scale_n) / scale_n;
    bs_q = round(bs * scale_n) / scale_n;
    cs_q = round(cs * scale_n) / scale_n;

    try
        ABCD_q = stuffABCD(as_q, gs, bs_q, cs_q, form);
        ntf_q  = calculateTF(ABCD_q);

        poles_q = pole(ntf_q);
        if any(abs(poles_q) >= 1)
            fprintf('%8d  %8d  %10s  %8s  NTF unstable\n',...
                N_frac, N_total,'---','---');
            continue;
        end

        [v_q,~] = simulateDSM(u, ntf_q, nlev);
        V_q     = fft(v_q .* w_hann);
        hwfft_q = V_q(1:bw_bins);
        snr_q   = calculateSNR(hwfft_q, bin, 1);
        loss    = snr_ref - snr_q;
        snr_results(N_frac) = snr_q;

        if loss <= snr_loss_limit
            status = 'SUFFICIENT';
            if isnan(N_frac_min_ok)
                N_frac_min_ok = N_frac;
            end
        elseif loss <= 2.0
            status = 'marginal';
        else
            status = 'insufficient';
        end

        fprintf('%8d  %8d  %10.1f  %8.2f  %s\n',...
            N_frac, N_total, snr_q, loss, status);

    catch e
        fprintf('%8d  failed: %s\n', N_frac, e.message);
    end
end

if isnan(N_frac_min_ok)
    error('No sufficient word length found in range 8-20 bits');
end

%% --- Step 5: Align to standard FPGA word widths ---
fprintf('\n--- Step 5: Word length selection ---\n');

N_frac_coef = N_frac_min_ok;
N_word_coef = int_bits_coef + N_frac_coef;

standard_widths = [18, 24, 32, 48];
N_word_coef_aligned = N_word_coef;
N_frac_coef_aligned = N_frac_coef;
for sw = standard_widths
    if N_word_coef <= sw
        N_word_coef_aligned = sw;
        N_frac_coef_aligned = sw - int_bits_coef;
        break;
    end
end

N_word_coef = N_word_coef_aligned;
N_frac_coef = N_frac_coef_aligned;
scale_fp    = 2^N_frac_coef;

%% Accumulator word length
%% int_bits_acc must cover the actual measured integrator swing
%% Use xmax from simulateDSM — these are already in normalised units
%% The integrators in the SCALED ABCD operate in range ~[-1, +1]
%% but we store them multiplied by scale_fp, so actual integer range is:
%% max_int_value = acc_max * scale_fp
acc_max_scaled = acc_max * scale_fp;
int_bits_acc   = ceil(log2(acc_max_scaled + 1)) + 1;   % includes sign
N_word_acc     = int_bits_acc + N_frac_coef;

%% Round up to even number for clean Verilog
N_word_acc = ceil(N_word_acc / 2) * 2;

%% Verify accumulator is wider than coefficient word
if N_word_acc <= N_word_coef
    N_word_acc = N_word_coef + 2;   % force accumulator wider than coefficients
end

fprintf('Minimum N_frac from sweep   : %d bits\n', N_frac_min_ok);
fprintf('Coefficient word length     : %d-bit (%d fractional)\n',...
    N_word_coef, N_frac_coef);
fprintf('acc_max (normalised)        : %.4f\n', acc_max);
fprintf('acc_max * scale_fp          : %.1f  (integer units)\n', acc_max_scaled);
fprintf('Integer bits for accumulator: %d (including sign)\n', int_bits_acc);
fprintf('Accumulator word length     : %d-bit (%d fractional)\n',...
    N_word_acc, N_frac_coef);

%% --- Step 6: Toolbox verification ---
fprintf('\n--- Step 6: Toolbox verification ---\n');

as_fp = round(as * scale_fp) / scale_fp;
bs_fp = round(bs * scale_fp) / scale_fp;
cs_fp = round(cs * scale_fp) / scale_fp;

ABCD_fp  = stuffABCD(as_fp, gs, bs_fp, cs_fp, form);
ntf_fp   = calculateTF(ABCD_fp);
[v_fp,~] = simulateDSM(u, ntf_fp, nlev);
V_fp     = fft(v_fp .* w_hann);
hwfft_fp = V_fp(1:bw_bins);
snr_fp   = calculateSNR(hwfft_fp, bin, 1);

fprintf('SNR reference   : %.1f dB\n', snr_ref);
fprintf('SNR fixed-point : %.1f dB\n', snr_fp);
fprintf('SNR loss        : %.2f dB\n', snr_ref - snr_fp);
if (snr_ref - snr_fp) <= snr_loss_limit
    fprintf('PASS: SNR loss within %.1f dB limit\n', snr_loss_limit);
else
    fprintf('FAIL: increase word length\n');
end

%% --- Step 7: Integer arithmetic simulation ---
fprintf('\n--- Step 7: Integer arithmetic simulation ---\n');

B1_int = int32(round(bs(1) * scale_fp));
A1_int = int32(round(as(1) * scale_fp));
C1_int = int32(round(cs(1) * scale_fp));
A2_int = int32(round(as(2) * scale_fp));
C2_int = int32(round(cs(2) * scale_fp));

acc_limit = int32(2^(N_word_acc-1) - 1);
acc_min   = int32(-2^(N_word_acc-1));

int1_reg = int32(0);
int2_reg = int32(0);
v_int    = zeros(1,N);
x1_int   = zeros(1,N);
x2_int   = zeros(1,N);

for k = 1:N
    u_int = int32(round(u(k) * scale_fp));

    if int2_reg >= int32(0)
        v_int(k) =  1;
        fb_A1    =  A1_int;
        fb_A2    =  A2_int;
    else
        v_int(k) = -1;
        fb_A1    = -A1_int;
        fb_A2    = -A2_int;
    end

    x1_int(k) = double(int1_reg) / scale_fp;
    x2_int(k) = double(int2_reg) / scale_fp;

    B1u      = int32(int64(B1_int) * int64(u_int) / int64(scale_fp));
    int1_reg = int1_reg + B1u - fb_A1;
    int1_reg = max(int1_reg, acc_min);
    int1_reg = min(int1_reg, acc_limit);

    C1x      = int32(int64(C1_int) * int64(int1_reg) / int64(scale_fp));
    int2_reg = int2_reg + C1x - fb_A2;
    int2_reg = max(int2_reg, acc_min);
    int2_reg = min(int2_reg, acc_limit);
end

V_int   = fft(v_int .* w_hann);
hwfft_i = V_int(1:bw_bins);
snr_int = calculateSNR(hwfft_i, bin, 1);

fprintf('Integer arithmetic SNR : %.1f dB\n', snr_int);
fprintf('Loss vs reference      : %.2f dB\n', snr_ref - snr_int);
fprintf('Max int1 swing         : %.4f  (limit: %.4f)\n',...
    max(abs(x1_int)), double(acc_limit)/scale_fp);
fprintf('Max int2 swing         : %.4f  (limit: %.4f)\n',...
    max(abs(x2_int)), double(acc_limit)/scale_fp);
fprintf('Toggle rate            : %d / %d\n',...
    sum(abs(diff(v_int)))/2, N);
fprintf('Mean of v              : %.6f\n', mean(v_int));

if max(abs(x1_int)) >= double(acc_limit)/scale_fp || ...
   max(abs(x2_int)) >= double(acc_limit)/scale_fp
    fprintf('WARNING: overflow — increase accumulator word length\n');
else
    fprintf('PASS: No overflow\n');
end

%% ---------------------------------------------------------------
%  PART 3: NTF CHECKS
% ---------------------------------------------------------------
fprintf('\n--- NTF Stability ---\n');
poles  = pole(ntf);
ntf_tf = tf(ntf);

fprintf('NTF pole magnitudes: '); fprintf('%.4f ', abs(poles)); fprintf('\n');
if all(abs(poles) < 1)
    fprintf('PASS: All poles inside unit circle\n');
else
    fprintf('FAIL: Unstable NTF\n');
end

f_check  = linspace(0, 0.5, 1000);
z_check  = exp(2j*pi*f_check);
ntf_mag  = abs(polyval(ntf_tf.Numerator{1},  z_check) ./ ...
               polyval(ntf_tf.Denominator{1}, z_check));
ntf_peak = max(ntf_mag);
fprintf('NTF peak gain: %.4f  ', ntf_peak);
if ntf_peak <= 1.5
    fprintf('PASS: Lee criterion satisfied\n');
else
    fprintf('WARNING: Peak > 1.5\n');
end

fprintf('\n--- Input Headroom ---\n');
fprintf('umax: %.4f  A_input: %.4f  ', umax, A_input);
if A_input <= umax
    fprintf('PASS\n');
else
    fprintf('FAIL\n');
end

%% ---------------------------------------------------------------
%  PART 4: VERILOG PARAMETERS
% ---------------------------------------------------------------
fprintf('\n--- Quantisation errors ---\n');
fprintf('B1: float=%.10f  fixed=%.10f  int=%8d  error=%.2e\n',...
    bs(1), double(B1_int)/scale_fp, double(B1_int), bs(1)-double(B1_int)/scale_fp);
fprintf('A1: float=%.10f  fixed=%.10f  int=%8d  error=%.2e\n',...
    as(1), double(A1_int)/scale_fp, double(A1_int), as(1)-double(A1_int)/scale_fp);
fprintf('C1: float=%.10f  fixed=%.10f  int=%8d  error=%.2e\n',...
    cs(1), double(C1_int)/scale_fp, double(C1_int), cs(1)-double(C1_int)/scale_fp);
fprintf('A2: float=%.10f  fixed=%.10f  int=%8d  error=%.2e\n',...
    as(2), double(A2_int)/scale_fp, double(A2_int), as(2)-double(A2_int)/scale_fp);
fprintf('C2: float=%.10f  fixed=%.10f  int=%8d  error=%.2e\n',...
    cs(2), double(C2_int)/scale_fp, double(C2_int), cs(2)-double(C2_int)/scale_fp);

fprintf('\n--- COPY THESE PARAMETERS INTO VERILOG ---\n');
fprintf('// Coefficient word length : %d-bit\n', N_word_coef);
fprintf('// Accumulator word length : %d-bit\n', N_word_acc);
fprintf('// Fractional bits         : %d  (scale = 2^%d = %d)\n',...
    N_frac_coef, N_frac_coef, uint64(scale_fp));
fprintf('// Integer bits (coef)     : %d (including sign)\n', int_bits_coef);
fprintf('\n');
fprintf('parameter signed [%d:0] B1 = %d''sd%d;\n',...
    N_word_coef-1, N_word_coef, double(B1_int));
fprintf('parameter signed [%d:0] A1 = %d''sd%d;\n',...
    N_word_coef-1, N_word_coef, double(A1_int));
fprintf('parameter signed [%d:0] C1 = %d''sd%d;\n',...
    N_word_coef-1, N_word_coef, double(C1_int));
fprintf('parameter signed [%d:0] A2 = %d''sd%d;\n',...
    N_word_coef-1, N_word_coef, double(A2_int));
fprintf('parameter signed [%d:0] C2 = %d''sd%d;\n',...
    N_word_coef-1, N_word_coef, double(C2_int));
fprintf('\n');
fprintf('reg signed [%d:0] int1_reg;  // accumulator 1\n', N_word_acc-1);
fprintf('reg signed [%d:0] int2_reg;  // accumulator 2\n', N_word_acc-1);

%% ---------------------------------------------------------------
%  PART 5: PLOTS
% ---------------------------------------------------------------
figure('Name','SDM Word Length Selection','NumberTitle','off');

%% Plot 1: SNR vs fractional bits
subplot(2,2,1);
valid_idx = find(snr_results > 0);
plot(valid_idx, snr_results(valid_idx), 'b-o','MarkerFaceColor','b');
hold on;
yline(snr_ref,               'r--');
yline(snr_ref-snr_loss_limit,'g--');
xline(N_frac_min_ok, 'k--');
xline(N_frac_coef,   'm--');
xlabel('Fractional bits');
ylabel('SQNR (dB)');
title('SQNR vs Fractional Bits');
grid on;
%% R2021b compatible legend — use cell array
legend({'SQNR',...
        sprintf('Float ref %.1fdB', snr_ref),...
        sprintf('-%.1fdB limit', snr_loss_limit),...
        sprintf('Min=%d bits', N_frac_min_ok),...
        sprintf('Selected=%d bits', N_frac_coef)},...
       'Location','best');

%% Plot 2: Output spectra
subplot(2,2,2);
f_axis = linspace(0, fs/2, N/2)/1e3;
plot(f_axis, dbv(abs(V_ref(1:N/2))/(N/2)), 'b');
hold on;
plot(f_axis, dbv(abs(V_fp(1:N/2))/(N/2)),  'r--');
plot(f_axis, dbv(abs(V_int(1:N/2))/(N/2)), 'g:');
xlabel('Frequency (kHz)');
ylabel('Amplitude (dB)');
title('Output Spectra: Float vs Fixed-point');
xlim([0 fs/2/1e3]);
grid on;
xline(fs/(2*osr)/1e3,'k--');
legend({sprintf('Float %.1fdB',   snr_ref),...
        sprintf('Toolbox FP %.1fdB', snr_fp),...
        sprintf('Integer %.1fdB', snr_int),...
        'Signal BW'},...
       'Location','best');

%% Plot 3: NTF magnitude
subplot(2,2,3);
f_plot   = linspace(0, 0.5, 2000);
z_plot   = exp(2j*pi*f_plot);
ntf_plot = abs(polyval(ntf_tf.Numerator{1},  z_plot) ./ ...
               polyval(ntf_tf.Denominator{1}, z_plot));
plot(f_plot*fs/1e3, 20*log10(ntf_plot));
xlabel('Frequency (kHz)');
ylabel('|NTF| (dB)');
title('Noise Transfer Function');
grid on;
xline(fs/(2*osr)/1e3,'r--');

%% Plot 4: Predicted SQNR vs input level
subplot(2,2,4);
plot(amp_p, snr_p);
hold on;
xline(A_input, 'r--');
yline(snr_int, 'b--');
yline(snr_ref, 'k--');
xlabel('Input amplitude (dBFS)');
ylabel('SQNR (dB)');
title('Predicted SQNR vs Input Level');
grid on;
legend({'Predicted SQNR',...
        sprintf('A input=%.1f', A_input),...
        sprintf('Integer=%.1fdB', snr_int),...
        sprintf('Float=%.1fdB',  snr_ref)},...
       'Location','best');

%% ---------------------------------------------------------------
%  SUMMARY
% ---------------------------------------------------------------
fprintf('\n======================================================\n');
fprintf('FIXED-POINT WORD LENGTH SUMMARY\n');
fprintf('======================================================\n');
fprintf('Method              : Delta-Sigma Toolbox SNR sweep\n');
fprintf('SNR loss limit      : %.1f dB\n',  snr_loss_limit);
fprintf('Minimum N_frac      : %d bits\n',  N_frac_min_ok);
fprintf('Selected N_frac     : %d bits\n',  N_frac_coef);
fprintf('Alignment target    : %d-bit\n',   N_word_coef);
fprintf('\nCoefficient         : fixdt(1,%d,%d)\n', N_word_coef, N_frac_coef);
fprintf('  reg signed [%d:0]\n', N_word_coef-1);
fprintf('  Integer bits      : %d (sign included)\n', int_bits_coef);
fprintf('  Range             : [%.3f, %.3f]\n',...
    -2^(int_bits_coef-1),...
     (2^(N_word_coef-1)-1)/scale_fp);
fprintf('\nAccumulator         : fixdt(1,%d,%d)\n', N_word_acc, N_frac_coef);
fprintf('  reg signed [%d:0]\n', N_word_acc-1);
fprintf('  Integer bits      : %d (sign included)\n', int_bits_acc);
fprintf('  Range             : [%.3f, %.3f]\n',...
    -2^(N_word_acc-1-N_frac_coef),...
     (2^(N_word_acc-1)-1)/scale_fp);
fprintf('\nSNR results:\n');
fprintf('  Float reference   : %.1f dB\n', snr_ref);
fprintf('  Toolbox FP sim    : %.1f dB  (loss: %.2f dB)\n',...
    snr_fp,  snr_ref-snr_fp);
fprintf('  Integer sim       : %.1f dB  (loss: %.2f dB)\n',...
    snr_int, snr_ref-snr_int);
fprintf('======================================================\n');


%% Auto-generate SDM_fcn.m

fid = fopen('SDM_fcn.m', 'w');
fprintf(fid, 'function dac_bit = SDM_fcn(u)  %%%%#codegen\n');
fprintf(fid, '%% Auto-generated by DESIGN_SECOND_ORDER.m\n');
fprintf(fid, '%% Coefficient WL : %d-bit  fixdt(1,%d,%d)\n',...
    N_word_coef, N_word_coef, N_frac_coef);
fprintf(fid, '%% Accumulator WL : %d-bit  fixdt(1,%d,%d)\n',...
    N_word_acc, N_word_acc, N_frac_coef);
fprintf(fid, '%% Input          : %d-bit signed\n\n', input_bits);
fprintf(fid, 'dac_bit = false;\n\n');
fprintf(fid, 'persistent int1 int2\n');
fprintf(fid, 'if isempty(int1)\n');
fprintf(fid, '    int1 = int32(0);\n');
fprintf(fid, '    int2 = int32(0);\n');
fprintf(fid, 'end\n\n');
fprintf(fid, '%% Coefficients\n');
fprintf(fid, 'B1_int = int32(%d);\n', double(B1_int));
fprintf(fid, 'A1_int = int32(%d);\n', double(A1_int));
fprintf(fid, 'C1_int = int32(%d);\n', double(C1_int));
fprintf(fid, 'A2_int = int32(%d);\n\n', double(A2_int));
fprintf(fid, 'scale_fp    = int64(%d);\n', uint64(scale_fp));
fprintf(fid, 'acc_max     = int32(%d);\n',  double(int32(2^(N_word_acc-1)-1)));
fprintf(fid, 'acc_min     = int32(%d);\n',  double(int32(-2^(N_word_acc-1))));
fprintf(fid, 'input_shift = int64(%d);\n\n', 2^input_shift);
fprintf(fid, 'u_in = int32(u);\n');
fprintf(fid, 'u_in = max(u_in, int32(%d));\n', -input_scale);
fprintf(fid, 'u_in = min(u_in, int32(%d));\n\n', input_scale-1);
fprintf(fid, 'if int2 >= int32(0)\n');
fprintf(fid, '    dac_bit = true;\n');
fprintf(fid, '    fb_A1   =  A1_int;\n');
fprintf(fid, '    fb_A2   =  A2_int;\n');
fprintf(fid, 'else\n');
fprintf(fid, '    dac_bit = false;\n');
fprintf(fid, '    fb_A1   = -A1_int;\n');
fprintf(fid, '    fb_A2   = -A2_int;\n');
fprintf(fid, 'end\n\n');
fprintf(fid, 'B1u  = int32(int64(B1_int) * int64(u_in) / input_shift);\n');
fprintf(fid, 'int1 = int1 + B1u - fb_A1;\n');
fprintf(fid, 'int1 = max(int1, acc_min);\n');
fprintf(fid, 'int1 = min(int1, acc_max);\n\n');
fprintf(fid, 'C1x  = int32(int64(C1_int) * int64(int1) / scale_fp);\n');
fprintf(fid, 'int2 = int2 + C1x - fb_A2;\n');
fprintf(fid, 'int2 = max(int2, acc_min);\n');
fprintf(fid, 'int2 = min(int2, acc_max);\n\n');
fprintf(fid, 'end\n');
fclose(fid);
fprintf('\nSDM_fcn.m auto-generated with coefficients from this run\n');