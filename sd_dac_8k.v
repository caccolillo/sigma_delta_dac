module sd_dac (
    input  wire        clk,
    input  wire        rst,
    input  wire        samp_valid,
    input  wire [12:0] din,
    output reg         dout,
    output wire        dbg_sdm_en
);

    localparam signed [31:0] ACC_MAX =  32'sd524287;
    localparam signed [31:0] ACC_MIN = -32'sd524288;

    assign dbg_sdm_en = 1'b1;

    reg signed [31:0] int1_reg;
    reg signed [31:0] int2_reg;

    wire dout_next;
    assign dout_next = (int2_reg >= 32'sd0) ? 1'b1 : 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 32'sd0;
            int2_reg <= 32'sd0;
            dout     <= 1'b0;
        end else begin

            // Integrator 1: with zero input,
            //   dout=1 → int1 -= 1000
            //   dout=0 → int1 += 1000
            if (dout_next)
                int1_reg <= (int1_reg - 32'sd1000 < ACC_MIN) ? ACC_MIN : int1_reg - 32'sd1000;
            else
                int1_reg <= (int1_reg + 32'sd1000 > ACC_MAX) ? ACC_MAX : int1_reg + 32'sd1000;

            // Integrator 2: int1/16 + feedback
            if (dout_next)
                int2_reg <= int2_reg + (int1_reg >>> 4) - 32'sd100;
            else
                int2_reg <= int2_reg + (int1_reg >>> 4) + 32'sd100;

            dout <= dout_next;
        end
    end

endmodule
