*** Keywords ***
Create Power Machine
    Execute Command                 mach create
    ${platform}=                    Evaluate  open('platforms/cpus/rp2350.repl').read().split('xip: MemoryControllers.RP2350_XIP')[0]
    Execute Command                 machine LoadPlatformDescriptionFromString """${platform}"""
    Execute Command                 sysbus WriteDoubleWord 0x40023000 0x01800000
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    Execute Command                 sysbus WriteDoubleWord 0 0x20008000
    Execute Command                 sysbus WriteDoubleWord 4 0x101
    Execute Command                 sysbus WriteWord 0x100 0xe7fe

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

*** Test Cases ***
ShouldCountTimerOnlyWhileItsReferenceTickIsEnabled
    Create Power Machine
    Execute Command                 sysbus WriteDoubleWord 0x4010801c 6
    Execute Command                 sysbus WriteDoubleWord 0x40108018 1
    Read Should Equal               0x400b0028  0
    Execute Command                 emulation RunFor "0.00001"
    Read Should Equal               0x400b0028  10
    Execute Command                 sysbus WriteDoubleWord 0x40108018 0
    Execute Command                 emulation RunFor "0.00001"
    Read Should Equal               0x400b0028  10

ShouldExpireWatchdogAfterTenTicksAndRetainEnableBit
    Create Power Machine
    Execute Command                 sysbus WriteDoubleWord 0x40108034 6
    Execute Command                 sysbus WriteDoubleWord 0x40108030 1
    Execute Command                 sysbus WriteDoubleWord 0x400d8004 10
    Execute Command                 sysbus WriteDoubleWord 0x400d8000 0x47000000
    Execute Command                 emulation RunFor "0.000009"
    Read Should Equal               0x400d8008  0
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x400d8008  1
    Read Should Equal               0x400d8000  0x47000000

ShouldResetOnlySelectedProcessorOnPSMWatchdogRequest
    Create Power Machine
    Execute Command                 cpu0 SetRegister "R0" 0x1234
    Execute Command                 cpu1 SetRegister "R0" 0x5678
    Execute Command                 sysbus WriteDoubleWord 0x40018008 0x800000
    Execute Command                 sysbus WriteDoubleWord 0x400d8000 0x80000000
    Execute Command                 emulation RunFor "0.00001"
    ${r0}=                          Execute Command  cpu0 GetRegister "R0"
    ${r1}=                          Execute Command  cpu1 GetRegister "R0"
    Should Be Equal As Integers      ${r0.strip()}  0
    Should Be Equal As Integers      ${r1.strip()}  0x5678
    Read Should Equal               0x400d8008  2

ShouldRetainAONScratchAndClearWatchdogScratchOnPOWMANReset
    Create Power Machine
    Execute Command                 sysbus WriteDoubleWord 0x401000b0 0xaabbccdd
    Execute Command                 sysbus WriteDoubleWord 0x400d800c 0x12345678
    Execute Command                 sysbus WriteDoubleWord 0x40100030 0x5afe1000
    Execute Command                 sysbus WriteDoubleWord 0x400d8000 0x80000000
    Execute Command                 emulation RunFor "0.00001"
    Read Should Equal               0x401000b0  0xaabbccdd
    Read Should Equal               0x400d800c  0
    Read Should Equal               0x400d8008  2
    Read Should Equal               0x4010002c  0x10000000
