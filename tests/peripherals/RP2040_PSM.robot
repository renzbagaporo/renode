*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m0+"
...  ${SPACE*4}nvic: nvic0
...  ${SPACE*4}id: 0
...  ${SPACE*4}InitVectorTableOffset: 0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m0+"
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}id: 1
...  ${SPACE*4}InitVectorTableOffset: 0
...  nvic0: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 }
...  ${SPACE*4}-> cpu1@0
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x1000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x1000
...  psm: Miscellaneous.RP2040_PSM @ sysbus 0x40010000
...  ${SPACE*4}core0: cpu0
...  ${SPACE*4}core1: cpu1
...  ${SPACE*4}nvic0: nvic0
...  ${SPACE*4}nvic1: nvic1

*** Keywords ***
Create Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 sysbus WriteDoubleWord 0 0x20001000
    Execute Command                 sysbus WriteDoubleWord 4 0x101
    Execute Command                 sysbus WriteWord 0x100 0xe7fe
    Execute Command                 emulation SetGlobalAdvanceImmediately true

Read Should Equal
    [Arguments]                     ${address}  ${expected}  ${core}=cpu0
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address} context=${core}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

CPU State Should Equal
    [Arguments]                     ${core}  ${property}  ${expected}
    ${value}=                       Execute Command  ${core} ${property}
    Should Be Equal                 ${value.strip()}  ${expected}

*** Test Cases ***
Should Hold Core One In Reset Until Released
    Create Machine
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 cpu1 SetRegister "r0" 0xdeadbeef
    Execute Command                 sysbus WriteDoubleWord 0xe000e100 1 context=cpu1
    Execute Command                 sysbus WriteDoubleWord 0x40012004 0x10000 context=cpu0
    Read Should Equal               0x40010004  0x10000
    Read Should Equal               0x4001000c  0xffff
    CPU State Should Equal          cpu1  IsHalted  True
    ${core0_r0}=                    Execute Command  cpu0 GetRegister "r0"
    ${core1_r0}=                    Execute Command  cpu1 GetRegister "r0"
    Should Be Equal As Integers      ${core0_r0.strip()}  0x12345678
    Should Be Equal As Integers      ${core1_r0.strip()}  0
    Read Should Equal               0xe000e100  0  cpu1
    Execute Command                 sysbus WriteDoubleWord 0x40013004 0x10000 context=cpu0
    Execute Command                 emulation RunToNearestSyncPoint
    CPU State Should Equal          cpu1  IsHalted  False
    ${pc}=                          Execute Command  cpu1 PC
    ${sp}=                          Execute Command  cpu1 SP
    Should Be Equal As Integers      ${pc.strip()}  0x100
    Should Be Equal As Integers      ${sp.strip()}  0x20001000
    Read Should Equal               0x4001000c  0x1ffff

Should Restart Core One On A Second Reset
    Create Machine
    Execute Command                 emulation RunFor "0.000001"
    Execute Command                 cpu1 PC 0x200
    Execute Command                 sysbus WriteDoubleWord 0x40010004 0x10000
    Execute Command                 emulation RunFor "0.000001"
    CPU State Should Equal          cpu1  IsHalted  True
    Execute Command                 sysbus WriteDoubleWord 0x40010004 0
    Execute Command                 emulation RunToNearestSyncPoint
    ${pc}=                          Execute Command  cpu1 PC
    Should Be Equal As Integers      ${pc.strip()}  0x100

Should Preserve Force Registers Across Atomic Alias Writes
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x40010000 0x100
    Execute Command                 sysbus WriteDoubleWord 0x40012000 0x200
    Read Should Equal               0x40010000  0x300
    Execute Command                 sysbus WriteDoubleWord 0x40011000 0x180
    Read Should Equal               0x40010000  0x280
    Execute Command                 sysbus WriteDoubleWord 0x40013000 0x200
    Read Should Equal               0x40010000  0x80
    Execute Command                 sysbus WriteDoubleWord 0x40010008 0xffffffff
    Read Should Equal               0x40010008  0x1ffff

Should Release A Held Core On Chip Reset
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x40012004 0x10000
    CPU State Should Equal          cpu1  IsHalted  True
    Execute Command                 machine Reset
    Execute Command                 emulation RunToNearestSyncPoint
    Read Should Equal               0x40010004  0
    CPU State Should Equal          cpu1  IsHalted  False
