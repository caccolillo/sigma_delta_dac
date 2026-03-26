// =============================================================================
// sine_gen.v
// Sine wave generator: 256-entry LUT, 8 kHz sample rate, 100 MHz clock
// Frequency range: 300 Hz to 3400 Hz (G.711 voice band)
//
// Phase increment = FREQ_HZ * 256 / 8000 (rounded)
// Frequency resolution: 31.25 Hz per increment step
//
// Frequency table:
//   300 Hz  -> PHASE_INC = 10  (actual 312.5 Hz)
//   500 Hz  -> PHASE_INC = 16  (actual 500.0 Hz)
//   1000 Hz -> PHASE_INC = 32  (actual 1000.0 Hz)
//   1500 Hz -> PHASE_INC = 48  (actual 1500.0 Hz)
//   2000 Hz -> PHASE_INC = 64  (actual 2000.0 Hz)
//   2500 Hz -> PHASE_INC = 80  (actual 2500.0 Hz)
//   3000 Hz -> PHASE_INC = 96  (actual 3000.0 Hz)
//   3400 Hz -> PHASE_INC = 109 (actual 3406.3 Hz)
// =============================================================================

module sine_gen (
    input  wire        clk,
    input  wire        rst,
    output reg  [12:0] sample,
    output reg         sample_valid
);

// ── Frequency control ─────────────────────────────────────────────────────────
localparam FREQ_HZ   = 1000;                           // <-- set frequency here
localparam PHASE_INC = (FREQ_HZ * 256 + 4000) / 8000; // rounded integer division
// ─────────────────────────────────────────────────────────────────────────────

// Sine lookup table: 256 entries, 13-bit unsigned (0-8191, mid-scale = 4096)
reg [12:0] sine_lut [0:255];
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1)
        sine_lut[i] = $rtoi(4096.0 + 4095.0 * $sin(2.0 * 3.14159265358979 * i / 256.0));
end

// Sample valid strobe: divide 100 MHz down to 8 kHz
// 100_000_000 / 8_000 = 12500 cycles per sample
reg [13:0] div_ctr;   // 14 bits holds up to 16383

always @(posedge clk) begin
    if (rst) begin
        div_ctr      <= 14'd0;
        sample_valid <= 1'b0;
    end else begin
        if (div_ctr == 14'd12499) begin
            div_ctr      <= 14'd0;
            sample_valid <= 1'b1;
        end else begin
            div_ctr      <= div_ctr + 1'b1;
            sample_valid <= 1'b0;
        end
    end
end

// Sine table read: advance phase by PHASE_INC on each valid strobe
reg [7:0] phase;

always @(posedge clk) begin
    if (rst) begin
        phase  <= 8'd0;
        sample <= 13'd4096;
    end else if (sample_valid) begin
        sample <= sine_lut[phase];
        phase  <= phase + PHASE_INC[7:0];   // wraps naturally at 256
    end
end

endmodule
