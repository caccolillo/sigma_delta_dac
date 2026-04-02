// =============================================================================
// top.v  (v3 - with 4x interpolation)
// =============================================================================
// Signal chain:
//   sine_gen (8kHz) -> interp4x (32kHz) -> sd_dac_8k (100MHz PDM)
// =============================================================================

module top (
    input  wire clk,
    input  wire rst,
    output wire dout
);

wire [12:0] sine_sample;
wire        sine_valid;
wire [3:0]  freq_idx;

wire [12:0] interp_sample;
wire        interp_valid;

sine_gen u_sine_gen (
    .clk          (clk),
    .rst          (rst),
    .sample       (sine_sample),
    .sample_valid (sine_valid),
    .freq_idx     (freq_idx)
);

interp4x u_interp (
    .clk        (clk),
    .rst        (rst),
    .samp_valid (sine_valid),
    .din        (sine_sample),
    .out_valid  (interp_valid),
    .dout       (interp_sample)
);

sd_dac_8k u_dac (
    .clk        (clk),
    .rst        (rst),
    .samp_valid (interp_valid),
    .din        (interp_sample),
    .dout       (dout)
);

endmodule
