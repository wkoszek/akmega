import cocotb
import os
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly
from cocotbext.axi import AxiLiteBus, AxiLiteRam

@cocotb.test()
async def test_akmega_firmware(dut):
    """Test the akmega core using compiled C firmware."""
    test_mode = os.getenv("AKMEGA_TEST_MODE", "fibonacci").strip().lower()
    max_cycles = int(os.getenv("AKMEGA_MAX_CYCLES", "2000"))
    default_bin = os.path.join(os.path.dirname(__file__), "..", "firmware", "main.bin")
    firmware_override = os.getenv("AKMEGA_FIRMWARE_BIN")
    if firmware_override:
        if os.path.isabs(firmware_override):
            bin_path = firmware_override
        else:
            bin_path = os.path.join(os.path.dirname(__file__), firmware_override)
    else:
        bin_path = default_bin

    # Provide initial value for reset
    dut.rst_n.value = 0
    await Timer(1, unit="ns")

    # Start clock (100MHz)
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    # Initialize AXI Ram models
    ibus = AxiLiteBus.from_prefix(dut, "ibus")
    dbus = AxiLiteBus.from_prefix(dut, "dbus")
    
    # 64KB memory blocks
    iram = AxiLiteRam(ibus, dut.clk, dut.rst_n, reset_active_level=False, size=65536)
    dram = AxiLiteRam(dbus, dut.clk, dut.rst_n, reset_active_level=False, size=65536)

    # Load compiled firmware
    with open(bin_path, "rb") as f:
        firmware_data = f.read()
        dut._log.info(f"Test mode: {test_mode}")
        dut._log.info(f"Loading {len(firmware_data)} bytes of firmware from {bin_path}...")
        iram.write(0x0000, firmware_data)

    # Apply Reset
    await Timer(20, unit="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    # Monitor Data Bus writes to 0x0025 (PORTB mapped to 0x20 + 0x05)
    results = []
    
    async def monitor_dbus_write():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if dut.dbus_wvalid.value and dut.dbus_wready.value:
                addr = int(dut.dbus_awaddr.value)
                if addr == 0x0025: # PORTB
                    val = int(dut.dbus_wdata.value) & 0xFF
                    results.append(val)
                    dut._log.info(f"FIRMWARE PORTB OUTPUT: {val} (hex: {hex(val)})")

    cocotb.start_soon(monitor_dbus_write())

    # Run for a sufficient number of cycles
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if 0xFF in results:
            break

    dut._log.info(f"Final Fibonacci sequence seen on PORTB: {results}")

    assert 0xFF in results, f"Did not see end marker 0xFF within {max_cycles} cycles"

    if test_mode == "fibonacci":
        # Fibonacci: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34
        expected = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]

        # Filter out the 0xFF marker
        clean_results = [r for r in results if r != 0xFF]

        dut._log.info(f"Clean results: {clean_results}")

        assert len(clean_results) >= len(expected), f"Not enough results! Got {len(clean_results)}"
        for i in range(len(expected)):
            assert clean_results[i] == expected[i], f"Mismatch at index {i}: expected {expected[i]}, got {clean_results[i]}"
    elif test_mode == "isa":
        dut._log.info("ISA mode completed with end marker.")
    else:
        raise AssertionError(f"Unknown AKMEGA_TEST_MODE: {test_mode}")

    dut._log.info("Cocotb test passed successfully.")
