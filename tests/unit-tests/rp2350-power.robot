*** Keywords ***
Create Power Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @platforms/boards/raspberry_pi_pico2.repl
    Execute Command                 sysbus WriteDoubleWord 0x40023000 0x01800000
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    ${image}=                       Evaluate  bytes.fromhex('0080002001010000') + bytes(248) + bytes.fromhex('fee7')
    ${rom_image}=                   Allocate Temporary File
    Evaluate                        open(r'${rom_image}', 'wb').write($image)
    Execute Command                 rom LoadBinary @${rom_image}

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

ShouldPowerGateSplitSRAMDomainsWithoutPartialMappedLocks
    Create Power Machine
    Execute Command                 sysbus WriteDoubleWord 0x20000000 0x12345678
    Execute Command                 sysbus WriteDoubleWord 0x20040000 0xabcdef01
    Execute Command                 sysbus WriteDoubleWord 0x40100038 0x5afe0010
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x40100038  0x11
    Read Should Equal               0x20000000  0x12345678
    Read Should Equal               0x20040000  0
    Execute Command                 sysbus WriteDoubleWord 0x20040000 0xdeadbeef
    Execute Command                 sysbus WriteDoubleWord 0x40100038 0x5afe0000
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x40100038  0
    Read Should Equal               0x20000000  0x12345678
    Read Should Equal               0x20040000  0

ShouldLoseBootRAMAndPinnedCacheWhenXIPDomainPowersDown
    Create Power Machine
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    Execute Command                 sysbus WriteDoubleWord 0x13ffc000 0x12345678
    Execute Command                 sysbus WriteDoubleWord 0x400e0000 0xabcdef01
    Execute Command                 sysbus WriteDoubleWord 0x40100038 0x5afe00c0
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x40100038  0xcc
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x13ffc000
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x400e0000
    Execute Command                 sysbus WriteDoubleWord 0x40100038 0x5afe0080
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x40100038  0x88
    Read Should Equal               0x400e0000  0
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x13ffc000
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    Read Should Equal               0x13ffc000  0

ShouldReleaseSRAMDomainGatesWhenPowerControllerResets
    Create Power Machine
    Execute Command                 sysbus WriteDoubleWord 0x40100038 0x5afe0010
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x40100038  0x11
    Execute Command                 powman Reset
    Read Should Equal               0x40100038  0
    Execute Command                 sysbus WriteDoubleWord 0x20040000 0x12345678
    Read Should Equal               0x20040000  0x12345678
