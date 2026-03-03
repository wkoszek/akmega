/*
 * verify_simavr.c — Golden-model trace generator using simavr.
 *
 * Links against libsimavr.a to step through firmware one instruction
 * at a time and dumps the same trace format as the RTL $display:
 *
 *   Exec: PC=xxxx Inst=xxxx R24:25=xxxx R18=xx R19=xx SREG=bbbbbbbb
 *
 * Usage: ./verify_simavr firmware/main.elf [trace_output.txt]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sim_avr.h"
#include "sim_elf.h"

#define MAX_STEPS 20000

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <firmware.elf> [trace_output.txt]\n", argv[0]);
        return 1;
    }
    const char *trace_path = (argc >= 3) ? argv[2] : "trace_simavr.txt";

    /* Load ELF firmware */
    elf_firmware_t fw;
    memset(&fw, 0, sizeof(fw));
    if (elf_read_firmware(argv[1], &fw) != 0) {
        fprintf(stderr, "Failed to read firmware: %s\n", argv[1]);
        return 1;
    }

    /* Override MCU to atmega328p if not embedded in ELF */
    if (fw.mmcu[0] == '\0')
        strcpy(fw.mmcu, "atmega328p");

    /* Create and init the AVR instance */
    avr_t *avr = avr_make_mcu_by_name(fw.mmcu);
    if (!avr) {
        fprintf(stderr, "Unknown MCU: %s\n", fw.mmcu);
        return 1;
    }
    avr_init(avr);
    avr_load_firmware(avr, &fw);

    /* PORTB data direction and data register addresses in I/O space:
     *   DDRB  = 0x04 (data[0x24])
     *   PORTB = 0x05 (data[0x25])
     * We watch writes to PORTB to detect the 0xFF end marker.
     */

    FILE *ftrace = fopen(trace_path, "w");
    if (!ftrace) { perror("fopen"); return 1; }

    int saw_end = 0;
    for (int step = 0; step < MAX_STEPS && !saw_end; step++) {
        /* Capture state BEFORE executing the instruction */
        uint32_t pc = avr->pc;           /* byte address */
        /* Read the 16-bit instruction word from flash (little-endian) */
        uint16_t inst = avr->flash[pc] | (avr->flash[pc + 1] << 8);

        /* GPRs live at data[0..31] */
        uint8_t r24 = avr->data[24];
        uint8_t r25 = avr->data[25];
        uint8_t r18 = avr->data[18];
        uint8_t r19 = avr->data[19];
        /* Build SREG from the sreg[8] bit-mirror array (more reliable
         * than data[0x5f] which may lag behind). Layout: sreg[0]=C,
         * sreg[1]=Z, sreg[2]=N, sreg[3]=V, sreg[4]=S, sreg[5]=H,
         * sreg[6]=T, sreg[7]=I */
        uint8_t sreg_val = (avr->sreg[7] << 7) | (avr->sreg[6] << 6) |
                           (avr->sreg[5] << 5) | (avr->sreg[4] << 4) |
                           (avr->sreg[3] << 3) | (avr->sreg[2] << 2) |
                           (avr->sreg[1] << 1) | (avr->sreg[0] << 0);

        fprintf(ftrace,
            "Exec: PC=%04x Inst=%04x R24:25=%02x%02x R18=%02x R19=%02x SREG=%c%c%c%c%c%c%c%c\n",
            pc, inst, r25, r24, r18, r19,
            (sreg_val & 0x80) ? '1' : '0',
            (sreg_val & 0x40) ? '1' : '0',
            (sreg_val & 0x20) ? '1' : '0',
            (sreg_val & 0x10) ? '1' : '0',
            (sreg_val & 0x08) ? '1' : '0',
            (sreg_val & 0x04) ? '1' : '0',
            (sreg_val & 0x02) ? '1' : '0',
            (sreg_val & 0x01) ? '1' : '0');

        /* Step one instruction */
        avr->state = cpu_Running;
        avr_run(avr);

        /* Check for end-of-test marker: PORTB == 0xFF */
        if (avr->data[0x25] == 0xFF)
            saw_end = 1;

        /* Stop if CPU crashed or halted */
        if (avr->state == cpu_Done || avr->state == cpu_Crashed)
            break;
    }

    fclose(ftrace);
    printf("simavr trace written to %s (%s)\n",
           trace_path, saw_end ? "end marker seen" : "max steps reached");

    avr_terminate(avr);
    return 0;
}
