module sd_dac (
    input  wire        clk,        // 100 MHz system clock
    input  wire        rst,        // active high reset
    input  wire        samp_valid, // 8 kHz sample valid pulse
    input  wire [12:0] din,        // 13-bit input sample (unsigned 0 to 8191)
    output reg         dout        // 5 MHz Sigma-Delta PDM output
);

    // --- Internal Signals ---
    reg [12:0] sample_hold;     // Holds the input sample
    reg [4:0]  clk_div_cnt;     // To divide 100MHz down to 5MHz (100/20 = 5)
    wire       tick_5mhz;       // Pulse every 20 clk cycles
    
    // 14-bit accumulator to handle carry-out from 13-bit addition
    reg [13:0] acc; 

    // --- 1. Sample and Hold ---
    // Capture the 8kHz input sample when samp_valid is high
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sample_hold <= 13'h1000; // Mid-point (approx 1.65V)
        end else if (samp_valid) begin
            sample_hold <= din;
        end
    end

    // --- 2. Clock Divider (100 MHz to 5 MHz) ---
    // Generate a enable tick every 20 cycles
    assign tick_5mhz = (clk_div_cnt == 5'd19);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_div_cnt <= 5'd0;
        end else begin
            if (tick_5mhz)
                clk_div_cnt <= 5'd0;
            else
                clk_div_cnt <= clk_div_cnt + 1'b1;
        end
    end

    // --- 3. Sigma-Delta Modulator (Accumulator) ---
    // The core logic runs at the oversampled 5 MHz rate
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc  <= 14'd0;
            dout <= 1'b0;
        end else if (tick_5mhz) begin
            // Error feedback logic:
            // Add input sample to the current remainder in the accumulator
            // The carry-out (bit 13) becomes the PDM bit
            acc  <= acc[12:0] + sample_hold;
            dout <= acc[13];
        end
    end

endmodule
