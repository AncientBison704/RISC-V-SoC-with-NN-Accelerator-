# RISC-V Neural Network SoC

A RISC-V System-on-Chip with a custom hardware neural network accelerator, fully verified in simulation. The CPU boots from ROM, loads quantized weights into the accelerator via memory-mapped registers, and runs multi-layer inference with bit-exact results matching a Python golden model.

## Architecture

```
┌──────────────────┐
│    PicoRV32      │  RV32IM CPU
│    (CPU)         │  Reset: 0x0000_0000
└────────┬─────────┘  Stack: 0x0000_3000
         │ AXI4-Lite
┌────────┴──────────────────────────────────────────────────┐
│              AXI4-Lite Interconnect                        │
│              (1 master → 4 slaves, address decoder)        │
└──┬──────────┬──────────────┬──────────────┬───────────────┘
   │          │              │              │
┌──┴───┐ ┌───┴────┐  ┌──────┴──────┐ ┌─────┴──────────────┐
│ ROM  │ │  RAM   │  │  UART TX    │ │  NN Accelerator    │
│ 4 KB │ │  8 KB  │  │  (sim)      │ │                    │
│ R/O  │ │  R/W   │  │  $write     │ │ ┌────────────────┐ │
└──────┘ └────────┘  └─────────────┘ │ │  Ctrl / Status │ │
                                     │ │  Registers     │ │
                                     │ ├────────────────┤ │
                                     │ │  Weight BRAM   │ │
                                     │ ├────────────────┤ │
                                     │ │  MAC Array     │ │
                                     │ │  (4 parallel)  │ │
                                     │ ├────────────────┤ │
                                     │ │  Activation    │ │
                                     │ │  Buffers       │ │
                                     │ ├────────────────┤ │
                                     │ │  Bias BRAM     │ │
                                     │ └────────────────┘ │
                                     └────────────────────┘
```

## Key Features

- **PicoRV32 CPU** (RV32IM) with AXI4-Lite master interface
- **Custom AXI4-Lite interconnect** with address-based routing (1 master, 4 slaves)
- **Neural network accelerator** with:
  - 4 parallel MAC units (parameterizable to 1/2/4/8)
  - Q8.8 fixed-point arithmetic (16-bit signed, 32-bit accumulator)
  - Per-neuron bias and optional ReLU activation
  - Automatic batching for layers with more neurons than MAC units
  - Hardware argmax over all output neurons
  - Inference cycle counter for performance measurement
- **Multi-layer inference**: firmware runs 2-layer network (16→16→10) through the accelerator
- **Bit-exact verification**: hardware outputs match Python Q8.8 golden model for all test inputs
- **Python training pipeline**: train, quantize, export weights as C header

## Memory Map

| Address Range               | Size   | Peripheral         |
|-----------------------------|--------|--------------------|
| `0x0000_0000 – 0x0000_0FFF` | 4 KB   | Boot ROM           |
| `0x0000_1000 – 0x0000_2FFF` | 8 KB   | Data RAM           |
| `0x1000_0000`                | 4 B    | UART TX (sim)      |
| `0x2000_0000 – 0x2000_0FFF` | 4 KB   | NN Accelerator     |

### NN Accelerator Register Map

| Offset  | Name     | R/W | Description                                          |
|---------|----------|-----|------------------------------------------------------|
| `0x000` | CTRL     | W   | Bit 0: start inference                               |
| `0x004` | STATUS   | R   | Bit 0: busy, Bit 1: done                             |
| `0x008` | CONFIG   | W   | `[9:0]` input_len, `[19:10]` num_neurons, `[20]` ReLU |
| `0x00C` | RESULT   | R   | `[15:0]` argmax class, `[31:16]` argmax value        |
| `0x010` | CYCLES   | R   | Inference cycle count                                |
| `0x400` | WEIGHTS  | W   | Weight memory (packed Q8.8 pairs)                    |
| `0x800` | ACT_IN   | W   | Input activation buffer                              |
| `0xA00` | ACT_OUT  | R   | Output activation buffer                             |
| `0xC00` | BIAS     | W   | Bias memory (packed Q8.8 pairs)                      |

## Directory Structure

```
riscv_nn_soc/
├── rtl/
│   ├── picorv32.v           # CPU core (upstream, ISC license)
│   ├── soc_top.v            # SoC top-level
│   ├── axi_interconnect.v   # 4-slave bus fabric
│   ├── axi_rom.v            # AXI4-Lite ROM
│   ├── axi_ram.v            # AXI4-Lite RAM
│   ├── axi_uart_tx.v        # Simulation UART
│   ├── mac_unit.v           # Single MAC (Q8.8, ReLU, bias, saturation)
│   ├── mac_array.v          # N parallel MAC units
│   └── nn_accelerator.v     # AXI-mapped accelerator peripheral
├── tb/
│   ├── soc_tb.v             # SoC testbench
│   └── mac_array_tb.v       # MAC unit standalone tests (9/9 pass)
├── fw/
│   ├── start.S              # RISC-V startup assembly
│   ├── main.c               # Multi-layer inference firmware
│   ├── link.ld              # Linker script
│   └── nn_weights.h         # Exported Q8.8 weights (auto-generated)
├── python/
│   ├── train.py             # Train + quantize + export + golden model
│   └── golden.txt           # Reference outputs
├── scripts/
│   └── makehex.py           # Binary → Verilog hex converter
├── Makefile
└── README.md
```

## Requirements

- `riscv64-unknown-elf-gcc` (bare-metal RISC-V cross compiler)
- `iverilog` + `vvp` (Icarus Verilog) or Synopsys VCS
- `python3` with `torch`, `torchvision`, `numpy` (for retraining only)
- Optional: `gtkwave` for waveform viewing

```bash
# Ubuntu/Debian
sudo apt install gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf iverilog
pip install torch torchvision numpy
```

## Quick Start

```bash
# Run full multi-layer inference simulation
make sim
```

Expected output:

```
== RISC-V NN SoC ==
Week 4: Multi-layer MNIST Inference
Network: 16 -> 16 (ReLU) -> 10

--- Test 0 (label=3) ---
  L1 cycles: 76, L2 cycles: 57
  Predicted: 7, Golden: 7 [MATCH]
--- Test 1 (label=3) ---
  L1 cycles: 76, L2 cycles: 57
  Predicted: 6, Golden: 6 [MATCH]
...
Results: 5/5 matched golden model
*** ALL TESTS PASSED ***
```

## Build Targets

| Target          | Description                                    |
|-----------------|------------------------------------------------|
| `make sim`      | Build firmware + run full SoC simulation       |
| `make fw`       | Compile firmware only                          |
| `make test-mac` | Run standalone MAC unit tests (9 tests)        |
| `make wave`     | Open SoC waveform in GTKWave                   |
| `make wave-mac` | Open MAC waveform in GTKWave                   |
| `make clean`    | Remove all generated files                     |

## Retraining the Network

```bash
python3 python/train.py
```

This trains a 16→16→10 network, quantizes weights to Q8.8, runs a golden model inference in Python, and exports `fw/nn_weights.h`. Then rebuild and simulate:

```bash
make clean && make sim
```

## How Multi-Layer Inference Works

The firmware runs two layers through the accelerator sequentially:

1. **Layer 1** (16 inputs → 16 hidden, ReLU):
   - Load fc1 weights and biases into accelerator
   - Load test image as input activations
   - Configure: `input_len=16, num_neurons=16, relu=ON`
   - Start inference → accelerator batches 4 neurons at a time (4 batches)
   - Read hidden activations from output buffer

2. **Layer 2** (16 hidden → 10 output, no ReLU):
   - Copy layer 1 outputs to input buffer
   - Load fc2 weights and biases
   - Configure: `input_len=16, num_neurons=10, relu=OFF`
   - Start inference → 3 batches (4+4+2)
   - Read argmax result

## Fixed-Point Format

Q8.8: 8 integer bits + 8 fractional bits, signed 16-bit.

| Value | Q8.8 Hex | Q8.8 Decimal |
|-------|----------|--------------|
| 1.0   | `0x0100` | 256          |
| 0.5   | `0x0080` | 128          |
| -1.0  | `0xFF00` | -256         |
| 2.5   | `0x0280` | 640          |

Multiply-accumulate: 16×16 → 32-bit accumulator, right-shift by 8 after summation to return to Q8.8.

## GTKWave Verification

After `make sim`, open `make wave` and inspect:

- `dut.nn_accel.inf_state`: FSM cycling `1→2→3→4→1→...→5→6→0` (batched inference)
- `dut.nn_accel.mac_start`: pulses once per batch
- `dut.nn_accel.status_done`: goes high when inference completes
- `dut.nn_accel.result_argmax_class`: predicted digit

## License

- PicoRV32: ISC License (Claire Xenia Wolf)
- SoC RTL, firmware, and scripts: MIT License
