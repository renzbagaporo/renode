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
    Execute Command                 sysbus WriteDoubleWord 0x100 0xe7fe242a
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
    Execute Command                 emulation RunFor "0.00001"
    ${r0}=                          Execute Command  cpu0 GetRegister "R0"
    Should Be Equal As Integers      ${r0.strip()}  0
    ${r1}=                          Execute Command  cpu1 GetRegister "R0"
    Should Be Equal As Integers      ${r1.strip()}  0x5678
    Read Should Equal               0x20001000  0x87654321
    Read Should Equal               0x401000b0  0xa5a55a5a
    Debug Power Should Be Retained
    ${r4}=                          Execute Command  cpu0 GetRegister "R4"
    Should Be Equal As Integers      ${r4.strip()}  42

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

Should ImplementDataOnlyAPBAtomicBootRAM
    Create Boot Machine
    Execute Command                 sysbus WriteDoubleWord 0x400e0000 0x10
    Execute Command                 sysbus WriteDoubleWord 0x400e2000 0x21
    Read Should Equal               0x400e0000  0x31
    Execute Command                 sysbus WriteDoubleWord 0x400e3000 0x10
    Read Should Equal               0x400e0000  0x21
    Execute Command                 sysbus WriteDoubleWord 0x400e1000 0x01
    Read Should Equal               0x400e0000  0x20
    Execute Command                 sysbus WriteByte 0x400e0000 0xa5
    Read Should Equal               0x400e0000  0xa5
    Execute Command                 sysbus WriteWord 0x400e0002 0xbeef
    Read Should Equal               0x400e0000  0xbeef00a5
    Execute Command                 sysbus WriteByte 0x400e2001 0x12
    Read Should Equal               0x400e0000  0xbeef12a5
    Execute Command                 bootram Reset
    Read Should Equal               0x400e0000  0xbeef12a5
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x400e0400

ShouldKeepWriteOnceBitsAndClaimBootLocksAtomically
    Create Boot Machine
    Execute Command                 sysbus WriteDoubleWord 0x400e0800 0x11
    Execute Command                 sysbus WriteDoubleWord 0x400e0800 0x20
    Execute Command                 sysbus WriteDoubleWord 0x400e3800 0x10
    Read Should Equal               0x400e0800  0x31
    Read Should Equal               0x400e0808  0xff
    Read Should Equal               0x400e0818  8
    Read Should Equal               0x400e0818  0
    Read Should Equal               0x400e0808  0xf7
    Execute Command                 sysbus WriteDoubleWord 0x400e0818 0
    Read Should Equal               0x400e0808  0xff
    Execute Command                 bootram Reset
    Read Should Equal               0x400e0800  0
    Read Should Equal               0x400e0808  0xff

ShouldRejectNonSecureBootRAMDataThroughMEMAP
    Create Boot Machine
    Execute Command                 sysbus WriteDoubleWord 0x400e0000 0x12345678
    ${value}=                       Execute Command  debug_port ReadCoreMemory 0 0x400e0000 true
    Should Be Equal As Integers      ${value.strip()}  0x12345678
    Run Keyword And Expect Error    *AP read refused*  Execute Command  debug_port ReadCoreMemory 0 0x400e0000 false
    ${status}=                      Execute Command  debug_port ReadPowerControl
    Should Be Equal As Integers      ${{int($status.strip(), 0) & 0x20}}  0x20
    Run Keyword And Expect Error    *AP write refused*  Execute Command  debug_port ReadCoreMemory 0 0x400e0000 true
    Execute Command                 debug_port ClearStickyErrors
    ${status}=                      Execute Command  debug_port ReadPowerControl
    Should Be Equal As Integers      ${{int($status.strip(), 0) & 0x20}}  0
    ${value}=                       Execute Command  debug_port ReadCoreMemory 0 0x400e0000 true
    Should Be Equal As Integers      ${value.strip()}  0x12345678

Should LockOTPReadsIrreversiblyAndFaultGuardedAccess
    Create Boot Machine
    Read Should Equal               0x40130000  0
    Read Should Equal               0x4013c000  0
    Execute Command                 sysbus WriteDoubleWord 0x40120000 2
    Read Should Equal               0x40130000  0xffffffff
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x4013c000
    Execute Command                 sysbus WriteDoubleWord 0x40123000 2
    Read Should Equal               0x40120000  2

ShouldFenceQueuedWarmResetWhenRescueHoldsProcessors
    Create Boot Machine
    # Exercise queued reset/release across multiple synchronization boundaries.
    Execute Command                 emulation SetGlobalQuantum "0.000001"
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 sysbus WriteDoubleWord 0xe000ed0c 0x05fa0004 context=cpu0
    Execute Command                 debug_port Rescue true
    Execute Command                 emulation RunFor "0.00001"
    ${held}=                        Execute Command  cpu0 IsHalted
    Should Be Equal                 ${held.strip()}  True
    Debug Power Should Be Retained
    Execute Command                 debug_port Rescue false
    Execute Command                 emulation RunFor "0.00001"
    Execute Command                 emulation RunFor "0.00001"
    ${r4}=                          Execute Command  cpu0 GetRegister "R4"
    Should Be Equal As Integers      ${r4.strip()}  42
