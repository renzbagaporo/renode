*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}nvic: nvic
...  nvic: IRQControllers.NVIC @ sysbus 0xe000e000
...  ${SPACE*4}-> cpu@0
...  rom: Memory.RP2350_ROM @ sysbus 0
...  sram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x10000

*** Keywords ***
Create ROM Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    ${image}=                       Evaluate  bytes.fromhex('0080002001010000') + bytes(248) + bytes.fromhex('2a20002100220a60fee7')
    Evaluate                        open(r'%{RP2_TEST_OUTPUT}/mask_rom.bin', 'wb').write($image)
    Execute Command                 rom LoadBinary @%{RP2_TEST_OUTPUT}/mask_rom.bin

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

*** Test Cases ***
ShouldIgnoreAllDataBusWritesAndRetainMaskROMOnReset
    Create ROM Machine
    Execute Command                 sysbus WriteByte 0 0xff
    Execute Command                 sysbus WriteWord 2 0xffff
    Execute Command                 sysbus WriteDoubleWord 4 0xdeadbeef
    Read Should Equal               0  0x20008000
    Read Should Equal               4  0x101
    Execute Command                 machine Reset
    Read Should Equal               0  0x20008000
    Read Should Equal               4  0x101

ShouldExecuteMaskROMAndIgnoreProcessorStoreToVector
    Create ROM Machine
    Execute Command                 emulation RunFor "0.00001"
    ${r0}=                          Execute Command  cpu GetRegister "R0"
    Should Be Equal As Integers      ${r0.strip()}  42
    Read Should Equal               0  0x20008000
    Read Should Equal               4  0x101
