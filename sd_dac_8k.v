module sd_dac (
    input  wire        clk,        // 100 MHz
    input  wire        rst,        // active high reset
    input  wire        samp_valid, // 8 kHz pulse
    input  wire [12:0] din,        // 13-bit input (0 to 8191)
    output reg         dout        // 5 MHz PDM output
);

    // --- Signals ---
    reg [12:0] sample_hold;
    reg [4:0]  clk_div_cnt;
    wire       tick_5mhz;

    // Accumulators for MASH structure
    // We use 14 bits to catch the carry out (MSB)
    reg [13:0] acc1; 
    reg [13:0] acc2;
    
    // --- 1. Clock Divider (100MHz to 5MHz) ---
    assign tick_5mhz = (clk_div_cnt == 5'd19);
    always @(posedge clk or posedge rst) begin
        if (rst) 
            clk_div_cnt <= 5'd0;
        else 
            clk_div_cnt <= tick_5mhz ? 5'd0 : clk_div_cnt + 1'b1;
    end

    // --- 2. Input Sample Hold ---
    always @(posedge clk or posedge rst) begin
        if (rst) 
            sample_hold <= 13'h1000; // Mid-scale
        else if (samp_valid) 
            sample_hold <= din;
    end

    // --- 3. MASH 1-1 Second Order Modulator ---
    // This structure is mathematically stable and won't "explode"
    reg carry1_d1, carry2, carry2_d1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc1      <= 0;
            acc2      <= 0;
            carry1_d1 <= 0;
            carry2_d1 <= 0;
            dout      <= 0;
        end else if (tick_5mhz) begin
            // First Stage (1st order)
            acc1 <= acc1[12:0] + sample_hold;
            
            // Second Stage (Integrates the error of the first stage)
            acc2 <= acc2[12:0] + acc1[12:0];
            
            // Delay the carries to perform the digital differentiation
            carry1_d1 <= acc1[13];
            carry2_d1 <= acc2[13];
            
            // The 2nd Order Result is: Carry1 + (Carry2 - Carry2_delayed)
            // Since we need a 1-bit output (0 or 1), we quantize the result:
            // If the sum > 0, output 1.
            if (acc1[13] || acc2[13]) 
                dout <= 1'b1;
            else 
                dout <= 1'b0;
        end
    end

endmodule
