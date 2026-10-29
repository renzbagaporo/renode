*** Settings ***
Library                             OperatingSystem

*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m0+"
...  ${SPACE*4}nvic: nvic
...  ${SPACE*4}InitVectorTableOffset: 0
...  nvic: IRQControllers.NVIC @ sysbus 0xe000e000
...  ${SPACE*4}-> cpu@0
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x1000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x1000
...  backing: Memory.MappedMemory
...  ${SPACE*4}size: 0x200000
...  ssi: SPI.RP2040_SSI @ sysbus 0x18000000
...  nor: SPI.WinbondW25QFlash @ ssi 0
...  ${SPACE*4}underlyingMemory: backing
...  xip: MemoryControllers.RP2040_XIP @ sysbus 0x14000000
...  ${SPACE*4}ssi: ssi
...  ${SPACE*4}flash: nor
...  flash: Memory.RP2040_XIPMemory @ { sysbus 0x10000000; sysbus 0x11000000; sysbus 0x12000000; sysbus 0x13000000 }
...  ${SPACE*4}flash: nor
...  ${SPACE*4}xip: xip

*** Keywords ***
Create Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 emulation SetGlobalAdvanceImmediately true

Configure Standard XIP Read
    Execute Command                 ssi WriteDoubleWord 0 0x001f0300
    Execute Command                 ssi WriteDoubleWord 0x14 2
    Execute Command                 ssi WriteDoubleWord 0xf4 0x03000218
    Execute Command                 ssi WriteDoubleWord 0x10 1
    Execute Command                 ssi WriteDoubleWord 8 1

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${actual}=                      Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

Check CPU Store
    [Arguments]                     ${address}
    Create Machine
    # Execute STR to the selected XIP alias, then write a success marker to SRAM.
    ${program}=                     Evaluate  bytes.fromhex("03490720086003492a200860fee7c046") + struct.pack("<II", int("${address}", 0), 0x20000100)  modules=struct
    Create Binary File              ${OUTPUT DIR}/rp2040_xip_store.bin  ${program}
    Execute Command                 flash LoadBinary @${OUTPUT DIR}/rp2040_xip_store.bin
    Execute Command                 sysbus WriteDoubleWord 0 0x20001000
    Execute Command                 sysbus WriteDoubleWord 4 0x10000001
    Configure Standard XIP Read
    Execute Command                 emulation RunFor "0.00001"
    Read Should Equal               0x20000100  0x2a
    Read Should Equal               ${address}  0xffffffff

*** Test Cases ***
Should Ignore CPU Stores To Cached Allocating Alias
    Check CPU Store                 0x10000100

Should Ignore CPU Stores To Cached Nonallocating Alias
    Check CPU Store                 0x11000100

Should Ignore CPU Stores To Uncached Allocating Alias
    Check CPU Store                 0x12000100

Should Ignore CPU Stores To Uncached Nonallocating Alias
    Check CPU Store                 0x13000100

Should Block Uncached Reads When SSI Is Disabled
    Create Machine
    ${program}=                     Evaluate  bytes.fromhex("03490720086003492a200860fee7c046")
    Create Binary File              ${OUTPUT DIR}/rp2040_xip_read.bin  ${program}
    Execute Command                 flash LoadBinary @${OUTPUT DIR}/rp2040_xip_read.bin
    Read Should Equal               0x13000000  0
    Configure Standard XIP Read
    Read Should Equal               0x13000000  0x20074903
    Execute Command                 ssi WriteDoubleWord 8 0
    Read Should Equal               0x13000000  0
