// mac_array.v — Parallel MAC array for NN inference
//
// Instantiates NUM_UNITS parallel mac_unit modules.
// All units receive the same input activation (broadcast),
// but each gets its own weight and bias.
//
// Usage:
//   1. Set input_len, relu_en
//   2. Assert start for one cycle
//   3. On each subsequent cycle, provide in_data (shared) and
//      in_weight[i] for each unit
//   4. When all_done asserts, read out_data[i] for each unit

`timescale 1 ns / 1 ps

module mac_array #(
    parameter NUM_UNITS = 4   // number of parallel MAC units (neurons)
) (
    input  wire        clk,
    input  wire        resetn,

    // Control
    input  wire        start,
    input  wire [9:0]  input_len,
    input  wire        relu_en,
    output wire        any_busy,
    output wire        all_done,

    // Shared input activation (broadcast to all units)
    input  wire signed [15:0] in_data,

    // Per-unit weight and bias
    input  wire signed [NUM_UNITS*16-1:0] in_weights,  // packed: {w[N-1], ..., w[1], w[0]}
    input  wire signed [NUM_UNITS*16-1:0] in_biases,   // packed: {b[N-1], ..., b[1], b[0]}

    // Per-unit output
    output wire signed [NUM_UNITS*16-1:0] out_data,    // packed results
    output wire [NUM_UNITS-1:0]           out_valid
);

    wire [NUM_UNITS-1:0] unit_busy;
    wire [NUM_UNITS-1:0] unit_done;

    assign any_busy = |unit_busy;
    assign all_done = &unit_done;

    genvar i;
    generate
        for (i = 0; i < NUM_UNITS; i = i + 1) begin : gen_mac
            mac_unit u_mac (
                .clk       (clk),
                .resetn    (resetn),

                .start     (start),
                .input_len (input_len),
                .busy      (unit_busy[i]),
                .done      (unit_done[i]),

                .in_data   (in_data),
                .in_weight (in_weights[i*16 +: 16]),
                .in_bias   (in_biases[i*16 +: 16]),
                .relu_en   (relu_en),

                .out_data  (out_data[i*16 +: 16]),
                .out_valid (out_valid[i])
            );
        end
    endgenerate

endmodule
