*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m0+"
...  ${SPACE*4}nvic: nvic
...  ${SPACE*4}InitVectorTableOffset: 0
...  nvic: IRQControllers.NVIC @ sysbus 0xe000e000
...  ${SPACE*4}-> cpu0@0
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x1000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x2000

# Each handler spins at its own address in RAM.
${THREAD}                           0x20000000
${PENDSV_HANDLER}                   0x20000010
${IRQ0_HANDLER}                     0x20000020
${HARDFAULT_HANDLER}                0x20000030

*** Keywords ***
Create Machine With Vectors In ROM
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 sysbus WriteDoubleWord 0x00 0x20001000
    Execute Command                 sysbus WriteDoubleWord 0x04 0x20000001
    Execute Command                 sysbus WriteDoubleWord 0x0c 0x20000031
    Execute Command                 sysbus WriteDoubleWord 0x38 0x20000011
    Execute Command                 sysbus WriteDoubleWord 0x40 0x20000021
    FOR  ${address}  IN  ${THREAD}  ${PENDSV_HANDLER}  ${IRQ0_HANDLER}  ${HARDFAULT_HANDLER}
        Execute Command             sysbus WriteWord ${address} 0xe7fe
    END
    Execute Command                 cpu0 PC ${THREAD}
    Execute Command                 cpu0 SetRegister "SP" 0x20001000

Run Briefly
    Execute Command                 emulation RunFor "0.0001"

PC Should Be
    [Arguments]                     ${expected}
    ${pc}=                          Execute Command  cpu0 PC
    Should Be Equal As Integers      ${pc.strip()}  ${expected}

*** Test Cases ***
Should Read Vectors At Their Addresses After Read-Only Memory Returns To The Bus
    Create Machine With Vectors In ROM
    # Mapping the page read-only and then sending its accesses back through
    # the bus leaves it unmapped, so the CPU reads PendSV's vector through
    # the bus, from its own address and not from the next vector's.
    Execute Command                 cpu0 RequestReadOnlyMemoryAccess <0x0 0x1000> true
    Run Briefly
    Execute Command                 cpu0 RequestReadOnlyMemoryAccess <0x0 0x1000> false
    Run Briefly
    PC Should Be                    ${THREAD}
    Execute Command                 sysbus WriteDoubleWord 0xe000ed04 0x10000000
    Run Briefly
    PC Should Be                    ${PENDSV_HANDLER}
