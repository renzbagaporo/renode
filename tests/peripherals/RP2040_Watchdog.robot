*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  xosc: Miscellaneous.RP2_XOSC @ sysbus 0x40024000
...  rosc: Miscellaneous.RP2040_ROSC @ sysbus 0x40060000
...  pllSys: Miscellaneous.RP2_PLL @ sysbus 0x40028000
...  ${SPACE*4}xosc: xosc
...  pllUsb: Miscellaneous.RP2_PLL @ sysbus 0x4002c000
...  ${SPACE*4}xosc: xosc
...  clocks: Miscellaneous.RP2040_Clocks @ sysbus 0x40008000
...  ${SPACE*4}xosc: xosc
...  ${SPACE*4}rosc: rosc
...  ${SPACE*4}pllSys: pllSys
...  ${SPACE*4}pllUsb: pllUsb
...  resets: Miscellaneous.RP2_Resets @ sysbus 0x4000c000
...  timer: Timers.RP2_Timer @ { sysbus 0x40054000; resets 21 }
...  watchdog: Miscellaneous.RP2040_Watchdog @ sysbus 0x40058000
...  ${SPACE*4}clocks: clocks
...  ${SPACE*4}timer: timer

*** Keywords ***
Create Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 emulation SetGlobalAdvanceImmediately true
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x200000
    # Nominal ring clock is 6 MHz, so six input cycles give a 1 MHz tick.
    Execute Command                 sysbus WriteDoubleWord 0x4005802c 0x206

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

*** Test Cases ***
Should Drive Timer From Watchdog Tick And Honor Enable
    Create Machine
    Execute Command                 emulation RunFor "0.000010"
    Read Should Equal               0x40054028  10
    Execute Command                 sysbus WriteDoubleWord 0x4005b02c 0x200
    Execute Command                 emulation RunFor "0.000010"
    Read Should Equal               0x40054028  10
    ${tick}=                        Execute Command  sysbus ReadDoubleWord 0x4005802c
    Should Be Equal As Integers      ${{int($tick.strip(), 0) & 0x400}}  0
    Execute Command                 sysbus WriteDoubleWord 0x4005a02c 0x200
    Execute Command                 emulation RunFor "0.000003"
    Read Should Equal               0x40054028  13

Should Preserve Watchdog Tick Across Timer Reset
    Create Machine
    Execute Command                 emulation RunFor "0.000005"
    Read Should Equal               0x40054028  5
    Execute Command                 sysbus WriteDoubleWord 0x4000e000 0x200000
    Execute Command                 emulation RunFor "0.000005"
    Read Should Equal               0x40054028  0
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x200000
    Execute Command                 emulation RunFor "0.000003"
    Read Should Equal               0x40054028  3

Should Propagate Reference Clock Changes To Tick Consumers
    Create Machine
    Execute Command                 emulation RunFor "0.000005"
    Read Should Equal               0x40054028  5
    Execute Command                 sysbus WriteDoubleWord 0x40060010 0xaa8
    Execute Command                 emulation RunFor "0.000005"
    Read Should Equal               0x40054028  15

Should Implement Doubled Watchdog Decrement And Pause
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x40058004 100
    Execute Command                 sysbus WriteDoubleWord 0x4005a000 0x40000000
    Execute Command                 emulation RunFor "0.000010"
    Read Should Equal               0x40058000  0x47000050
    Execute Command                 sysbus WriteDoubleWord 0x4005b000 0x40000000
    Execute Command                 emulation RunFor "0.000020"
    Read Should Equal               0x40058000  0x07000050

Should Replicate Scratch Narrow Writes And Apply Atomic Aliases
    Create Machine
    Execute Command                 sysbus WriteByte 0x4005800c 0x12
    Read Should Equal               0x4005800c  0x12121212
    Execute Command                 sysbus WriteWord 0x4005800e 0xabcd
    Read Should Equal               0x4005800c  0xabcdabcd
    Execute Command                 sysbus WriteDoubleWord 0x4005b00c 0x00ff00ff
    Read Should Equal               0x4005800c  0xab00ab00
