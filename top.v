// =============================================================================
// top.v
// Top-level: sine generator + sigma-delta DAC
// =============================================================================

module top (
    input  wire clk,
    input  wire rst,
    output wire dout
);

wire [12:0] sample;
wire        sample_valid;

sine_gen u_sine_gen (
    .clk          (clk),
    .rst          (rst),
    .sample       (sample),
    .sample_valid (sample_valid)
);

sd_dac_8k u_sd_dac (
    .clk        (clk),
    .rst        (rst),
    .samp_valid (sample_valid),
    .din        (sample),
    .dout       (dout)
);

endmodule
