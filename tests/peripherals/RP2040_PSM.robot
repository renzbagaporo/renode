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
...  ${SPACE*4}SystemResetRequest -> psm@1
...  nvic1: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 }
...  ${SPACE*4}-> cpu1@0
...  ${SPACE*4}SystemResetRequest -> psm@2
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x1000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x1000
...  psm: Miscellaneous.RP2040_PSM @ sysbus 0x40010000
...  ${SPACE*4}core0: cpu0
...  ${SPACE*4}core1: cpu1
...  ${SPACE*4}nvic0: nvic0
...  ${SPACE*4}nvic1: nvic1
...  chip_reset: Miscellaneous.RP2040_VregAndChipReset @ sysbus 0x40064000
...  debug_port: CPU.RP2040TestDebugPort @ sysbus
...  ${SPACE*4}cpu0: cpu0
...  ${SPACE*4}cpu1: cpu1

*** Keywords ***
Create Machine
    Execute Command                 include @${CURDIR}/RP2040TestDebugPort.cs
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 sysbus WriteDoubleWord 0 0x20001000
    Execute Command                 sysbus WriteDoubleWord 4 0x101
    # Distinct entry markers and ADD loops prove real reset-vector execution.
    Execute Command                 sysbus WriteWord 0x100 0x235a
    Execute Command                 sysbus WriteWord 0x102 0x3201
    Execute Command                 sysbus WriteWord 0x104 0xe7fd
    Execute Command                 sysbus WriteWord 0x200 0x23a5
    Execute Command                 sysbus WriteWord 0x202 0x3201
    Execute Command                 sysbus WriteWord 0x204 0xe7fd
    Execute Command                 emulation SetGlobalQuantum "0.000001"
    Execute Command                 emulation SetGlobalAdvanceImmediately true

Read Should Equal
    [Arguments]                     ${address}  ${expected}  ${core}=cpu0
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address} context=${core}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Core One Should Remain In Reset
    Read Should Equal               0x40010004  0x10000
    Read Should Equal               0x4001000c  0xffff
    ${before}=                      Execute Command  cpu1 ExecutedInstructions
    Should Be Equal As Integers      ${before.strip()}  0
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 emulation RunFor "0.00001"
    ${after}=                       Execute Command  cpu1 ExecutedInstructions
    Should Be Equal As Integers      ${after.strip()}  ${before.strip()}
    ${counter}=                     Execute Command  cpu1 GetRegister "r2"
    Should Be Equal As Integers      ${counter.strip()}  0

Both Cores Should Be Held In Reset
    ${r0}=                          Execute Command  cpu0 GetRegister "r0"
    Should Be Equal As Integers      ${r0.strip()}  0
    FOR  ${core}  IN  cpu0  cpu1
        ${before}=                  Execute Command  ${core} ExecutedInstructions
        Execute Command             emulation RunFor "0.00001"
        ${after}=                   Execute Command  ${core} ExecutedInstructions
        Should Be Equal As Integers  ${after.strip()}  ${before.strip()}
        ${marker}=                  Execute Command  ${core} GetRegister "r3"
        Should Be Equal As Integers  ${marker.strip()}  0
    END

Core One Should Boot From Reset Vector
    Execute Command                 emulation RunFor "0.00001"
    Read Should Equal               0x40010004  0
    Read Should Equal               0x4001000c  0x1ffff
    ${pc}=                          Execute Command  cpu1 PC
    ${sp}=                          Execute Command  cpu1 SP
    ${marker}=                      Execute Command  cpu1 GetRegister "r3"
    ${counter}=                     Execute Command  cpu1 GetRegister "r2"
    Should Be True                  int("${pc.strip()}", 0) in (0x102, 0x104)
    Should Be Equal As Integers      ${sp.strip()}  0x20001000
    Should Be Equal As Integers      ${marker.strip()}  0x5a
    Should Be True                  int("${counter.strip()}", 0) > 0

*** Test Cases ***
Should Hold Core One In Reset Until Released
    Create Machine
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 cpu1 SetRegister "r0" 0xdeadbeef
    Execute Command                 sysbus WriteDoubleWord 0xe000e100 1 context=cpu1
    Execute Command                 sysbus WriteDoubleWord 0x40012004 0x10000 context=cpu0
    Execute Command                 emulation RunFor "0.00001"
    Core One Should Remain In Reset
    ${core0_r0}=                    Execute Command  cpu0 GetRegister "r0"
    ${core1_r0}=                    Execute Command  cpu1 GetRegister "r0"
    ${core0_progress}=              Execute Command  cpu0 GetRegister "r2"
    Should Be Equal As Integers      ${core0_r0.strip()}  0x12345678
    Should Be Equal As Integers      ${core1_r0.strip()}  0
    Should Be True                  int("${core0_progress.strip()}", 0) > 0
    Read Should Equal               0xe000e100  0  cpu1
    Execute Command                 sysbus WriteDoubleWord 0x40013004 0x10000 context=cpu0
    Core One Should Boot From Reset Vector

Should Reset Only The Requesting Core On SYSRESETREQ
    Create Machine
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 cpu1 SetRegister "r0" 0x5678
    Execute Command                 sysbus WriteDoubleWord 0xe000e100 1 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000e100 2 context=cpu1
    # A debugger's AIRCR write arrives from outside the CPU threads.
    Execute Command                 sysbus WriteDoubleWord 0xe000ed0c 0x05fa0004 context=cpu0
    Execute Command                 emulation RunFor "0.00001"
    ${r0}=                          Execute Command  cpu0 GetRegister "r0"
    ${marker}=                      Execute Command  cpu0 GetRegister "r3"
    Should Be Equal As Integers      ${r0.strip()}  0
    Should Be Equal As Integers      ${marker.strip()}  0x5a
    Read Should Equal               0xe000e100  0  cpu0
    # RP2040 datasheet 2.4.2: the NVIC resets only its own core.
    ${core1_r0}=                    Execute Command  cpu1 GetRegister "r0"
    Should Be Equal As Integers      ${core1_r0.strip()}  0x5678
    Read Should Equal               0xe000e100  2  cpu1
    Read Should Equal               0x40064008  0x100

Should Hold Both Cores In A Rescue Reset Requested From Outside The CPU Threads
    Create Machine
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 debug_port Rescue true
    Execute Command                 emulation RunFor "0.00001"
    Both Cores Should Be Held In Reset
    Execute Command                 debug_port Rescue false
    Execute Command                 emulation RunFor "0.00001"
    ${marker}=                      Execute Command  cpu0 GetRegister "r3"
    ${counter}=                     Execute Command  cpu0 GetRegister "r2"
    Should Be Equal As Integers      ${marker.strip()}  0x5a
    Should Be True                  int("${counter.strip()}", 0) > 0

Should Record Each Chip Reset Cause In CHIP_RESET
    Create Machine
    Read Should Equal               0x40064008  0x100
    Execute Command                 debug_port Rescue true
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 debug_port Rescue false
    Execute Command                 emulation RunFor "0.00001"
    # HAD_PSM_RESTART and PSM_RESTART_FLAG, which the boot ROM writes back to clear.
    Read Should Equal               0x40064008  0x1100000
    Execute Command                 sysbus WriteDoubleWord 0x40064008 0x1100000 context=cpu0
    Read Should Equal               0x40064008  0x100000
    Execute Command                 debug_port Rescue true
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 debug_port Rescue false
    Execute Command                 debug_port OnGPIO 2 false
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 debug_port OnGPIO 2 true
    Execute Command                 emulation RunFor "0.00001"
    # RUN leaves an unacknowledged restart flag set.
    Read Should Equal               0x40064008  0x1010000
    Execute Command                 sysbus WriteDoubleWord 0x40066008 0x1000000 context=cpu0
    Read Should Equal               0x40064008  0x10000
    Execute Command                 sysbus WriteDoubleWord 0xe000ed0c 0x05fa0004 context=cpu0
    Execute Command                 emulation RunFor "0.00001"
    Read Should Equal               0x40064008  0x10000
    Execute Command                 machine Reset
    Read Should Equal               0x40064008  0x100

Should Hold Both Cores While RUN Is Low
    Create Machine
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 debug_port OnGPIO 2 false
    Execute Command                 emulation RunFor "0.00001"
    Both Cores Should Be Held In Reset
    Execute Command                 debug_port OnGPIO 2 true
    Execute Command                 emulation RunFor "0.00001"
    ${marker}=                      Execute Command  cpu0 GetRegister "r3"
    Should Be Equal As Integers      ${marker.strip()}  0x5a

Should Restart Core One On A Second Reset
    Create Machine
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 cpu1 PC 0x200
    Execute Command                 emulation RunFor "0.00001"
    ${old_marker}=                  Execute Command  cpu1 GetRegister "r3"
    Should Be Equal As Integers      ${old_marker.strip()}  0xa5
    Execute Command                 sysbus WriteDoubleWord 0x40010004 0x10000
    Execute Command                 emulation RunFor "0.00001"
    Core One Should Remain In Reset
    Execute Command                 sysbus WriteDoubleWord 0x40010004 0
    Core One Should Boot From Reset Vector

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
    Execute Command                 emulation RunFor "0.00001"
    Core One Should Remain In Reset
    Execute Command                 machine Reset
    Core One Should Boot From Reset Vector
