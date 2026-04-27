// =============================================================================
// sd_dac.v — full diagnostic version
//   - Bare integer shift amounts (Verilator safe)
//   - Inline saturation in always block
//   - dbg_sdm_en debug output for QSPICE probing
//   - TEST_MODE selector for diagnostics
// =============================================================================

module sd_dac (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,
    input  wire [12:0] din,
    output reg         dout,
    output wire        dbg_sdm_en   // probe in QSPICE — should be 5 MHz pulse
);

    // ----------------------------------------------------------------
    //  TEST MODE SELECT
    //    0 = normal SDM operation (sine input via samp_valid + din)
    //    1 = self-test: dout toggles at 5 MHz (50% duty)
    //    2 = SDM with internal DC input = +1024
    //    3 = SDM with internal DC input = -1024
    //    4 = SDM with internal DC input = 0
    // ----------------------------------------------------------------
    localparam [3:0] TEST_MODE = 4'd4;

    // ----------------------------------------------------------------
    //  COEFFICIENTS
    // ----------------------------------------------------------------
    localparam signed [31:0] B1 =  32'sd25564;
    localparam signed [31:0] A1 =  32'sd25564;
    localparam signed [31:0] C1 =  32'sd437;
    localparam signed [31:0] A2 =  32'sd610;

    localparam signed [31:0] ACC_MAX =  32'sd524287;
    localparam signed [31:0] ACC_MIN = -32'sd524288;
    localparam        [31:0] SDM_DIV = 32'd20;

    // ----------------------------------------------------------------
    //  CLOCK DIVIDER — 100 MHz → 5 MHz enable
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
    //  INPUT SELECT — based on TEST_MODE
    // ----------------------------------------------------------------
    reg signed [31:0] u_reg;

    always @(posedge clk) begin
        if (rst) begin
            u_reg <= 32'sd0;
        end else begin
            case (TEST_MODE)
                4'd0:    if (samp_valid) u_reg <= {{19{din[12]}}, din};
                4'd2:    u_reg <=  32'sd1024;
                4'd3:    u_reg <= -32'sd1024;
                4'd4:    u_reg <=  32'sd0;
                default: u_reg <=  32'sd0;
            endcase
        end
    end

    // ----------------------------------------------------------------
    //  INTEGRATOR REGISTERS
    // ----------------------------------------------------------------
    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    // ----------------------------------------------------------------
    //  COMBINATORIAL DATAPATH — bare integer shift amounts
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
    assign B1u      = B1u_full >>> 12;

    wire signed [63:0] C1x_full;
    wire signed [31:0] C1x;
    assign C1x_full = $signed(C1) * $signed(int1_reg);
    assign C1x      = C1x_full >>> 13;

    wire signed [31:0] sum1_raw;
    wire signed [31:0] sum2_raw;
    assign sum1_raw = int1_reg + B1u - fb_A1;
    assign sum2_raw = int2_reg + C1x - fb_A2;

    // ----------------------------------------------------------------
    //  REGISTERED UPDATE — inline saturation, single always block
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 32'sd0;
            int2_reg <= 32'sd0;
            dout     <= 1'b0;
        end else if (TEST_MODE == 4'd1) begin
            // Self-test: toggle dout at 5 MHz
            if (sdm_en)
                dout <= ~dout;
        end else if (sdm_en) begin
            // Integrator 1 with inline saturation
            if (sum1_raw > ACC_MAX)
                int1_reg <= ACC_MAX;
            else if (sum1_raw < ACC_MIN)
                int1_reg <= ACC_MIN;
            else
                int1_reg <= sum1_raw;

            // Integrator 2 with inline saturation
            if (sum2_raw > ACC_MAX)
                int2_reg <= ACC_MAX;
            else if (sum2_raw < ACC_MIN)
                int2_reg <= ACC_MIN;
            else
                int2_reg <= sum2_raw;

            // Quantizer output
            dout <= dout_next;
        end
    end

endmodule
