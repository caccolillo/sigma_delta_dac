// =============================================================================
// sd_dac.v — QSPICE compatible
// Coefficients from DESIGN_SECOND_ORDER.m
// Interface exactly as specified by user
// =============================================================================

module sd_dac (
    input  wire        clk,        // 100 MHz
    input  wire        rst,        // active high reset
    input  wire        samp_valid, // 8 kHz sample valid
    input  wire [12:0] din,        // 13-bit input sample
    output reg         dout        // 5 MHz PDM output
);

    // ----------------------------------------------------------------
    //  COEFFICIENTS — paste integers from DESIGN_SECOND_ORDER.m
    //  Section: --- COPY THESE PARAMETERS INTO VERILOG ---
    // ----------------------------------------------------------------
    localparam signed [31:0] B1 =  32'sd25564;
    localparam signed [31:0] A1 =  32'sd25564;
    localparam signed [31:0] C1 =  32'sd437;
    localparam signed [31:0] A2 =  32'sd610;

    // ----------------------------------------------------------------
    //  CONSTANTS
    // ----------------------------------------------------------------
    localparam signed [31:0] ACC_MAX     =  32'sd524287;  //  2^19 - 1
    localparam signed [31:0] ACC_MIN     = -32'sd524288;  // -2^19
    localparam        [31:0] INPUT_SHIFT = 32'd12;        // 13-bit input scale
    localparam        [31:0] FRAC_SHIFT  = 32'd13;        // N_FRAC
    localparam        [31:0] CLK_DIV     = 32'd20;        // 100MHz/20 = 5MHz

    // ----------------------------------------------------------------
    //  CLOCK DIVIDER — 100 MHz → 5 MHz enable
    // ----------------------------------------------------------------
    reg [31:0] clk_cnt;
    wire       sdm_en;

    assign sdm_en = (clk_cnt == CLK_DIV - 1);

    always @(posedge clk) begin
        if (rst) begin
            clk_cnt <= 32'd0;
        end else begin
            if (sdm_en)
                clk_cnt <= 32'd0;
            else
                clk_cnt <= clk_cnt + 32'd1;
        end
    end

    // ----------------------------------------------------------------
    //  INPUT LATCH
    //  Sign-extend 13-bit din to 32-bit signed on samp_valid
    // ----------------------------------------------------------------
    reg signed [31:0] u_reg;

    always @(posedge clk) begin
        if (rst) begin
            u_reg <= 32'sd0;
        end else if (samp_valid) begin
            u_reg <= {{19{din[12]}}, din};
        end
    end

    // ----------------------------------------------------------------
    //  INTEGRATOR REGISTERS — 32-bit signed covers 20-bit range
    // ----------------------------------------------------------------
    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    // ----------------------------------------------------------------
    //  COMBINATORIAL DATAPATH
    // ----------------------------------------------------------------

    // Quantizer: sign bit of int2_reg
    // int2 >= 0 → MSB=0 → dout_next=1 → feedback = +A1/+A2
    // int2 <  0 → MSB=1 → dout_next=0 → feedback = -A1/-A2
    wire dout_next;
    assign dout_next = ~int2_reg[31];

    // DAC feedback: 2:1 mux — no multiplier needed
    wire signed [31:0] fb_A1;
    wire signed [31:0] fb_A2;
    assign fb_A1 = dout_next ?  A1 : -A1;
    assign fb_A2 = dout_next ?  A2 : -A2;

    // B1 x u_reg:
    // B1   is Q13 (32-bit signed)
    // u_reg is sign-extended 13-bit integer (scaled by 2^12)
    // Product is 64-bit → shift right 12 → Q13
    wire signed [63:0] B1u_full;
    wire signed [31:0] B1u;
    assign B1u_full = $signed(B1) * $signed(u_reg);
    assign B1u      = B1u_full >>> INPUT_SHIFT;

    // C1 x int1_reg:
    // Both Q13 → 64-bit product → shift right 13 → Q13
    wire signed [63:0] C1x_full;
    wire signed [31:0] C1x;
    assign C1x_full = $signed(C1) * $signed(int1_reg);
    assign C1x      = C1x_full >>> FRAC_SHIFT;

    // Integrator sums
    wire signed [31:0] sum1_raw;
    wire signed [31:0] sum2_raw;
    assign sum1_raw = int1_reg + B1u - fb_A1;
    assign sum2_raw = int2_reg + C1x - fb_A2;

    // Saturation — inline ternary, no automatic functions
    wire signed [31:0] sum1;
    wire signed [31:0] sum2;
    assign sum1 = (sum1_raw > ACC_MAX) ? ACC_MAX :
                  (sum1_raw < ACC_MIN) ? ACC_MIN : sum1_raw;
    assign sum2 = (sum2_raw > ACC_MAX) ? ACC_MAX :
                  (sum2_raw < ACC_MIN) ? ACC_MIN : sum2_raw;

    // ----------------------------------------------------------------
    //  REGISTERED UPDATE — gated by sdm_en (5 MHz)
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 32'sd0;
            int2_reg <= 32'sd0;
            dout     <= 1'b0;
        end else if (sdm_en) begin
            int1_reg <= sum1;
            int2_reg <= sum2;
            dout     <= dout_next;
        end
    end

endmodule
