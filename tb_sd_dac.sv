// =============================================================================
// tb_sd_dac.sv  (v4 - fixed $system path for xsim)
// =============================================================================

`timescale 1ns/1ps

module tb_sd_dac;

    logic clk;
    logic rst;
    logic [12:0] sample;
    logic        sample_valid;
    logic        dout;

    sine_gen u_sine_gen (
        .clk          (clk),
        .rst          (rst),
        .sample       (sample),
        .sample_valid (sample_valid)
    );

    sd_dac_8k u_sd_dac (
        .clk        (clk),
        .rst        (rst),
        .samp_valid (sample_valid),
        .din        (sample),
        .dout       (dout)
    );

    // 100 MHz clock
    initial clk = 0;
    always #5 clk = ~clk;

    // 50 ms simulation = 5,000,000 cycles at 100 MHz
    localparam SIM_CYCLES = 5_000_000;

    // ── EDIT THIS PATH to point to where plot_dac.py lives on your machine ──
    localparam CSV_PATH   = "/home/caccolillo/sigma_delta_dac/pdm_output.csv";
    localparam PLOT_CMD   = "python3 /home/caccolillo/sigma_delta_dac/plot_dac.py";

    integer  fd;
    longint  cycle_count;

    initial begin
        fd = $fopen(CSV_PATH, "w");
        if (fd == 0) begin
            $display("ERROR: could not open %s", CSV_PATH);
            $finish;
        end
        $fwrite(fd, "time_ns,clk,rst,sample_valid,din,dout\n");
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
            $fwrite(fd, "%0t,%0b,%0b,%0b,%0d,%0b\n",
                    $time, clk, rst, sample_valid, sample, dout);
            cycle_count++;
        end

        $fclose(fd);
        $display("Simulation complete: %0d cycles written to %s",
                 cycle_count, CSV_PATH);

        $display("Running plot_dac.py...");
        $system(PLOT_CMD);

        $finish;
    end

    // Watchdog
    initial begin
        #600_000_000;
        $display("TIMEOUT");
        $fclose(fd);
        $finish;
    end

endmodule