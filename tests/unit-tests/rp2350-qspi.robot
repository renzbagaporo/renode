*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  accessctrl: Miscellaneous.RP2350_AccessControl @ sysbus 0x40060000
...  sio: Miscellaneous.RP2350_SIO @ sysbus 0xd0000000
...  ${SPACE*4}accessControl: accessctrl
...  qspi: GPIOPort.RP2350_QSPI @ sysbus 0x40030000
...  ${SPACE*4}sio: sio
...  ${SPACE*4}accessControl: accessctrl
...  pads: GPIOPort.RP2350_PadsQSPI @ sysbus 0x40040000
...  ${SPACE*4}gpio: qspi
...  sysinfo: Miscellaneous.RP2350_SYSINFO @ sysbus 0x40000000
...  ${SPACE*4}packageQfn60: true

*** Keywords ***
Create QSPI Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

*** Test Cases ***
ShouldExposeColdPadPullsThroughIsolatedInputLatches
    Create QSPI Machine
    Read Should Equal               0x40040004  0x156
    Read Should Equal               0x4004000c  0x156
    Read Should Equal               0x40040010  0x15a
    Read Should Equal               0x40040018  0x15a
    Read Should Equal               0xd0000008  0xc8000000
    Execute Command                 qspi OnGPIO 5 true
    Read Should Equal               0xd0000008  0xe8000000
    Execute Command                 qspi ReleaseInput 5
    Read Should Equal               0xd0000008  0xc8000000

ShouldMapPadSSAfterDataPinsAndPreserveIsolationOnAPBReset
    Create QSPI Machine
    Execute Command                 sysbus WriteDoubleWord 0x40040018 0x56
    Read Should Equal               0xd0000008  0xc0000000
    Read Should Equal               0x40040018  0x56
    Execute Command                 pads ResetHeld true
    Read Should Equal               0x40040018  0x5a
    Execute Command                 pads ResetHeld false
    Read Should Equal               0xd0000008  0xc8000000

ShouldReportA2ChipAndQFN60Package
    Create QSPI Machine
    Read Should Equal               0x40000000  0x20004927
    Read Should Equal               0x40000004  1
    Read Should Equal               0x40000008  2
