// =============================================================================
// sd_dac.v (v2 — fixed quantizer, explicit sign compare)
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

    localparam signed [31:0] ACC_MAX     =  32'sd524287;
    localparam signed [31:0] ACC_MIN     = -32'sd524288;
    localparam        [31:0] INPUT_SHIFT = 32'd12;
    localparam        [31:0] FRAC_SHIFT  = 32'd13;
    localparam        [31:0] CLK_DIV     = 32'd20;

    // ----------------------------------------------------------------
    //  CLOCK DIVIDER
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
    //  INPUT LATCH — sign extend 13-bit to 32-bit
    // ----------------------------------------------------------------
    reg signed [31:0] u_reg;

    always @(posedge clk) begin
        if (rst) begin
            u_reg <= 32'sd0;
        end else if (samp_valid) begin
            // Explicit sign extension of 13-bit two's complement
            // din[12] is the sign bit
            if (din[12])
                u_reg <= {19'h7FFFF, din};   // negative: fill upper bits with 1
            else
                u_reg <= {19'h00000, din};   // positive: fill upper bits with 0
        end
    end

    // ----------------------------------------------------------------
    //  INTEGRATORS
    // ----------------------------------------------------------------
    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    // ----------------------------------------------------------------
    //  QUANTIZER — explicit signed comparison, not bit check
    // ----------------------------------------------------------------
    wire dout_next;
    assign dout_next = (int2_reg >= 32'sd0) ? 1'b1 : 1'b0;

    // ----------------------------------------------------------------
    //  DAC FEEDBACK
    // ----------------------------------------------------------------
    wire signed [31:0] fb_A1;
    wire signed [31:0] fb_A2;
    assign fb_A1 = dout_next ?  A1 : -A1;
    assign fb_A2 = dout_next ?  A2 : -A2;

    // ----------------------------------------------------------------
    //  MULTIPLIERS
    // ----------------------------------------------------------------
    wire signed [63:0] B1u_full;
    wire signed [31:0] B1u;
    assign B1u_full = $signed(B1) * $signed(u_reg);
    assign B1u      = B1u_full >>> INPUT_SHIFT;

    wire signed [63:0] C1x_full;
    wire signed [31:0] C1x;
    assign C1x_full = $signed(C1) * $signed(int1_reg);
    assign C1x      = C1x_full >>> FRAC_SHIFT;

    // ----------------------------------------------------------------
    //  INTEGRATOR SUMS + SATURATION
    // ----------------------------------------------------------------
    wire signed [31:0] sum1_raw;
    wire signed [31:0] sum2_raw;
    assign sum1_raw = int1_reg + B1u  - fb_A1;
    assign sum2_raw = int2_reg + C1x  - fb_A2;

    wire signed [31:0] sum1;
    wire signed [31:0] sum2;
    assign sum1 = (sum1_raw > ACC_MAX) ? ACC_MAX :
                  (sum1_raw < ACC_MIN) ? ACC_MIN : sum1_raw;
    assign sum2 = (sum2_raw > ACC_MAX) ? ACC_MAX :
                  (sum2_raw < ACC_MIN) ? ACC_MIN : sum2_raw;

    // ----------------------------------------------------------------
    //  REGISTERED UPDATE — 5 MHz gate
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
