// AXI4-Lite ROM (read-only, single-cycle response)
// 4 KB = 1024 words, initialized from firmware hex via $readmemh

`timescale 1 ns / 1 ps

module axi_rom #(
    parameter DEPTH = 1024  // number of 32-bit words
) (
    input clk,
    input resetn,

    // AXI4-Lite read channel only
    input         axi_arvalid,
    output reg    axi_arready,
    input  [31:0] axi_araddr,

    output reg        axi_rvalid,
    input             axi_rready,
    output reg [31:0] axi_rdata
);

    reg [31:0] mem [0:DEPTH-1];

    // Simple single-cycle read
    always @(posedge clk) begin
        if (!resetn) begin
            axi_arready <= 0;
            axi_rvalid  <= 0;
            axi_rdata   <= 0;
        end else begin
            // Deassert ready after handshake
            if (axi_arready)
                axi_arready <= 0;

            // Deassert rvalid after read data accepted
            if (axi_rvalid && axi_rready)
                axi_rvalid <= 0;

            // Accept new read request
            if (axi_arvalid && !axi_arready && !axi_rvalid) begin
                axi_arready <= 1;
                axi_rvalid  <= 1;
                axi_rdata   <= mem[axi_araddr[($clog2(DEPTH)+1):2]];
            end
        end
    end

endmodule
