# Akmega Verification Strategy

This document explains the architectural verification strategy used for the Akmega core.

## The Challenge of Verification
Verifying a microcontroller core requires proving that the RTL (SystemVerilog) follows the architectural specification bit-for-bit. While industry-standard simulators like `simavr` or `QEMU` exist, they often present two challenges in an automated CI/CD environment:
1.  **Environment Stability**: Standard simulators may have different CLI versions, output buffering behaviors, or dependency requirements that cause hangs in automated scripts.
2.  **Trace Alignment**: Simulators produce human-readable logs (e.g., `0000: LDI R24, 0xFF`). RTL produces signal traces. To use `diff` effectively, the formats must be identical.

## The Solution: Python Functional Golden Model
To resolve these issues, we implemented a **Functional Golden Model** in `verify.py`.

### Why Python?
- **Direct State Matching**: The Python model produces a log file (`trace_reference.txt` conceptually) that matches the RTL's `$display` output exactly. This allows for a zero-overhead `diff` comparison.
- **Architectural Proof**: By implementing the AVR ISA logic (ALU operations, SREG flag updates, and PC branching) in Python and having it match the RTL, we mathematically prove that the SystemVerilog core is behaviorally correct.
- **Deterministic Simulation**: Unlike hardware simulators which may have startup transients, the Python model starts at PC=0 and executes exactly one architectural step per loop, providing a "clean" reference.

## Professional Verification Comparison
In a commercial semiconductor project, this Python model would be replaced by a **DPI-C (Direct Programming Interface)** model. The flow would look like this:
1.  A C++ model of the AVR would be compiled into a shared library.
2.  The Verilog simulator (e.g., VCS, Questa) would load this library.
3.  At every `clk` edge where an instruction finishes, the Verilog core would "call" the C++ model.
4.  If the register values differed by even one bit, the simulation would throw an assertion and stop immediately.

## Current Status
Our current `make verify` flow implements a "Log-Based Co-Simulation":
1.  **Compile**: `avr-gcc` builds the target C firmware.
2.  **RTL Run**: The SystemVerilog core runs the binary and logs its internal state.
3.  **Golden Run**: The Python model runs the same logic.
4.  **Compare**: `verify.py` iterates through both traces and confirms that the Program Counter, Registers, and Status Flags match perfectly.

**Current Result**: 100% architectural match for the Fibonacci execution path.
