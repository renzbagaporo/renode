*** Keywords ***
Run Timer Poll Loop
    [Arguments]                     ${name}  ${skip}
    Execute Command                 mach create "${name}"
    Execute Command                 machine LoadPlatformDescription @platforms/boards/raspberry_pi_pico.repl
    Execute Command                 cpu1 IsHalted true
    # ldr r1, [r0]; b . : spin reading TIMERAWL, as busy_wait_us does.
    Execute Command                 sysbus WriteWord 0x20000000 0x6801
    Execute Command                 sysbus WriteWord 0x20000002 0xe7fd
    Execute Command                 cpu0 PC 0x20000000
    Execute Command                 cpu0 SetRegister 0 0x40054028
    # Release the timer from reset (RESETS bit 21, through the atomic-clear
    # alias) and start the watchdog's tick generator, which counts it.
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x200000
    Execute Command                 sysbus WriteDoubleWord 0x4005802c 0x206
    # clk_sys at 125 MHz, as programs run it: 125 instructions per count.
    Execute Command                 cpu0 PerformanceInMips 125
    Execute Command                 timer SkipPollingTime ${skip}
    Execute Command                 emulation RunFor "0.0002"
    ${executed}=                    Execute Command  cpu0 ExecutedInstructions
    ${counter}=                     Execute Command  sysbus ReadDoubleWord 0x40054028
    RETURN                          ${executed.strip()}  ${counter.strip()}

Run Timer Wait Loop
    [Arguments]                     ${name}  ${skip}
    # Each run alone in the emulation, so no other machine's rounds bound its skips.
    Reset Emulation
    Execute Command                 mach create "${name}"
    Execute Command                 machine LoadPlatformDescription @platforms/boards/raspberry_pi_pico.repl
    Execute Command                 cpu1 IsHalted true
    # Waits for the next count and counts the waits in r2, as a sleep_us(1)
    # loop does: ldr r1, [r0]; adds r1, #1; then ldr r3, [r0]; cmp r3, r1;
    # bcc back to that read; adds r2, #1; b to the start.
    Execute Command                 sysbus WriteWord 0x20000000 0x6801
    Execute Command                 sysbus WriteWord 0x20000002 0x3101
    Execute Command                 sysbus WriteWord 0x20000004 0x6803
    Execute Command                 sysbus WriteWord 0x20000006 0x428b
    Execute Command                 sysbus WriteWord 0x20000008 0xd3fc
    Execute Command                 sysbus WriteWord 0x2000000a 0x3201
    Execute Command                 sysbus WriteWord 0x2000000c 0xe7f8
    Execute Command                 cpu0 PC 0x20000000
    Execute Command                 cpu0 SetRegister 0 0x40054028
    Execute Command                 cpu0 SetRegister 2 0
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x200000
    Execute Command                 sysbus WriteDoubleWord 0x4005802c 0x206
    Execute Command                 cpu0 PerformanceInMips 125
    Execute Command                 timer SkipPollingTime ${skip}
    Execute Command                 emulation RunFor "0.0002"
    ${executed}=                    Execute Command  cpu0 ExecutedInstructions
    ${waits}=                       Execute Command  cpu0 GetRegister 2
    RETURN                          ${executed.strip()}  ${waits.strip()}

*** Test Cases ***
Should Skip A Timer Poll Loop's Time Without Changing What It Reads
    ${plain_executed}  ${plain_counter}=    Run Timer Poll Loop  plain  false
    ${skip_executed}  ${skip_counter}=      Run Timer Poll Loop  skipping  true
    Should Be True                  int("${plain_counter}", 0) > 0
    # Virtual time and the counter advance the same; the spinning CPU
    # executes far fewer instructions.
    Should Be Equal As Integers      ${skip_counter}  ${plain_counter}
    Should Be True                  int("${skip_executed}", 0) * 4 < int("${plain_executed}", 0)

Should End A Wait For The Next Count At That Count
    ${plain_executed}  ${plain_waits}=      Run Timer Wait Loop  plain  false
    ${skip_executed}  ${skip_waits}=        Run Timer Wait Loop  skipping  true
    Should Be True                  int("${plain_waits}", 0) > 150
    # The read that sees the count ends the wait without skipping on past
    # it, so each wait still takes one count.
    Should Be True                  abs(int("${skip_waits}", 0) - int("${plain_waits}", 0)) <= 1
    Should Be True                  int("${skip_executed}", 0) * 4 < int("${plain_executed}", 0)
