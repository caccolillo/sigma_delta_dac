module sd_dac (
    input  wire        clk,        // 100 MHz
    input  wire        rst,        // active high
    input  wire        samp_valid, // 8 kHz
    input  wire [12:0] din,        // 13-bit input
    output reg         dout        // 5 MHz PDM output
);

    // --- Clock Divider (5 MHz) ---
    reg [4:0] clk_div_cnt;
    wire      tick_5mhz = (clk_div_cnt == 5'd19);
    always @(posedge clk or posedge rst) begin
        if (rst) clk_div_cnt <= 0;
        else clk_div_cnt <= tick_5mhz ? 0 : clk_div_cnt + 1;
    end

    // --- Sample Hold ---
    reg [12:0] x_in;
    always @(posedge clk or posedge rst) begin
        if (rst) x_in <= 13'h1000;
        else if (samp_valid) x_in <= din;
    end

    // --- MASH 1-1 Logic ---
    // Each accumulator is 14 bits (13 bits + 1 bit carry)
    reg [13:0] acc1; 
    reg [13:0] acc2;
    reg        c1, c2, c2_delayed;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc1 <= 0;
            acc2 <= 0;
            c1   <= 0;
            c2   <= 0;
            c2_delayed <= 0;
            dout <= 0;
        end else if (tick_5mhz) begin
            // STAGE 1: Standard 1st order SDM
            // The carry out (acc1[13]) is the 1st order bitstream
            acc1 <= acc1[12:0] + x_in;
            c1   <= acc1[13];

            // STAGE 2: Processes the "error" (remainder) of Stage 1
            // The input to Stage 2 is the remainder of the first accumulator
            acc2 <= acc2[12:0] + acc1[12:0];
            c2   <= acc2[13];
            
            // MASH Combination Logic:
            // In a MASH 1-1, the output is: Carry1 + (Carry2 - Carry2_Delayed)
            c2_delayed <= c2;

            // To keep 'dout' as a single bit (0 or 1) for your PDM filter:
            // We use the Carry 1 as the primary driver, and Carry 2
            // provides the high-frequency "dither" for 2nd order shaping.
            dout <= c1 | (c2 & !c2_delayed);
        end
    end

endmodule
