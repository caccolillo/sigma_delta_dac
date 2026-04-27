// =============================================================================
// sd_dac.v — fixed timing, OSR counter drives SDM not separate clock divider
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

    // OSR = 5MHz / 8kHz = 625
    // SDM runs 625 times per audio sample
    // Each SDM tick = 100MHz / 5MHz = 20 clock cycles
    localparam [31:0] SDM_DIV = 32'd20;    // 100 MHz / 5 MHz
    localparam [31:0] OSR     = 32'd625;   // SDM cycles per audio sample

    // ----------------------------------------------------------------
    //  INPUT LATCH — updated on samp_valid
    // ----------------------------------------------------------------
    reg signed [31:0] u_reg;

    always @(posedge clk) begin
        if (rst)
            u_reg <= 32'sd0;
        else if (samp_valid)
            u_reg <= {{19{din[12]}}, din};
    end

    // ----------------------------------------------------------------
    //  SDM CLOCK DIVIDER — 100 MHz → 5 MHz
    //  Runs freely, independent of samp_valid
    // ----------------------------------------------------------------
    reg [31:0] clk_cnt;
    wire       sdm_en;
    assign sdm_en = (clk_cnt == SDM_DIV - 1);

    always @(posedge clk) begin
        if (rst)
            clk_cnt <= 32'd0;
        else if (sdm_en)
            clk_cnt <= 32'd0;
        else
            clk_cnt <= clk_cnt + 32'd1;
    end

    // ----------------------------------------------------------------
    //  INTEGRATOR REGISTERS
    // ----------------------------------------------------------------
    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    // ----------------------------------------------------------------
    //  COMBINATORIAL DATAPATH
    // ----------------------------------------------------------------
    wire dout_next;
    assign dout_next = (int2_reg >= 32'sd0) ? 1'b1 : 1'b0;

    wire signed [31:0] fb_A1;
    wire signed [31:0] fb_A2;
    assign fb_A1 = dout_next ?  A1 : -A1;
    assign fb_A2 = dout_next ?  A2 : -A2;

    wire signed [63:0] B1u_full;
    wire signed [31:0] B1u;
    assign B1u_full = $signed(B1) * $signed(u_reg);
    assign B1u      = B1u_full >>> 32'd12;

    wire signed [63:0] C1x_full;
    wire signed [31:0] C1x;
    assign C1x_full = $signed(C1) * $signed(int1_reg);
    assign C1x      = C1x_full >>> 32'd13;

    wire signed [31:0] sum1_raw;
    wire signed [31:0] sum2_raw;
    assign sum1_raw = int1_reg + B1u - fb_A1;
    assign sum2_raw = int2_reg + C1x - fb_A2;

    wire signed [31:0] sum1;
    wire signed [31:0] sum2;
    assign sum1 = (sum1_raw > ACC_MAX) ? ACC_MAX :
                  (sum1_raw < ACC_MIN) ? ACC_MIN : sum1_raw;
    assign sum2 = (sum2_raw > ACC_MAX) ? ACC_MAX :
                  (sum2_raw < ACC_MIN) ? ACC_MIN : sum2_raw;

    // ----------------------------------------------------------------
    //  REGISTERED UPDATE — only on sdm_en
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
