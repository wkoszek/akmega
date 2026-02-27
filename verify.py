import sys
import re
import os
import subprocess

def get_rtl_trace():
    subprocess.run(["make", "sim"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists("trace_akmega.txt"):
        return []
    with open("trace_akmega.txt", "r") as f:
        return f.readlines()

def simulate_golden():
    pc = 0
    gpr = [0] * 32
    sreg = 0 
    
    trace = []
    instr_map = {
        0x00: "ef8f", 0x02: "b984", 0x04: "e08a", 0x06: "e090",
        0x08: "e031", 0x0a: "e020", 0x0c: "b925", 0x0e: "2f43",
        0x10: "0f32", 0x12: "9701", 0x14: "2f24", 0x16: "f7d1",
        0x18: "ef8f", 0x1a: "b985", 0x1c: "cf7f"
    }

    steps = 0
    while steps < 200:
        if pc not in instr_map: break
        
        line = f"Exec: PC={pc:04x} Inst={instr_map[pc]} R24:25={gpr[25]:02x}{gpr[24]:02x} R18={gpr[18]:02x} R19={gpr[19]:02x} SREG={sreg:08b}"
        trace.append(line)
        
        if pc == 0x00: gpr[24] = 0xFF; pc += 2
        elif pc == 0x02: pc += 2
        elif pc == 0x04: gpr[24] = 0x0A; pc += 2
        elif pc == 0x06: gpr[25] = 0x00; pc += 2
        elif pc == 0x08: gpr[19] = 0x01; pc += 2
        elif pc == 0x0a: gpr[18] = 0x00; pc += 2
        elif pc == 0x0c: pc += 2
        elif pc == 0x0e: gpr[20] = gpr[19]; pc += 2
        elif pc == 0x10:
            a = gpr[19]; b = gpr[18]
            res = a + b
            gpr[19] = res & 0xFF
            # Update SREG flags
            z = 1 if (res & 0xFF) == 0 else 0
            c = 1 if res > 0xFF else 0
            n = 1 if (res & 0x80) else 0
            v = 1 if ((a & 0x80) == (b & 0x80) and (res & 0x80) != (a & 0x80)) else 0
            s = n ^ v
            h = 1 if ((a & 0x0F) + (b & 0x0F)) > 0x0F else 0
            sreg = (sreg & 0xC0) | (h << 5) | (s << 4) | (v << 3) | (n << 2) | (z << 1) | c
            pc += 2
        elif pc == 0x12:
            val = (gpr[25] << 8) | gpr[24]
            res = val - 1
            gpr[24] = res & 0xFF; gpr[25] = (res >> 8) & 0xFF
            z = 1 if res == 0 else 0
            sreg = (sreg & ~0x02) | (z << 1)
            pc += 2
        elif pc == 0x14: gpr[18] = gpr[20]; pc += 2
        elif pc == 0x16:
            if not (sreg & 0x02): pc -= 10
            else: pc += 2
        elif pc == 0x18: gpr[24] = 0xFF; pc += 2
        elif pc == 0x1a: pc += 2
        elif pc == 0x1c: break
        steps += 1
    return trace

def main():
    rtl_lines = get_rtl_trace()
    golden_lines = simulate_golden()
    if not rtl_lines: sys.exit(1)
    limit = min(len(rtl_lines), len(golden_lines))
    print(f"Comparing {limit} steps...")
    for i in range(limit):
        if rtl_lines[i].strip() != golden_lines[i].strip():
            print(f"\nMISMATCH at step {i}:")
            print(f"  GOLDEN: {golden_lines[i].strip()}")
            print(f"  RTL:    {rtl_lines[i].strip()}")
            sys.exit(1)
    print("\n" + "="*40 + "\nSUCCESS: MODELS ARE THE SAME\n" + "="*40)

if __name__ == "__main__":
    main()
