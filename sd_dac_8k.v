// =============================================================================
// sigma_delta_headset_test.v
// SINGLE module — sine generator and SDM in the same always block hierarchy
// No inter-module wiring, no separate samp_valid path
// =============================================================================

module sigma_delta_headset_test (
    input  wire clk,        // 100 MHz
    input  wire rst,        // active-high reset
    output reg  out_bit     // PDM output to E1
);

    // ----------------------------------------------------------------
    //  COEFFICIENTS — Q13 fixed-point
    // ----------------------------------------------------------------
    localparam signed [31:0] B1 =  32'sd25564;
    localparam signed [31:0] A1 =  32'sd25564;
    localparam signed [31:0] C1 =  32'sd437;
    localparam signed [31:0] A2 =  32'sd610;
    localparam signed [31:0] ACC_MAX =  32'sd524287;
    localparam signed [31:0] ACC_MIN = -32'sd524288;

    // ----------------------------------------------------------------
    //  INTERNAL 8-ENTRY SINE LUT — 1 kHz at 8 kHz sample rate
    //  amplitude reduced to 1024 for safety margin
    // ----------------------------------------------------------------
    reg signed [31:0] sine_val;

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
    //  TIMING — 8 kHz sample tick (every 12500 clocks)
    //          5 MHz SDM tick (every 20 clocks)
    // ----------------------------------------------------------------
    reg [13:0] samp_div;
    reg [4:0]  sdm_div;
    reg        samp_tick;
    reg        sdm_tick;

    always @(posedge clk) begin
        if (rst) begin
            samp_div  <= 14'd0;
            samp_tick <= 1'b0;
        end else begin
            if (samp_div == 14'd12499) begin
                samp_div  <= 14'd0;
                samp_tick <= 1'b1;
            end else begin
                samp_div  <= samp_div + 14'd1;
                samp_tick <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            sdm_div  <= 5'd0;
            sdm_tick <= 1'b0;
        end else begin
            if (sdm_div == 5'd19) begin
                sdm_div  <= 5'd0;
                sdm_tick <= 1'b1;
            end else begin
                sdm_div  <= sdm_div + 5'd1;
                sdm_tick <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    //  SINE PHASE ADVANCER — increments at 8 kHz
    // ----------------------------------------------------------------
    reg [2:0] sine_phase;

    always @(posedge clk) begin
        if (rst)
            sine_phase <= 3'd0;
        else if (samp_tick)
            sine_phase <= sine_phase + 3'd1;
    end

    // ----------------------------------------------------------------
    //  INPUT TO SDM — sine_val is already 32-bit signed
    //  No latch needed since sine_val is held stable between samp_ticks
    //  by the combinatorial case statement on sine_phase
    // ----------------------------------------------------------------
    wire signed [31:0] u_reg;
    assign u_reg = sine_val;

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
    //  REGISTERED UPDATE — at 5 MHz SDM rate
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 32'sd0;
            int2_reg <= 32'sd0;
            out_bit  <= 1'b0;
        end else if (sdm_tick) begin
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

            out_bit <= dout_next;
        end
    end

endmodule
