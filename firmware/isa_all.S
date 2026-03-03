#include <avr/io.h>

.global main
.type main, @function

main:
    ; Initialize stack pointer for PUSH/POP/CALL/RET tests.
    ldi r16, hi8(RAMEND)
    out _SFR_IO_ADDR(SPH), r16
    ldi r16, lo8(RAMEND)
    out _SFR_IO_ADDR(SPL), r16

    ; Configure PORTB as output and clear it.
    ldi r16, 0xff
    out _SFR_IO_ADDR(DDRB), r16
    ldi r16, 0x00
    out _SFR_IO_ADDR(PORTB), r16

    ; Advance SP once so RCALL/RET byte pushes land on distinct word-aligned
    ; locations with the current AXI byte-lane implementation.
    pop r0

    ; Arithmetic / logic group
    nop
    ldi r18, 0x11
    ldi r19, 0x22
    add r18, r19
    bclr 0
    adc r18, r19
    adiw r24, 3
    sub r18, r19
    subi r18, 1
    bset 0
    sbc r18, r19
    sbci r18, 1
    and r18, r19
    andi r18, 0x0f
    or r18, r19
    ori r18, 0x80
    eor r18, r19
    com r18
    neg r18
    inc r18
    dec r18
    cp r18, r19
    cpc r18, r19
    cpi r18, 0x55
    mov r20, r18
    movw r22, r24
    sbiw r24, 1

    ; Shift/bit primitives
    lsr r20
    bset 0
    ror r20
    asr r20
    swap r20
    bst r20, 1
    bld r21, 2

    ; Branch and skip primitives
    bset 0
    brbs 0, brbs_taken
    nop
brbs_taken:
    bclr 0
    brbc 0, brbc_taken
    nop
brbc_taken:
    rjmp rjmp_target
    nop
rjmp_target:
    cpse r18, r18
    nop
    ldi r22, 0x00
    sbrc r22, 0
    nop
    ldi r22, 0x01
    sbrs r22, 0
    nop

    ; Multiply family
    ldi r16, 0x06
    ldi r17, 0x07
    mul r16, r17
    ldi r18, 0xfe
    ldi r19, 0x03
    muls r18, r19
    ldi r20, 0xfc
    ldi r21, 0x06
    mulsu r20, r21
    ldi r20, 0x40
    ldi r21, 0x20
    fmul r20, r21
    ldi r20, 0xf0
    ldi r21, 0x10
    fmuls r20, r21
    ldi r20, 0xf0
    ldi r21, 0x04
    fmulsu r20, r21

    ; 32-bit LDS/STS
    ldi r16, 0x5a
    sts 0x0130, r16
    lds r17, 0x0130

    ; Setup data for indirect addressing tests.
    ldi r16, 0x11
    sts 0x0100, r16
    ldi r16, 0x22
    sts 0x0101, r16
    ldi r16, 0x33
    sts 0x0110, r16
    ldi r16, 0x44
    sts 0x0111, r16
    ldi r16, 0x55
    sts 0x0120, r16
    ldi r16, 0x66
    sts 0x0121, r16

    ; X pointer loads
    ldi r26, lo8(0x0100)
    ldi r27, hi8(0x0100)
    ld r2, X
    ld r3, X+
    ld r4, -X

    ; Y pointer loads
    ldi r28, lo8(0x0110)
    ldi r29, hi8(0x0110)
    ld r5, Y+
    ld r6, -Y

    ; Z pointer loads
    ldi r30, lo8(0x0120)
    ldi r31, hi8(0x0120)
    ld r7, Z+
    ld r8, -Z

    ; X/Y/Z store variants
    ldi r16, 0xa1
    ldi r17, 0xb2
    ldi r18, 0xc3
    ldi r26, lo8(0x0140)
    ldi r27, hi8(0x0140)
    st X, r16
    st X+, r17
    st -X, r18

    ldi r16, 0xd4
    ldi r17, 0xe5
    ldi r18, 0xf6
    ldi r28, lo8(0x0150)
    ldi r29, hi8(0x0150)
    st Y+, r16
    st -Y, r17

    ldi r30, lo8(0x0160)
    ldi r31, hi8(0x0160)
    st Z+, r18
    st -Z, r16

    ; LDD/STD with displacement
    ldi r28, lo8(0x0110)
    ldi r29, hi8(0x0110)
    ldd r23, Y+1
    std Y+2, r22
    ldi r30, lo8(0x0120)
    ldi r31, hi8(0x0120)
    ldd r24, Z+1
    std Z+2, r21

    ; IN / OUT and I/O bit operations
    ldi r16, 0x3c
    out _SFR_IO_ADDR(PORTB), r16
    in r17, _SFR_IO_ADDR(PORTB)
    sbi _SFR_IO_ADDR(PORTB), 0
    cbi _SFR_IO_ADDR(PORTB), 0
    cbi _SFR_IO_ADDR(PORTB), 1
    sbic _SFR_IO_ADDR(PORTB), 1
    nop
    sbi _SFR_IO_ADDR(PORTB), 1
    sbis _SFR_IO_ADDR(PORTB), 1
    nop

    ; Program-memory reads
    ldi r30, lo8(lpm_data)
    ldi r31, hi8(lpm_data)
    lpm r25, Z
    lpm r24, Z+

    ; Stack ops
    push r16
    pop r17

    ; Control-flow via stack and Z-indirect targets
    rcall sub_ret
    rcall sub_reti

    ldi r30, lo8(pm(sub_icall))
    ldi r31, hi8(pm(sub_icall))
    icall

    ldi r30, lo8(pm(after_ijmp))
    ldi r31, hi8(pm(after_ijmp))
    ijmp

after_ijmp:
    sleep
    wdr
    break

    ; End marker expected by simavr/cocotb harness.
    ldi r16, 0xff
    out _SFR_IO_ADDR(PORTB), r16

done:
    rjmp done

sub_ret:
    nop
    ret

sub_reti:
    reti

sub_icall:
    nop
    ret

lpm_data:
    .byte 0x12, 0x34, 0x56, 0x78
