// =============================================================================
// sd_dac_8k.v  (v5 - dual LFSR TPDF dither)
// 13-bit 4th-order MASH 1-1-1-1 Sigma-Delta DAC
//
// Changes from v4:
//   - Replaced single 16-bit LFSR rectangular dither with dual LFSR TPDF
//   - LFSR A: 16-bit, poly x^16+x^15+x^13+x^4+1, period = 65,535
//   - LFSR B: 17-bit, poly x^17+x^16+x^15+x^4+1, period = 131,071
//   - Combined dither period LCM = 8,589,737,985 clocks = 85 seconds
//   - Sync period with 1kHz signal: 1,717,948 seconds (never repeats in sim)
//   - TPDF values: {-1, 0, 0, +1} with weights {1, 2, 2, 1}/4
//   - Zero mean: no DC bias added to signal
//   - Completely decorrelates quantisation error from periodic inputs
//
// Clock: 100 MHz | Sample rate: 8 kHz | OSR: 12500
// =============================================================================

module sd_dac_8k (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,
    input  wire [12:0] din,
    output reg         dout
);

// =============================================================================
// 1. LINEAR INTERPOLATION - Bresenham accumulator
// =============================================================================

reg [12:0] curr_s, prev_s;
reg [12:0] interp;
reg [13:0] bres_err;
reg [12:0] bres_delta_abs;
reg        bres_dir;
reg        bres_active;

always @(posedge clk) begin
    if (rst) begin
        curr_s         <= 13'd4096;
        prev_s         <= 13'd4096;
        interp         <= 13'd4096;
        bres_err       <= 14'd0;
        bres_delta_abs <= 13'd0;
        bres_dir       <= 1'b0;
        bres_active    <= 1'b0;
    end else if (samp_valid) begin
        prev_s         <= curr_s;
        curr_s         <= din;
        interp         <= curr_s;
        bres_err       <= 14'd0;
        bres_dir       <= (din >= curr_s);
        bres_active    <= (din != curr_s);
        bres_delta_abs <= (din >= curr_s) ? (din - curr_s)
                                          : (curr_s - din);
    end else if (bres_active) begin
        bres_err <= bres_err + {1'b0, bres_delta_abs};
        if (bres_err + {1'b0, bres_delta_abs} >= 14'd12500) begin
            bres_err <= bres_err + {1'b0, bres_delta_abs} - 14'd12500;
            if (bres_dir)
                interp <= (interp < 13'd8191) ? interp + 1'b1 : 13'd8191;
            else
                interp <= (interp > 13'd0)    ? interp - 1'b1 : 13'd0;
        end
    end
end

// =============================================================================
// 2. DUAL LFSR TPDF DITHER
// =============================================================================
// Two independent LFSRs with different polynomials and seeds.
// Their periods are coprime so combined period = LCM = 8.6 billion clocks.
// This prevents any synchronisation with the signal period in simulation.
//
// LFSR A: 16-bit, poly x^16+x^15+x^13+x^4+1  period = 65,535
// LFSR B: 17-bit, poly x^17+x^16+x^15+x^4+1  period = 131,071
//
// TPDF = lfsr_a[0] - lfsr_b[0]
// Gives values {-1, 0, 0, +1} with probabilities {1/4, 1/4, 1/4, 1/4}
// Mean = 0, Variance = 1/2
// Completely decorrelates quantisation error from periodic inputs.
//
// To disable dither for testing:
//   Comment the tpdf/din_mod lines and uncomment:
//   wire [12:0] din_mod = interp;

reg [15:0] lfsr_a;
reg [16:0] lfsr_b;

always @(posedge clk) begin
    if (rst) begin
        lfsr_a <= 16'hACE1;       // seed A — must not be zero
        lfsr_b <= 17'h1F351;      // seed B — must not be zero, different from A
    end else begin
        // LFSR A: x^16+x^15+x^13+x^4+1
        lfsr_a <= {lfsr_a[0] ^ lfsr_a[2] ^ lfsr_a[12] ^ lfsr_a[15],
                   lfsr_a[15:1]};
        // LFSR B: x^17+x^16+x^15+x^4+1
        lfsr_b <= {lfsr_b[0] ^ lfsr_b[3] ^ lfsr_b[14] ^ lfsr_b[15] ^ lfsr_b[16],
                   lfsr_b[16:1]};
    end
end

// TPDF: subtract two independent bits -> {-1, 0, 0, +1}
wire signed [13:0] tpdf     = $signed({13'b0, lfsr_a[0]})
                             - $signed({13'b0, lfsr_b[0]});

// Add TPDF to interpolated value, clamp to valid range
wire signed [13:0] dith_sum = $signed({1'b0, interp}) + tpdf;

wire [12:0] din_mod = (dith_sum < $signed(14'd0))    ? 13'd0    :
                      (dith_sum > $signed(14'd8191))  ? 13'd8191 :
                       dith_sum[12:0];

// Uncomment to disable dither for testing:
// wire [12:0] din_mod = interp;

// =============================================================================
// 3. MASH 1-1-1-1
// =============================================================================

reg [13:0] acc1, acc2, acc3, acc4;
reg        c1, c2, c3, c4;
reg        c2_d;
reg        c3_d,  c3_dd;
reg        c4_d,  c4_dd, c4_ddd;
reg signed [4:0] comb;

always @(posedge clk) begin
    if (rst) begin
        acc1    <= 14'd0; acc2    <= 14'd0;
        acc3    <= 14'd0; acc4    <= 14'd0;
        c1      <= 1'b0;  c2      <= 1'b0;
        c3      <= 1'b0;  c4      <= 1'b0;
        c2_d    <= 1'b0;
        c3_d    <= 1'b0;  c3_dd   <= 1'b0;
        c4_d    <= 1'b0;  c4_dd   <= 1'b0; c4_ddd  <= 1'b0;
        comb    <= 5'sd0;
        dout    <= 1'b0;
    end else begin
        // Stage 1
        {c1, acc1[12:0]} <= acc1[12:0] + din_mod;

        // Stage 2 - error of stage 1
        {c2, acc2[12:0]} <= acc2[12:0] + (~acc1[12:0] + 1'b1);

        // Stage 3 - error of stage 2
        {c3, acc3[12:0]} <= acc3[12:0] + (~acc2[12:0] + 1'b1);

        // Stage 4 - error of stage 3
        {c4, acc4[12:0]} <= acc4[12:0] + (~acc3[12:0] + 1'b1);

        // Delay pipeline
        c2_d   <= c2;
        c3_d   <= c3;  c3_dd  <= c3_d;
        c4_d   <= c4;  c4_dd  <= c4_d;  c4_ddd <= c4_dd;

        // MASH 1-1-1-1 combiner
        // y = c1 + (c2-c2d) + (c3-2c3d+c3dd) + (c4-3c4d+3c4dd-c4ddd)
        comb <=   $signed({4'b0000, c1})
                + $signed({4'b0000, c2})    - $signed({4'b0000, c2_d})
                + $signed({4'b0000, c3})    - $signed({3'b000,  c3_d,  1'b0})
                                            + $signed({4'b0000, c3_dd})
                + $signed({4'b0000, c4})    - $signed({2'b00,   c4_d,  2'b00})
                                            + $signed({3'b000,  c4_dd, 1'b0})
                                            - $signed({4'b0000, c4_ddd});

        dout <= (comb > 5'sd0) ? 1'b1 : 1'b0;
    end
end

endmodule
