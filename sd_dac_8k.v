module sd_dac_2nd_order (
    input  wire        clk,        // 100 MHz
    input  wire        rst,        // active high
    input  wire        samp_valid, // 8 kHz
    input  wire [12:0] din,        // 13-bit input
    output reg         dout        // 5 MHz PDM output
);

    reg [12:0] sample_hold;
    reg [4:0]  clk_div_cnt;
    wire       tick_5mhz;

    // We use extra bits to prevent overflow within the integrators
    // For a 13-bit input, 16-bit registers are used for internal math
    reg signed [15:0] integ1; 
    reg signed [15:0] integ2;
    wire signed [15:0] feedback;

    // --- 1. Sample and Hold ---
    always @(posedge clk or posedge rst) begin
        if (rst) sample_hold <= 13'h1000;
        else if (samp_valid) sample_hold <= din;
    end

    // --- 2. Clock Divider (5 MHz) ---
    assign tick_5mhz = (clk_div_cnt == 5'd19);
    always @(posedge clk or posedge rst) begin
        if (rst) clk_div_cnt <= 0;
        else clk_div_cnt <= tick_5mhz ? 0 : clk_div_cnt + 1;
    end

    // --- 3. 2nd Order Modulator Logic ---
    // Mapping: If dout=1, feedback is "Full Scale" (8191). If 0, feedback is 0.
    assign feedback = dout ? 16'd8191 : 16'd0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            integ1 <= 0;
            integ2 <= 0;
            dout   <= 0;
        end else if (tick_5mhz) begin
            // First Integrator: adds difference between input and feedback
            integ1 <= integ1 + (sample_hold - feedback);
            
            // Second Integrator: adds difference between integ1 and feedback
            integ2 <= integ2 + (integ1 - feedback);
            
            // Quantizer: If second integrator is positive, output 1
            if (integ2 >= 0)
                dout <= 1'b1;
            else
                dout <= 1'b0;
        end
    end

endmodule
