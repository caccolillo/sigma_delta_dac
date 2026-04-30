%auto-generated
function dac_bit = SDM_fcn_fp_fixpt(u)  %#codegen

%% 2nd-order CIFB SDM — double-precision floating-point version
%% u is the audio sample input — same scale as the integer version:
%%   range -4096 to +4095 (13-bit signed full scale)
%%
%% All internal arithmetic uses double precision.
%% Coefficients are the same Q16 integer values divided by 2^16
%% so they represent the same real-valued coefficients as the
%% Verilog/integer implementation.
%%
%% Output: boolean dac_bit (1-bit PDM)

fm = get_fimath();
u = fi(u, 1, 16, 2, fm);

dac_bit = false;

persistent int1 int2
if isempty(int1)
    int1 = fi(0.0, 1, 16, 12, fm);
    int2 = fi(0.0, 1, 16, 11, fm);
end

%% ---------------------------------------------------------------
%  COEFFICIENTS — exact same values as integer version
%  Original integers were Q16 (scaled by 2^16 = 65536)
%  Dividing by 65536 recovers the real-valued coefficient
% ---------------------------------------------------------------
B1 = fi(51138 / 65536, 0, 16, 16, fm);     %  ≈ 0.7803
A1 = fi(51138 / 65536, 0, 16, 16, fm);     %  ≈ 0.7803
C1 =  fi(3493 / 65536, 0, 16, 20, fm);     %  ≈ 0.0533
A2 =  fi(9765 / 65536, 0, 16, 18, fm);     %  ≈ 0.1490

%% ---------------------------------------------------------------
%  INPUT NORMALISATION
%  Map the 13-bit signed integer input to the [-1, +1] range
%  expected by the normalised SDM coefficients above.
%
%  +4095 → +0.9998
%  -4096 → -1.0
% ---------------------------------------------------------------
u_d = fi(double(u), 1, 16, 2, fm);

%% Clamp to 13-bit signed range
if u_d >  fi(4095, 0, 12, 0, fm), u_d(:) =  4095; end
if u_d < fi(-4096, 1, 13, 0, fm), u_d(:) = -4096; end

%% Normalise to [-1, +1]
u_norm = fi(fi_div_by_shift(u_d, 12), 1, 16, 14, fm);

%% ---------------------------------------------------------------
%  QUANTIZER — sign of int2
% ---------------------------------------------------------------
if int2 >= fi(0.0, 0, 1, 0, fm)
    dac_bit(:) = true;
    dac_val = fi(+1.0, 1, 16, 14, fm);
else
    dac_bit(:) = false;
    dac_val = fi(-1.0, 1, 16, 14, fm);
end

%% ---------------------------------------------------------------
%  INTEGRATOR 1: int1[n] = B1*u_norm[n] + int1[n-1] - A1*dac_val
% ---------------------------------------------------------------
int1(:) = fi_signed(int1 + B1 * u_norm) - A1 * dac_val;

%% Saturation — match integer version's ±524288/65536 = ±8.0 range
if int1 >  fi(8.0, 0, 4, 0, fm), int1(:) =  8.0; end
if int1 < fi(-8.0, 1, 4, 0, fm), int1(:) = -8.0; end

%% ---------------------------------------------------------------
%  INTEGRATOR 2: int2[n] = C1*int1[n] + int2[n-1] - A2*dac_val
% ---------------------------------------------------------------
int2(:) = fi_signed(int2 + C1 * int1) - A2 * dac_val;

%% Saturation
if int2 >  fi(8.0, 0, 4, 0, fm), int2(:) =  8.0; end
if int2 < fi(-8.0, 1, 4, 0, fm), int2(:) = -8.0; end

end



function y = fi_div_by_shift(a,shift_len)
    coder.inline( 'always' );
    if isfi( a )
        nt = numerictype( a );
        fm = fimath( a );
        nt_bs = numerictype( nt.Signed, nt.WordLength + shift_len, nt.FractionLength + shift_len );
        y = bitsra( fi( a, nt_bs, fm ), shift_len );
    else
        y = a / 2 ^ shift_len;
    end
end


function y = fi_signed(a)
    coder.inline( 'always' );
    if isfi( a ) && ~(issigned( a ))
        nt = numerictype( a );
        new_nt = numerictype( 1, nt.WordLength + 1, nt.FractionLength );
        y = fi( a, new_nt, fimath( a ) );
    else
        y = a;
    end
end

function fm = get_fimath()
	fm = fimath('RoundingMethod', 'Floor',...
	     'OverflowAction', 'Wrap',...
	     'ProductMode','FullPrecision',...
	     'MaxProductWordLength', 128,...
	     'SumMode','FullPrecision',...
	     'MaxSumWordLength', 128);
end







function dac_bit = SDM_fcn_fp(u)  %#codegen

%% 2nd-order CIFB SDM — double-precision floating-point version
%% u is the audio sample input — same scale as the integer version:
%%   range -4096 to +4095 (13-bit signed full scale)
%%
%% All internal arithmetic uses double precision.
%% Coefficients are the same Q16 integer values divided by 2^16
%% so they represent the same real-valued coefficients as the
%% Verilog/integer implementation.
%%
%% Output: boolean dac_bit (1-bit PDM)

dac_bit = false;

persistent int1 int2
if isempty(int1)
    int1 = 0.0;
    int2 = 0.0;
end

%% ---------------------------------------------------------------
%  COEFFICIENTS — exact same values as integer version
%  Original integers were Q16 (scaled by 2^16 = 65536)
%  Dividing by 65536 recovers the real-valued coefficient
% ---------------------------------------------------------------
B1 = 51138 / 65536;     %  ≈ 0.7803
A1 = 51138 / 65536;     %  ≈ 0.7803
C1 =  3493 / 65536;     %  ≈ 0.0533
A2 =  9765 / 65536;     %  ≈ 0.1490

%% ---------------------------------------------------------------
%  INPUT NORMALISATION
%  Map the 13-bit signed integer input to the [-1, +1] range
%  expected by the normalised SDM coefficients above.
%
%  +4095 → +0.9998
%  -4096 → -1.0
% ---------------------------------------------------------------
u_d = double(u);

%% Clamp to 13-bit signed range
if u_d >  4095, u_d =  4095; end
if u_d < -4096, u_d = -4096; end

%% Normalise to [-1, +1]
u_norm = u_d / 4096.0;

%% ---------------------------------------------------------------
%  QUANTIZER — sign of int2
% ---------------------------------------------------------------
if int2 >= 0.0
    dac_bit = true;
    dac_val = +1.0;
else
    dac_bit = false;
    dac_val = -1.0;
end

%% ---------------------------------------------------------------
%  INTEGRATOR 1: int1[n] = B1*u_norm[n] + int1[n-1] - A1*dac_val
% ---------------------------------------------------------------
int1 = int1 + B1 * u_norm - A1 * dac_val;

%% Saturation — match integer version's ±524288/65536 = ±8.0 range
if int1 >  8.0, int1 =  8.0; end
if int1 < -8.0, int1 = -8.0; end

%% ---------------------------------------------------------------
%  INTEGRATOR 2: int2[n] = C1*int1[n] + int2[n-1] - A2*dac_val
% ---------------------------------------------------------------
int2 = int2 + C1 * int1 - A2 * dac_val;

%% Saturation
if int2 >  8.0, int2 =  8.0; end
if int2 < -8.0, int2 = -8.0; end

end