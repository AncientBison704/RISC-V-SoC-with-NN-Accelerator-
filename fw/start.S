    .section .text
    .global _start

_start:
    # Set stack pointer to top of RAM (0x3000)
    li sp, 0x00003000

    # Zero the .bss section (not strictly needed for this tiny firmware
    # but good practice)
    la a0, _bss_start
    la a1, _bss_end
bss_loop:
    bge a0, a1, bss_done
    sw zero, 0(a0)
    addi a0, a0, 4
    j bss_loop
bss_done:

    # Jump to main
    jal ra, main

    # If main returns, spin forever
halt:
    j halt
