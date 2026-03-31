// SoC Top: PicoRV32 + ROM + RAM + UART + NN Accelerator
//
// Memory map:
//   0x0000_0000 - 0x0000_0FFF : ROM  (4 KB)
//   0x0000_1000 - 0x0000_2FFF : RAM  (8 KB)
//   0x1000_0000               : UART TX
//   0x2000_0000 - 0x2000_0FFF : NN Accelerator

`timescale 1 ns / 1 ps

module soc_top (
    input clk,
    input resetn,
    output trap
);

    // CPU AXI master
    wire        cpu_axi_awvalid, cpu_axi_awready;
    wire [31:0] cpu_axi_awaddr;
    wire [ 2:0] cpu_axi_awprot;
    wire        cpu_axi_wvalid, cpu_axi_wready;
    wire [31:0] cpu_axi_wdata;
    wire [ 3:0] cpu_axi_wstrb;
    wire        cpu_axi_bvalid, cpu_axi_bready;
    wire        cpu_axi_arvalid, cpu_axi_arready;
    wire [31:0] cpu_axi_araddr;
    wire [ 2:0] cpu_axi_arprot;
    wire        cpu_axi_rvalid, cpu_axi_rready;
    wire [31:0] cpu_axi_rdata;

    // ROM signals
    wire        rom_arvalid, rom_arready;
    wire [31:0] rom_araddr;
    wire        rom_rvalid, rom_rready;
    wire [31:0] rom_rdata;

    // RAM signals
    wire        ram_awvalid, ram_awready;
    wire [31:0] ram_awaddr;
    wire        ram_wvalid, ram_wready;
    wire [31:0] ram_wdata;
    wire [ 3:0] ram_wstrb;
    wire        ram_bvalid, ram_bready;
    wire        ram_arvalid, ram_arready;
    wire [31:0] ram_araddr;
    wire        ram_rvalid, ram_rready;
    wire [31:0] ram_rdata;

    // UART signals
    wire        uart_awvalid, uart_awready;
    wire [31:0] uart_awaddr;
    wire        uart_wvalid, uart_wready;
    wire [31:0] uart_wdata;
    wire [ 3:0] uart_wstrb;
    wire        uart_bvalid, uart_bready;

    // NN Accelerator signals
    wire        nn_awvalid, nn_awready;
    wire [31:0] nn_awaddr;
    wire        nn_wvalid, nn_wready;
    wire [31:0] nn_wdata;
    wire [ 3:0] nn_wstrb;
    wire        nn_bvalid, nn_bready;
    wire        nn_arvalid, nn_arready;
    wire [31:0] nn_araddr;
    wire        nn_rvalid, nn_rready;
    wire [31:0] nn_rdata;

    // ========================================================
    // CPU
    // ========================================================
    picorv32_axi #(
        .ENABLE_MUL(1), .ENABLE_DIV(1), .ENABLE_IRQ(0), .ENABLE_TRACE(0),
        .PROGADDR_RESET(32'h0000_0000), .STACKADDR(32'h0000_3000)
    ) cpu (
        .clk(clk), .resetn(resetn), .trap(trap),
        .mem_axi_awvalid(cpu_axi_awvalid), .mem_axi_awready(cpu_axi_awready),
        .mem_axi_awaddr(cpu_axi_awaddr),   .mem_axi_awprot(cpu_axi_awprot),
        .mem_axi_wvalid(cpu_axi_wvalid),   .mem_axi_wready(cpu_axi_wready),
        .mem_axi_wdata(cpu_axi_wdata),     .mem_axi_wstrb(cpu_axi_wstrb),
        .mem_axi_bvalid(cpu_axi_bvalid),   .mem_axi_bready(cpu_axi_bready),
        .mem_axi_arvalid(cpu_axi_arvalid), .mem_axi_arready(cpu_axi_arready),
        .mem_axi_araddr(cpu_axi_araddr),   .mem_axi_arprot(cpu_axi_arprot),
        .mem_axi_rvalid(cpu_axi_rvalid),   .mem_axi_rready(cpu_axi_rready),
        .mem_axi_rdata(cpu_axi_rdata),
        .irq(32'b0), .eoi(), .trace_valid(), .trace_data(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0)
    );

    // ========================================================
    // Interconnect
    // ========================================================
    axi_interconnect bus (
        .clk(clk), .resetn(resetn),
        // Master
        .m_axi_awvalid(cpu_axi_awvalid), .m_axi_awready(cpu_axi_awready),
        .m_axi_awaddr(cpu_axi_awaddr),   .m_axi_awprot(cpu_axi_awprot),
        .m_axi_wvalid(cpu_axi_wvalid),   .m_axi_wready(cpu_axi_wready),
        .m_axi_wdata(cpu_axi_wdata),     .m_axi_wstrb(cpu_axi_wstrb),
        .m_axi_bvalid(cpu_axi_bvalid),   .m_axi_bready(cpu_axi_bready),
        .m_axi_arvalid(cpu_axi_arvalid), .m_axi_arready(cpu_axi_arready),
        .m_axi_araddr(cpu_axi_araddr),   .m_axi_arprot(cpu_axi_arprot),
        .m_axi_rvalid(cpu_axi_rvalid),   .m_axi_rready(cpu_axi_rready),
        .m_axi_rdata(cpu_axi_rdata),
        // S0: ROM
        .s0_axi_arvalid(rom_arvalid), .s0_axi_arready(rom_arready),
        .s0_axi_araddr(rom_araddr),
        .s0_axi_rvalid(rom_rvalid),   .s0_axi_rready(rom_rready),
        .s0_axi_rdata(rom_rdata),
        // S1: RAM
        .s1_axi_awvalid(ram_awvalid), .s1_axi_awready(ram_awready),
        .s1_axi_awaddr(ram_awaddr),
        .s1_axi_wvalid(ram_wvalid),   .s1_axi_wready(ram_wready),
        .s1_axi_wdata(ram_wdata),     .s1_axi_wstrb(ram_wstrb),
        .s1_axi_bvalid(ram_bvalid),   .s1_axi_bready(ram_bready),
        .s1_axi_arvalid(ram_arvalid), .s1_axi_arready(ram_arready),
        .s1_axi_araddr(ram_araddr),
        .s1_axi_rvalid(ram_rvalid),   .s1_axi_rready(ram_rready),
        .s1_axi_rdata(ram_rdata),
        // S2: UART
        .s2_axi_awvalid(uart_awvalid), .s2_axi_awready(uart_awready),
        .s2_axi_awaddr(uart_awaddr),
        .s2_axi_wvalid(uart_wvalid),   .s2_axi_wready(uart_wready),
        .s2_axi_wdata(uart_wdata),     .s2_axi_wstrb(uart_wstrb),
        .s2_axi_bvalid(uart_bvalid),   .s2_axi_bready(uart_bready),
        // S3: NN Accelerator
        .s3_axi_awvalid(nn_awvalid),   .s3_axi_awready(nn_awready),
        .s3_axi_awaddr(nn_awaddr),
        .s3_axi_wvalid(nn_wvalid),     .s3_axi_wready(nn_wready),
        .s3_axi_wdata(nn_wdata),       .s3_axi_wstrb(nn_wstrb),
        .s3_axi_bvalid(nn_bvalid),     .s3_axi_bready(nn_bready),
        .s3_axi_arvalid(nn_arvalid),   .s3_axi_arready(nn_arready),
        .s3_axi_araddr(nn_araddr),
        .s3_axi_rvalid(nn_rvalid),     .s3_axi_rready(nn_rready),
        .s3_axi_rdata(nn_rdata)
    );

    // ========================================================
    // ROM (4 KB)
    // ========================================================
    axi_rom #(.DEPTH(1024)) rom (
        .clk(clk), .resetn(resetn),
        .axi_arvalid(rom_arvalid), .axi_arready(rom_arready),
        .axi_araddr(rom_araddr),
        .axi_rvalid(rom_rvalid),   .axi_rready(rom_rready),
        .axi_rdata(rom_rdata)
    );

    // ========================================================
    // RAM (8 KB)
    // ========================================================
    axi_ram #(.DEPTH(2048)) ram (
        .clk(clk), .resetn(resetn),
        .axi_awvalid(ram_awvalid), .axi_awready(ram_awready), .axi_awaddr(ram_awaddr),
        .axi_wvalid(ram_wvalid),   .axi_wready(ram_wready),
        .axi_wdata(ram_wdata),     .axi_wstrb(ram_wstrb),
        .axi_bvalid(ram_bvalid),   .axi_bready(ram_bready),
        .axi_arvalid(ram_arvalid), .axi_arready(ram_arready), .axi_araddr(ram_araddr),
        .axi_rvalid(ram_rvalid),   .axi_rready(ram_rready),   .axi_rdata(ram_rdata)
    );

    // ========================================================
    // UART TX
    // ========================================================
    axi_uart_tx uart (
        .clk(clk), .resetn(resetn),
        .axi_awvalid(uart_awvalid), .axi_awready(uart_awready), .axi_awaddr(uart_awaddr),
        .axi_wvalid(uart_wvalid),   .axi_wready(uart_wready),
        .axi_wdata(uart_wdata),     .axi_wstrb(uart_wstrb),
        .axi_bvalid(uart_bvalid),   .axi_bready(uart_bready)
    );

    // ========================================================
    // NN Accelerator
    // ========================================================
    nn_accelerator #(.NUM_UNITS(4), .BASE_ADDR(32'h2000_0000)) nn_accel (
        .clk(clk), .resetn(resetn),
        .axi_awvalid(nn_awvalid), .axi_awready(nn_awready), .axi_awaddr(nn_awaddr),
        .axi_wvalid(nn_wvalid),   .axi_wready(nn_wready),
        .axi_wdata(nn_wdata),     .axi_wstrb(nn_wstrb),
        .axi_bvalid(nn_bvalid),   .axi_bready(nn_bready),
        .axi_arvalid(nn_arvalid), .axi_arready(nn_arready), .axi_araddr(nn_araddr),
        .axi_rvalid(nn_rvalid),   .axi_rready(nn_rready),   .axi_rdata(nn_rdata)
    );

endmodule
