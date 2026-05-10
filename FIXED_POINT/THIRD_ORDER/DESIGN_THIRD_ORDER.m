%% 3rd-Order Sigma-Delta Design and Golden-Reference Generation
%% CIFB topology with one resonator local feedback (g1) for in-band NTF zeros
%% Produces the floating-point reference for MATLAB Fixed-Point Designer.
%% Requires: Delta-Sigma Toolbox
%% MATLAB R2021b compatible

clear; clc;

%% ---------------------------------------------------------------
%  PART 1: DESIGN
% ---------------------------------------------------------------
order = 3;
osr   = 625;    % 5MHz / 8kHz
nlev  = 2;      % 1-bit quantizer
form  = 'CIFB';
input_bits   = 13;                          % signed 13-bit input
input_scale  = 2^(input_bits-1);            % = 4096
A_input      = 0.5;                         % scaled input amplitude

fprintf('Input: %d-bit signed, range [%d, %d]\n',...
    input_bits, -input_scale, input_scale-1);

%% 1) Synthesize NTF
%% Hinf = 1.5 is the Lee criterion limit. For 3rd-order modulators a slightly
%% relaxed Hinf (e.g. 2.0-3.0) is sometimes used to gain noise-shaping
%% aggressiveness; start at 1.5 and revisit only if SNR is insufficient.
H_inf = 1.5;
ntf = synthesizeNTF(order, osr, 1, H_inf);

%% 2) Realize coefficients (CIFB topology)
[a, g, b, c] = realizeNTF(ntf, form);

%% 3) Build ABCD matrix and scale dynamic range
ABCD          = stuffABCD(a, g, b, c, form);
[ABCDs, umax] = scaleABCD(ABCD, nlev, [], A_input);

%% 4) Extract scaled floating-point coefficients
[as, gs, bs, cs] = mapABCD(ABCDs, form);

fprintf('\nFloating-point coefficients:\n');
fprintf('  B1 = %.10f\n', bs(1));
fprintf('  A1 = %.10f   A2 = %.10f   A3 = %.10f\n', as(1), as(2), as(3));
fprintf('  C1 = %.10f   C2 = %.10f   C3 = %.10f\n', cs(1), cs(2), cs(3));
fprintf('  G1 = %.10f   (resonator local feedback)\n', gs(1));

%% ---------------------------------------------------------------
%  PART 2: SANITY SIMULATION
% ---------------------------------------------------------------

%% --- Integrator peak swings (drives accumulator-width sizing) ---
fprintf('\n--- Integrator peak swings ---\n');
N        = 2^16;
fs       = 5e6;
bin      = 7;
fin_norm = bin / N;
u        = A_input * sin(2*pi*fin_norm*(0:N-1));

ntf_scaled        = calculateTF(ABCDs);
[v_ref, ~, xmax]  = simulateDSM(u, ntf_scaled, nlev);

fprintf('  xmax integrator 1 : %.6f\n', xmax(1));
fprintf('  xmax integrator 2 : %.6f\n', xmax(2));
fprintf('  xmax integrator 3 : %.6f\n', xmax(3));
fprintf('  umax              : %.6f\n', umax);

headroom = 1.1;
acc_max  = max(xmax) * headroom;
fprintf('  Accumulators must cover : +-%.4f (%.0f%% headroom)\n',...
    acc_max, (headroom-1)*100);
fprintf('  -> use this as a cross-check against any tool-proposed\n');
fprintf('     integrator widths; tool proposals are stimulus-dependent.\n');

%% --- Reference SNR (floating-point ceiling) ---
fprintf('\n--- Reference SNR ---\n');
w_hann  = hann(N).';
V_ref   = fft(v_ref .* w_hann);
bw_bins = floor(N/(2*osr));
hwfft   = V_ref(1:bw_bins);
snr_ref = calculateSNR(hwfft, bin, 1);
fprintf('  Reference SNR (float)   : %.1f dB\n', snr_ref);

[snr_p, amp_p] = predictSNR(ntf, osr);
fprintf('  Predicted peak SNR      : %.1f dB\n', max(snr_p));
fprintf('  -> this is the ceiling that any fixed-point implementation\n');
fprintf('     should approach within the agreed loss budget.\n');

%% ---------------------------------------------------------------
%  PART 3: NTF CHECKS
% ---------------------------------------------------------------
fprintf('\n--- NTF stability ---\n');
poles  = pole(ntf);
ntf_tf = tf(ntf);

fprintf('  Pole magnitudes : '); fprintf('%.4f ', abs(poles)); fprintf('\n');
if all(abs(poles) < 1)
    fprintf('  PASS: all poles inside unit circle\n');
else
    fprintf('  FAIL: unstable NTF\n');
end

f_check  = linspace(0, 0.5, 1000);
z_check  = exp(2j*pi*f_check);
ntf_mag  = abs(polyval(ntf_tf.Numerator{1},  z_check) ./ ...
               polyval(ntf_tf.Denominator{1}, z_check));
ntf_peak = max(ntf_mag);
fprintf('  NTF peak gain   : %.4f  ', ntf_peak);
if ntf_peak <= 1.5
    fprintf('PASS (Lee criterion satisfied)\n');
else
    fprintf('WARNING: peak > 1.5 (acceptable for 3rd-order if stable)\n');
end

fprintf('\n--- Input headroom ---\n');
fprintf('  umax = %.4f   A_input = %.4f   ', umax, A_input);
if A_input <= umax
    fprintf('PASS\n');
else
    fprintf('FAIL\n');
end

%% ---------------------------------------------------------------
%  PART 4: NTF MAGNITUDE PLOT
% ---------------------------------------------------------------
figure('Name','3rd-Order SDM NTF','NumberTitle','off');
f_plot   = linspace(0, 0.5, 2000);
z_plot   = exp(2j*pi*f_plot);
ntf_plot = abs(polyval(ntf_tf.Numerator{1},  z_plot) ./ ...
               polyval(ntf_tf.Denominator{1}, z_plot));
plot(f_plot*fs/1e3, 20*log10(ntf_plot));
xlabel('Frequency (kHz)');
ylabel('|NTF| (dB)');
title('Noise Transfer Function (3rd order, CIFB)');
grid on;
xline(fs/(2*osr)/1e3,'r--','Signal BW');

%% ---------------------------------------------------------------
%  PART 5: AUTO-GENERATE SDM_fcn.m
% ---------------------------------------------------------------
%% Floating-point reference implementation, intended as the input to
%% MATLAB Fixed-Point Designer ("Convert to Fixed Point" workflow).
%% Keep all arithmetic in plain double precision so the tool can
%% instrument the function, observe min/max ranges, and propose data types.

fid = fopen('SDM_fcn.m', 'w');
fprintf(fid, 'function dac_bit = SDM_fcn(u)  %%#codegen\n');
fprintf(fid, '%% Auto-generated by DESIGN_THIRD_ORDER.m\n');
fprintf(fid, '%% 3rd-order CIFB sigma-delta modulator - FLOATING POINT REFERENCE\n');
fprintf(fid, '%%\n');
fprintf(fid, '%% Input  u : signed integer count from the %d-bit ADC,\n', input_bits);
fprintf(fid, '%%            range [%d, %d]. Internally normalised to [-1,+1).\n',...
    -input_scale, input_scale-1);
fprintf(fid, '%% Output : single bit (logical) for 1-bit DAC drive.\n');
fprintf(fid, '\n');
fprintf(fid, 'dac_bit = false;\n\n');
fprintf(fid, 'persistent int1 int2 int3\n');
fprintf(fid, 'if isempty(int1)\n');
fprintf(fid, '    int1 = 0;\n');
fprintf(fid, '    int2 = 0;\n');
fprintf(fid, '    int3 = 0;\n');
fprintf(fid, 'end\n\n');
fprintf(fid, '%% Floating-point coefficients (scaled CIFB, 3rd order)\n');
fprintf(fid, 'B1 = %.15g;\n', bs(1));
fprintf(fid, 'A1 = %.15g;\n', as(1));
fprintf(fid, 'A2 = %.15g;\n', as(2));
fprintf(fid, 'A3 = %.15g;\n', as(3));
fprintf(fid, 'C1 = %.15g;\n', cs(1));
fprintf(fid, 'C2 = %.15g;\n', cs(2));
fprintf(fid, 'G1 = %.15g;\n\n', gs(1));
fprintf(fid, '%% Saturate and normalise the %d-bit signed input to [-1, +1)\n', input_bits);
fprintf(fid, 'u_sat  = max(min(double(u), %d), %d);\n', input_scale-1, -input_scale);
fprintf(fid, 'u_norm = u_sat / %d;\n\n', input_scale);
fprintf(fid, '%% Quantizer decision based on the last integrator (int3)\n');
fprintf(fid, 'if int3 >= 0\n');
fprintf(fid, '    dac_bit = true;\n');
fprintf(fid, '    v       =  1;\n');
fprintf(fid, 'else\n');
fprintf(fid, '    dac_bit = false;\n');
fprintf(fid, '    v       = -1;\n');
fprintf(fid, 'end\n\n');
fprintf(fid, '%% Integrator 1: int1 += B1*u - A1*v\n');
fprintf(fid, 'int1 = int1 + B1*u_norm - A1*v;\n\n');
fprintf(fid, '%% Integrator 2: int2 += C1*int1 - A2*v\n');
fprintf(fid, 'int2 = int2 + C1*int1 - A2*v;\n\n');
fprintf(fid, '%% Integrator 3: int3 += C2*int2 - G1*int3 - A3*v\n');
fprintf(fid, '%% G1 is the resonator local feedback that places NTF zeros\n');
fprintf(fid, '%% at non-DC frequencies inside the signal band.\n');
fprintf(fid, 'int3 = int3 + C2*int2 - G1*int3 - A3*v;\n\n');
fprintf(fid, 'end\n');
fclose(fid);

%% ---------------------------------------------------------------
%  SUMMARY
% ---------------------------------------------------------------
fprintf('\n======================================================\n');
fprintf('3rd-ORDER SDM DESIGN SUMMARY\n');
fprintf('======================================================\n');
fprintf('Order              : %d\n', order);
fprintf('Topology           : %s\n', form);
fprintf('OSR                : %d\n', osr);
fprintf('Quantizer levels   : %d (1-bit)\n', nlev);
fprintf('H_inf              : %.2f\n', H_inf);
fprintf('Scaled input range : [-%.3f, +%.3f]   (umax = %.3f)\n',...
    A_input, A_input, umax);
fprintf('Max integrator swing (×%.1f headroom) : %.4f\n', headroom, acc_max);
fprintf('Floating-point reference SNR          : %.1f dB\n', snr_ref);
fprintf('Predicted peak SNR                    : %.1f dB\n', max(snr_p));
fprintf('\nGolden-reference file written : SDM_fcn.m\n');
fprintf('  -> feed this into Fixed-Point Designer for conversion.\n');
fprintf('======================================================\n');