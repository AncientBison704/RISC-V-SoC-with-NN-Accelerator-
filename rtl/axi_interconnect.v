// AXI4-Lite Interconnect (1 master -> 4 slaves)
//
// Memory map:
//   0x0000_0000 - 0x0000_0FFF : ROM  (4 KB)  - read only
//   0x0000_1000 - 0x0000_2FFF : RAM  (8 KB)  - read/write
//   0x1000_0000               : UART TX       - write only
//   0x2000_0000 - 0x2000_0FFF : NN Accel      - read/write

`timescale 1 ns / 1 ps

module axi_interconnect (
    input clk,
    input resetn,

    // Master port (CPU)
    input         m_axi_awvalid,
    output        m_axi_awready,
    input  [31:0] m_axi_awaddr,
    input  [ 2:0] m_axi_awprot,
    input         m_axi_wvalid,
    output        m_axi_wready,
    input  [31:0] m_axi_wdata,
    input  [ 3:0] m_axi_wstrb,
    output        m_axi_bvalid,
    input         m_axi_bready,
    input         m_axi_arvalid,
    output        m_axi_arready,
    input  [31:0] m_axi_araddr,
    input  [ 2:0] m_axi_arprot,
    output        m_axi_rvalid,
    input         m_axi_rready,
    output [31:0] m_axi_rdata,

    // Slave 0: ROM (read only)
    output        s0_axi_arvalid,
    input         s0_axi_arready,
    output [31:0] s0_axi_araddr,
    input         s0_axi_rvalid,
    output        s0_axi_rready,
    input  [31:0] s0_axi_rdata,

    // Slave 1: RAM (read/write)
    output        s1_axi_awvalid,
    input         s1_axi_awready,
    output [31:0] s1_axi_awaddr,
    output        s1_axi_wvalid,
    input         s1_axi_wready,
    output [31:0] s1_axi_wdata,
    output [ 3:0] s1_axi_wstrb,
    input         s1_axi_bvalid,
    output        s1_axi_bready,
    output        s1_axi_arvalid,
    input         s1_axi_arready,
    output [31:0] s1_axi_araddr,
    input         s1_axi_rvalid,
    output        s1_axi_rready,
    input  [31:0] s1_axi_rdata,

    // Slave 2: UART (write only)
    output        s2_axi_awvalid,
    input         s2_axi_awready,
    output [31:0] s2_axi_awaddr,
    output        s2_axi_wvalid,
    input         s2_axi_wready,
    output [31:0] s2_axi_wdata,
    output [ 3:0] s2_axi_wstrb,
    input         s2_axi_bvalid,
    output        s2_axi_bready,

    // Slave 3: NN Accelerator (read/write)
    output        s3_axi_awvalid,
    input         s3_axi_awready,
    output [31:0] s3_axi_awaddr,
    output        s3_axi_wvalid,
    input         s3_axi_wready,
    output [31:0] s3_axi_wdata,
    output [ 3:0] s3_axi_wstrb,
    input         s3_axi_bvalid,
    output        s3_axi_bready,
    output        s3_axi_arvalid,
    input         s3_axi_arready,
    output [31:0] s3_axi_araddr,
    input         s3_axi_rvalid,
    output        s3_axi_rready,
    input  [31:0] s3_axi_rdata
);

    // Address decode
    wire rd_is_rom  = (m_axi_araddr < 32'h0000_1000);
    wire rd_is_ram  = (m_axi_araddr >= 32'h0000_1000) && (m_axi_araddr < 32'h0000_3000);
    wire rd_is_nn   = (m_axi_araddr[31:12] == 20'h2000_0);

    wire wr_is_ram  = (m_axi_awaddr >= 32'h0000_1000) && (m_axi_awaddr < 32'h0000_3000);
    wire wr_is_uart = (m_axi_awaddr[31:4] == 28'h1000_000);
    wire wr_is_nn   = (m_axi_awaddr[31:12] == 20'h2000_0);

    // =========================================================================
    // Read path
    // =========================================================================
    // States: 0=idle, 1=ROM, 2=RAM, 3=NN
    reg [2:0] rd_state;

    always @(posedge clk) begin
        if (!resetn)
            rd_state <= 0;
        else case (rd_state)
            3'd0: if (m_axi_arvalid) begin
                if (rd_is_rom)       rd_state <= 3'd1;
                else if (rd_is_ram)  rd_state <= 3'd2;
                else if (rd_is_nn)   rd_state <= 3'd3;
            end
            3'd1: if (s0_axi_rvalid && m_axi_rready) rd_state <= 3'd0;
            3'd2: if (s1_axi_rvalid && m_axi_rready) rd_state <= 3'd0;
            3'd3: if (s3_axi_rvalid && m_axi_rready) rd_state <= 3'd0;
            default: rd_state <= 3'd0;
        endcase
    end

    // AR routing
    assign s0_axi_arvalid = m_axi_arvalid && rd_is_rom && (rd_state == 0);
    assign s0_axi_araddr  = m_axi_araddr;
    assign s1_axi_arvalid = m_axi_arvalid && rd_is_ram && (rd_state == 0);
    assign s1_axi_araddr  = m_axi_araddr;
    assign s3_axi_arvalid = m_axi_arvalid && rd_is_nn  && (rd_state == 0);
    assign s3_axi_araddr  = m_axi_araddr;

    assign m_axi_arready = (rd_state == 0) && (
        (rd_is_rom && s0_axi_arready) ||
        (rd_is_ram && s1_axi_arready) ||
        (rd_is_nn  && s3_axi_arready) ||
        (!rd_is_rom && !rd_is_ram && !rd_is_nn));

    // R mux
    assign m_axi_rvalid = (rd_state == 1) ? s0_axi_rvalid :
                          (rd_state == 2) ? s1_axi_rvalid :
                          (rd_state == 3) ? s3_axi_rvalid : 1'b0;
    assign m_axi_rdata  = (rd_state == 1) ? s0_axi_rdata :
                          (rd_state == 2) ? s1_axi_rdata :
                          (rd_state == 3) ? s3_axi_rdata : 32'hDEAD_BEEF;
    assign s0_axi_rready = (rd_state == 1) ? m_axi_rready : 1'b0;
    assign s1_axi_rready = (rd_state == 2) ? m_axi_rready : 1'b0;
    assign s3_axi_rready = (rd_state == 3) ? m_axi_rready : 1'b0;

    // =========================================================================
    // Write path
    // =========================================================================
    // States: 0=idle, 1=RAM, 2=UART, 3=NN
    reg [2:0] wr_state;

    always @(posedge clk) begin
        if (!resetn)
            wr_state <= 0;
        else case (wr_state)
            3'd0: if (m_axi_awvalid) begin
                if (wr_is_ram)       wr_state <= 3'd1;
                else if (wr_is_uart) wr_state <= 3'd2;
                else if (wr_is_nn)   wr_state <= 3'd3;
            end
            3'd1: if (s1_axi_bvalid && m_axi_bready) wr_state <= 3'd0;
            3'd2: if (s2_axi_bvalid && m_axi_bready) wr_state <= 3'd0;
            3'd3: if (s3_axi_bvalid && m_axi_bready) wr_state <= 3'd0;
            default: wr_state <= 3'd0;
        endcase
    end

    // AW routing
    assign s1_axi_awvalid = m_axi_awvalid && wr_is_ram  && (wr_state == 0);
    assign s1_axi_awaddr  = m_axi_awaddr;
    assign s2_axi_awvalid = m_axi_awvalid && wr_is_uart && (wr_state == 0);
    assign s2_axi_awaddr  = m_axi_awaddr;
    assign s3_axi_awvalid = m_axi_awvalid && wr_is_nn   && (wr_state == 0);
    assign s3_axi_awaddr  = m_axi_awaddr;

    assign m_axi_awready = (wr_state == 0) && (
        (wr_is_ram  && s1_axi_awready) ||
        (wr_is_uart && s2_axi_awready) ||
        (wr_is_nn   && s3_axi_awready) ||
        (!wr_is_ram && !wr_is_uart && !wr_is_nn));

    // W routing
    assign s1_axi_wvalid = (wr_state == 1 || (wr_state == 0 && wr_is_ram))  ? m_axi_wvalid : 1'b0;
    assign s1_axi_wdata  = m_axi_wdata;
    assign s1_axi_wstrb  = m_axi_wstrb;
    assign s2_axi_wvalid = (wr_state == 2 || (wr_state == 0 && wr_is_uart)) ? m_axi_wvalid : 1'b0;
    assign s2_axi_wdata  = m_axi_wdata;
    assign s2_axi_wstrb  = m_axi_wstrb;
    assign s3_axi_wvalid = (wr_state == 3 || (wr_state == 0 && wr_is_nn))   ? m_axi_wvalid : 1'b0;
    assign s3_axi_wdata  = m_axi_wdata;
    assign s3_axi_wstrb  = m_axi_wstrb;

    assign m_axi_wready = (wr_state == 1) ? s1_axi_wready :
                          (wr_state == 2) ? s2_axi_wready :
                          (wr_state == 3) ? s3_axi_wready :
                          wr_is_ram       ? s1_axi_wready :
                          wr_is_uart      ? s2_axi_wready :
                          wr_is_nn        ? s3_axi_wready : 1'b1;

    // B mux
    assign m_axi_bvalid  = (wr_state == 1) ? s1_axi_bvalid :
                           (wr_state == 2) ? s2_axi_bvalid :
                           (wr_state == 3) ? s3_axi_bvalid : 1'b0;
    assign s1_axi_bready = (wr_state == 1) ? m_axi_bready : 1'b0;
    assign s2_axi_bready = (wr_state == 2) ? m_axi_bready : 1'b0;
    assign s3_axi_bready = (wr_state == 3) ? m_axi_bready : 1'b0;

endmodule
