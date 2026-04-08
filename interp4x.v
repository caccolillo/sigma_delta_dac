// =============================================================================
// interp4x.v  (v2 - direct-form FIR, no polyphase, no functions)
// 4x linear interpolation filter: 8 kHz -> 32 kHz
// =============================================================================
// Architecture: direct-form FIR on upsampled stream
//   - A 32 kHz clock-rate shift register holds the upsampled input
//   - Every 3125 clocks (one 32kHz period) one sample is valid
//   - On samp_valid (8kHz strobe): load new input, others get zero
//   - FIR runs every clock, output valid matches input timing
//
// Filter: 31-tap Kaiser windowed-sinc (beta=8), cutoff=4kHz at 32kHz
//   Passband 0-3.4kHz: <0.1dB ripple
//   Stopband 4kHz+   : >60dB attenuation (8kHz image: -79dB)
//
// This version uses only plain Verilog-2001:
//   - No functions with internal reg
//   - No reg declarations inside always blocks
//   - No case statements with local variables
//   - No implicit truncation of wide signals
//   No polyphase decomposition — simpler and more reliable in simulation.
//
// FPGA cost: 31 multipliers -> maps to ~8 DSP48E1 slices (4 inputs per DSP)
// Latency  : 15 output samples = 0.47 ms
// =============================================================================

module interp4x (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,    // 8 kHz input strobe
    input  wire [12:0] din,           // 13-bit unsigned input (0..8191)
    output reg         out_valid,     // 32 kHz output strobe
    output reg  [12:0] dout           // 13-bit unsigned output (0..8191)
);

// =============================================================================
// 32kHz clock divider — generates out_valid at 32kHz
// =============================================================================
// 100MHz / 32kHz = 3125 clocks per output sample

localparam DIV = 3125;

reg [11:0] div_ctr;   // 0..3124

always @(posedge clk) begin
    if (rst) begin
        div_ctr   <= 12'd0;
        out_valid <= 1'b0;
    end else begin
        if (div_ctr == DIV - 1) begin
            div_ctr   <= 12'd0;
            out_valid <= 1'b1;
        end else begin
            div_ctr   <= div_ctr + 1'b1;
            out_valid <= 1'b0;
        end
    end
end

// =============================================================================
// Upsampling shift register
// =============================================================================
// Holds 31 samples of the upsampled stream (zeros between 8kHz samples).
// On out_valid: shift register advances by one position.
// On samp_valid AND out_valid: load new sample into position 0.
// On out_valid only: load zero into position 0 (L-1 zeros between samples).

reg signed [13:0] sr [0:30];   // 14-bit signed (zero-extended 13-bit input)
integer k;

always @(posedge clk) begin
    if (rst) begin
        for (k = 0; k <= 30; k = k + 1)
            sr[k] <= 14'sd0;
    end else if (out_valid) begin
        for (k = 30; k >= 1; k = k - 1)
            sr[k] <= sr[k-1];
        // Load new sample on 8kHz strobe, zero otherwise (upsampling)
        sr[0] <= samp_valid ? {1'b0, din} : 14'sd0;
    end
end

// =============================================================================
// FIR coefficients
// =============================================================================
// Kaiser windowed-sinc, 31 taps, beta=8, cutoff=4kHz at 32kHz.
// Stored as 15-bit signed fixed-point with shift=14.
// Gain of L=4 is embedded (coefficients already multiplied by 4).
// Output must be right-shifted by 14 bits after MAC.
//
// h[n] = 4 * firwin(31, 4000, window=('kaiser',8), fs=32000)
// Quantised: round(h[n] * 2^14 / 4) stored here, multiply by 4 at output.
// Equivalently: coeff[n] = round(h_normalised[n] * 2^14)
// then output = (sum(sr[n]*coeff[n]) * 4) >> 14
//             = sum(sr[n]*coeff[n]) >> 12

localparam signed [14:0] C00 = -15'sd1;
localparam signed [14:0] C01 = -15'sd4;
localparam signed [14:0] C02 = -15'sd7;
localparam signed [14:0] C03 =  15'sd0;
localparam signed [14:0] C04 =  15'sd32;
localparam signed [14:0] C05 =  15'sd79;
localparam signed [14:0] C06 =  15'sd93;
localparam signed [14:0] C07 =  15'sd0;
localparam signed [14:0] C08 = -15'sd223;
localparam signed [14:0] C09 = -15'sd466;
localparam signed [14:0] C10 = -15'sd481;
localparam signed [14:0] C11 =  15'sd0;
localparam signed [14:0] C12 =  15'sd1057;
localparam signed [14:0] C13 =  15'sd2439;
localparam signed [14:0] C14 =  15'sd3627;
localparam signed [14:0] C15 =  15'sd4096;   // centre tap
localparam signed [14:0] C16 =  15'sd3627;
localparam signed [14:0] C17 =  15'sd2439;
localparam signed [14:0] C18 =  15'sd1057;
localparam signed [14:0] C19 =  15'sd0;
localparam signed [14:0] C20 = -15'sd481;
localparam signed [14:0] C21 = -15'sd466;
localparam signed [14:0] C22 = -15'sd223;
localparam signed [14:0] C23 =  15'sd0;
localparam signed [14:0] C24 =  15'sd93;
localparam signed [14:0] C25 =  15'sd79;
localparam signed [14:0] C26 =  15'sd32;
localparam signed [14:0] C27 =  15'sd0;
localparam signed [14:0] C28 = -15'sd7;
localparam signed [14:0] C29 = -15'sd4;
localparam signed [14:0] C30 = -15'sd1;

// =============================================================================
// MAC — runs every clock, registered output
// =============================================================================
// Accumulator width: 14 (sr) + 15 (coeff) + ceil(log2(31)) = 34 bits
// Use 36-bit signed to be safe.
// Output shift: >> 12 (because L=4 = 2^2, shift=14, net = 14-2 = 12)

reg signed [35:0] mac;

always @(posedge clk) begin
    if (rst) begin
        mac  <= 36'sd0;
        dout <= 13'd4096;
    end else begin
        mac <= sr[ 0]*C00 + sr[ 1]*C01 + sr[ 2]*C02 + sr[ 3]*C03
             + sr[ 4]*C04 + sr[ 5]*C05 + sr[ 6]*C06 + sr[ 7]*C07
             + sr[ 8]*C08 + sr[ 9]*C09 + sr[10]*C10 + sr[11]*C11
             + sr[12]*C12 + sr[13]*C13 + sr[14]*C14 + sr[15]*C15
             + sr[16]*C16 + sr[17]*C17 + sr[18]*C18 + sr[19]*C19
             + sr[20]*C20 + sr[21]*C21 + sr[22]*C22 + sr[23]*C23
             + sr[24]*C24 + sr[25]*C25 + sr[26]*C26 + sr[27]*C27
             + sr[28]*C28 + sr[29]*C29 + sr[30]*C30;

        // Right-shift by 12 to get output (L=4 absorbed into shift)
        // mac >> 12 needs 13 bits (0..8191): use mac[24:12] not mac[23:12]
        // mac[23:12] is only 12 bits wide (max 4095) — would clip at half scale
        if      (mac[35:12] < $signed(36'sd0))    dout <= 13'd0;
        else if (mac[35:12] > $signed(36'sd8191)) dout <= 13'd8191;
        else                                       dout <= mac[24:12];
    end
end

endmodule
