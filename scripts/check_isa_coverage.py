#!/usr/bin/env python3
import re
import sys
from collections import Counter
from typing import Callable, Iterable


TraceClassifier = tuple[str, str | Callable[[int], str]]


TRACE_RE = re.compile(r"Inst=([0-9a-fA-F]{4})")


def _match(pattern: str, inst: int) -> bool:
    for i, ch in enumerate(pattern):
        bit = (inst >> (15 - i)) & 1
        if ch == "?":
            continue
        if ch == "0" and bit != 0:
            return False
        if ch == "1" and bit != 1:
            return False
    return True


CLASSIFIERS: list[TraceClassifier] = [
    ("0000000000000000", "NOP"),
    ("000011??????????", "ADD"),
    ("000111??????????", "ADC"),
    ("10010110????????", "ADIW"),
    ("000110??????????", "SUB"),
    ("0101????????????", "SUBI"),
    ("000010??????????", "SBC"),
    ("0100????????????", "SBCI"),
    ("001000??????????", "AND"),
    ("0111????????????", "ANDI"),
    ("001010??????????", "OR"),
    ("0110????????????", "ORI"),
    ("001001??????????", "EOR"),
    ("1001010?????0000", "COM"),
    ("1001010?????0001", "NEG"),
    ("1001010?????0011", "INC"),
    ("1001010?????1010", "DEC"),
    ("000101??????????", "CP"),
    ("000001??????????", "CPC"),
    ("0011????????????", "CPI"),
    ("001011??????????", "MOV"),
    ("1110????????????", "LDI"),
    ("1100????????????", "RJMP"),
    ("111100??????????", "BRBS"),
    ("111101??????????", "BRBC"),
    ("1101????????????", "RCALL"),
    ("1001010100001000", "RET"),
    ("1001010100011000", "RETI"),
    ("1001010100001001", "ICALL"),
    ("1001010000001001", "IJMP"),
    ("000100??????????", "CPSE"),
    ("1111110?????0???", "SBRC"),
    ("1111111?????0???", "SBRS"),
    ("100111??????????", "MUL"),
    ("00000010????????", "MULS"),
    ("000000110???0???", "MULSU"),
    ("000000110???1???", "FMUL"),
    ("000000111???0???", "FMULS"),
    ("000000111???1???", "FMULSU"),
    ("00000001????????", "MOVW"),
    ("1001001?????1111", "PUSH"),
    ("1001000?????1111", "POP"),
    ("1001000?????1100", "LD_X"),
    ("1001000?????1101", "LD_X_POSTINC"),
    ("1001000?????1110", "LD_X_PREDEC"),
    ("1001000?????1001", "LD_Y_POSTINC"),
    ("1001000?????1010", "LD_Y_PREDEC"),
    ("1001000?????0001", "LD_Z_POSTINC"),
    ("1001000?????0010", "LD_Z_PREDEC"),
    ("1001001?????1100", "ST_X"),
    ("1001001?????1101", "ST_X_POSTINC"),
    ("1001001?????1110", "ST_X_PREDEC"),
    ("1001001?????1001", "ST_Y_POSTINC"),
    ("1001001?????1010", "ST_Y_PREDEC"),
    ("1001001?????0001", "ST_Z_POSTINC"),
    ("1001001?????0010", "ST_Z_PREDEC"),
    ("10110???????????", "IN"),
    ("1001000?????0100", "LPM_Z"),
    ("1001000?????0101", "LPM_Z_POSTINC"),
    ("10?0????????1???", lambda inst: "STD_YQ" if (inst >> 9) & 1 else "LDD_YQ"),
    ("10?0????????0???", lambda inst: "STD_ZQ" if (inst >> 9) & 1 else "LDD_ZQ"),
    ("10111???????????", "OUT"),
    ("1001010?????0110", "LSR"),
    ("1001010?????0111", "ROR"),
    ("1001010?????0101", "ASR"),
    ("1001010?????0010", "SWAP"),
    ("1111101?????0???", "BST"),
    ("1111100?????0???", "BLD"),
    ("10011010????????", "SBI"),
    ("10011000????????", "CBI"),
    ("100101000???1000", "BSET"),
    ("100101001???1000", "BCLR"),
    ("10011001????????", "SBIC"),
    ("10011011????????", "SBIS"),
    ("1001010110001000", "SLEEP"),
    ("1001010110101000", "WDR"),
    ("1001010110011000", "BREAK"),
    ("10010111????????", "SBIW"),
    ("100100????????00", lambda inst: "STS_32" if (inst >> 9) & 1 else "LDS_32"),
]


REQUIRED_CLASSES: list[str] = [
    "NOP",
    "ADD",
    "ADC",
    "ADIW",
    "SUB",
    "SUBI",
    "SBC",
    "SBCI",
    "AND",
    "ANDI",
    "OR",
    "ORI",
    "EOR",
    "COM",
    "NEG",
    "INC",
    "DEC",
    "CP",
    "CPC",
    "CPI",
    "MOV",
    "LDI",
    "RJMP",
    "BRBS",
    "BRBC",
    "RCALL",
    "RET",
    "RETI",
    "ICALL",
    "IJMP",
    "CPSE",
    "SBRC",
    "SBRS",
    "MUL",
    "MULS",
    "MULSU",
    "FMUL",
    "FMULS",
    "FMULSU",
    "MOVW",
    "PUSH",
    "POP",
    "LD_X",
    "LD_X_POSTINC",
    "LD_X_PREDEC",
    "LD_Y_POSTINC",
    "LD_Y_PREDEC",
    "LD_Z_POSTINC",
    "LD_Z_PREDEC",
    "ST_X",
    "ST_X_POSTINC",
    "ST_X_PREDEC",
    "ST_Y_POSTINC",
    "ST_Y_PREDEC",
    "ST_Z_POSTINC",
    "ST_Z_PREDEC",
    "IN",
    "LPM_Z",
    "LPM_Z_POSTINC",
    "LDD_YQ",
    "STD_YQ",
    "LDD_ZQ",
    "STD_ZQ",
    "OUT",
    "LSR",
    "ROR",
    "ASR",
    "SWAP",
    "BST",
    "BLD",
    "SBI",
    "CBI",
    "BSET",
    "BCLR",
    "SBIC",
    "SBIS",
    "SLEEP",
    "WDR",
    "BREAK",
    "SBIW",
    "LDS_32",
    "STS_32",
]


def classify(inst: int) -> str | None:
    for pattern, label in CLASSIFIERS:
        if _match(pattern, inst):
            if isinstance(label, str):
                return label
            return label(inst)
    return None


def parse_trace(trace_path: str) -> Iterable[int]:
    with open(trace_path, "r", encoding="utf-8") as f:
        for line in f:
            m = TRACE_RE.search(line)
            if not m:
                continue
            yield int(m.group(1), 16)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check_isa_coverage.py <trace_file>", file=sys.stderr)
        return 2

    trace_file = sys.argv[1]
    seen: Counter[str] = Counter()
    unknown_count = 0

    for inst in parse_trace(trace_file):
        klass = classify(inst)
        if klass is None:
            unknown_count += 1
            continue
        seen[klass] += 1

    missing = [k for k in REQUIRED_CLASSES if k not in seen]

    print(f"Trace: {trace_file}")
    print(f"Decoded classes: {len(seen)} / {len(REQUIRED_CLASSES)}")
    print(f"Unknown instructions in trace: {unknown_count}")

    for name in REQUIRED_CLASSES:
        print(f"{name:16s} : {seen.get(name, 0)}")

    if missing:
        print("\nMissing ISA classes:")
        for name in missing:
            print(f" - {name}")
        return 1

    print("\nISA coverage check passed: all implemented classes were executed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
