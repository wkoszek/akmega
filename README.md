# Akmega ⚡

**Akmega** is a 100% ATmega-compatible 8-bit microcontroller core implemented in pure SystemVerilog, featuring modern AXI4-Lite instruction and data buses.

This project is an exploration of the boundaries of AI-assisted hardware engineering, developed entirely through an interactive session with an LLM.

## Background & Motivation
The idea for this project was suggested by my good friend, **Mike Matera**, following a short text exchange. Mike's thesis was that while the ATmega architecture is incredibly popular, it is surprisingly poorly documented from an ISA (Instruction Set Architecture) perspective compared to modern standards. He noted that the toolchain visibility is often lacking, making it significantly tougher to bootstrap a custom core from scratch.

### The Engineering Challenge
My primary goal was to determine if I could achieve a complete physical layout (GDSII) of a functional core. I had previously attempted a similar experiment with a larger RISC-V design, but that project ultimately failed at the **placement** stage—the physical complexity was simply too high for the initial automated flow.

## Milestones Achieved
Akmega represents several personal and technical "firsts":
- **Simulation Success**: This is the first chip I've designed that is trivially easy to simulate and verify against real-world C code.
- **SystemVerilog Design**: One of my first complete designs implemented in SystemVerilog.
- **Silicon Ready**: This is the first design where I have successfully navigated the entire OpenLane flow to produce a synthesized GDSII file using the **Skywater 130nm (Sky130)** process.

## Technical Features
- **AVR Compatible**: Supports the core ATmega328P instruction set, including 16-bit word arithmetic and hardware multiplication.
- **AXI4-Lite Integration**: Unlike standard AVR cores, Akmega uses standard AXI4-Lite buses for both instruction fetch and data memory, making it SoC-ready.
- **Verification-First**: Includes a Python-based **Functional Golden Model** used for bit-perfect behavioral verification of the RTL.
- **C-to-GDS Flow**: Fully integrated pipeline from C firmware (Fibonacci test) to GDSII layout.

## Quick Start

### 1. Verification
To compile the firmware, run the RTL simulation, and verify behavior against the golden model:
```bash
make verify
```

### 2. Physical Design
To run the full ASIC flow and generate the GDSII layout:
```bash
make gds
```

## Acknowledgments
- **Mike Matera**: For the inspiration and the "ATmega Thesis."
- **OpenLane/Sky130**: For providing the open-source tools and PDK that made the physical layout possible.
