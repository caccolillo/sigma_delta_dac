// =============================================================================
// sigma_delta_headset_test.sv
// 2nd-order CIFB sigma-delta DAC modulator with built-in 1 kHz sine generator
// 
// Architecture:
//   - 8-entry sine LUT, amplitude ±1024 (25% full scale for headroom)
//   - 8 kHz audio sample rate (1 kHz output = 8 samples per cycle)
//   - 5 MHz SDM rate (OSR = 625)
//   - Q13 fixed-point coefficients
//   - 32-bit signed accumulators with saturation at ±524287
//
// Coefficients from Delta-Sigma Toolbox (DESIGN_SECOND_ORDER.m):
//   B1 = A1 = 25564 / 2^13 = 3.121
//   C1 = 437   / 2^13 = 0.0533
//   A2 = 610   / 2^13 = 0.0745
// =============================================================================

module sigma_delta_headset_test (
    input  wire clk,        // 100 MHz
    input  wire rst,        // active-high reset
    output reg  out_bit     // 1-bit PDM output
);

    // ----------------------------------------------------------------
    //  COEFFICIENTS - Q13 fixed-point
    // ----------------------------------------------------------------
    localparam signed [31:0] B1 =  32'sd25564;
    localparam signed [31:0] A1 =  32'sd25564;
    localparam signed [31:0] C1 =  32'sd437;
    localparam signed [31:0] A2 =  32'sd610;
    localparam signed [31:0] ACC_MAX =  32'sd524287;
    localparam signed [31:0] ACC_MIN = -32'sd524288;

    // ----------------------------------------------------------------
    //  SINE LUT - 8 entries, signed, amplitude 1024
    //  Output frequency: 8 kHz / 8 = 1 kHz
    // ----------------------------------------------------------------
    reg signed [31:0] sine_val;
    reg [2:0] sine_phase;

    always @(*) begin
        case (sine_phase)
            3'd0: sine_val =  32'sd0;
            3'd1: sine_val =  32'sd724;
            3'd2: sine_val =  32'sd1024;
            3'd3: sine_val =  32'sd724;
            3'd4: sine_val =  32'sd0;
            3'd5: sine_val = -32'sd724;
            3'd6: sine_val = -32'sd1024;
            3'd7: sine_val = -32'sd724;
            default: sine_val = 32'sd0;
        endcase
    end

    // ----------------------------------------------------------------
    //  8 kHz SAMPLE TICK - every 12500 clock cycles
    // ----------------------------------------------------------------
    reg [13:0] samp_div;
    reg samp_tick;

    always @(posedge clk) begin
        if (rst) begin
            samp_div  <= 14'd0;
            samp_tick <= 1'b0;
        end else if (samp_div == 14'd12499) begin
            samp_div  <= 14'd0;
            samp_tick <= 1'b1;
        end else begin
            samp_div  <= samp_div + 14'd1;
            samp_tick <= 1'b0;
        end
    end

    // ----------------------------------------------------------------
    //  5 MHz SDM TICK - every 20 clock cycles
    // ----------------------------------------------------------------
    reg [4:0] sdm_div;
    reg sdm_tick;

    always @(posedge clk) begin
        if (rst) begin
            sdm_div  <= 5'd0;
            sdm_tick <= 1'b0;
        end else if (sdm_div == 5'd19) begin
            sdm_div  <= 5'd0;
            sdm_tick <= 1'b1;
        end else begin
            sdm_div  <= sdm_div + 5'd1;
            sdm_tick <= 1'b0;
        end
    end

    // ----------------------------------------------------------------
    //  SINE PHASE ADVANCE
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)
            sine_phase <= 3'd0;
        else if (samp_tick)
            sine_phase <= sine_phase + 3'd1;
    end

    // ----------------------------------------------------------------
    //  INTEGRATORS
    // ----------------------------------------------------------------
    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    wire signed [31:0] u_reg = sine_val;
    wire dout_next = (int2_reg >= 32'sd0) ? 1'b1 : 1'b0;
    wire signed [31:0] fb_A1 = dout_next ?  A1 : -A1;
    wire signed [31:0] fb_A2 = dout_next ?  A2 : -A2;

    // Multiplications with arithmetic right shift via bit slice
    wire signed [63:0] B1u_64 = $signed(B1) * $signed(u_reg);
    wire signed [31:0] B1u    = B1u_64[43:12];

    wire signed [63:0] C1x_64 = $signed(C1) * $signed(int1_reg);
    wire signed [31:0] C1x    = C1x_64[44:13];

    wire signed [31:0] sum1_raw = int1_reg + B1u - fb_A1;
    wire signed [31:0] sum2_raw = int2_reg + C1x - fb_A2;

    // ----------------------------------------------------------------
    //  REGISTERED UPDATE - at 5 MHz SDM rate
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 32'sd0;
            int2_reg <= 32'sd0;
            out_bit  <= 1'b0;
        end else if (sdm_tick) begin
            int1_reg <= (sum1_raw > ACC_MAX) ? ACC_MAX :
                        (sum1_raw < ACC_MIN) ? ACC_MIN : sum1_raw;
            int2_reg <= (sum2_raw > ACC_MAX) ? ACC_MAX :
                        (sum2_raw < ACC_MIN) ? ACC_MIN : sum2_raw;
            out_bit  <= dout_next;
        end
    end

endmodule
