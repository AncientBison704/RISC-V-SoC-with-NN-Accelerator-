/* Linker script for riscv_nn_soc
 *
 * ROM: 0x0000_0000 - 0x0000_0FFF  (4 KB)
 * RAM: 0x0000_1000 - 0x0000_2FFF  (8 KB)
 * Stack grows down from 0x3000
 */

MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    RAM (rwx) : ORIGIN = 0x00001000, LENGTH = 8K
}

ENTRY(_start)

SECTIONS {
    /* Code goes in ROM */
    .text : {
        KEEP(*start*.o(.text))
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
    } > ROM

    /* Initialized data: stored in ROM, copied to RAM at startup
     * For simplicity in this small firmware, we keep everything in ROM
     * and use RAM only for stack + BSS */

    /* BSS in RAM */
    .bss : {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM
}
