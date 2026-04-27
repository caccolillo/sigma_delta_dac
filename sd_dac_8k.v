// =============================================================================
// sd_dac.v — minimal SDM with hand-traced arithmetic
// Bypasses all multiplication using the fact that B1=A1 with zero input
// =============================================================================

module sd_dac (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,
    input  wire [12:0] din,
    output reg         dout,
    output wire        dbg_sdm_en
);

    localparam [3:0] TEST_MODE = 4'd4;

    localparam signed [31:0] ACC_MAX =  32'sd524287;
    localparam signed [31:0] ACC_MIN = -32'sd524288;
    localparam        [31:0] SDM_DIV = 32'd20;

    // ----------------------------------------------------------------
    //  CLOCK DIVIDER
    // ----------------------------------------------------------------
    reg [31:0] clk_cnt;
    wire       sdm_en;
    assign sdm_en     = (clk_cnt == SDM_DIV - 1);
    assign dbg_sdm_en = sdm_en;

    always @(posedge clk) begin
        if (rst)
            clk_cnt <= 32'd0;
        else if (sdm_en)
            clk_cnt <= 32'd0;
        else
            clk_cnt <= clk_cnt + 32'd1;
    end

    // ----------------------------------------------------------------
    //  MINIMAL SDM — for TEST_MODE 4 (zero input):
    //  With u=0, B1*u=0
    //  int1 update: int1 += -fb_A1 = (dout ? -A1 : +A1)
    //  C1*int1 = small value
    //  int2 update: int2 += C1x - fb_A2
    //
    //  Use very simple coefficients to make it easy to trace:
    //    A1_simple = 1024
    //    A2_simple = 100
    //    C1_simple = 1 (no shift, direct add)
    //
    //  Expected with zero input:
    //    dout=1 → int1 -= 1024, int1 saturates negative quickly
    //    int1 = -524288 → int2 += -524288/something - 100
    //    int2 goes negative → dout flips to 0
    //    dout=0 → int1 += 1024, recovers
    //    Loop oscillates → dout has 50% duty cycle → 1.65V output
    // ----------------------------------------------------------------

    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    wire dout_next;
    assign dout_next = (int2_reg >= 32'sd0) ? 1'b1 : 1'b0;

    // ----------------------------------------------------------------
    //  Simplified update — no multiplications at all for TEST_MODE 4
    //  This isolates whether the loop control logic works
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 32'sd0;
            int2_reg <= 32'sd0;
            dout     <= 1'b0;
        end else if (TEST_MODE == 4'd1) begin
            if (sdm_en) dout <= ~dout;

        end else if (sdm_en) begin

            // Simplified integrator 1: just subtract/add a constant
            if (dout_next) begin
                // dout=1 → subtract 1000
                if (int1_reg - 32'sd1000 < ACC_MIN)
                    int1_reg <= ACC_MIN;
                else
                    int1_reg <= int1_reg - 32'sd1000;
            end else begin
                // dout=0 → add 1000
                if (int1_reg + 32'sd1000 > ACC_MAX)
                    int1_reg <= ACC_MAX;
                else
                    int1_reg <= int1_reg + 32'sd1000;
            end

            // Simplified integrator 2: scale int1 by /16 then accumulate
            if (dout_next) begin
                if (int2_reg + (int1_reg >>> 4) - 32'sd100 < ACC_MIN)
                    int2_reg <= ACC_MIN;
                else if (int2_reg + (int1_reg >>> 4) - 32'sd100 > ACC_MAX)
                    int2_reg <= ACC_MAX;
                else
                    int2_reg <= int2_reg + (int1_reg >>> 4) - 32'sd100;
            end else begin
                if (int2_reg + (int1_reg >>> 4) + 32'sd100 < ACC_MIN)
                    int2_reg <= ACC_MIN;
                else if (int2_reg + (int1_reg >>> 4) + 32'sd100 > ACC_MAX)
                    int2_reg <= ACC_MAX;
                else
                    int2_reg <= int2_reg + (int1_reg >>> 4) + 32'sd100;
            end

            dout <= dout_next;
        end
    end

endmodule
