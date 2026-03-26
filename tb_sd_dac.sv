// =============================================================================
// tb_sd_dac.sv  (v3)
// SystemVerilog testbench for sigma-delta DAC system.
// Simulates 50 ms (5,000,000 cycles at 100 MHz), writes PDM output to CSV,
// then calls plot_dac.py for filter + plot post-processing.
//
// Note on $time units:
//   With `timescale 1ns/1ps, xsim reports $time in nanoseconds.
//   plot_dac.py auto-detects the unit from the magnitude of the values.
// =============================================================================

`timescale 1ns/1ps

module tb_sd_dac;

    // ── Clock and reset ──
    logic clk;
    logic rst;

    // ── DUT signals ──
    logic [12:0] sample;
    logic        sample_valid;
    logic        dout;

    // ── Instantiate sine generator ──
    sine_gen u_sine_gen (
        .clk          (clk),
        .rst          (rst),
        .sample       (sample),
        .sample_valid (sample_valid)
    );

    // ── Instantiate sigma-delta DAC ──
    sd_dac_8k u_sd_dac (
        .clk        (clk),
        .rst        (rst),
        .samp_valid (sample_valid),
        .din        (sample),
        .dout       (dout)
    );

    // ── 100 MHz clock: 10 ns period ──
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Simulation parameters ──
    // 50 ms at 100 MHz = 5,000,000 cycles (50 cycles of a 1000 Hz sine)
    localparam SIM_CYCLES = 5_000_000;
    localparam CSV_FILE   = "pdm_output.csv";

    integer  fd;
    longint  cycle_count;

    // ── Open CSV and write header ──
    initial begin
        fd = $fopen(CSV_FILE, "w");
        if (fd == 0) begin
            $display("ERROR: could not open %s", CSV_FILE);
            $finish;
        end
        $fwrite(fd, "time_ns,clk,rst,sample_valid,din,dout\n");
    end

    // ── Reset sequence: hold reset for 20 cycles ──
    initial begin
        rst = 1;
        repeat (20) @(posedge clk);
        @(negedge clk);
        rst = 0;
    end

    // ── Main simulation loop ──
    initial begin
        cycle_count = 0;
        @(negedge rst);          // wait until reset released

        repeat (SIM_CYCLES) begin
            @(posedge clk);
            #1;                  // let outputs settle after clock edge
            // Write raw $time value - plot_dac.py auto-detects ns vs ps
            $fwrite(fd, "%0t,%0b,%0b,%0b,%0d,%0b\n",
                    $time, clk, rst, sample_valid, sample, dout);
            cycle_count++;
        end

        $fclose(fd);
        $display("Simulation complete: %0d cycles written to %s", cycle_count, CSV_FILE);

        // ── Invoke Python post-processing ──
        $display("Running plot_dac.py...");
        $system("python3 plot_dac.py");

        $finish;
    end

    // ── Timeout watchdog: 600 ms wall-time limit ──
    initial begin
        #600_000_000;
        $display("TIMEOUT: simulation exceeded 600 ms");
        $fclose(fd);
        $finish;
    end

endmodule