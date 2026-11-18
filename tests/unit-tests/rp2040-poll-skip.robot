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

*** Test Cases ***
Should Skip A Timer Poll Loop's Time Without Changing What It Reads
    ${plain_executed}  ${plain_counter}=    Run Timer Poll Loop  plain  false
    ${skip_executed}  ${skip_counter}=      Run Timer Poll Loop  skipping  true
    Should Be True                  int("${plain_counter}", 0) > 0
    # Virtual time and the counter advance the same; the spinning CPU
    # executes far fewer instructions.
    Should Be Equal As Integers      ${skip_counter}  ${plain_counter}
    Should Be True                  int("${skip_executed}", 0) * 4 < int("${plain_executed}", 0)
