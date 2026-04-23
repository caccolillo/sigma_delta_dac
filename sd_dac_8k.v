module sd_dac (
    input  wire        clk,        // 100 MHz
    input  wire        rst,        // active high reset
    input  wire        samp_valid, // 8 kHz sample valid
    input  wire [12:0] din,           // 13-bit input sample
    output reg         dout        // 5 MHz PDM output
);

    // --- 1. Clock Divider (100MHz -> 5MHz) ---
    reg [4:0] clk_div_cnt;
    wire      tick_5mhz = (clk_div_cnt == 5'd19);

    always @(posedge clk or posedge rst) begin
        if (rst) clk_div_cnt <= 5'd0;
        else clk_div_cnt <= tick_5mhz ? 5'd0 : clk_div_cnt + 1'b1;
    end

    // --- 2. Input Sample Hold ---
    reg [12:0] x_in;
    always @(posedge clk or posedge rst) begin
        if (rst) x_in <= 13'd0; // Bug 3 Fix: Reset to 0
        else if (samp_valid) x_in <= din;
    end

    // --- 3. Combinational 2nd-Order Logic (Bug 1 & 2 Fix) ---
    // Use 20 bits to prevent overflow during intermediate sums
    reg signed [19:0] acc1, acc2;
    wire signed [19:0] x_signed = $signed({1'b0, x_in});
    
    // Feedback: If the PREVIOUS dout was 1, we subtract 8191. If 0, we subtract 0.
    // This is the standard 1-bit DAC feedback loop.
    wire signed [19:0] fb = dout ? 20'sd8191 : 20'sd0;

    // FRESH VALUES: We calculate the sums combinatorially before registering them
    wire signed [19:0] next_acc1 = acc1 + (x_signed - fb);
    wire signed [19:0] next_acc2 = acc2 + (next_acc1 - fb);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc1 <= 20'sd0;
            acc2 <= 20'sd0;
            dout <= 1'b0;
        end else if (tick_5mhz) begin
            // Update the state with the freshly calculated sums
            acc1 <= next_acc1;
            acc2 <= next_acc2;
            
            // Quantizer: Current output is based on the fresh internal state
            // This closes the loop without the 1-cycle carry lag.
            dout <= (next_acc2 >= 20'sd0);
        end
    end

endmodule
