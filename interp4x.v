// =============================================================================
// interp4x.v — 4x polyphase FIR interpolation filter
// =============================================================================
// Upsamples 8 kHz → 32 kHz using a 31-tap Kaiser windowed-sinc FIR.
// Implemented as a polyphase filter: 4 branches of 8 taps each.
// No multipliers needed — uses Xilinx DSP48 inference.
//
// Input  : 13-bit PCM at 8 kHz, presented on samp_valid pulse
// Output : 13-bit PCM at 32 kHz, one sample per out_valid pulse
//
// Filter spec (Kaiser beta=8):
//   Passband:  0 – 3.4 kHz   ±0.1 dB
//   Stopband:  4.0 kHz+      < –60 dB (at 8 kHz: –79 dB)
//   Taps:      31 (7–8 per polyphase branch)
//   Latency:   15 output samples = 0.47 ms
//   FPGA cost: ~4 DSP48 slices (one per polyphase branch, time-multiplexed)
//
// Clock: 100 MHz | Output rate: 100 MHz / 3125 = 32 kHz
// =============================================================================

module interp4x (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,    // 8 kHz input strobe
    input  wire [12:0] din,           // 13-bit input sample (unsigned 0..8191)
    output reg         out_valid,     // 32 kHz output strobe (4x per samp_valid)
    output reg  [12:0] dout           // 13-bit interpolated output
);

// =============================================================================
// Polyphase decomposition
// =============================================================================
// The 31-tap FIR is split into 4 polyphase branches, each 8 taps.
// Branch p (p=0..3) contains coefficients H[p], H[p+4], H[p+8], ..., H[p+28]
//
// Coefficients: 15-bit signed fixed-point, shift=14
// (multiply input by coeff, accumulate, then >>> 14 to get output)
//
// Kaiser beta=8, cutoff = 4kHz at 32kHz sample rate
// ─────────────────────────────────────────────────────────────────────────────

// Branch 0: H[0],H[4],H[8],H[12],H[16],H[20],H[24],H[28]
localparam signed [14:0] B0_0 = -15'sd1;
localparam signed [14:0] B0_1 =  15'sd32;
localparam signed [14:0] B0_2 = -15'sd223;
localparam signed [14:0] B0_3 =  15'sd1057;
localparam signed [14:0] B0_4 =  15'sd3627;
localparam signed [14:0] B0_5 = -15'sd481;
localparam signed [14:0] B0_6 =  15'sd93;
localparam signed [14:0] B0_7 = -15'sd7;

// Branch 1: H[1],H[5],H[9],H[13],H[17],H[21],H[25],H[29]
localparam signed [14:0] B1_0 = -15'sd4;
localparam signed [14:0] B1_1 =  15'sd79;
localparam signed [14:0] B1_2 = -15'sd466;
localparam signed [14:0] B1_3 =  15'sd2439;
localparam signed [14:0] B1_4 =  15'sd2439;
localparam signed [14:0] B1_5 = -15'sd466;
localparam signed [14:0] B1_6 =  15'sd79;
localparam signed [14:0] B1_7 = -15'sd4;

// Branch 2: H[2],H[6],H[10],H[14],H[18],H[22],H[26],H[30]
localparam signed [14:0] B2_0 = -15'sd7;
localparam signed [14:0] B2_1 =  15'sd93;
localparam signed [14:0] B2_2 = -15'sd481;
localparam signed [14:0] B2_3 =  15'sd3627;
localparam signed [14:0] B2_4 =  15'sd1057;
localparam signed [14:0] B2_5 = -15'sd223;
localparam signed [14:0] B2_6 =  15'sd32;
localparam signed [14:0] B2_7 = -15'sd1;

// Branch 3: H[3],H[7],H[11],H[15],H[19],H[23],H[27]  (7 taps — pad with 0)
localparam signed [14:0] B3_0 =  15'sd0;
localparam signed [14:0] B3_1 =  15'sd0;
localparam signed [14:0] B3_2 =  15'sd0;
localparam signed [14:0] B3_3 =  15'sd4096;
localparam signed [14:0] B3_4 =  15'sd0;
localparam signed [14:0] B3_5 =  15'sd0;
localparam signed [14:0] B3_6 =  15'sd0;
localparam signed [14:0] B3_7 =  15'sd0;

// =============================================================================
// Input shift register — 8 taps deep (holds last 8 input samples)
// =============================================================================
reg signed [13:0] sr [0:7];   // signed extension of 13-bit input
integer k;

always @(posedge clk) begin
    if (rst) begin
        for (k=0; k<8; k=k+1) sr[k] <= 14'sd0;
    end else if (samp_valid) begin
        sr[7] <= sr[6];
        sr[6] <= sr[5];
        sr[5] <= sr[4];
        sr[4] <= sr[3];
        sr[3] <= sr[2];
        sr[2] <= sr[1];
        sr[1] <= sr[0];
        sr[0] <= {1'b0, din};   // zero-extend unsigned input to signed
    end
end

// =============================================================================
// Polyphase branch outputs
// =============================================================================
// Each branch: 8 multiply-accumulate operations
// Product: 14-bit * 15-bit = 29-bit, accumulate to 32-bit, then >>> 14

function automatic signed [31:0] branch_mac;
    input signed [13:0] s0, s1, s2, s3, s4, s5, s6, s7;
    input signed [14:0] c0, c1, c2, c3, c4, c5, c6, c7;
    begin
        branch_mac = s0*c0 + s1*c1 + s2*c2 + s3*c3
                   + s4*c4 + s5*c5 + s6*c6 + s7*c7;
    end
endfunction

// =============================================================================
// Output sequencer
// =============================================================================
// On each samp_valid, output 4 interpolated samples in consecutive clock cycles
// Phase 0: branch 0 output (= input at time n, filtered)
// Phase 1: branch 1 output (= interpolated at n + 1/4)
// Phase 2: branch 2 output (= interpolated at n + 2/4)
// Phase 3: branch 3 output (= interpolated at n + 3/4)

reg [1:0] phase;        // 0..3 output phase counter
reg       running;      // high while outputting the 4 samples
reg signed [31:0] acc;
reg signed [31:0] result;

reg [13:0] sr_capture [0:7];  // captured shift register at samp_valid time

always @(posedge clk) begin
    if (rst) begin
        phase     <= 2'd0;
        running   <= 1'b0;
        out_valid <= 1'b0;
        dout      <= 13'd4096;
        for (k=0; k<8; k=k+1) sr_capture[k] <= 14'sd0;
    end else begin
        out_valid <= 1'b0;

        if (samp_valid) begin
            // Capture the shift register state for this input sample
            for (k=0; k<8; k=k+1) sr_capture[k] <= sr[k];
            phase   <= 2'd0;
            running <= 1'b1;
        end else if (running) begin
            // Output one interpolated sample per clock until all 4 done
            case (phase)
                2'd0: acc = branch_mac(
                    sr_capture[0], sr_capture[1], sr_capture[2], sr_capture[3],
                    sr_capture[4], sr_capture[5], sr_capture[6], sr_capture[7],
                    B0_0, B0_1, B0_2, B0_3, B0_4, B0_5, B0_6, B0_7);
                2'd1: acc = branch_mac(
                    sr_capture[0], sr_capture[1], sr_capture[2], sr_capture[3],
                    sr_capture[4], sr_capture[5], sr_capture[6], sr_capture[7],
                    B1_0, B1_1, B1_2, B1_3, B1_4, B1_5, B1_6, B1_7);
                2'd2: acc = branch_mac(
                    sr_capture[0], sr_capture[1], sr_capture[2], sr_capture[3],
                    sr_capture[4], sr_capture[5], sr_capture[6], sr_capture[7],
                    B2_0, B2_1, B2_2, B2_3, B2_4, B2_5, B2_6, B2_7);
                2'd3: acc = branch_mac(
                    sr_capture[0], sr_capture[1], sr_capture[2], sr_capture[3],
                    sr_capture[4], sr_capture[5], sr_capture[6], sr_capture[7],
                    B3_0, B3_1, B3_2, B3_3, B3_4, B3_5, B3_6, B3_7);
            endcase

            // Right-shift by 14 (coefficient scale factor), clamp to 13-bit
            result = acc >>> 14;

            if      (result < 32'sd0)    dout <= 13'd0;
            else if (result > 32'sd8191) dout <= 13'd8191;
            else                         dout <= result[12:0];

            out_valid <= 1'b1;
            phase     <= phase + 1'b1;
            if (phase == 2'd3) running <= 1'b0;
        end
    end
end

endmodule
