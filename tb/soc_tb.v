// Testbench for soc_top
// Loads firmware hex into ROM, runs simulation, watches for UART output and trap

`timescale 1 ns / 1 ps

module soc_tb;

    reg clk = 1;
    reg resetn = 0;
    wire trap;

    // 100 MHz clock (10 ns period)
    always #5 clk = ~clk;

    // Hold reset for 100 cycles then release
    initial begin
        repeat (100) @(posedge clk);
        resetn <= 1;
        $display("[TB] Reset released at time %0t", $time);
    end

    // Timeout watchdog
    integer cycle_count;
    always @(posedge clk) begin
        if (!resetn)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    initial begin
        // VCD dump for waveform viewing
        $dumpfile("soc_tb.vcd");
        $dumpvars(0, soc_tb);

        // Timeout after 200k cycles
        repeat (200_000) @(posedge clk);
        $display("\n[TB] TIMEOUT after %0d cycles", cycle_count);
        $finish;
    end

    // Trap detection
    always @(posedge clk) begin
        if (resetn && trap) begin
            $display("\n[TB] CPU TRAP at cycle %0d", cycle_count);
            repeat (10) @(posedge clk);
            $finish;
        end
    end

    // DUT
    soc_top dut (
        .clk    (clk),
        .resetn (resetn),
        .trap   (trap)
    );

    // Load firmware into ROM
    reg [1023:0] firmware_file;
    initial begin
        if (!$value$plusargs("firmware=%s", firmware_file))
            firmware_file = "firmware.hex";
        $display("[TB] Loading firmware: %0s", firmware_file);
        $readmemh(firmware_file, dut.rom.mem);
    end

endmodule
