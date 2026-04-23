module sd_dac (
    input  wire        clk,        // 100 MHz
    input  wire        rst,        // active high reset
    input  wire        samp_valid, // 8 kHz pulse
    input  wire [12:0] din,        // 13-bit input (0 to 8191)
    output reg         dout        // 5 MHz PDM output
);

    // Internal signals
    reg [12:0] sample_hold;
    reg [4:0]  clk_div_cnt;
    wire       tick_5mhz;

    // Use 20-bit signed registers for integrators to provide plenty of headroom
    reg signed [19:0] acc1; 
    reg signed [19:0] acc2;
    
    // Convert 13-bit unsigned input [0, 8191] to signed [-4096, 4095]
    wire signed [19:0] x_in = $signed({1'b0, sample_hold}) - 20'sd4096;
    
    // Feedback value: ±2048 (scaled to prevent loop instability)
    wire signed [19:0] fb = dout ? 20'sd2048 : -20'sd2048;

    // Limits for saturation (prevents wrap-around/clipping noise)
    localparam signed [19:0] POS_LIMIT = 20'sh3FFFF; 
    localparam signed [19:0] NEG_LIMIT = 20'shC0001;

    // 1. Clock Divider (100MHz -> 5MHz)
    assign tick_5mhz = (clk_div_cnt == 5'd19);
    always @(posedge clk or posedge rst) begin
        if (rst) clk_div_cnt <= 0;
        else clk_div_cnt <= tick_5mhz ? 5'd0 : clk_div_cnt + 1'b1;
    end

    // 2. Input Sample-and-Hold
    always @(posedge clk or posedge rst) begin
        if (rst) sample_hold <= 13'h1000;
        else if (samp_valid) sample_hold <= din;
    end

    // 3. Stabilized 2nd Order Math
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc1 <= 0;
            acc2 <= 0;
            dout <= 0;
        end else if (tick_5mhz) begin
            
            // --- Integrator 1 ---
            // acc1 = acc1 + (input - feedback)
            // Using saturation logic to prevent wrap-around
            if (acc1 > POS_LIMIT - (x_in - fb)) acc1 <= POS_LIMIT;
            else if (acc1 < NEG_LIMIT - (x_in - fb)) acc1 <= NEG_LIMIT;
            else acc1 <= acc1 + (x_in - fb);

            // --- Integrator 2 ---
            // acc2 = acc2 + (acc1_shifted - feedback)
            // We shift acc1 to apply a gain of 0.5 for stability
            if (acc2 > POS_LIMIT - (acc1[19:1] - fb)) acc2 <= POS_LIMIT;
            else if (acc2 < NEG_LIMIT - (acc1[19:1] - fb)) acc2 <= NEG_LIMIT;
            else acc2 <= acc2 + (acc1[19:1] - fb);

            // --- Quantizer ---
            dout <= (acc2 >= 0);
        end
    end

endmodule
