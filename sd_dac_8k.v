module sd_dac (
    input  wire        clk,        // 100 MHz
    input  wire        rst,        // active high reset
    input  wire        samp_valid, // 8 kHz pulse
    input  wire [12:0] din,        // 13-bit unsigned input (0 to 8191)
    output reg         dout        // 5 MHz PDM output
);

    // --- Internal Registers ---
    reg [12:0] sample_hold;
    reg [4:0]  clk_div_cnt;
    wire       tick_5mhz;

    // We use 18-bit signed registers to prevent overflow during integration.
    // 13 bits (input) + 5 bits headroom for 2nd order accumulation.
    reg signed [17:0] acc1; 
    reg signed [17:0] acc2;
    
    // Signed representation of the input and the feedback
    wire signed [17:0] x_signed;
    wire signed [17:0] feedback;

    // 1. Clock Divider (100MHz -> 5MHz)
    assign tick_5mhz = (clk_div_cnt == 5'd19);
    always @(posedge clk or posedge rst) begin
        if (rst) clk_div_cnt <= 0;
        else clk_div_cnt <= tick_5mhz ? 5'd0 : clk_div_cnt + 1'b1;
    end

    // 2. Input Sample-and-Hold
    always @(posedge clk or posedge rst) begin
        if (rst) sample_hold <= 13'h1000; // Midpoint
        else if (samp_valid) sample_hold <= din;
    end

    // 3. Sigma-Delta Math
    // Map unsigned [0, 8191] to signed roughly [-4096, 4095]
    assign x_signed = $signed({1'b0, sample_hold}) - 18'sd4096;

    // If dout is 1, we feedback "High" (+4096). If 0, we feedback "Low" (-4096).
    assign feedback = dout ? 18'sd4096 : -18'sd4096;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc1 <= 0;
            acc2 <= 0;
            dout <= 0;
        end else if (tick_5mhz) begin
            // First Integrator
            // acc1 = acc1 + (input - feedback)
            acc1 <= acc1 + (x_signed - feedback);
            
            // Second Integrator
            // acc2 = acc2 + (acc1 - feedback)
            acc2 <= acc2 + (acc1 - feedback);
            
            // Quantizer: bitstream is 1 if acc2 is positive
            if (acc2 >= 0)
                dout <= 1'b1;
            else
                dout <= 1'b0;
        end
    end

endmodule
