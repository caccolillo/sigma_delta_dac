// =============================================================================
// tb_sd_dac.sv  (v6 - 4.5 second sweep, 450M cycles)
// 9 frequencies x 500ms = 4.5 seconds total simulation.
// =============================================================================

`timescale 1ns/1ps

module tb_sd_dac;

    logic        clk;
    logic        rst;
    logic [12:0] sample;
    logic        sample_valid;
    logic [3:0]  freq_idx;
    logic        dout;

    sine_gen u_sine_gen (
        .clk          (clk),
        .rst          (rst),
        .sample       (sample),
        .sample_valid (sample_valid),
        .freq_idx     (freq_idx)
    );

    sd_dac_8k u_sd_dac (
        .clk        (clk),
        .rst        (rst),
        .samp_valid (sample_valid),
        .din        (sample),
        .dout       (dout)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // 9 x 500ms x 100MHz = 450,000,000 cycles
    localparam SIM_CYCLES = 450_000_000;

    // ── EDIT THESE PATHS ──────────────────────────────────────────────────────
    localparam CSV_PATH = "/home/caccolillo/sigma_delta_dac/pdm_output.csv";
    localparam PLOT_CMD = "python3 /home/caccolillo/sigma_delta_dac/plot_dac.py";
    // ─────────────────────────────────────────────────────────────────────────

    integer fd;
    longint cycle_count;

    initial begin
        fd = $fopen(CSV_PATH, "w");
        if (fd == 0) begin
            $display("ERROR: could not open %s", CSV_PATH);
            $finish;
        end
        $fwrite(fd, "time_ns,freq_idx,sample_valid,din,dout\n");
    end

    initial begin
        rst = 1;
        repeat (20) @(posedge clk);
        @(negedge clk);
        rst = 0;
    end

    initial begin
        cycle_count = 0;
        @(negedge rst);

        repeat (SIM_CYCLES) begin
            @(posedge clk);
            #1;
            if (sample_valid)
                $fwrite(fd, "%0t,%0d,%0b,%0d,%0b\n",
                        $time, freq_idx, sample_valid, sample, dout);
            cycle_count++;
        end

        $fclose(fd);
        $display("Simulation complete: %0d total cycles", cycle_count);
        $display("Running plot_dac.py...");
        $system(PLOT_CMD);
        $finish;
    end

    // 60 second watchdog
    initial begin
        repeat (600) #100_000_000;        $display("TIMEOUT");
        $fclose(fd);
        $finish;
    end

endmodule
