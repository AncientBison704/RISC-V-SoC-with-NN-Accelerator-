// AXI4-Lite RAM (read/write, single-cycle response)
// 8 KB = 2048 words

`timescale 1 ns / 1 ps

module axi_ram #(
    parameter DEPTH = 2048  // number of 32-bit words
) (
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
    input         axi_bready,

    // AXI4-Lite read address channel
    input         axi_arvalid,
    output reg    axi_arready,
    input  [31:0] axi_araddr,

    // AXI4-Lite read data channel
    output reg        axi_rvalid,
    input             axi_rready,
    output reg [31:0] axi_rdata
);

    localparam AW = $clog2(DEPTH);

    reg [31:0] mem [0:DEPTH-1];

    // --- Write handling ---
    reg        wr_addr_latched;
    reg [31:0] wr_addr;

    always @(posedge clk) begin
        if (!resetn) begin
            axi_awready    <= 0;
            axi_wready     <= 0;
            axi_bvalid     <= 0;
            wr_addr_latched <= 0;
        end else begin
            // Deassert after handshake
            if (axi_awready) axi_awready <= 0;
            if (axi_wready)  axi_wready  <= 0;

            // Write response accepted
            if (axi_bvalid && axi_bready)
                axi_bvalid <= 0;

            // Latch write address
            if (axi_awvalid && !axi_awready && !wr_addr_latched) begin
                axi_awready     <= 1;
                wr_addr         <= axi_awaddr;
                wr_addr_latched <= 1;
            end

            // Perform write when we have both address and data
            if (axi_wvalid && !axi_wready && wr_addr_latched) begin
                axi_wready <= 1;
                // Byte-lane write
                if (axi_wstrb[0]) mem[(wr_addr - 32'h0000_1000) >> 2][ 7: 0] <= axi_wdata[ 7: 0];
                if (axi_wstrb[1]) mem[(wr_addr - 32'h0000_1000) >> 2][15: 8] <= axi_wdata[15: 8];
                if (axi_wstrb[2]) mem[(wr_addr - 32'h0000_1000) >> 2][23:16] <= axi_wdata[23:16];
                if (axi_wstrb[3]) mem[(wr_addr - 32'h0000_1000) >> 2][31:24] <= axi_wdata[31:24];
                axi_bvalid      <= 1;
                wr_addr_latched <= 0;
            end
        end
    end

    // --- Read handling ---
    always @(posedge clk) begin
        if (!resetn) begin
            axi_arready <= 0;
            axi_rvalid  <= 0;
            axi_rdata   <= 0;
        end else begin
            if (axi_arready) axi_arready <= 0;

            if (axi_rvalid && axi_rready)
                axi_rvalid <= 0;

            if (axi_arvalid && !axi_arready && !axi_rvalid) begin
                axi_arready <= 1;
                axi_rvalid  <= 1;
                axi_rdata   <= mem[(axi_araddr - 32'h0000_1000) >> 2];
            end
        end
    end

endmodule
