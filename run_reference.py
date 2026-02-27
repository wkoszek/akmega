import subprocess
import time
import os

def run_reference_sim(elf_path, cycles=1000):
    # simavr doesn't have a simple "dump and quit" CLI for exact cycle counts
    # But it has a trace mode. Let's use the trace to see what happens.
    
    cmd = ["/opt/homebrew/bin/simavr", "-m", "atmega328p", "-t", elf_path]
    print(f"Running reference sim: {' '.join(cmd)}")
    
    # We will run it and capture output
    # Note: -t prints every instruction executed.
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        
        # We'll let it run for a short bit. Our Fibonacci is very short.
        # Instruction trace will show us the registers.
        
        time.sleep(2)
        proc.terminate()
        stdout, stderr = proc.communicate()
        
        return stdout + stderr
    except Exception as e:
        return str(e)

if __name__ == "__main__":
    elf = "firmware/main.elf"
    if os.path.exists(elf):
        res = run_reference_sim(elf)
        with open("sim_reference.log", "w") as f:
            f.write(res)
        print("Reference log saved to sim_reference.log")
    else:
        print("ELF not found!")
