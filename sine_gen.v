// =============================================================================
// sine_gen.v — simple single-frequency sine generator
// Generic FREQ_HZ sets the output frequency
// Sample rate: 8 kHz (one sample every 12500 clocks at 100 MHz)
// Output: 13-bit signed PCM (-2047 to +2047), centred on zero
// =============================================================================

module sine_gen #(
    parameter FREQ_HZ   = 1000,     // output frequency in Hz
    parameter LUT_SIZE  = 256,      // sine LUT entries
    parameter CLK_HZ    = 100000000,// system clock frequency
    parameter SAMP_HZ   = 8000      // audio sample rate
)(
    input  wire        clk,
    input  wire        rst,
    output reg  [12:0] sample,        // 13-bit signed PCM
    output reg         sample_valid   // one clock pulse at SAMP_HZ rate
);

// =============================================================================
//  SINE LUT — 256 entries, signed 13-bit, amplitude 2047
// =============================================================================
reg signed [12:0] sine_lut [0:LUT_SIZE-1];
integer i;
integer val;
initial begin
    for (i = 0; i < LUT_SIZE; i = i + 1) begin
        val = $rtoi(2047.0 * $sin(2.0 * 3.14159265358979323846 * i / LUT_SIZE));
        sine_lut[i] = val[12:0];
    end
end

// =============================================================================
//  8 kHz CLOCK DIVIDER
//  100 MHz / 8 kHz = 12500 clocks per sample
// =============================================================================
localparam [31:0] DIV = CLK_HZ / SAMP_HZ;   // = 12500

reg [31:0] div_ctr;

always @(posedge clk) begin
    if (rst) begin
        div_ctr      <= 32'd0;
        sample_valid <= 1'b0;
    end else begin
        if (div_ctr == DIV - 1) begin
            div_ctr      <= 32'd0;
            sample_valid <= 1'b1;
        end else begin
            div_ctr      <= div_ctr + 32'd1;
            sample_valid <= 1'b0;
        end
    end
end

// =============================================================================
//  PHASE ACCUMULATOR
//  phase_inc = LUT_SIZE * FREQ_HZ / SAMP_HZ
//  Kept as a fixed integer — frequency resolution = SAMP_HZ / LUT_SIZE
//  = 8000 / 256 = 31.25 Hz per LUT step
//
//  Examples at 8 kHz / 256-entry LUT:
//    440  Hz : phase_inc = round(256 * 440  / 8000) = round(14.08) = 14
//              actual    = 14 * 8000 / 256 = 437.5 Hz
//    1000 Hz : phase_inc = round(256 * 1000 / 8000) = 32
//              actual    = 32 * 8000 / 256 = 1000.0 Hz  (exact)
//    3000 Hz : phase_inc = round(256 * 3000 / 8000) = 96
//              actual    = 96 * 8000 / 256 = 3000.0 Hz  (exact)
// =============================================================================
localparam [7:0] PHASE_INC = (LUT_SIZE * FREQ_HZ + SAMP_HZ/2) / SAMP_HZ;

reg [7:0] phase;

always @(posedge clk) begin
    if (rst) begin
        phase  <= 8'd0;
        sample <= 13'd0;
    end else if (sample_valid) begin
        sample <= sine_lut[phase];
        phase  <= phase + PHASE_INC;
    end
end

endmodule
