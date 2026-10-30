# Pico SDK examples

The core examples use the source revisions and Release configuration pinned in
`inputs.json`. The board matrix covers Pico/RP2040 and Pico 2/RP2350 Arm.

The doorbell example's interrupt handler updates `exit_core0`. Its declaration
requires `volatile` so the foreground loop reloads the flag after an interrupt.
`patches/multicore_doorbell_volatile.patch` supplies exactly that qualifier. The
patch preserves the iteration count, interrupt handler, handshake and compiler
optimization settings. The original upstream checkout remains a separate input
for inventory and failure-control evidence.

Flash examples provision only file-backed NOR image segments and boot through
the official ROM. `flash_nuke` uses the SDK's SRAM debugger entry, as required by
its `no_flash` build, and must finish through the real ROM USB bootloader.
