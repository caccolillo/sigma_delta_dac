// =============================================================================
// sd_dac.v
// 2nd-Order CIFB Sigma-Delta DAC Modulator
// Auto-generated parameters from DESIGN_SECOND_ORDER.m
//
// Interface:
//   clk        : 100 MHz system clock
//   rst        : active-high synchronous reset
//   samp_valid : 8 kHz pulse — when high, din contains a new audio sample
//   din        : 13-bit signed audio input (-4096 to +4095)
//   dout       : 5 MHz PDM bitstream output → RC filter → audio
//
// Architecture:
//   The modulator runs at 5 MHz (OSR=625 relative to 8 kHz audio).
//   A clock enable divides the 100 MHz clk down to 5 MHz for the SDM.
//   A new audio sample (din) is latched on samp_valid and held for
//   625 SDM cycles until the next samp_valid pulse arrives.
//
// Coefficient word length : 18-bit  fixdt(1,18,N_FRAC)
// Accumulator word length : 30-bit  fixdt(1,30,N_FRAC)
// Fractional bits         : N_FRAC
// Input shift             : 12  (= input_bits-1 = 13-1)
// =============================================================================

module sd_dac #(
    //------------------------------------------------------------------
    // PASTE YOUR VALUES FROM DESIGN_SECOND_ORDER.m
    // Section: --- COPY THESE PARAMETERS INTO VERILOG ---
    //------------------------------------------------------------------
    parameter signed [17:0] B1 = 18'sd25564,
    parameter signed [17:0] A1 = 18'sd25564,
    parameter signed [17:0] C1 = 18'sd437,
    parameter signed [17:0] A2 = 18'sd610,

    //------------------------------------------------------------------
    // Word length parameters — must match DESIGN_SECOND_ORDER.m output
    //------------------------------------------------------------------
    parameter N_FRAC      = 13,    // fractional bits
    parameter N_ACC       = 30,    // accumulator word length
    parameter INPUT_SHIFT = 12,    // = input_bits-1

    //------------------------------------------------------------------
    // Clock divider: 100 MHz / CLK_DIV = 5 MHz SDM clock
    // CLK_DIV = 100e6 / 5e6 = 20
    //------------------------------------------------------------------
    parameter CLK_DIV     = 20     // 100 MHz → 5 MHz
)(
    input  wire        clk,        // 100 MHz system clock
    input  wire        rst,        // active-high synchronous reset
    input  wire        samp_valid, // 8 kHz sample strobe
    input  wire [12:0] din,        // 13-bit signed audio input
    output reg         dout        // 5 MHz PDM output
);

    // ----------------------------------------------------------------
    //  ACCUMULATOR SATURATION LIMITS
    //  Must match acc_min/acc_max in DESIGN_SECOND_ORDER.m
    // ----------------------------------------------------------------
    localparam signed [N_ACC-1:0] ACC_MAX =  (1 <<< (N_ACC-1)) - 1;
    localparam signed [N_ACC-1:0] ACC_MIN = -(1 <<< (N_ACC-1));

    // ----------------------------------------------------------------
    //  CLOCK DIVIDER — generates 5 MHz enable from 100 MHz clock
    //  sdm_en is high for exactly one 100 MHz cycle every CLK_DIV cycles
    //  All SDM logic is gated by sdm_en so it only updates at 5 MHz
    // ----------------------------------------------------------------
    reg [$clog2(CLK_DIV)-1:0] clk_cnt;
    wire                       sdm_en;

    always @(posedge clk) begin
        if (rst) begin
            clk_cnt <= 0;
        end else begin
            if (clk_cnt == CLK_DIV-1)
                clk_cnt <= 0;
            else
                clk_cnt <= clk_cnt + 1;
        end
    end

    assign sdm_en = (clk_cnt == CLK_DIV-1);

    // ----------------------------------------------------------------
    //  INPUT SAMPLE REGISTER
    //  Latches din on samp_valid and holds it for all 625 SDM cycles
    //  until the next samp_valid pulse arrives.
    //  din is treated as signed 13-bit: sign-extend to N_ACC bits
    // ----------------------------------------------------------------
    reg signed [N_ACC-1:0] u_reg;   // held audio sample, sign-extended

    always @(posedge clk) begin
        if (rst) begin
            u_reg <= 0;
        end else if (samp_valid) begin
            // Sign-extend 13-bit signed input to N_ACC bits
            u_reg <= {{(N_ACC-13){din[12]}}, din};
        end
    end

    // ----------------------------------------------------------------
    //  INTEGRATOR STATE REGISTERS
    // ----------------------------------------------------------------
    reg signed [N_ACC-1:0] int1_reg;
    reg signed [N_ACC-1:0] int2_reg;

    // ----------------------------------------------------------------
    //  COMBINATORIAL DATAPATH
    //  All arithmetic is combinatorial — only the registers are clocked
    //  This gives a clean single-cycle pipeline matching the block diagram
    // ----------------------------------------------------------------

    //  Quantizer: invert MSB (sign bit) of int2_reg
    //  int2_reg >= 0 → MSB=0 → dout=1  → feedback = +A1/+A2
    //  int2_reg <  0 → MSB=1 → dout=0  → feedback = -A1/-A2
    wire dout_next;
    assign dout_next = ~int2_reg[N_ACC-1];

    //  DAC feedback: 2:1 mux selecting +coeff or -coeff
    //  No multiplier — just conditional sign flip
    wire signed [N_ACC-1:0] fb_A1;
    wire signed [N_ACC-1:0] fb_A2;

    assign fb_A1 = dout_next ?
        {{(N_ACC-18){A1[17]}}, A1} :
        -{{(N_ACC-18){A1[17]}}, A1};

    assign fb_A2 = dout_next ?
        {{(N_ACC-18){A2[17]}}, A2} :
        -{{(N_ACC-18){A2[17]}}, A2};

    //  B1 × u_in:
    //    B1   is Q(N_FRAC) — 18-bit coefficient
    //    u_in is 13-bit raw integer scaled by 2^INPUT_SHIFT=2^12
    //    Product is Q(N_FRAC+INPUT_SHIFT) = Q25
    //    Right shift by INPUT_SHIFT=12 → Q(N_FRAC)=Q13
    wire signed [N_ACC+INPUT_SHIFT-1:0] B1u_full;
    wire signed [N_ACC-1:0]             B1u;

    assign B1u_full = $signed(B1) * $signed(u_reg[INPUT_SHIFT+:13]);
    assign B1u      = B1u_full >>> INPUT_SHIFT;

    //  C1 × int1_reg:
    //    C1       is Q(N_FRAC) — 18-bit
    //    int1_reg is Q(N_FRAC) — N_ACC-bit accumulator
    //    Product  is Q(2*N_FRAC) — (18+N_ACC)-bit
    //    Right shift by N_FRAC → Q(N_FRAC)
    wire signed [17+N_ACC:0] C1x_full;
    wire signed [N_ACC-1:0]  C1x;

    assign C1x_full = $signed(C1) * $signed(int1_reg);
    assign C1x      = C1x_full >>> N_FRAC;

    //  Integrator sums (before saturation)
    wire signed [N_ACC-1:0] sum1_raw;
    wire signed [N_ACC-1:0] sum2_raw;

    assign sum1_raw = int1_reg + B1u  - fb_A1;
    assign sum2_raw = int2_reg + C1x  - fb_A2;

    //  Saturation function
    function automatic signed [N_ACC-1:0] saturate;
        input signed [N_ACC-1:0] x;
        begin
            if      (x > ACC_MAX)  saturate = ACC_MAX;
            else if (x < ACC_MIN)  saturate = ACC_MIN;
            else                   saturate = x;
        end
    endfunction

    wire signed [N_ACC-1:0] sum1;
    wire signed [N_ACC-1:0] sum2;

    assign sum1 = saturate(sum1_raw);
    assign sum2 = saturate(sum2_raw);

    // ----------------------------------------------------------------
    //  REGISTERED UPDATE — only on sdm_en (5 MHz gate)
    //  Between sdm_en pulses all registers hold their values
    //  dout is registered to prevent glitches on the output pin
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            int1_reg <= 0;
            int2_reg <= 0;
            dout     <= 1'b0;
        end else if (sdm_en) begin
            int1_reg <= sum1;
            int2_reg <= sum2;
            dout     <= dout_next;
        end
    end

endmodule
