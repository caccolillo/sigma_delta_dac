// =============================================================================
// sd_dac_8k.v  (v6 - 32kHz internal rate via 4x interpolation)
// =============================================================================
// Changes from v5:
//   - Bresenham divider changed from 12500 to 3125 (100MHz / 32kHz)
//   - Input is now 32kHz interpolated samples from interp4x.v
//   - All other logic unchanged
//   - OSR unchanged: 100MHz / (2 x 3.4kHz) = 14706
//   - Samples per cycle at 1kHz: 32 (was 8) -> dips eliminated
// =============================================================================

module sd_dac_8k (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,    // 32 kHz strobe (from interp4x out_valid)
    input  wire [12:0] din,           // 13-bit interpolated input
    output reg         dout
);

// =============================================================================
// 1. LINEAR INTERPOLATION - Bresenham accumulator
// =============================================================================
// Divider updated to 3125 (100MHz / 32kHz)

reg [12:0] curr_s, prev_s;
reg [12:0] interp;
reg [11:0] bres_err;        // 12-bit: range 0..6249 (< 2*3125)
reg [12:0] bres_delta_abs;
reg        bres_dir;
reg        bres_active;

always @(posedge clk) begin
    if (rst) begin
        curr_s         <= 13'd4096;
        prev_s         <= 13'd4096;
        interp         <= 13'd4096;
        bres_err       <= 12'd0;
        bres_delta_abs <= 13'd0;
        bres_dir       <= 1'b0;
        bres_active    <= 1'b0;
    end else if (samp_valid) begin
        prev_s         <= curr_s;
        curr_s         <= din;
        interp         <= curr_s;
        bres_err       <= 12'd0;
        bres_dir       <= (din >= curr_s);
        bres_active    <= (din != curr_s);
        bres_delta_abs <= (din >= curr_s) ? (din - curr_s)
                                          : (curr_s - din);
    end else if (bres_active) begin
        if (bres_err + {1'b0, bres_delta_abs[11:0]} >= 12'd3125) begin
            bres_err <= bres_err + bres_delta_abs[11:0] - 12'd3125;
            if (bres_dir)
                interp <= (interp < 13'd8191) ? interp + 1'b1 : 13'd8191;
            else
                interp <= (interp > 13'd0)    ? interp - 1'b1 : 13'd0;
        end else begin
            bres_err <= bres_err + bres_delta_abs[11:0];
        end
    end
end

// =============================================================================
// 2. DUAL LFSR TPDF DITHER (unchanged from v5)
// =============================================================================

reg [15:0] lfsr_a;
reg [16:0] lfsr_b;

always @(posedge clk) begin
    if (rst) begin
        lfsr_a <= 16'hACE1;
        lfsr_b <= 17'h1F351;
    end else begin
        lfsr_a <= {lfsr_a[0]^lfsr_a[2]^lfsr_a[12]^lfsr_a[15], lfsr_a[15:1]};
        lfsr_b <= {lfsr_b[0]^lfsr_b[3]^lfsr_b[14]^lfsr_b[15]^lfsr_b[16],
                   lfsr_b[16:1]};
    end
end

wire signed [13:0] tpdf     = $signed({13'b0, lfsr_a[0]})
                             - $signed({13'b0, lfsr_b[0]});
wire signed [13:0] dith_sum = $signed({1'b0, interp}) + tpdf;
wire        [12:0] din_mod  = (dith_sum < $signed(14'd0))   ? 13'd0    :
                              (dith_sum > $signed(14'd8191)) ? 13'd8191 :
                               dith_sum[12:0];

// Uncomment to disable dither for testing:
// wire [12:0] din_mod = interp;

// =============================================================================
// 3. MASH 1-1-1-1 (unchanged)
// =============================================================================

reg [13:0] acc1, acc2, acc3, acc4;
reg        c1, c2, c3, c4;
reg        c2_d;
reg        c3_d,  c3_dd;
reg        c4_d,  c4_dd, c4_ddd;
reg signed [4:0] comb;

always @(posedge clk) begin
    if (rst) begin
        acc1  <= 14'd0; acc2  <= 14'd0;
        acc3  <= 14'd0; acc4  <= 14'd0;
        c1    <= 1'b0;  c2    <= 1'b0;
        c3    <= 1'b0;  c4    <= 1'b0;
        c2_d  <= 1'b0;
        c3_d  <= 1'b0;  c3_dd  <= 1'b0;
        c4_d  <= 1'b0;  c4_dd  <= 1'b0; c4_ddd <= 1'b0;
        comb  <= 5'sd0;
        dout  <= 1'b0;
    end else begin
        {c1, acc1[12:0]} <= acc1[12:0] + din_mod;
        {c2, acc2[12:0]} <= acc2[12:0] + (~acc1[12:0] + 1'b1);
        {c3, acc3[12:0]} <= acc3[12:0] + (~acc2[12:0] + 1'b1);
        {c4, acc4[12:0]} <= acc4[12:0] + (~acc3[12:0] + 1'b1);

        c2_d  <= c2;
        c3_d  <= c3;  c3_dd  <= c3_d;
        c4_d  <= c4;  c4_dd  <= c4_d;  c4_ddd <= c4_dd;

        comb <=   $signed({4'b0000, c1})
                + $signed({4'b0000, c2})   - $signed({4'b0000, c2_d})
                + $signed({4'b0000, c3})   - $signed({3'b000,  c3_d,  1'b0})
                                           + $signed({4'b0000, c3_dd})
                + $signed({4'b0000, c4})   - $signed({2'b00,   c4_d,  2'b00})
                                           + $signed({3'b000,  c4_dd, 1'b0})
                                           - $signed({4'b0000, c4_ddd});

        dout <= (comb > 5'sd0) ? 1'b1 : 1'b0;
    end
end

endmodule
