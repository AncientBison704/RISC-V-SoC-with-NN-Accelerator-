// nn_accelerator.v — AXI4-Lite Neural Network Accelerator
//
// Register map (byte addresses, relative to base 0x2000_0000):
//   0x000  CTRL     [W]  bit 0: start inference
//   0x004  STATUS   [R]  bit 0: busy, bit 1: done
//   0x008  CONFIG   [W]  [9:0] input_len, [19:10] num_neurons, bit 20: relu_en
//   0x00C  RESULT   [R]  [15:0] argmax class, [31:16] argmax value
//   0x010  CYCLES   [R]  inference cycle count
//
//   0x400 - 0x7FF  WEIGHTS [W]  weight memory (256 x 32-bit words = 512 Q8.8 values)
//   0x800 - 0x9FF  ACT_IN  [W]  input activation buffer  (128 x 32-bit = 256 Q8.8)
//   0xA00 - 0xBFF  ACT_OUT [R]  output activation buffer (128 x 32-bit = 256 Q8.8)
//   0xC00 - 0xCFF  BIAS    [W]  bias memory (64 x 32-bit = 128 Q8.8 values)
//
// Operation:
//   1. CPU writes weights to WEIGHTS region
//   2. CPU writes input activations to ACT_IN region
//   3. CPU writes biases to BIAS region
//   4. CPU writes CONFIG (input_len, num_neurons, relu)
//   5. CPU writes CTRL.start = 1
//   6. Accelerator reads activations + weights, feeds MAC array
//   7. CPU polls STATUS.done, reads ACT_OUT for results
//
// The MAC array has NUM_UNITS parallel units. If num_neurons > NUM_UNITS,
// the accelerator iterates in batches of NUM_UNITS.

`timescale 1 ns / 1 ps

module nn_accelerator #(
    parameter NUM_UNITS  = 4,
    parameter BASE_ADDR  = 32'h2000_0000
) (
    input clk,
    input resetn,

    // AXI4-Lite slave interface
    input         axi_awvalid,
    output reg    axi_awready,
    input  [31:0] axi_awaddr,

    input         axi_wvalid,
    output reg    axi_wready,
    input  [31:0] axi_wdata,
    input  [ 3:0] axi_wstrb,

    output reg    axi_bvalid,
    input         axi_bready,

    input         axi_arvalid,
    output reg    axi_arready,
    input  [31:0] axi_araddr,

    output reg        axi_rvalid,
    input             axi_rready,
    output reg [31:0] axi_rdata
);

    // =========================================================================
    // Address offsets (relative to BASE_ADDR)
    // =========================================================================
    localparam OFFSET_CTRL    = 12'h000;
    localparam OFFSET_STATUS  = 12'h004;
    localparam OFFSET_CONFIG  = 12'h008;
    localparam OFFSET_RESULT  = 12'h00C;
    localparam OFFSET_CYCLES  = 12'h010;

    // Memory regions (check bit [11])
    localparam REGION_WEIGHT  = 3'b001;  // 0x400-0x7FF
    localparam REGION_ACT_IN  = 3'b010;  // 0x800-0x9FF
    localparam REGION_ACT_OUT = 3'b010;  // 0xA00-0xBFF (read)
    localparam REGION_BIAS    = 3'b011;  // 0xC00-0xCFF

    // =========================================================================
    // Storage
    // =========================================================================
    reg [31:0] weight_mem [0:255];   // 256 words = 512 Q8.8 weights
    reg [31:0] act_in_mem [0:127];   // 128 words = 256 Q8.8 activations
    reg [31:0] act_out_mem [0:127];  // 128 words = 256 Q8.8 outputs
    reg [31:0] bias_mem [0:63];      // 64 words  = 128 Q8.8 biases

    // =========================================================================
    // Control/config registers
    // =========================================================================
    reg        ctrl_start;
    reg        status_busy;
    reg        status_done;
    reg [9:0]  cfg_input_len;    // number of input activations
    reg [9:0]  cfg_num_neurons;  // number of output neurons
    reg        cfg_relu_en;
    reg [31:0] cycle_count;
    reg [15:0] result_argmax_class;
    reg [15:0] result_argmax_value;

    // =========================================================================
    // MAC array interface
    // =========================================================================
    reg         mac_start;
    wire        mac_any_busy;
    wire        mac_all_done;
    reg  signed [15:0] mac_in_data;
    reg  signed [NUM_UNITS*16-1:0] mac_in_weights;
    reg  signed [NUM_UNITS*16-1:0] mac_in_biases;
    wire signed [NUM_UNITS*16-1:0] mac_out_data;
    wire [NUM_UNITS-1:0] mac_out_valid;

    mac_array #(.NUM_UNITS(NUM_UNITS)) u_mac_array (
        .clk        (clk),
        .resetn     (resetn),
        .start      (mac_start),
        .input_len  (cfg_input_len),
        .relu_en    (cfg_relu_en),
        .any_busy   (mac_any_busy),
        .all_done   (mac_all_done),
        .in_data    (mac_in_data),
        .in_weights (mac_in_weights),
        .in_biases  (mac_in_biases),
        .out_data   (mac_out_data),
        .out_valid  (mac_out_valid)
    );

    // =========================================================================
    // Inference FSM
    // =========================================================================
    localparam INF_IDLE    = 3'd0;
    localparam INF_START   = 3'd1;  // issue start pulse to MAC
    localparam INF_FEED    = 3'd2;  // feed data cycle by cycle
    localparam INF_WAIT    = 3'd3;  // wait for MAC done
    localparam INF_STORE   = 3'd4;  // store results, check if more batches
    localparam INF_ARGMAX  = 3'd5;  // compute argmax over all outputs
    localparam INF_DONE    = 3'd6;

    reg [2:0]  inf_state;
    reg [9:0]  inf_neuron_base;   // which batch of neurons we're computing
    reg [9:0]  inf_feed_idx;      // which input element we're feeding
    reg [9:0]  inf_total_neurons; // latched from config

    // Weight address: for neuron N, input I:
    //   weight_mem[(N * input_len + I) / 2]
    //   Each 32-bit word holds 2 Q8.8 weights (low half = even index)
    // For simplicity, we store weights as:
    //   weight_mem[word_addr][15:0]  = weight for even index
    //   weight_mem[word_addr][31:16] = weight for odd index

    // Helper: extract Q8.8 from activation memory
    // act_in_mem[idx/2][15:0] for even, [31:16] for odd
    function signed [15:0] get_act_in;
        input [9:0] idx;
        begin
            if (idx[0])
                get_act_in = act_in_mem[idx >> 1][31:16];
            else
                get_act_in = act_in_mem[idx >> 1][15:0];
        end
    endfunction

    // Helper: extract Q8.8 weight
    // Weights laid out as: neuron N, input I → index = N*input_len + I
    // weight_mem[flat_idx/2], low or high half
    function signed [15:0] get_weight;
        input [9:0] neuron;
        input [9:0] input_idx;
        reg [19:0] flat;
        begin
            flat = neuron * cfg_input_len + input_idx;
            if (flat[0])
                get_weight = weight_mem[flat >> 1][31:16];
            else
                get_weight = weight_mem[flat >> 1][15:0];
        end
    endfunction

    // Helper: extract Q8.8 bias
    function signed [15:0] get_bias;
        input [9:0] neuron;
        begin
            if (neuron[0])
                get_bias = bias_mem[neuron >> 1][31:16];
            else
                get_bias = bias_mem[neuron >> 1][15:0];
        end
    endfunction

    // Helper: store Q8.8 to output activation memory
    task store_act_out;
        input [9:0] idx;
        input signed [15:0] value;
        begin
            if (idx[0])
                act_out_mem[idx >> 1][31:16] <= value;
            else
                act_out_mem[idx >> 1][15:0] <= value;
        end
    endtask

    // Argmax computation
    reg [9:0]  argmax_idx;
    reg signed [15:0] argmax_val;
    reg [9:0]  argmax_scan_idx;

    integer i;

    always @(posedge clk) begin
        if (!resetn) begin
            inf_state       <= INF_IDLE;
            status_busy     <= 0;
            status_done     <= 0;
            ctrl_start      <= 0;
            mac_start       <= 0;
            cycle_count     <= 0;
            inf_neuron_base <= 0;
            inf_feed_idx    <= 0;
            inf_total_neurons <= 0;
            result_argmax_class <= 0;
            result_argmax_value <= 0;
            argmax_idx      <= 0;
            argmax_val      <= 16'sh8000;  // most negative
            argmax_scan_idx <= 0;
        end else begin
            mac_start <= 0;  // default: no start pulse

            case (inf_state)
                INF_IDLE: begin
                    if (ctrl_start) begin
                        ctrl_start      <= 0;
                        status_busy     <= 1;
                        status_done     <= 0;
                        cycle_count     <= 0;
                        inf_neuron_base <= 0;
                        inf_total_neurons <= cfg_num_neurons;
                        argmax_val      <= 16'sh8000;
                        argmax_idx      <= 0;
                        inf_state       <= INF_START;
                    end
                end

                INF_START: begin
                    // Set up biases and issue start pulse
                    for (i = 0; i < NUM_UNITS; i = i + 1) begin
                        if (inf_neuron_base + i < inf_total_neurons)
                            mac_in_biases[i*16 +: 16] <= get_bias(inf_neuron_base + i);
                        else
                            mac_in_biases[i*16 +: 16] <= 16'sh0000;
                    end

                    // Present first input element + weights on the bus
                    mac_in_data <= get_act_in(0);
                    for (i = 0; i < NUM_UNITS; i = i + 1) begin
                        if (inf_neuron_base + i < inf_total_neurons)
                            mac_in_weights[i*16 +: 16] <= get_weight(inf_neuron_base + i, 0);
                        else
                            mac_in_weights[i*16 +: 16] <= 16'sh0000;
                    end

                    mac_start    <= 1;
                    inf_feed_idx <= 1;  // element 0 is on the bus now
                    cycle_count  <= cycle_count + 1;

                    if (cfg_input_len == 10'd1)
                        inf_state <= INF_WAIT;  // single element, MAC goes IDLE→OUTPUT
                    else
                        inf_state <= INF_FEED;
                end

                INF_FEED: begin
                    // Feed next input element + corresponding weights
                    mac_in_data <= get_act_in(inf_feed_idx);
                    for (i = 0; i < NUM_UNITS; i = i + 1) begin
                        if (inf_neuron_base + i < inf_total_neurons)
                            mac_in_weights[i*16 +: 16] <= get_weight(inf_neuron_base + i, inf_feed_idx);
                        else
                            mac_in_weights[i*16 +: 16] <= 16'sh0000;
                    end

                    inf_feed_idx <= inf_feed_idx + 1;
                    cycle_count  <= cycle_count + 1;

                    if (inf_feed_idx + 1 == cfg_input_len)
                        inf_state <= INF_WAIT;
                end

                INF_WAIT: begin
                    cycle_count <= cycle_count + 1;
                    if (mac_all_done) begin
                        inf_state <= INF_STORE;
                    end
                end

                INF_STORE: begin
                    // Store MAC outputs to act_out_mem
                    for (i = 0; i < NUM_UNITS; i = i + 1) begin
                        if (inf_neuron_base + i < inf_total_neurons)
                            store_act_out(inf_neuron_base + i,
                                          mac_out_data[i*16 +: 16]);
                    end

                    // Find best in this batch (combinational scan)
                    // Use blocking assigns for local computation
                    begin
                        reg signed [15:0] batch_best_val;
                        reg [9:0] batch_best_idx;
                        batch_best_val = argmax_val;  // current global best
                        batch_best_idx = argmax_idx;
                        for (i = 0; i < NUM_UNITS; i = i + 1) begin
                            if (inf_neuron_base + i < inf_total_neurons) begin
                                if ($signed(mac_out_data[i*16 +: 16]) > $signed(batch_best_val)) begin
                                    batch_best_val = mac_out_data[i*16 +: 16];
                                    batch_best_idx = inf_neuron_base + i;
                                end
                            end
                        end
                        argmax_val <= batch_best_val;
                        argmax_idx <= batch_best_idx;
                    end

                    // Next batch or done?
                    if (inf_neuron_base + NUM_UNITS >= inf_total_neurons) begin
                        inf_state <= INF_DONE;
                    end else begin
                        inf_neuron_base <= inf_neuron_base + NUM_UNITS;
                        inf_state       <= INF_START;
                    end
                end

                INF_DONE: begin
                    result_argmax_class <= {6'b0, argmax_idx};
                    result_argmax_value <= argmax_val;
                    status_busy <= 0;
                    status_done <= 1;
                    inf_state   <= INF_IDLE;
                end

                default: inf_state <= INF_IDLE;
            endcase
        end
    end

    // =========================================================================
    // AXI Write handling
    // =========================================================================
    reg        wr_addr_valid;
    reg [31:0] wr_addr;

    always @(posedge clk) begin
        if (!resetn) begin
            axi_awready   <= 0;
            axi_wready    <= 0;
            axi_bvalid    <= 0;
            wr_addr_valid <= 0;
            cfg_input_len   <= 0;
            cfg_num_neurons <= 0;
            cfg_relu_en     <= 0;
        end else begin
            if (axi_awready) axi_awready <= 0;
            if (axi_wready)  axi_wready  <= 0;
            if (axi_bvalid && axi_bready) axi_bvalid <= 0;

            // Latch write address
            if (axi_awvalid && !axi_awready && !wr_addr_valid) begin
                axi_awready   <= 1;
                wr_addr       <= axi_awaddr - BASE_ADDR;
                wr_addr_valid <= 1;
            end

            // Process write data
            if (axi_wvalid && !axi_wready && wr_addr_valid) begin
                axi_wready <= 1;
                axi_bvalid <= 1;
                wr_addr_valid <= 0;

                // Decode write target
                if (wr_addr[11:0] == OFFSET_CTRL) begin
                    ctrl_start <= axi_wdata[0];
                end
                else if (wr_addr[11:0] == OFFSET_CONFIG) begin
                    cfg_input_len   <= axi_wdata[9:0];
                    cfg_num_neurons <= axi_wdata[19:10];
                    cfg_relu_en     <= axi_wdata[20];
                end
                else if (wr_addr[11:8] == 4'h4 || wr_addr[11:8] == 4'h5 ||
                         wr_addr[11:8] == 4'h6 || wr_addr[11:8] == 4'h7) begin
                    // Weight memory: 0x400-0x7FF
                    weight_mem[(wr_addr[9:0] - 10'h400) >> 2] <= axi_wdata;
                end
                else if (wr_addr[11:8] == 4'h8 || wr_addr[11:8] == 4'h9) begin
                    // Activation input: 0x800-0x9FF
                    act_in_mem[(wr_addr[9:0] - 10'h000) >> 2] <= axi_wdata;
                end
                else if (wr_addr[11:8] == 4'hC) begin
                    // Bias memory: 0xC00-0xCFF
                    bias_mem[(wr_addr[7:0]) >> 2] <= axi_wdata;
                end
            end
        end
    end

    // =========================================================================
    // AXI Read handling
    // =========================================================================
    always @(posedge clk) begin
        if (!resetn) begin
            axi_arready <= 0;
            axi_rvalid  <= 0;
            axi_rdata   <= 0;
        end else begin
            if (axi_arready) axi_arready <= 0;
            if (axi_rvalid && axi_rready) axi_rvalid <= 0;

            if (axi_arvalid && !axi_arready && !axi_rvalid) begin
                axi_arready <= 1;
                axi_rvalid  <= 1;

                case ((axi_araddr - BASE_ADDR) & 32'hFFF)
                    OFFSET_STATUS: axi_rdata <= {30'b0, status_done, status_busy};
                    OFFSET_RESULT: axi_rdata <= {result_argmax_value, result_argmax_class};
                    OFFSET_CYCLES: axi_rdata <= cycle_count;
                    default: begin
                        // Check if reading from ACT_OUT region
                        if (((axi_araddr - BASE_ADDR) & 12'hF00) == 12'hA00 ||
                            ((axi_araddr - BASE_ADDR) & 12'hF00) == 12'hB00)
                            axi_rdata <= act_out_mem[((axi_araddr - BASE_ADDR - 12'hA00) >> 2) & 7'h7F];
                        else
                            axi_rdata <= 32'h0;
                    end
                endcase
            end
        end
    end

endmodule
