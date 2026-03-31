// mac_array_tb.v — Testbench for MAC array
//
// Data protocol:
//   - Set in_data/in_weights BEFORE the rising clock edge
//   - Data changes on negedge to avoid setup races
//   - start pulse on same cycle as first data element

`timescale 1 ns / 1 ps

module mac_array_tb;

    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg         start;
    reg  [9:0]  input_len;
    reg         relu_en;
    wire        any_busy;
    wire        all_done;

    reg  signed [15:0] in_data;
    reg  signed [4*16-1:0] in_weights;
    reg  signed [4*16-1:0] in_biases;

    wire signed [4*16-1:0] out_data;
    wire [3:0] out_valid;

    wire signed [15:0] out0 = out_data[0*16 +: 16];
    wire signed [15:0] out1 = out_data[1*16 +: 16];
    wire signed [15:0] out2 = out_data[2*16 +: 16];
    wire signed [15:0] out3 = out_data[3*16 +: 16];

    mac_array #(.NUM_UNITS(4)) dut (
        .clk(clk), .resetn(resetn),
        .start(start), .input_len(input_len), .relu_en(relu_en),
        .any_busy(any_busy), .all_done(all_done),
        .in_data(in_data), .in_weights(in_weights), .in_biases(in_biases),
        .out_data(out_data), .out_valid(out_valid)
    );

    integer pass_count = 0;
    integer fail_count = 0;

    task check(input [255:0] name, input signed [15:0] got, input signed [15:0] expected);
        if (got == expected) begin
            $display("  PASS: %0s = 0x%04h", name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %0s = 0x%04h (expected 0x%04h)", name, got, expected);
            fail_count = fail_count + 1;
        end
    endtask

    // Capture results on out_valid
    reg signed [15:0] r0, r1, r2, r3;
    always @(posedge clk) begin
        if (out_valid[0]) begin
            r0 <= out0; r1 <= out1; r2 <= out2; r3 <= out3;
        end
    end

    // Wait for done and let capture register settle
    task wait_done;
        begin
            // Poll until out_valid fires
            while (!out_valid[0]) @(posedge clk);
            // out_valid is high now — capture reg latches this edge
            @(posedge clk);  // capture reg has the value
            @(posedge clk);  // now r0..r3 are safe to read (NBA settled)
        end
    endtask

    initial begin
        $dumpfile("mac_array_tb.vcd");
        $dumpvars(0, mac_array_tb);
    end

    initial begin
        start = 0; input_len = 0; relu_en = 0;
        in_data = 0; in_weights = 0; in_biases = 0;

        repeat (20) @(posedge clk);
        resetn <= 1;
        repeat (5) @(posedge clk);

        // ====================================================
        // TEST 1: Single element: 2.0 * 3.0 = 6.0 = 0x0600
        // ====================================================
        $display("\n=== TEST 1: Single element dot product ===");
        @(negedge clk);
        input_len  = 10'd1;
        relu_en    = 0;
        in_biases  = 0;
        in_data    = 16'sh0200;  // 2.0
        in_weights = {16'h0, 16'h0, 16'h0, 16'sh0300};  // w0=3.0
        start      = 1;
        @(negedge clk);
        start = 0;
        // Keep data stable for the compute cycle
        @(negedge clk);
        in_data = 0; in_weights = 0;

        wait_done;
        check("unit0", r0, 16'sh0600);
        repeat (3) @(posedge clk);

        // ====================================================
        // TEST 2: 4 elements: [1,2,0.5,-1]·[1,1,1,1] = 2.5 = 0x0280
        // ====================================================
        $display("\n=== TEST 2: 4-element dot product ===");
        @(negedge clk);
        input_len = 10'd4;
        relu_en   = 0;
        in_biases = 0;
        in_data    = 16'sh0100;  // element 0: 1.0
        in_weights = {16'h0, 16'h0, 16'h0, 16'sh0100};
        start = 1;
        @(negedge clk);
        start = 0;
        in_data    = 16'sh0200;  // element 1: 2.0
        in_weights = {16'h0, 16'h0, 16'h0, 16'sh0100};
        @(negedge clk);
        in_data    = 16'sh0080;  // element 2: 0.5
        in_weights = {16'h0, 16'h0, 16'h0, 16'sh0100};
        @(negedge clk);
        in_data    = 16'shFF00;  // element 3: -1.0
        in_weights = {16'h0, 16'h0, 16'h0, 16'sh0100};
        @(negedge clk);
        in_data = 0; in_weights = 0;

        wait_done;
        check("unit0", r0, 16'sh0280);
        repeat (3) @(posedge clk);

        // ====================================================
        // TEST 3: All 4 units parallel, 2 elements
        //   input: [1.0, 2.0]
        //   u0 w: [1,1]   → 3.0
        //   u1 w: [2,0]   → 2.0
        //   u2 w: [0,3]   → 6.0
        //   u3 w: [-1,-1] → -3.0
        // ====================================================
        $display("\n=== TEST 3: All 4 units parallel ===");
        @(negedge clk);
        input_len = 10'd2;
        relu_en   = 0;
        in_biases = 0;
        in_data = 16'sh0100;  // element 0: 1.0
        in_weights = {16'shFF00, 16'sh0000, 16'sh0200, 16'sh0100};
        start = 1;
        @(negedge clk);
        start = 0;
        in_data = 16'sh0200;  // element 1: 2.0
        in_weights = {16'shFF00, 16'sh0300, 16'sh0000, 16'sh0100};
        @(negedge clk);
        in_data = 0; in_weights = 0;

        wait_done;
        check("unit0", r0, 16'sh0300);
        check("unit1", r1, 16'sh0200);
        check("unit2", r2, 16'sh0600);
        check("unit3", r3, 16'shFD00);
        repeat (3) @(posedge clk);

        // ====================================================
        // TEST 4: ReLU clamps negative
        //   1.0 * -2.0 = -2.0, ReLU → 0
        // ====================================================
        $display("\n=== TEST 4: ReLU clamping ===");
        @(negedge clk);
        input_len = 10'd1;
        relu_en   = 1;
        in_biases = 0;
        in_data    = 16'sh0100;
        in_weights = {16'h0, 16'h0, 16'h0, 16'shFE00};
        start = 1;
        @(negedge clk);
        start = 0;
        @(negedge clk);
        in_data = 0; in_weights = 0;

        wait_done;
        check("unit0 relu", r0, 16'sh0000);
        repeat (3) @(posedge clk);

        // ====================================================
        // TEST 5: Negative passes through without ReLU
        //   1.0 * -2.0 = -2.0 = 0xFE00
        // ====================================================
        $display("\n=== TEST 5: Negative without ReLU ===");
        @(negedge clk);
        input_len = 10'd1;
        relu_en   = 0;
        in_biases = 0;
        in_data    = 16'sh0100;
        in_weights = {16'h0, 16'h0, 16'h0, 16'shFE00};
        start = 1;
        @(negedge clk);
        start = 0;
        @(negedge clk);
        in_data = 0; in_weights = 0;

        wait_done;
        check("unit0 neg", r0, 16'shFE00);
        repeat (3) @(posedge clk);

        // ====================================================
        // TEST 6: Bias: 1.0*1.0 + 0.5 = 1.5 = 0x0180
        // ====================================================
        $display("\n=== TEST 6: Bias addition ===");
        @(negedge clk);
        input_len = 10'd1;
        relu_en   = 0;
        in_biases = {16'h0, 16'h0, 16'h0, 16'sh0080};  // bias0=0.5
        in_data    = 16'sh0100;
        in_weights = {16'h0, 16'h0, 16'h0, 16'sh0100};
        start = 1;
        @(negedge clk);
        start = 0;
        @(negedge clk);
        in_data = 0; in_weights = 0;

        wait_done;
        check("unit0 bias", r0, 16'sh0180);
        repeat (3) @(posedge clk);

        // ====================================================
        $display("\n========================================");
        $display("  %0d / %0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  %0d TESTS FAILED", fail_count);
        $display("========================================\n");
        $finish;
    end

    initial begin
        repeat (50000) @(posedge clk);
        $display("TIMEOUT");
        $finish;
    end

endmodule
