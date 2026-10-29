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
...  ${SPACE*4}Core0IRQ -> nvic0@25
...  ${SPACE*4}Core1IRQ -> nvic1@25
...  ${SPACE*4}Core0NonSecureIRQ -> nvic0@27
...  ${SPACE*4}Core1NonSecureIRQ -> nvic1@27

*** Keywords ***
Create SIO Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true

Read Should Equal
    [Arguments]                     ${address}  ${expected}  ${core}=cpu0
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address} context=${core}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

*** Test Cases ***
ShouldIdentifyBothCoresAndMapAll64GPIOPositions
    Create SIO Machine
    Read Should Equal               0xd0000000  0  cpu0
    Read Should Equal               0xd0000000  1  cpu1
    Execute Command                 sio OnGPIO 42 true
    Execute Command                 sio OnGPIO 59 true
    Read Should Equal               0xd0000008  0x08000400
    Execute Command                 sysbus WriteDoubleWord 0xd0000014 0xffffffff
    Read Should Equal               0xd0000014  0xff00ffff
    Execute Command                 sysbus WriteDoubleWord 0xd0000024 0x80008000
    Read Should Equal               0xd0000014  0x7f007fff
    Execute Command                 sysbus WriteDoubleWord 0xd000002c 0x100
    Read Should Equal               0xd0000014  0x7f007eff
    Execute Command                 sysbus WriteDoubleWord 0xd0000034 0x80000001
    Read Should Equal               0xd0000034  0x80000001

ShouldEnforceFourWordFIFOWithStickyErrorsAndIndependentSecurityBanks
    Create SIO Machine
    FOR  ${i}  IN RANGE  4
        Execute Command             sysbus WriteDoubleWord 0xd0000054 ${i} context=cpu0
    END
    Read Should Equal               0xd0000050  0  cpu0
    Read Should Equal               0xd0000050  3  cpu1
    Execute Command                 sysbus WriteDoubleWord 0xd0000054 0x99 context=cpu0
    Read Should Equal               0xd0000050  4  cpu0
    Read Should Equal               0xd0020050  2  cpu1
    FOR  ${i}  IN RANGE  4
        Read Should Equal           0xd0000058  ${i}  cpu1
    END
    Read Should Equal               0xd0000058  0  cpu1
    Read Should Equal               0xd0000050  10  cpu1
    Execute Command                 sysbus WriteDoubleWord 0xd0000050 8 context=cpu1
    Read Should Equal               0xd0000050  2  cpu1

ShouldApplyGPIOAccessMasksWithoutChangingSecurePinValues
    Create SIO Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 0x55
    Execute Command                 sysbus WriteDoubleWord 0xd0020010 0xff
    Read Should Equal               0xd0000010  0x55
    Read Should Equal               0xd0020010  0
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x0f
    Execute Command                 sysbus WriteDoubleWord 0xd0020010 0xaa
    Read Should Equal               0xd0000010  0x5a
    Read Should Equal               0xd0020010  0x0a

ShouldKeepSpinlockBanksSeparateAndModelDoorbellWriteAliasErratum
    Create SIO Machine
    Read Should Equal               0xd0000100  1
    Read Should Equal               0xd0000100  0  cpu1
    Read Should Equal               0xd0020100  1  cpu1
    Execute Command                 sysbus WriteDoubleWord 0xd0000180 0x80 context=cpu0
    Read Should Equal               0xd0000188  0x80  cpu1
    Read Should Equal               0xd0020188  0  cpu1
    Read Should Equal               0xd0000100  1
    Execute Command                 sysbus WriteDoubleWord 0xd000018c 0x80 context=cpu1
    Read Should Equal               0xd0000188  0  cpu1

ShouldRequireAccessControlPasswordAndRespectMasterLock
    Create SIO Machine
    Read Should Equal               0x40060000  4
    Read Should Equal               0x40060014  0xff
    Read Should Equal               0x400600e4  0xb8
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus WriteDoubleWord 0x40060008 1
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x1234 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0x40060000 0xacce0001 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0xffff context=cpu0
    Read Should Equal               0x4006000c  0x1234
