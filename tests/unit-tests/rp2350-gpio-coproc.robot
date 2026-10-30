*** Variables ***
${GPIOC_PLATFORM}                  SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "@MODEL@"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic0
...  ${SPACE*4}GPIOCoprocessor: sio
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "@MODEL@"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}cpuId: 1
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}GPIOCoprocessor: sio
...  nvic0: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 }
...  ${SPACE*4}-> cpu1@0
...  code: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x10000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x10000
...  accessctrl: Miscellaneous.RP2350_AccessControl @ sysbus 0x40060000
...  sio: Miscellaneous.RP2350_SIO @ sysbus 0xd0000000
...  ${SPACE*4}accessControl: accessctrl

*** Keywords ***
Create GPIOC Machine
    [Arguments]                     ${model}=cortex-m33-rp2350  ${binding}=${True}
    Reset Emulation
    Execute Command                 mach create
    ${platform}=                    Evaluate  $GPIOC_PLATFORM.replace('@MODEL@', $model)
    IF  not $binding
        ${platform}=                Evaluate  $platform.replace('GPIOCoprocessor: sio', '')
    END
    Execute Command                 machine LoadPlatformDescriptionFromString """${platform}"""
    Execute Command                 sysbus WriteDoubleWord 0x0 0x20010000
    Execute Command                 sysbus WriteDoubleWord 0x4 0x1001
    Execute Command                 sysbus WriteDoubleWord 0xc 0x3001
    Execute Command                 sysbus WriteDoubleWord 0x18 0x2001
    Execute Command                 sysbus WriteWord 0x2000 0xe7fe
    Execute Command                 sysbus WriteWord 0x3000 0xe7fe
    FOR  ${cpu}  IN  cpu0  cpu1
        Execute Command             ${cpu} ExecutionMode SingleStep
        Execute Command             ${cpu} VectorTableOffset 0
        Execute Command             ${cpu} SP 0x20010000
        Execute Command             sysbus WriteDoubleWord 0xe000ed24 0x40000 context=${cpu}
        Execute Command             ${cpu} CPACR 3
    END

Issue GPIOC Instruction
    [Arguments]                     ${opcode}  ${cpu}=cpu0  ${clear_cache}=${True}
    ${word}=                        Evaluate  ((int($opcode, 0) & 0xffff) << 16) | (int($opcode, 0) >> 16)
    Execute Command                 sysbus WriteDoubleWord 0x1000 ${word}
    IF  $clear_cache
        Execute Command             ${cpu} ClearTranslationCache
    END
    Execute Command                 ${cpu} PC 0x1000
    Execute Command                 ${cpu} Step

GPIOC Register Should Equal
    [Arguments]                     ${register}  ${expected}  ${cpu}=cpu0
    ${value}=                       Execute Command  ${cpu} GetRegister "${register}"
    Should Be Equal As Integers      ${value.strip()}  ${expected}

GPIOC Memory Should Equal
    [Arguments]                     ${address}  ${expected}  ${cpu}=cpu0
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address} context=${cpu}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Should Fault GPIOC Instruction
    [Arguments]                     ${opcode}  ${status}=0x10000
    Issue GPIOC Instruction          ${opcode}
    GPIOC Register Should Equal     PC  0x2000
    GPIOC Memory Should Equal       0xe000ed28  ${status}
    GPIOC Memory Should Equal       0xd0000010  0
    GPIOC Memory Should Equal       0xd0000014  0

Enter NonSecure GPIOC
    [Arguments]                     ${nsacr}=1
    Execute Command                 cpu0 NSACR ${nsacr}
    Execute Command                 cpu0 SAUControl 2
    Execute Command                 cpu0 SecureState false
    Execute Command                 cpu0 VectorTableOffset 0
    Execute Command                 cpu0 SP 0x20010000
    Execute Command                 cpu0 CPACR_NS 3
    Execute Command                 sysbus WriteDoubleWord 0xe000ed24 0x40000 context=cpu0

*** Test Cases ***
Should Execute Bit Put Used By Unmodified SDK
    Create GPIOC Machine
    Execute Command                 cpu0 SetRegister "r0" 25
    Execute Command                 cpu0 SetRegister "r1" 1
    Issue GPIOC Instruction          0xec410044
    GPIOC Memory Should Equal       0xd0000030  0x02000000
    Issue GPIOC Instruction          0xec410040
    GPIOC Memory Should Equal       0xd0000010  0x02000000

Should Share Paired GPIO State Between Cores
    Create GPIOC Machine
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 cpu0 SetRegister "r1" 0x81001234
    Issue GPIOC Instruction          0xec410000
    Issue GPIOC Instruction          0xec532000  cpu1
    GPIOC Register Should Equal     r2  0x12345678  cpu1
    GPIOC Register Should Equal     r3  0x81001234  cpu1

Should Read Both Input Halves
    Create GPIOC Machine
    Execute Command                 sio OnGPIO 1 true
    Execute Command                 sio OnGPIO 45 true
    Issue GPIOC Instruction          0xec510008
    GPIOC Register Should Equal     r0  2
    GPIOC Register Should Equal     r1  0x2000
    Issue GPIOC Instruction          0xee102018
    GPIOC Register Should Equal     r2  2
    Issue GPIOC Instruction          0xee103019
    GPIOC Register Should Equal     r3  0x2000

Should Update NZCV Through MRC To R15
    Create GPIOC Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 0xa0000000
    Issue GPIOC Instruction          0xee10f010
    ${flags}=                       Execute Command  cpu0 GetRegister "CPSR"
    Should Be Equal As Integers      ${{int($flags.strip(), 0) & 0xf0000000}}  0xa0000000

Should Allow Privileged Only CPACR In Privileged Thread
    Create GPIOC Machine
    Execute Command                 cpu0 CPACR 1
    Issue GPIOC Instruction          0xee100010
    GPIOC Register Should Equal     PC  0x1004

Should Deny Privileged Only CPACR In Unprivileged Thread
    Create GPIOC Machine
    Execute Command                 cpu0 CPACR 1
    Execute Command                 cpu0 Control 1
    Should Fault GPIOC Instruction  0xee100010  0x80000

Should Allow Full CPACR In Unprivileged Thread
    Create GPIOC Machine
    Execute Command                 cpu0 Control 1
    Issue GPIOC Instruction          0xee100010
    GPIOC Register Should Equal     PC  0x1004

Should Reject CPACR Zero
    Create GPIOC Machine
    Execute Command                 cpu0 CPACR 0
    Should Fault GPIOC Instruction  0xee100010  0x80000

Should Reject CPACR ReservedValue
    Create GPIOC Machine
    Execute Command                 cpu0 CPACR 2
    Should Fault GPIOC Instruction  0xee100010  0x80000

Should Reject Missing GPIOC Binding
    Create GPIOC Machine            binding=${False}
    Should Fault GPIOC Instruction  0xee100010  0x80000

Should Reject GPIOC On Generic CortexM33
    Create GPIOC Machine            cortex-m33
    Should Fault GPIOC Instruction  0xee100010  0x80000

Should Reject NonSecure Access Without NSACR
    Create GPIOC Machine
    Enter NonSecure GPIOC           0
    Should Fault GPIOC Instruction  0xee100010  0x80000

Should Filter NonSecure Paired Access
    Create GPIOC Machine
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x80000001
    Execute Command                 sysbus WriteDoubleWord 0x40060010 0x01000001
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 0x7ffffffe
    Execute Command                 sysbus WriteDoubleWord 0xd0000014 0x80000002
    Enter NonSecure GPIOC
    Execute Command                 cpu0 SetRegister "r0" 0xffffffff
    Execute Command                 cpu0 SetRegister "r1" 0xffffffff
    Issue GPIOC Instruction          0xec410000
    Issue GPIOC Instruction          0xec532000
    GPIOC Register Should Equal     r2  0x80000001
    GPIOC Register Should Equal     r3  0x01000001
    Execute Command                 cpu0 SecureState true
    GPIOC Memory Should Equal       0xd0000010  0xffffffff
    GPIOC Memory Should Equal       0xd0000014  0x81000003

Should Observe Revoked CPACR For Cached Instruction
    Create GPIOC Machine
    Execute Command                 cpu0 SetRegister "r0" 1
    Issue GPIOC Instruction          0xee400010
    GPIOC Memory Should Equal       0xd0000010  1
    Execute Command                 cpu0 CPACR 0
    Execute Command                 cpu0 PC 0x1000
    Execute Command                 cpu0 Step
    GPIOC Register Should Equal     PC  0x2000
    GPIOC Memory Should Equal       0xe000ed28  0x80000
    GPIOC Memory Should Equal       0xd0000010  1

Should Observe Revoked NSACR For Cached Instruction
    Create GPIOC Machine
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 1
    Enter NonSecure GPIOC
    Execute Command                 cpu0 SetRegister "r0" 1
    Issue GPIOC Instruction          0xee400010
    GPIOC Memory Should Equal       0xd0000010  1
    Execute Command                 cpu0 NSACR 0
    Execute Command                 cpu0 PC 0x1000
    Execute Command                 cpu0 Step
    GPIOC Register Should Equal     PC  0x2000
    GPIOC Memory Should Equal       0xe000ed28  0x80000
    GPIOC Memory Should Equal       0xd0000010  1

Should Apply Shared Forced NonSecure Sio Policy To CoreOne
    Create GPIOC Machine
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 2
    Execute Command                 sysbus WriteDoubleWord 0x40060004 0xacce0002
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 1
    Execute Command                 cpu1 SetRegister "r0" 0xffffffff
    Execute Command                 cpu1 SetRegister "r1" 0xffffffff
    Issue GPIOC Instruction          0xec410000  cpu1
    Issue GPIOC Instruction          0xec532000  cpu1
    GPIOC Register Should Equal     r2  2  cpu1
    GPIOC Register Should Equal     r3  0  cpu1
    GPIOC Memory Should Equal       0xd0000010  3

Should Reject Reserved Encodings Without GPIO Changes
    [Template]                      Should Reject Reserved Encoding
    0xee010010
    0xee000030
    0xee000012
    0xee000018
    0xee800010
    0xfe000010
    0xec400000
    0xec4f0000
    0xec41000c
    0xec410002
    0xec510010
    0xee00f010

*** Keywords ***
Should Reject Reserved Encoding
    [Arguments]                     ${opcode}
    Create GPIOC Machine
    Should Fault GPIOC Instruction  ${opcode}
