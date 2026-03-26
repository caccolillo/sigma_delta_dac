// =============================================================================
// sd_dac_8k.v
// 13-bit 3rd-order MASH 1-1-1 Sigma-Delta DAC
// Clock: 100 MHz | Sample rate: 8 kHz | OSR: 12500
// =============================================================================

module sd_dac_8k (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,
    input  wire [12:0] din,
    output reg         dout
);

// Zero-order hold: latch input on valid strobe, hold for 12500 clocks
reg [12:0] held;
always @(posedge clk)
    if (rst)             held <= 13'd4096;   // mid-scale = silence
    else if (samp_valid) held <= din;

// MASH 1-1-1: three cascaded first-order sigma-delta stages
// Accumulators are 14 bits (13-bit data + 1 carry)
reg [13:0] acc1, acc2, acc3;
reg        c1, c2, c3;                      // carry bits must be reg
reg        c2_d, c3_d, c3_dd;              // delay taps for MASH combiner

always @(posedge clk) begin
    if (rst) begin
        acc1  <= 14'd0; acc2  <= 14'd0; acc3  <= 14'd0;
        c1    <= 1'b0;  c2    <= 1'b0;  c3    <= 1'b0;
        c2_d  <= 1'b0;  c3_d  <= 1'b0;  c3_dd <= 1'b0;
        dout  <= 1'b0;
    end else begin
        // Stage 1: accumulate input, capture carry into reg
        {c1, acc1[12:0]} <= acc1[12:0] + held;

        // Stage 2: accumulate quantisation error from stage 1
        {c2, acc2[12:0]} <= acc2[12:0] + (~acc1[12:0] + 1'b1);

        // Stage 3: accumulate quantisation error from stage 2
        {c3, acc3[12:0]} <= acc3[12:0] + (~acc2[12:0] + 1'b1);

        // Delay taps for MASH noise-cancelling combiner
        c2_d  <= c2;
        c3_d  <= c3;
        c3_dd <= c3_d;

        // Full MASH combiner: y = c1 + (c2 - c2_d) + (c3 - 2*c3_d + c3_dd)
        // Produces a signed 3-bit result; requantise to 1-bit
        dout <= (  $signed({2'b00, c1})
                 + $signed({2'b00, c2})  - $signed({2'b00, c2_d})
                 + $signed({2'b00, c3})  - $signed({2'b00, c3_d,  1'b0})
                 + $signed({2'b00, c3_dd})
                ) > $signed(3'b000);
    end
end

endmodule