// =============================================================================
// sine_gen.v  (v3 - 500ms dwell per frequency)
// Dwell increased from 100ms to 500ms to give 4000 samples per segment,
// enough for a 2048-point FFT with good frequency resolution.
// Total simulation: 9 x 500ms = 4.5 seconds = 450,000,000 cycles.
// =============================================================================

module sine_gen (
    input  wire        clk,
    input  wire        rst,
    output reg  [12:0] sample,
    output reg         sample_valid,
    output reg  [3:0]  freq_idx
);

reg [12:0] sine_lut [0:255];
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1)
        sine_lut[i] = $rtoi(4096.0 + 4095.0 *
                      $sin(2.0 * 3.14159265358979 * i / 256.0));
end

reg [7:0] inc_table [0:8];
initial begin
    inc_table[0] = 8'd10;   // 312.5 Hz
    inc_table[1] = 8'd16;   // 500.0 Hz
    inc_table[2] = 8'd26;   // 812.5 Hz
    inc_table[3] = 8'd32;   // 1000.0 Hz
    inc_table[4] = 8'd48;   // 1500.0 Hz
    inc_table[5] = 8'd64;   // 2000.0 Hz
    inc_table[6] = 8'd80;   // 2500.0 Hz
    inc_table[7] = 8'd96;   // 3000.0 Hz
    inc_table[8] = 8'd109;  // 3406.3 Hz
end

// 500ms dwell = 50,000,000 cycles at 100MHz
localparam DWELL = 27'd50_000_000;

reg [26:0] dwell_ctr;
reg [7:0]  phase;
reg [13:0] div_ctr;

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

always @(posedge clk) begin
    if (rst) begin
        freq_idx  <= 4'd0;
        phase     <= 8'd0;
        dwell_ctr <= 27'd0;
        sample    <= 13'd4096;
    end else begin
        if (dwell_ctr == DWELL - 1) begin
            dwell_ctr <= 27'd0;
            phase     <= 8'd0;
            freq_idx  <= (freq_idx == 4'd8) ? 4'd0 : freq_idx + 1'b1;
        end else begin
            dwell_ctr <= dwell_ctr + 1'b1;
        end

        if (sample_valid) begin
            sample <= sine_lut[phase];
            phase  <= phase + inc_table[freq_idx];
        end
    end
end

endmodule
