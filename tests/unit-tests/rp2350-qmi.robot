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
    Read Should Equal               0x10001000  0xffffffff
