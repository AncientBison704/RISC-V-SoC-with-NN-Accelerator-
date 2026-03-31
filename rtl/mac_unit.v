// mac_unit.v — Single neuron MAC (Multiply-Accumulate) unit
//
// Computes: output = ReLU( (sum of input[i] * weight[i]) >> 8 + bias )
//
// Fixed-point format: Q8.8 (signed 16-bit)
//   - Inputs/Weights: 16-bit signed
//   - Accumulator: 32-bit signed (holds Q16.16 intermediate)
//   - Output: 16-bit signed Q8.8 (after >>8 and clamp)
//
// Protocol:
//   1. Set input_len, in_bias, relu_en
//   2. Assert start=1 with first in_data/in_weight pair
//   3. On each subsequent cycle, provide next in_data/in_weight
//   4. After input_len cycles of data feeding, result appears on out_data
//      with out_valid=1
//
// Timing:
//   - Data is sampled on the cycle AFTER start (first compute cycle)
//   - Total latency: input_len + 1 cycles (start + N compute + output)

`timescale 1 ns / 1 ps

module mac_unit (
    input  wire        clk,
    input  wire        resetn,

    // Control
    input  wire        start,
    input  wire [9:0]  input_len,
    output reg         busy,
    output reg         done,

    // Data input (one pair per cycle during COMPUTE)
    input  wire signed [15:0] in_data,
    input  wire signed [15:0] in_weight,
    input  wire signed [15:0] in_bias,

    // ReLU enable
    input  wire        relu_en,

    // Result
    output reg  signed [15:0] out_data,
    output reg                out_valid
);

    // States
    localparam S_IDLE    = 2'd0;
    localparam S_COMPUTE = 2'd1;
    localparam S_OUTPUT  = 2'd2;

    reg [1:0] state;
    reg signed [31:0] accum;
    reg [9:0] count;
    reg [9:0] target_len;
    reg signed [15:0] latched_bias;
    reg latched_relu;

    // Combinational multiply
    wire signed [31:0] mult_result = in_data * in_weight;

    // Combinational output (reads registered accum)
    wire signed [31:0] accum_shifted = accum >>> 8;
    wire signed [31:0] bias_ext = {{16{latched_bias[15]}}, latched_bias};
    wire signed [31:0] result_biased = accum_shifted + bias_ext;

    always @(posedge clk) begin
        if (!resetn) begin
            state        <= S_IDLE;
            busy         <= 0;
            done         <= 0;
            out_valid    <= 0;
            out_data     <= 0;
            accum        <= 0;
            count        <= 0;
            target_len   <= 0;
            latched_bias <= 0;
            latched_relu <= 0;
        end else begin
            // Defaults: clear pulses
            done      <= 0;
            out_valid <= 0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state        <= S_COMPUTE;
                        busy         <= 1;
                        accum        <= mult_result;  // capture first element NOW
                        count        <= 1;            // one element already done
                        target_len   <= input_len;
                        latched_bias <= in_bias;
                        latched_relu <= relu_en;

                        // If only one element, go straight to output
                        if (input_len == 10'd1)
                            state <= S_OUTPUT;
                    end
                end

                S_COMPUTE: begin
                    // Each cycle: accumulate one input*weight product
                    accum <= accum + mult_result;
                    count <= count + 1;

                    // After target_len accumulations, move to output
                    if (count + 10'd1 == target_len) begin
                        state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    // accum now holds final sum in Q16.16
                    // Shift right by 8 → Q8.8, add bias, apply ReLU
                    if (result_biased > 32'sh00007FFF)
                        out_data <= 16'h7FFF;
                    else if (result_biased < -32'sh00008000)
                        out_data <= 16'h8000;
                    else if (latched_relu && result_biased[31])
                        out_data <= 16'h0000;
                    else
                        out_data <= result_biased[15:0];

                    out_valid <= 1;
                    done      <= 1;
                    busy      <= 0;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
