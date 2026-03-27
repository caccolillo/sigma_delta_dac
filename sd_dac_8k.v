// =============================================================================
// sd_dac_8k.v  (v4 - fixed linear interpolation)
// 13-bit 4th-order MASH 1-1-1-1 Sigma-Delta DAC
//
// Linear interpolation: counter-based, no fixed-point arithmetic.
//   Each 8kHz period the delta (new-old) is computed once.
//   A 14-bit error accumulator adds |delta| every clock.
//   When it overflows 12500 the integer output steps by +/-1.
//   This is a Bresenham-style line algorithm - exact, no rounding error,
//   no bit-width issues, synthesises to ~30 LUTs.
//
// PRBS dither: 16-bit LFSR, 1 LSB, breaks idle tones.
// MASH 1-1-1-1: 4th order, unconditionally stable.
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
// Ramps the output from prev_s to curr_s over exactly 12500 clock cycles.
// Algorithm:
//   err accumulates |delta| each cycle
//   when err >= 12500, subtract 12500 and step the output by sign(delta)
// This is integer-exact with no fixed-point approximation errors.

reg [12:0] curr_s, prev_s;
reg [12:0] interp;          // current interpolated value (integer, no fraction)
reg [13:0] bres_err;        // Bresenham error accumulator (range 0..24999)
reg [12:0] bres_delta_abs;  // |curr_s - prev_s|
reg        bres_dir;        // 1 = ramping up, 0 = ramping down
reg        bres_active;     // high when delta != 0

always @(posedge clk) begin
    if (rst) begin
        curr_s      <= 13'd4096;
        prev_s      <= 13'd4096;
        interp      <= 13'd4096;
        bres_err    <= 14'd0;
        bres_delta_abs <= 13'd0;
        bres_dir    <= 1'b0;
        bres_active <= 1'b0;
    end else if (samp_valid) begin
        // Latch new sample, compute delta
        prev_s      <= curr_s;
        curr_s      <= din;
        interp      <= curr_s;   // start ramp from current (will ramp to din)
        bres_err    <= 14'd0;
        bres_dir    <= (din >= curr_s);
        bres_active <= (din != curr_s);
        bres_delta_abs <= (din >= curr_s) ? (din - curr_s) : (curr_s - din);
    end else if (bres_active) begin
        bres_err <= bres_err + {1'b0, bres_delta_abs};
        if (bres_err + {1'b0, bres_delta_abs} >= 14'd12500) begin
            bres_err <= bres_err + {1'b0, bres_delta_abs} - 14'd12500;
            if (bres_dir) begin
                interp <= (interp < 13'd8191) ? interp + 1'b1 : 13'd8191;
            end else begin
                interp <= (interp > 13'd0)    ? interp - 1'b1 : 13'd0;
            end
        end
    end
end

// =============================================================================
// 2. PRBS DITHER - 16-bit maximal LFSR
// =============================================================================
// Polynomial: x^16 + x^15 + x^13 + x^4 + 1   period = 65535

reg [15:0] lfsr;
always @(posedge clk) begin
    if (rst) lfsr <= 16'hACE1;
    else     lfsr <= {lfsr[0] ^ lfsr[2] ^ lfsr[12] ^ lfsr[15],
                      lfsr[15:1]};
end

// Add 0 or 1 LSB, saturate at 8191
wire [13:0] dith_sum = {1'b0, interp} + {13'b0, lfsr[0]};
wire [12:0] din_mod  = dith_sum[13] ? 13'd8191 : dith_sum[12:0];

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