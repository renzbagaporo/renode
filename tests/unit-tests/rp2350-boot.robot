*** Variables ***
${BOOT_PLATFORM}                    SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}cpuId: 1
...  ${SPACE*4}isCpuWaitSignalSet: true
...  nvic0: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 }
...  ${SPACE*4}-> cpu0@0
...  ${SPACE*4}SystemResetRequest -> powman@0
...  nvic1: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 }
...  ${SPACE*4}-> cpu1@0
...  ${SPACE*4}SystemResetRequest -> powman@1
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x8000
...  sram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x10000
...  bootram: Memory.RP2350_BootRAM @ sysbus 0x400e0000
...  debug_port: CPU.RP2350TestDebugPort @ sysbus 0x60000000
...  ${SPACE*4}cpu0: cpu0
...  ${SPACE*4}cpu1: cpu1
...  powman: Miscellaneous.RP2350_POWMAN @ sysbus 0x40100000
...  ${SPACE*4}core0: cpu0
...  ${SPACE*4}core1: cpu1
...  ${SPACE*4}nvic0: nvic0
...  ${SPACE*4}nvic1: nvic1
...  ${SPACE*4}debugPort: debug_port
...  otp: Miscellaneous.RP2350_OTP @ sysbus 0x40120000
...  otpData: Memory.RP2350_OTPData @ sysbus 0x40130000
...  ${SPACE*4}otp: otp
...  otpRaw: Memory.RP2350_OTPData @ sysbus 0x40134000
...  ${SPACE*4}otp: otp
...  ${SPACE*4}raw: true
...  otpGuarded: Memory.RP2350_OTPData @ sysbus 0x4013c000
...  ${SPACE*4}otp: otp
...  ${SPACE*4}raw: true
...  ${SPACE*4}guarded: true

*** Keywords ***
Create Boot Machine
    Execute Command                 include @${CURDIR}/RP2350TestDebugPort.cs
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${BOOT_PLATFORM}"""
    Execute Command                 sysbus WriteDoubleWord 0 0x20008000
    Execute Command                 sysbus WriteDoubleWord 4 0x101
    Execute Command                 sysbus WriteWord 0x100 0xe7fe
    Execute Command                 debug_port EnableDebugPower
    Execute Command                 cpu1 IsHalted true

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Debug Power Should Be Retained
    ${value}=                       Execute Command  debug_port ReadPowerControl
    Should Be Equal As Integers      ${value.strip()}  0xf0000040

*** Test Cases ***
Should Retain Sibling Core SRAM And Debug Power AcrossCore0WarmReset
    Create Boot Machine
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 cpu0 SetRegister "R0" 0x1234
    Execute Command                 cpu1 SetRegister "R0" 0x5678
    Execute Command                 sysbus WriteDoubleWord 0x20001000 0x87654321
    Execute Command                 sysbus WriteDoubleWord 0x401000b0 0xa5a55a5a
    Execute Command                 sysbus WriteDoubleWord 0xe000ed0c 0x05fa0004 context=cpu0
    Execute Command                 emulation RunFor "0.00001"
    ${r0}=                          Execute Command  cpu0 GetRegister "R0"
    Should Be Equal As Integers      ${r0.strip()}  0
    ${r1}=                          Execute Command  cpu1 GetRegister "R0"
    Should Be Equal As Integers      ${r1.strip()}  0x5678
    Read Should Equal               0x20001000  0x87654321
    Read Should Equal               0x401000b0  0xa5a55a5a
    Debug Power Should Be Retained

Should PreserveAONScratchAndRPAPAcrossRescueAndRequirePasswordToClearFlag
    Create Boot Machine
    Execute Command                 sysbus WriteDoubleWord 0x401000b0 0xcafef00d
    Execute Command                 debug_port Rescue true
    Execute Command                 debug_port Rescue false
    Execute Command                 emulation RunFor "0.00001"
    Read Should Equal               0x4010002c  0x00200010
    Read Should Equal               0x401000b0  0xcafef00d
    Debug Power Should Be Retained
    Execute Command                 sysbus WriteDoubleWord 0x4010002c 0x10
    Read Should Equal               0x4010002c  0x00200010
    Read Should Equal               0x40100000  1
    Execute Command                 sysbus WriteDoubleWord 0x4010002c 0x5afe0010
    Read Should Equal               0x4010002c  0x00200000

Should ImplementAPBAtomicBootRAMAndExecuteItsContents
    Create Boot Machine
    Execute Command                 sysbus WriteDoubleWord 4 0x400e0101
    Execute Command                 sysbus WriteDoubleWord 0x400e0000 0x10
    Execute Command                 sysbus WriteDoubleWord 0x400e2000 0x21
    Read Should Equal               0x400e0000  0x31
    Execute Command                 sysbus WriteDoubleWord 0x400e3000 0x10
    Read Should Equal               0x400e0000  0x21
    Execute Command                 sysbus WriteDoubleWord 0x400e1000 0x01
    Read Should Equal               0x400e0000  0x20
    Execute Command                 sysbus WriteDoubleWord 0x400e0100 0xe7fe202a
    Execute Command                 cpu0 VectorTableOffset 0
    Execute Command                 sysbus WriteDoubleWord 0xe000ed98 0 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000ed9c 0x400e0000 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000eda0 0x400e03e1 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000edc0 0xff context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000ed94 5 context=cpu0
    Execute Command                 cpu0 PC 0x400e0100
    Execute Command                 emulation RunFor "0.001"
    ${halt}=                        Execute Command  cpu0 IsHalted
    ${dhcsr}=                       Execute Command  sysbus ReadDoubleWord 0xe000edf0 context=cpu0
    ${mem}=                         Execute Command  sysbus ReadDoubleWord 0x400e0100
    Log To Console                  BootRAM halted=${halt} DHCSR=${dhcsr} code=${mem}
    ${pc}=                          Execute Command  cpu0 PC
    ${fault}=                       Execute Command  sysbus ReadDoubleWord 0xe000ed28 context=cpu0
    ${sfsr}=                        Execute Command  sysbus ReadDoubleWord 0xe000ede4 context=cpu0
    Log To Console                  BootRAM PC=${pc} CFSR=${fault} SFSR=${sfsr}
    ${r0}=                          Execute Command  cpu0 GetRegister "R0"
    Should Be Equal As Integers      ${r0.strip()}  42

Should LockOTPReadsIrreversiblyAndFaultGuardedAccess
    Create Boot Machine
    Read Should Equal               0x40130000  0
    Read Should Equal               0x4013c000  0
    Execute Command                 sysbus WriteDoubleWord 0x40120000 2
    Read Should Equal               0x40130000  0xffffffff
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x4013c000
    Execute Command                 sysbus WriteDoubleWord 0x40123000 2
    Read Should Equal               0x40120000  2
