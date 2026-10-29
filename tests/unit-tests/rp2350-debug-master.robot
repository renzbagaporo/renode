*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}cpuId: 1
...  ${SPACE*4}nvic: nvic1
...  nvic0: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 }
...  ${SPACE*4}-> cpu1@0
...  accessctrl: Miscellaneous.RP2350_AccessControl @ sysbus 0x40060000
...  sio: Miscellaneous.RP2350_SIO @ { sysbus 0xd0000000; sysbus new Bus.BusMultiRegistration { address: 0xd0020000; size: 0x1000; region: "NonSecure" } }
...  ${SPACE*4}accessControl: accessctrl
...  debug: CPU.RP2350TestDebugPort @ sysbus 0x60000000
...  ${SPACE*4}cpu0: cpu0
...  ${SPACE*4}cpu1: cpu1
...  gpio: GPIOPort.RP2_GPIOBank0 @ sysbus 0x40028000
...  ${SPACE*4}rp2350: true
...  ${SPACE*4}accessControl: accessctrl
...  probe: Antmicro.Renode.PeripheralsTests.RP2350AccessNotificationProbe @ sysbus 0x70000000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}access: accessctrl

*** Keywords ***
Create Debug Machine
    Execute Command                 include @${CURDIR}/RP2350TestDebugPort.cs
    Execute Command                 include @${CURDIR}/RP2350AccessNotificationProbe.cs
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    Execute Command                 debug EnableDebugPower

Read Should Equal
    [Arguments]                     ${address}  ${expected}  ${core}=cpu0
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address} context=${core}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

AP1 Read Should Equal
    [Arguments]                     ${address}  ${expected}  ${secure}=true
    ${value}=                       Execute Command  debug ReadCoreMemory 1 ${address} ${secure}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

*** Test Cases ***
ShouldApplyForceCoreNSOnlyToProcessorMasterWhilePreservingAPSecurity
    Create Debug Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 0x55 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0x40060004 0xacce0002 context=cpu0
    Read Should Equal               0xd0000010  0  cpu1
    AP1 Read Should Equal           0xd0000010  0x55  true
    AP1 Read Should Equal           0xd0000010  0  false

ShouldUseDebugLockRatherThanCore1LockForRealAP1Transfers
    Create Debug Machine
    Execute Command                 sysbus WriteDoubleWord 0x40060000 0xacce0002 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0x40060004 0xacce0002 context=cpu0
    Execute Command                 debug WriteCoreMemory 1 0x4006000c 0x1234
    Read Should Equal               0x4006000c  0x1234
    Execute Command                 sysbus WriteDoubleWord 0x40060000 0xacce0008 context=cpu0
    Execute Command                 debug WriteCoreMemory 1 0x4006000c 0xffff
    Read Should Equal               0x4006000c  0x1234
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x5678 context=cpu0
    AP1 Read Should Equal           0x4006000c  0x5678  true

ShouldPublishPermissionEffectsAfterReleasingAccessControlLock
    Create Debug Machine
    Execute Command                 sysbus WriteDoubleWord 0x40060090 0xacce00ff
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 1
    Execute Command                 gpio ResetPadConfiguration 0 0x56
    Execute Command                 sysbus WriteDoubleWord 0x40028004 1
    Execute Command                 gpio SetPeripheralOutput 1 0 true true
    Execute Command                 probe Arm
    Execute Command                 sysbus WriteDoubleWord 0x40060090 0xacce00fc
    Read Should Equal               0x70000000  1
