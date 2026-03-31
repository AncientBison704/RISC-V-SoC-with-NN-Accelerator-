// AXI4-Lite UART TX (simulation only)
// Accepts writes at any address in its range, outputs the low byte as a char.
// Address: 0x1000_0000

`timescale 1 ns / 1 ps

module axi_uart_tx (
    input clk,
    input resetn,

    // AXI4-Lite write address channel
    input         axi_awvalid,
    output reg    axi_awready,
    input  [31:0] axi_awaddr,

    // AXI4-Lite write data channel
    input         axi_wvalid,
    output reg    axi_wready,
    input  [31:0] axi_wdata,
    input  [ 3:0] axi_wstrb,

    // AXI4-Lite write response channel
    output reg    axi_bvalid,
    input         axi_bready
);

    reg aw_done;
    reg w_done;

    reg [31:0] latched_wdata;

    always @(posedge clk) begin
        if (!resetn) begin
            axi_awready <= 0;
            axi_wready  <= 0;
            axi_bvalid  <= 0;
            aw_done     <= 0;
            w_done      <= 0;
        end else begin
            // Deassert handshake signals
            if (axi_awready) axi_awready <= 0;
            if (axi_wready)  axi_wready  <= 0;

            // Write response accepted
            if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 0;
            end

            // Accept write address
            if (axi_awvalid && !axi_awready && !aw_done && !axi_bvalid) begin
                axi_awready <= 1;
                aw_done     <= 1;
            end

            // Accept write data
            if (axi_wvalid && !axi_wready && !w_done && !axi_bvalid) begin
                axi_wready   <= 1;
                w_done       <= 1;
                latched_wdata <= axi_wdata;
            end

            // Both address and data received: print and respond
            if (aw_done && w_done && !axi_bvalid) begin
                // Print character to simulation console
                $write("%c", latched_wdata[7:0]);
                $fflush();
                axi_bvalid <= 1;
                aw_done    <= 0;
                w_done     <= 0;
            end
        end
    end

endmodule
