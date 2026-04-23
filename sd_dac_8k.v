// =============================================================================
//  sd_dac.v  –  2nd-Order Sigma-Delta Modulator DAC
// =============================================================================
//  Architecture : MASH-1-1  (cascaded 1st-order stages = true 2nd-order noise
//                 shaping), running at 5 MHz PDM output rate.
//
//  Clock plan
//  ----------
//    clk        : 100 MHz system clock
//    samp_valid : 8 kHz strobe – new 13-bit sample on din is valid
//    PDM clock  : 100 MHz / 20 = 5 MHz  (over-sampling ratio = 5M/8k = 625)
//
//  Signal chain
//  ------------
//    din[12:0] → ZOH hold → 2nd-order Σ-Δ → dout (PDM)
//    dout → external RC + dual Sallen-Key LPF → audio voltage 0 V – 3.3 V
//
//  Accumulator widths
//  ------------------
//    The 13-bit input sample is treated as an unsigned value (0 … 8191).
//    Two 14-bit accumulators are used so carry/overflow arithmetic is clean
//    and the MSB naturally captures the 1-bit quantiser output.
//
//  Noise shaping  (why 2nd order?)
//  --------------------------------
//    1st-order Σ-Δ  →  quantisation noise shaped at 20 dB/decade.
//    2nd-order MASH  →  40 dB/decade slope.  Much more noise is pushed above
//    ~20 kHz, which the Sallen-Key filters remove.  Gives ~13-bit effective
//    ENOB in the 300 Hz – 3.4 kHz band with a simple 1-bit PDM output.
//
//  MASH-1-1 equations  (discrete time)
//  ------------------------------------
//    Stage 1:  acc1[n] = acc1[n-1] + x[n]
//              c1[n]   = carry(acc1[n])         (1-bit, MSB overflow)
//              e1[n]   = acc1[n] mod 2^N        (quantisation error)
//
//    Stage 2:  acc2[n] = acc2[n-1] + e1[n]
//              c2[n]   = carry(acc2[n])
//
//    Combined: y[n] = c1[n] + c2[n] - c2[n-1]
//              Range: -1, 0, 1, 2
//              The first-difference cancels Stage-2 signal component,
//              leaving 2nd-order noise shaping on the combined stream.
//
//    A tiny 2-bit carry PDM serialiser converts the multi-level y[n]
//    into the final clean 1-bit dout without adding in-band noise.
// =============================================================================

`timescale 1ns / 1ps

module sd_dac (
    input  wire        clk,        // 100 MHz system clock
    input  wire        rst,        // synchronous, active-high reset
    input  wire        samp_valid, // 8 kHz sample valid strobe
    input  wire [12:0] din,        // 13-bit unsigned sample (0 … 8191)
    output reg         dout        // sigma-delta PDM output at 5 MHz
);

// ---------------------------------------------------------------------------
// 1.  PDM clock enable  –  divide 100 MHz by 20 to get 5 MHz tick
// ---------------------------------------------------------------------------
localparam integer PDM_DIV = 20;

reg [4:0] pdm_cnt;
reg       pdm_en;   // single-cycle enable pulse at the 5 MHz PDM rate

always @(posedge clk) begin
    if (rst) begin
        pdm_cnt <= 5'd0;
        pdm_en  <= 1'b0;
    end else begin
        if (pdm_cnt == PDM_DIV - 1) begin
            pdm_cnt <= 5'd0;
            pdm_en  <= 1'b1;
        end else begin
            pdm_cnt <= pdm_cnt + 1'b1;
            pdm_en  <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// 2.  Sample register  –  zero-order hold (hold until next samp_valid)
// ---------------------------------------------------------------------------
reg [12:0] sample_reg;

always @(posedge clk) begin
    if (rst)
        sample_reg <= 13'd0;
    else if (samp_valid)
        sample_reg <= din;
end

// ---------------------------------------------------------------------------
// 3.  MASH-1-1  2nd-order sigma-delta core
//
//     N = 14-bit accumulators.
//     The 13-bit sample is zero-extended to 14 bits (MSB = 0, range 0…8191).
//     One extra bit (W = 15) is used during addition to capture the carry
//     cleanly without sign-extension ambiguity.
// ---------------------------------------------------------------------------
localparam N = 14;
localparam W = N + 1;   // 15 bits for carry detection

// 14-bit unsigned input word
wire [N-1:0] x = {1'b0, sample_reg};

// --- Stage 1 ---
reg  [N-1:0] acc1;
wire [W-1:0] sum1   = {1'b0, acc1} + {1'b0, x};
wire         c1     = sum1[N];          // quantiser output (carry out)
wire [N-1:0] e1     = sum1[N-1:0];     // residual error fed to Stage 2

// --- Stage 2 ---
reg  [N-1:0] acc2;
wire [W-1:0] sum2   = {1'b0, acc2} + {1'b0, e1};
wire         c2     = sum2[N];
wire [N-1:0] e2     = sum2[N-1:0];     // Stage-2 residual (not forwarded)

// --- First difference of c2  (MASH noise-cancellation) ---
reg c2_d;   // c2 delayed by one PDM cycle

// MASH combined output:  y = c1 + c2 - c2_d  ∈ {-1, 0, 1, 2}
// Use 3-bit signed arithmetic; c1/c2/c2_d are each 0 or 1.
wire signed [2:0] mash_out = $signed({2'b00, c1})
                            + $signed({2'b00, c2})
                            - $signed({2'b00, c2_d});

// ---------------------------------------------------------------------------
// 4.  PDM serialiser
//
//     mash_out is multi-level ({-1,0,1,2}).  Accumulate into a 2-bit carry
//     register; the overflow bit becomes the 1-bit PDM output.
//
//         {carry_out, carry} = carry + mash_out
//         dout               = carry_out
//
//     This is a trivial 1st-order loop that simply serialises the already
//     noise-shaped MASH sequence.  It adds negligible in-band noise because
//     it operates on a signal that is *already* quantised to ±2 levels.
// ---------------------------------------------------------------------------
reg  [1:0] carry;

// Sign-extend mash_out to 3 bits and add to the 2-bit carry (zero-extended).
wire [2:0] ser_sum = {1'b0, carry} + mash_out;   // mash_out is 3-bit signed

// ---------------------------------------------------------------------------
// 5.  Registered logic  (advance Σ-Δ core and output only on pdm_en)
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        acc1  <= {N{1'b0}};
        acc2  <= {N{1'b0}};
        c2_d  <= 1'b0;
        carry <= 2'b00;
        dout  <= 1'b0;
    end else if (pdm_en) begin
        // Update MASH accumulators
        acc1 <= e1;         // acc1 := (acc1 + x) mod 2^N
        acc2 <= e2;         // acc2 := (acc2 + e1) mod 2^N
        c2_d <= c2;         // pipeline delay for first-difference

        // PDM serialiser
        carry <= ser_sum[1:0];
        dout  <= ser_sum[2];  // MSB overflow → PDM bit
    end
end

endmodule
