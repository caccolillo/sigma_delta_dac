// =============================================================================
// sigma_delta_headset_test.v
// Top-level for QSPICE — contains sine generator + sigma-delta DAC integrated
//
// Ports match QSPICE schematic:
//   clk     : 100 MHz clock from V3
//   rst     : active-high reset from V9
//   out_bit : 1-bit PDM output → E1 controlled voltage source → RC filter
//
// Internal:
//   - sine_gen produces 13-bit signed audio at 8 kHz sample rate
//   - sd_dac modulates to 1-bit PDM at 5 MHz (OSR=625)
//   - All wiring done inside Verilog — no QSPICE intermediate signals
// =============================================================================

module sigma_delta_headset_test (
    input  wire clk,        // 100 MHz
    input  wire rst,        // active-high reset
    output wire out_bit     // PDM output to E1
);

    // ----------------------------------------------------------------
    //  INTERNAL WIRING between sine_gen and sd_dac
    // ----------------------------------------------------------------
    wire [12:0] din_internal;
    wire        samp_valid_internal;

    // ----------------------------------------------------------------
    //  SINE GENERATOR — 1 kHz at 8 kHz sample rate
    // ----------------------------------------------------------------
    sine_gen u_sine (
        .clk          (clk),
        .rst          (rst),
        .sample       (din_internal),
        .sample_valid (samp_valid_internal)
    );

    // ----------------------------------------------------------------
    //  SIGMA-DELTA DAC
    // ----------------------------------------------------------------
    sd_dac u_dac (
        .clk        (clk),
        .rst        (rst),
        .samp_valid (samp_valid_internal),
        .din        (din_internal),
        .dout       (out_bit)
    );

endmodule


// =============================================================================
// sine_gen — 1 kHz signed sine at 8 kHz sample rate
//   Output: 13-bit two's complement, range -2047..+2047
//   Uses hardcoded 8-entry LUT (no $sin/$rtoi for Verilator robustness)
//   8 samples × 8 kHz / 8 = 1000 Hz output frequency
// =============================================================================
module sine_gen (
    input  wire        clk,
    input  wire        rst,
    output reg  [12:0] sample,
    output reg         sample_valid
);

    // ----------------------------------------------------------------
    //  Hardcoded 8-entry sine LUT, 13-bit signed, amplitude 2047
    //  i=0:  0
    //  i=1: +1448
    //  i=2: +2047
    //  i=3: +1448
    //  i=4:  0
    //  i=5: -1448
    //  i=6: -2047
    //  i=7: -1448
    //  Stored as 13-bit two's complement
    // ----------------------------------------------------------------
    reg signed [12:0] lut [0:7];
    initial begin
        lut[0] =  13'sd0;
        lut[1] =  13'sd1448;
        lut[2] =  13'sd2047;
        lut[3] =  13'sd1448;
        lut[4] =  13'sd0;
        lut[5] = -13'sd1448;
        lut[6] = -13'sd2047;
        lut[7] = -13'sd1448;
    end

    // ----------------------------------------------------------------
    //  8 kHz sample tick: 100 MHz / 8 kHz = 12500 clocks
    // ----------------------------------------------------------------
    reg [13:0] div_cnt;

    always @(posedge clk) begin
        if (rst) begin
            div_cnt      <= 14'd0;
            sample_valid <= 1'b0;
        end else begin
            if (div_cnt == 14'd12499) begin
                div_cnt      <= 14'd0;
                sample_valid <= 1'b1;
            end else begin
                div_cnt      <= div_cnt + 14'd1;
                sample_valid <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    //  LUT phase advancer
    // ----------------------------------------------------------------
    reg [2:0] phase;

    always @(posedge clk) begin
        if (rst) begin
            phase  <= 3'd0;
            sample <= 13'sd0;
        end else if (sample_valid) begin
            sample <= lut[phase];
            phase  <= phase + 3'd1;
        end
    end

endmodule


// =============================================================================
// sd_dac — 2nd order CIFB sigma-delta modulator
//   100 MHz clk → 5 MHz SDM rate (CLK_DIV=20)
//   13-bit signed input, 1-bit PDM output
//   Coefficients from Delta-Sigma Toolbox, Q13 fixed-point
// =============================================================================
module sd_dac (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,
    input  wire [12:0] din,
    output reg         dout
);

    localparam signed [31:0] B1 =  32'sd25564;
    localparam signed [31:0] A1 =  32'sd25564;
    localparam signed [31:0] C1 =  32'sd437;
    localparam signed [31:0] A2 =  32'sd610;

    localparam signed [31:0] ACC_MAX =  32'sd524287;
    localparam signed [31:0] ACC_MIN = -32'sd524288;

    // ----------------------------------------------------------------
    //  CLOCK DIVIDER — 100 MHz → 5 MHz enable
    // ----------------------------------------------------------------
    reg [4:0] clk_cnt;
    reg       sdm_en;

    always @(posedge clk) begin
        if (rst) begin
            clk_cnt <= 5'd0;
            sdm_en  <= 1'b0;
        end else begin
            if (clk_cnt == 5'd19) begin
                clk_cnt <= 5'd0;
                sdm_en  <= 1'b1;
            end else begin
                clk_cnt <= clk_cnt + 5'd1;
                sdm_en  <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    //  INPUT LATCH on samp_valid
    // ----------------------------------------------------------------
    reg signed [31:0] u_reg;

    always @(posedge clk) begin
        if (rst)
            u_reg <= 32'sd0;
        else if (samp_valid)
            u_reg <= {{19{din[12]}}, din};
    end

    // ----------------------------------------------------------------
    //  INTEGRATORS
    // ----------------------------------------------------------------
    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    wire dout_next;
    assign dout_next = (int2_reg >= 32'sd0) ? 1'b1 : 1'b0;

    wire signed [31:0] fb_A1;
    wire signed [31:0] fb_A2;
    assign fb_A1 = dout_next ?  A1 : -A1;
    assign fb_A2 = dout_next ?  A2 : -A2;

    wire signed [63:0] B1u_64;
    wire signed [31:0] B1u;
    assign B1u_64 = $signed(B1) * $signed(u_reg);
    assign B1u    = B1u_64[43:12];

    wire signed [63:0] C1x_64;
    wire signed [31:0] C1x;
    assign C1x_64 = $signed(C1) * $signed(int1_reg);
    assign C1x    = C1x_64[44:13];

    wire signed [31:0] sum1_raw;
    wire signed [31:0] sum2_raw;
    assign sum1_raw = int1_reg + B1u - fb_A1;
    assign sum2_raw = int2_reg + C1x - fb_A2;

    // ----------------------------------------------------------------
    //  REGISTERED UPDATE
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 32'sd0;
            int2_reg <= 32'sd0;
            dout     <= 1'b0;
        end else if (sdm_en) begin
            if (sum1_raw > ACC_MAX)
                int1_reg <= ACC_MAX;
            else if (sum1_raw < ACC_MIN)
                int1_reg <= ACC_MIN;
            else
                int1_reg <= sum1_raw;

            if (sum2_raw > ACC_MAX)
                int2_reg <= ACC_MAX;
            else if (sum2_raw < ACC_MIN)
                int2_reg <= ACC_MIN;
            else
                int2_reg <= sum2_raw;

            dout <= dout_next;
        end
    end

endmodule
