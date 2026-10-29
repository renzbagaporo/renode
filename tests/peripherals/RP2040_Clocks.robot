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

*** Keywords ***
Create Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 emulation SetGlobalAdvanceImmediately true

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Frequency Should Equal
    [Arguments]                     ${clock}  ${expected}
    ${value}=                       Execute Command  clocks GetFrequency ${clock}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Enable Crystal
    Execute Command                 sysbus WriteDoubleWord 0x4002400c 1
    Execute Command                 sysbus WriteDoubleWord 0x40024000 0xfabaa0
    Execute Command                 emulation RunFor "0.000022"

Configure PLLs
    Execute Command                 sysbus WriteDoubleWord 0x40028008 125
    Execute Command                 sysbus WriteDoubleWord 0x4002800c 0x62000
    Execute Command                 sysbus WriteDoubleWord 0x4002b004 0x29
    Execute Command                 sysbus WriteDoubleWord 0x4002c008 40
    Execute Command                 sysbus WriteDoubleWord 0x4002c00c 0x52000
    Execute Command                 sysbus WriteDoubleWord 0x4002f004 0x29

*** Test Cases ***
Should Start On Ring Oscillator With Disabled Auxiliary Clocks
    Create Machine
    Frequency Should Equal          4  6000000
    Frequency Should Equal          5  6000000
    Frequency Should Equal          6  0
    Frequency Should Equal          7  0
    Read Should Equal               0x40008034  0x100
    Read Should Equal               0x40008040  0x100
    Read Should Equal               0x4000804c  0

Should Switch To Crystal Only After Startup Completes
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4002400c 1
    Execute Command                 sysbus WriteDoubleWord 0x40024000 0xfabaa0
    Execute Command                 sysbus WriteDoubleWord 0x40008030 2
    Read Should Equal               0x40008038  1
    Frequency Should Equal          4  6000000
    Execute Command                 emulation RunFor "0.000021"
    Read Should Equal               0x40008038  1
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x40008038  4
    Frequency Should Equal          4  12000000
    Frequency Should Equal          5  12000000

Should Configure Pico SDK Clock Tree With Eight Fraction Bits
    Create Machine
    Enable Crystal
    Configure PLLs
    Execute Command                 sysbus WriteDoubleWord 0x40008030 2
    Execute Command                 sysbus WriteDoubleWord 0x4000803c 1
    Execute Command                 sysbus WriteDoubleWord 0x40008048 0x800
    Execute Command                 sysbus WriteDoubleWord 0x40008054 0x800
    Execute Command                 sysbus WriteDoubleWord 0x40008060 0x800
    Execute Command                 sysbus WriteDoubleWord 0x40008070 0x40000
    Execute Command                 sysbus WriteDoubleWord 0x4000806c 0x800
    Frequency Should Equal          4  12000000
    Frequency Should Equal          5  125000000
    Frequency Should Equal          6  125000000
    Frequency Should Equal          7  48000000
    Frequency Should Equal          8  48000000
    Frequency Should Equal          9  46875
    Read Should Equal               0x40008044  2
    Read Should Equal               0x40008054  0x800
    Execute Command                 sysbus WriteDoubleWord 0x40008040 0x280
    Frequency Should Equal          5  50000000
    Frequency Should Equal          6  50000000

Should Not Select A PLL Before It Locks
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4000803c 1
    Read Should Equal               0x40008044  1
    Configure PLLs
    Read Should Equal               0x40028000  1
    Read Should Equal               0x40008044  1
    Enable Crystal
    Read Should Equal               0x40028000  0x80000001
    Read Should Equal               0x40008044  2
    Frequency Should Equal          5  125000000

Should Apply Ring Divider And Fail Safe Invalid Writes
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x40060010 0xaa1
    Frequency Should Equal          4  96000000
    Execute Command                 sysbus WriteDoubleWord 0x40060010 0
    ${frequency}=                   Execute Command  rosc Frequency
    Should Be Equal As Integers      ${frequency.strip()}  ${{96000000 // 31}}
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x636f6d61
    Frequency Should Equal          4  0
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0
    Frequency Should Equal          4  ${{96000000 // 31}}

Should Pause Ring Countdown While Dormant
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x40060020 100
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x636f6d61
    Execute Command                 emulation RunFor "0.000010"
    Read Should Equal               0x40060020  100
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x77616b65
    Execute Command                 emulation RunFor "0.000010"
    Read Should Equal               0x40060020  40
