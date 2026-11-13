*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}nvic: nvic
...  nvic: IRQControllers.NVIC @ sysbus 0xe000e000
...  ${SPACE*4}-> cpu@0
...  sram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x10000
...  storage: Memory.MappedMemory @ sysbus 0x30000000
...  ${SPACE*4}size: 0x400000
...  flash: SPI.WinbondW25QFlash
...  ${SPACE*4}underlyingMemory: storage
...  qmi: MemoryControllers.RP2350_QMI @ sysbus 0x400d0000
...  ${SPACE*4}flash: flash
...  xip: Memory.RP2350_XIPMemory @ sysbus 0x10000000
...  ${SPACE*4}flash: flash
...  ${SPACE*4}qmi: qmi
...  qspi: GPIOPort.RP2350_QSPI @ sysbus 0x40030000
...  ${SPACE*4}qmi: qmi

*** Keywords ***
Create QMI Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 cpu IsHalted true

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

QMI Write
    [Arguments]                     ${offset}  ${value}
    Execute Command                 sysbus WriteDoubleWord ${{0x400d0000 + int($offset, 0)}} ${value}

*** Test Cases ***
Should Execute Through QMI With Read Only XIP Stores
    Create QMI Machine
    Execute Command                 sysbus WriteDoubleWord 0x30000000 0x4770202a
    Execute Command                 cpu SP 0x20008000
    Execute Command                 sysbus WriteDoubleWord 0x20000000 0x20008000
    Execute Command                 sysbus WriteDoubleWord 0x20000004 0x10000001
    Execute Command                 cpu VectorTableOffset 0x20000000
    Execute Command                 cpu IsHalted false
    Execute Command                 cpu PC 0x10000000
    Execute Command                 cpu Step
    ${r0}=                          Execute Command  cpu GetRegister "R0"
    Should Be Equal As Integers      ${r0.strip()}  42
    Execute Command                 sysbus WriteDoubleWord 0x10000000 0
    Read Should Equal               0x10000000  0x4770202a

Should ExposeReal4MiBJEDECIdentificationWithClockedFrames
    Create QMI Machine
    Read Should Equal               0x400d0000  0x01810800
    QMI Write                       0x0  0x01800005
    QMI Write                       0x4  0x9f
    QMI Write                       0x4  0
    QMI Write                       0x4  0
    QMI Write                       0x4  0
    Execute Command                 emulation RunFor "0.0001"
    Read Should Equal               0x400d0008  0xff
    Read Should Equal               0x400d0008  0xef
    Read Should Equal               0x400d0008  0x40
    Read Should Equal               0x400d0008  0x16
    QMI Write                       0x0  0x01800000

ShouldTranslate4MiBWindowsAndKeepUntranslatedReadsDistinct
    Create QMI Machine
    Execute Command                 sysbus WriteDoubleWord 0x30001000 0x12345678
    QMI Write                       0x34  0x00010001
    Read Should Equal               0x10000000  0x12345678
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x10001000

Should Enter And Leave Continuous Read Through Mapped Quad Reads
    Create QMI Machine
    Execute Command                 sysbus WriteDoubleWord 0x30000000 0x12345678
    # EBh with an 8-bit A0h suffix: quad address, mode bits, 4 dummy clocks, quad data.
    QMI Write                       0x14  0xa0eb
    QMI Write                       0x10  0x492a8
    Read Should Equal               0x10000000  0x12345678
    # The flash now stays in continuous read, so reads without the command still work.
    QMI Write                       0x10  0x482a8
    Read Should Equal               0x10000000  0x12345678
    # Mode bits other than Axh end continuous read after that read.
    QMI Write                       0x14  0x00eb
    Read Should Equal               0x10000000  0x12345678
    Read Should Equal               0x10000000  0xffffffff

Should Keep Quad Reads Without Continuous Mode Bits Out Of Continuous Read
    Create QMI Machine
    Execute Command                 sysbus WriteDoubleWord 0x30000000 0x12345678
    # The boot ROM's EBh format: an 8-bit suffix of 00h, which never enters continuous read.
    QMI Write                       0x14  0x00eb
    QMI Write                       0x10  0x492a8
    Read Should Equal               0x10000000  0x12345678
    Read Should Equal               0x10000000  0x12345678
    QMI Write                       0x10  0x482a8
    Read Should Equal               0x10000000  0xffffffff

Should Drive The QSPI SS Pad From QMI Chip Select 0
    Create QMI Machine
    # GPIO_QSPI_SS_CTRL.FUNCSEL = 0 (XIP) with the pad out of isolation;
    # STATUS.OUTTOPAD is bit 9.
    Execute Command                 qspi SetPadConfiguration 3 0x56
    Execute Command                 sysbus WriteDoubleWord 0x4003001c 0
    ${status}=                      Execute Command  sysbus ReadDoubleWord 0x40030018
    Should Be True                  (int(${status.strip()}) & 0x200) != 0
    QMI Write                       0x0  0x01800005
    ${status}=                      Execute Command  sysbus ReadDoubleWord 0x40030018
    Should Be True                  (int(${status.strip()}) & 0x200) == 0
    QMI Write                       0x0  0x01800001
    ${status}=                      Execute Command  sysbus ReadDoubleWord 0x40030018
    Should Be True                  (int(${status.strip()}) & 0x200) != 0
