# Akmega Core: ATmega-Compatible Microcontroller with AXI4-Lite
# -------------------------------------------------------------
# Integrated Makefile for Firmware, Simulation, Verification, and ASIC Flow

# Toolchain Paths
AVR_GCC      = /opt/homebrew/bin/avr-gcc
AVR_OBJCOPY  = /opt/homebrew/bin/avr-objcopy
AVR_OBJDUMP  = /opt/homebrew/bin/avr-objdump
SIMAVR       = /opt/homebrew/bin/simavr
PDK_ROOT     ?= $(HOME)/openlane/pdk
DOCKER_IMG   = efabless/openlane:latest
OPENLANE_CFG = ./openlane/akmega_core

.PHONY: all firmware sim verify clean gds synth help

# Default target: Compile and Verify behavior
all: verify

help:
	@echo "Akmega Core Build System"
	@echo "Usage:"
	@echo "  make verify   - Compiles C firmware and runs behavioral verification vs Golden Model"
	@echo "  make sim      - Runs the RTL simulation (cocotb) and generates trace_akmega.txt"
	@echo "  make firmware - Compiles the C Fibonacci program into a binary"
	@echo "  make gds      - Runs the full OpenLane ASIC flow (Synthesis to GDSII)"
	@echo "  make clean    - Removes all generated build artifacts and logs"

# 1. Compile C Firmware
firmware:
	@echo "--- [1/3] COMPILING C FIRMWARE ---"
	@mkdir -p firmware
	$(AVR_GCC) -Os -mmcu=atmega328p -nostartfiles -o firmware/main.elf firmware/main.c
	$(AVR_OBJCOPY) -O binary firmware/main.elf firmware/main.bin
	$(AVR_OBJDUMP) -d firmware/main.elf > firmware/main.dis

# 2. Run Akmega RTL Simulation
# This target is usually called internally by verify.py
sim: firmware
	@echo "--- [2/3] RUNNING AKMEGA RTL SIMULATION (cocotb) ---"
	@source venv/bin/activate && cd tb && make > ../sim_akmega.log 2>&1
	@grep "Exec: " sim_akmega.log > trace_akmega.txt

# 3. Comprehensive Behavioral Verification
# Compares the RTL state-trace against the Python Golden Model
verify: firmware
	@echo "--- [3/3] STARTING BEHAVIORAL VERIFICATION ---"
	@python3 verify.py

# --- ASIC Flow Targets ---

synth:
	@echo "--- RUNNING LOGIC SYNTHESIS (OpenLane) ---"
	docker run --rm -v $(PWD):/work -v $(PDK_ROOT):/pdk -e PDK_ROOT=/pdk -u $(shell id -u):$(shell id -g) $(DOCKER_IMG) bash -c "cd /work/$(OPENLANE_CFG) && flow.tcl -design . -to synthesis -overwrite"

gds:
	@echo "--- RUNNING FULL PHYSICAL DESIGN FLOW (OpenLane) ---"
	docker run --rm -v $(PWD):/work -v $(PDK_ROOT):/pdk -e PDK_ROOT=/pdk -u $(shell id -u):$(shell id -g) $(DOCKER_IMG) bash -c "cd /work/$(OPENLANE_CFG) && flow.tcl -design . -overwrite"

# --- Cleanup ---

clean:
	@echo "Cleaning up artifacts..."
	@rm -rf firmware/*.elf firmware/*.bin firmware/*.dis firmware/*.o firmware/*.hex
	@rm -f sim_akmega.log trace_akmega.txt trace_reference.txt trace_ref_raw.txt manual_trace.txt
	@cd tb && make clean > /dev/null 2>&1
	@rm -rf $(OPENLANE_CFG)/runs
