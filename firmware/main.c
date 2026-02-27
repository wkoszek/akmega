#include <avr/io.h>
#include <stdint.h>

int main(void) {
    // Set PORTB as output
    DDRB = 0xFF;
    
    uint8_t a = 0;
    uint8_t b = 1;
    uint8_t next;

    for (int i = 0; i < 10; i++) {
        PORTB = a;
        next = a + b;
        a = b;
        b = next;
    }

    // End of test marker
    PORTB = 0xFF;

    while(1) {
        // Spin
    }
}
