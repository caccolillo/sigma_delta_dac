// =============================================================================
// sine_gen.v  (v4 — 5-frequency sweep, 6 exact cycles per frequency)
// =============================================================================
// Sweeps through 5 voice-band test frequencies, playing exactly 6 complete
// LUT cycles of each before advancing to the next frequency.
//
// Test frequencies (8 kHz sample rate, 256-entry LUT):
//   Index 0 : 312.5 Hz  (phase_inc=10)  — near HPF cutoff
//   Index 1 : 1000.0 Hz (phase_inc=32)  — ITU standard test tone
//   Index 2 : 2000.0 Hz (phase_inc=64)  — upper midband
//   Index 3 : 3000.0 Hz (phase_inc=96)  — near LPF cutoff
//   Index 4 : 3375.0 Hz (phase_inc=108) — near 3.4 kHz band edge
//
// Dwell calculation: 6 cycles = 6 * (LUT_SIZE / gcd(LUT_SIZE, phase_inc)) samples
//   312.5 Hz: gcd(256,10)=2  -> 256/2=128 samples/cycle -> 6*128 = 768 samples
//   1000  Hz: gcd(256,32)=32 -> 256/32=8 samples/cycle  -> 6*8   = 48  samples
//   2000  Hz: gcd(256,64)=64 -> 256/64=4 samples/cycle  -> 6*4   = 24  samples
//   3000  Hz: gcd(256,96)=32 -> 256/32=8 samples/cycle  -> 6*8   = 48  samples
//   3375  Hz: gcd(256,108)=4 -> 256/4=64 samples/cycle  -> 6*64  = 384 samples
//
// Phase is reset to 0 at each frequency transition so there are no
// phase discontinuities relative to the new frequency's LUT.
//
// Clock: 100 MHz | Sample rate: 8 kHz (one sample every 12500 clocks)
// =============================================================================

module sine_gen (
    input  wire        clk,
    input  wire        rst,
    output reg  [12:0] sample,       // 13-bit unsigned PCM (0..8191)
    output reg         sample_valid, // pulses high for one clock at 8 kHz
    output reg  [2:0]  freq_idx      // 0..4, current frequency index
);

// =============================================================================
// 256-entry sine LUT
// =============================================================================
reg [12:0] sine_lut [0:255];
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1)
        sine_lut[i] = $rtoi(4096.0 + 4095.0 *
                      $sin(2.0 * 3.14159265358979 * i / 256.0));
end

// =============================================================================
// Frequency table
// =============================================================================
// phase_inc: LUT phase increment per sample
reg [7:0] inc_table [0:4];
initial begin
    inc_table[0] = 8'd10;    // 312.5 Hz
    inc_table[1] = 8'd32;    // 1000.0 Hz
    inc_table[2] = 8'd64;    // 2000.0 Hz
    inc_table[3] = 8'd96;    // 3000.0 Hz
    inc_table[4] = 8'd108;   // 3375.0 Hz
end

// dwell_table: number of 8kHz samples for exactly 6 complete LUT cycles
// = 6 * (256 / gcd(256, phase_inc))
reg [9:0] dwell_table [0:4];
initial begin
    dwell_table[0] = 10'd768;   // 312.5 Hz : 6 * 128 = 768
    dwell_table[1] = 10'd48;    // 1000  Hz : 6 * 8   = 48
    dwell_table[2] = 10'd24;    // 2000  Hz : 6 * 4   = 24
    dwell_table[3] = 10'd48;    // 3000  Hz : 6 * 8   = 48
    dwell_table[4] = 10'd384;   // 3375  Hz : 6 * 64  = 384
end

// =============================================================================
// 8 kHz clock divider
// =============================================================================
// 100 MHz / 8 kHz = 12500 clocks per sample

localparam DIV = 13'd12500;

reg [13:0] div_ctr;

always @(posedge clk) begin
    if (rst) begin
        div_ctr      <= 14'd0;
        sample_valid <= 1'b0;
    end else begin
        if (div_ctr == DIV - 1) begin
            div_ctr      <= 14'd0;
            sample_valid <= 1'b1;
        end else begin
            div_ctr      <= div_ctr + 1'b1;
            sample_valid <= 1'b0;
        end
    end
end

// =============================================================================
// Frequency sequencer and LUT output
// =============================================================================

reg [7:0]  phase;        // current LUT phase (0..255)
reg [9:0]  samp_ctr;     // counts samples played for current frequency

always @(posedge clk) begin
    if (rst) begin
        freq_idx <= 3'd0;
        phase    <= 8'd0;
        samp_ctr <= 10'd0;
        sample   <= 13'd4096;
    end else if (sample_valid) begin

        // Output current LUT value
        sample <= sine_lut[phase];

        // Advance LUT phase
        phase <= phase + inc_table[freq_idx];

        // Advance sample counter and check for end of dwell
        if (samp_ctr == dwell_table[freq_idx] - 1) begin
            // Move to next frequency, reset phase and counter
            samp_ctr <= 10'd0;
            phase    <= 8'd0;   // reset phase cleanly at boundary
            if (freq_idx == 3'd4)
                freq_idx <= 3'd0;   // wrap back to first frequency
            else
                freq_idx <= freq_idx + 1'b1;
        end else begin
            samp_ctr <= samp_ctr + 1'b1;
        end

    end
end

endmodule
