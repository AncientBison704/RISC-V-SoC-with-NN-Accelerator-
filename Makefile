################################################################################
# Makefile for RISC-V NN SoC (simulation-only, Week 1: CPU bring-up)
#
# Targets:
#   make fw          - Compile firmware to hex
#   make sim         - Build and run simulation (iverilog + vvp)
#   make wave        - Open waveform viewer (gtkwave)
#   make clean       - Remove generated files
#
# Requirements:
#   - riscv64-unknown-elf-gcc (or riscv32-unknown-elf-gcc)
#   - iverilog / vvp (Icarus Verilog) OR vcs
#   - python3 (for makehex.py)
################################################################################

# ---- Toolchain ----
CROSS    ?= riscv64-unknown-elf-
CC        = $(CROSS)gcc
OBJCOPY   = $(CROSS)objcopy

# RISC-V flags: RV32IM, ilp32 ABI, optimize for size, no std lib
ARCH      = rv32im
ABI       = ilp32
CFLAGS    = -march=$(ARCH) -mabi=$(ABI) -Os -ffreestanding -nostdlib -Wall
LDFLAGS   = -march=$(ARCH) -mabi=$(ABI) -T fw/link.ld -nostdlib -Wl,--gc-sections

# ---- RTL sources ----
RTL_DIR   = rtl
RTL_SRC   = $(RTL_DIR)/picorv32.v \
            $(RTL_DIR)/axi_interconnect.v \
            $(RTL_DIR)/axi_rom.v \
            $(RTL_DIR)/axi_ram.v \
            $(RTL_DIR)/axi_uart_tx.v \
            $(RTL_DIR)/mac_unit.v \
            $(RTL_DIR)/mac_array.v \
            $(RTL_DIR)/nn_accelerator.v \
            $(RTL_DIR)/soc_top.v

TB_SRC    = tb/soc_tb.v

# ---- Firmware sources ----
FW_SRC    = fw/start.S fw/main.c
FW_ELF    = sim/firmware.elf
FW_BIN    = sim/firmware.bin
FW_HEX    = sim/firmware.hex

# ---- Simulation outputs ----
SIM_OUT   = sim/soc_tb
VCD_FILE  = soc_tb.vcd

# ROM depth in 32-bit words (4 KB / 4)
ROM_WORDS = 1024

################################################################################
# Firmware
################################################################################

.PHONY: fw
fw: $(FW_HEX)

sim/start.o: fw/start.S
	$(CC) $(CFLAGS) -c -o $@ $<

sim/main.o: fw/main.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(FW_ELF): sim/start.o sim/main.o fw/link.ld
	$(CC) $(LDFLAGS) -o $@ sim/start.o sim/main.o

$(FW_BIN): $(FW_ELF)
	$(OBJCOPY) -O binary $< $@

$(FW_HEX): $(FW_BIN)
	python3 scripts/makehex.py $< $(ROM_WORDS) > $@

################################################################################
# Simulation (Icarus Verilog)
################################################################################

.PHONY: sim
sim: $(FW_HEX) $(SIM_OUT)
	cd sim && vvp ../$(SIM_OUT) +firmware=firmware.hex

$(SIM_OUT): $(RTL_SRC) $(TB_SRC)
	iverilog -g2012 -o $@ -s soc_tb $(RTL_SRC) $(TB_SRC)

################################################################################
# Simulation (Synopsys VCS) -- uncomment to use instead of iverilog
################################################################################

# .PHONY: sim-vcs
# sim-vcs: $(FW_HEX)
# 	cd sim && vcs -full64 -sverilog -timescale=1ns/1ps \
# 	    $(addprefix ../,$(RTL_SRC)) $(addprefix ../,$(TB_SRC)) \
# 	    -top soc_tb -o simv && \
# 	    ./simv +firmware=firmware.hex

################################################################################
# Waveform
################################################################################

.PHONY: wave
wave:
	gtkwave sim/$(VCD_FILE) &

################################################################################
# MAC unit standalone test
################################################################################

MAC_RTL = $(RTL_DIR)/mac_unit.v $(RTL_DIR)/mac_array.v
MAC_TB  = tb/mac_array_tb.v

.PHONY: test-mac
test-mac: sim/mac_array_tb
	cd sim && vvp ../sim/mac_array_tb

sim/mac_array_tb: $(MAC_RTL) $(MAC_TB)
	iverilog -g2012 -o $@ -s mac_array_tb $(MAC_RTL) $(MAC_TB)

.PHONY: wave-mac
wave-mac:
	gtkwave sim/mac_array_tb.vcd &

################################################################################
# Clean
################################################################################

.PHONY: clean
clean:
	rm -f sim/firmware.elf sim/firmware.bin sim/firmware.hex
	rm -f sim/start.o sim/main.o
	rm -f sim/soc_tb sim/soc_tb.vcd
	rm -f sim/mac_array_tb sim/mac_array_tb.vcd
	rm -f soc_tb.vcd
