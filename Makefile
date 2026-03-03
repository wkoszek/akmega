# Akmega Core: ATmega-Compatible Microcontroller with AXI4-Lite
# -------------------------------------------------------------
# Integrated Makefile for Firmware, Simulation, Verification, and ASIC Flow

# Toolchain Paths
AVR_GCC      = /opt/homebrew/bin/avr-gcc
AVR_OBJCOPY  = /opt/homebrew/bin/avr-objcopy
AVR_OBJDUMP  = /opt/homebrew/bin/avr-objdump
CC           = /usr/bin/cc
UV           ?= uv
UV_CACHE_DIR ?= .uv-cache
VENV         ?= venv
PDK_ROOT     ?= $(HOME)/openlane/pdk
DOCKER_IMG   = efabless/openlane:latest
OPENLANE_CFG = ./openlane/akmega_core

# simavr paths
SIMAVR_INC   = /opt/homebrew/include/simavr
SIMAVR_LIB   = /opt/homebrew/lib

.PHONY: all setup firmware isa_firmware sim sim_isa verify verify_isa clean gds synth help

# Default target: Compile and Verify behavior
all: verify

help:
	@echo "Akmega Core Build System"
	@echo "Usage:"
	@echo "  make setup    - Installs Python test dependencies using uv"
	@echo "  make verify   - Full verification: RTL trace vs simavr golden model"
	@echo "  make verify_isa - Verifies every implemented ISA class against simavr"
	@echo "  make sim      - Runs the RTL simulation (cocotb) and generates trace_akmega.txt"
	@echo "  make firmware - Compiles the C Fibonacci program into a binary"
	@echo "  make isa_firmware - Compiles ISA coverage assembly firmware"
	@echo "  make gds      - Runs the full OpenLane ASIC flow (Synthesis to GDSII)"
	@echo "  make clean    - Removes all generated build artifacts and logs"

# 0. Setup Python environment for cocotb flow
setup:
	@echo "--- INSTALLING PYTHON DEPENDENCIES (uv) ---"
	@UV_CACHE_DIR=$(UV_CACHE_DIR) $(UV) venv --allow-existing $(VENV)
	@UV_CACHE_DIR=$(UV_CACHE_DIR) $(UV) pip install --python $(VENV)/bin/python -r requirements.txt

# 1. Compile C Firmware
firmware: firmware/main.elf firmware/main.bin

firmware/main.elf: firmware/main.c
	@echo "--- COMPILING C FIRMWARE ---"
	@mkdir -p firmware
	$(AVR_GCC) -Os -mmcu=atmega328p -nostartfiles -o firmware/main.elf firmware/main.c
	$(AVR_OBJCOPY) -O binary firmware/main.elf firmware/main.bin
	$(AVR_OBJDUMP) -d firmware/main.elf > firmware/main.dis

firmware/main.bin: firmware/main.elf

isa_firmware: firmware/isa_all.elf firmware/isa_all.bin

firmware/isa_all.elf: firmware/isa_all.S
	@echo "--- COMPILING ISA COVERAGE FIRMWARE ---"
	@mkdir -p firmware
	$(AVR_GCC) -mmcu=atmega328p -nostartfiles -o firmware/isa_all.elf firmware/isa_all.S
	$(AVR_OBJCOPY) -O binary firmware/isa_all.elf firmware/isa_all.bin
	$(AVR_OBJDUMP) -d firmware/isa_all.elf > firmware/isa_all.dis

firmware/isa_all.bin: firmware/isa_all.elf

# 2. Build the simavr golden-model trace generator
verify_simavr: verify_simavr.c
	@echo "--- BUILDING SIMAVR VERIFICATION HARNESS ---"
	$(CC) -o $@ $< -I$(SIMAVR_INC) -L$(SIMAVR_LIB) -lsimavr -lsimavrparts -lelf -lm

# 3. Generate golden trace from simavr
trace_simavr.txt: verify_simavr firmware/main.elf
	@echo "--- GENERATING SIMAVR GOLDEN TRACE ---"
	./verify_simavr firmware/main.elf

# 4. Run Akmega RTL Simulation (cocotb + icarus)
sim: firmware
	@echo "--- RUNNING AKMEGA RTL SIMULATION (cocotb) ---"
	@$(MAKE) setup > /dev/null
	@source $(VENV)/bin/activate && $(MAKE) -C tb > sim_akmega.log 2>&1
	@grep "Exec: " sim_akmega.log > trace_akmega.txt

trace_akmega.txt: sim

sim_isa: isa_firmware
	@echo "--- RUNNING AKMEGA RTL SIMULATION (ISA mode, cocotb) ---"
	@$(MAKE) setup > /dev/null
	@source $(VENV)/bin/activate && AKMEGA_TEST_MODE=isa AKMEGA_MAX_CYCLES=20000 AKMEGA_FIRMWARE_BIN=../firmware/isa_all.bin $(MAKE) -C tb > sim_isa.log 2>&1
	@grep "Exec: " sim_isa.log > trace_akmega_isa.txt

trace_simavr_isa.txt: verify_simavr firmware/isa_all.elf
	@echo "--- GENERATING SIMAVR GOLDEN TRACE (ISA mode) ---"
	./verify_simavr firmware/isa_all.elf trace_simavr_isa.txt

# 5. Verification: diff RTL trace against simavr golden trace
verify: trace_simavr.txt sim
	@echo "--- VERIFYING RTL vs SIMAVR GOLDEN MODEL ---"
	@echo "RTL trace:    $$(wc -l < trace_akmega.txt) steps"
	@echo "simavr trace: $$(wc -l < trace_simavr.txt) steps"
	@if diff -q trace_simavr.txt trace_akmega.txt > /dev/null 2>&1; then \
		echo ""; \
		echo "========================================"; \
		echo " SUCCESS: RTL matches simavr (0 diffs)"; \
		echo "========================================"; \
	else \
		echo ""; \
		echo "MISMATCH FOUND:"; \
		diff trace_simavr.txt trace_akmega.txt | head -20; \
		echo ""; \
		exit 1; \
	fi

verify_isa: trace_simavr_isa.txt sim_isa
	@echo "--- VERIFYING ISA TRACE (RTL vs SIMAVR) ---"
	@echo "RTL trace:    $$(wc -l < trace_akmega_isa.txt) steps"
	@echo "simavr trace: $$(wc -l < trace_simavr_isa.txt) steps"
	@if diff -q trace_simavr_isa.txt trace_akmega_isa.txt > /dev/null 2>&1; then \
		echo ""; \
		echo "========================================"; \
		echo " SUCCESS: ISA trace matches simavr"; \
		echo "========================================"; \
	else \
		echo ""; \
		echo "MISMATCH FOUND (ISA):"; \
		diff trace_simavr_isa.txt trace_akmega_isa.txt | head -20; \
		echo ""; \
		exit 1; \
	fi
	@$(VENV)/bin/python scripts/check_isa_coverage.py trace_simavr_isa.txt

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
	@rm -f verify_simavr trace_simavr.txt
	@rm -f trace_simavr_isa.txt
	@rm -f sim_akmega.log sim_isa.log
	@rm -f trace_akmega.txt trace_akmega_isa.txt trace_reference.txt trace_ref_raw.txt manual_trace.txt
	@if [ -x $(VENV)/bin/cocotb-config ]; then \
		source $(VENV)/bin/activate && $(MAKE) -C tb clean > /dev/null 2>&1; \
	else \
		rm -rf tb/sim_build tb/results.xml; \
	fi
	@rm -rf $(OPENLANE_CFG)/runs
