# Akmega Verification Strategy

This document summarizes how Akmega RTL is verified today.

## Verification Flows

### 1) Baseline Firmware Equivalence (`make verify`)
`make verify` runs the C Fibonacci firmware through both models:
1. Build `firmware/main.elf` + `firmware/main.bin`.
2. Run simavr (`verify_simavr`) and emit `trace_simavr.txt`.
3. Run RTL (cocotb + Icarus) and emit `trace_akmega.txt`.
4. Diff traces for exact equivalence.

This validates architectural behavior for the baseline firmware path.

### 2) Full Implemented ISA Coverage (`make verify_isa`)
`make verify_isa` uses a directed assembly workload (`firmware/isa_all.S`) that executes every implemented decode class:
1. Build ISA coverage firmware (`firmware/isa_all.elf` + `.bin`).
2. Run simavr and emit `trace_simavr_isa.txt`.
3. Run RTL in ISA mode and emit `trace_akmega_isa.txt`.
4. Diff traces for exact equivalence.
5. Run `scripts/check_isa_coverage.py` to ensure all implemented instruction classes were observed.

Current target coverage is `82/82` implemented decode classes.

## Notes

- The cocotb testbench supports two modes via `AKMEGA_TEST_MODE`:
  - `fibonacci` (default): checks expected Fibonacci PORTB sequence.
  - `isa`: checks completion marker for the ISA coverage firmware.
- Trace format is instruction-step based and includes `PC`, `Inst`, selected GPRs, and `SREG`.
