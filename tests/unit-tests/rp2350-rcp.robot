*** Variables ***
${RCP_PLATFORM}                     SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "@MODEL@"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "@MODEL@"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}cpuId: 1
...  nvic0: IRQControllers.NVIC @ { sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 } }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ { sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 } }
...  ${SPACE*4}-> cpu1@0
...  mem: Memory.MappedMemory @ sysbus 0x0
...  ${SPACE*4}size: 0x10000

*** Keywords ***
Create RCP Machine
    [Arguments]                     ${model}=cortex-m33-rp2350
    Execute Command                 mach create
    ${platform}=                    Evaluate  $RCP_PLATFORM.replace('@MODEL@', $model)
    Execute Command                 machine LoadPlatformDescriptionFromString """${platform}"""
    Execute Command                 sysbus WriteDoubleWord 0x0 0x8000
    Execute Command                 sysbus WriteDoubleWord 0x4 0x1001
    Execute Command                 sysbus WriteDoubleWord 0x8 0x4001
    Execute Command                 sysbus WriteDoubleWord 0xc 0x3001
    Execute Command                 sysbus WriteDoubleWord 0x18 0x2001
    Execute Command                 sysbus WriteWord 0x2000 0xe7fe
    Execute Command                 sysbus WriteWord 0x3000 0xe7fe
    Execute Command                 sysbus WriteWord 0x4000 0xe7fe
    FOR  ${cpu}  IN  cpu0  cpu1
        Execute Command             sysbus WriteDoubleWord 0xe000ed24 0x40000 context=${cpu}
        Execute Command             sysbus WriteDoubleWord 0xe000ed88 0xc000 context=${cpu}
        Execute Command             ${cpu} ExecutionMode SingleStep
        Execute Command             ${cpu} VectorTableOffset 0
        Execute Command             ${cpu} SP 0x8000
    END

Issue RCP Instruction
    [Arguments]                     ${opcode}  ${cpu}=cpu0
    ${word}=                        Evaluate  ((int($opcode, 0) & 0xffff) << 16) | (int($opcode, 0) >> 16)
    Execute Command                 sysbus WriteDoubleWord 0x1000 ${word}
    Execute Command                 ${cpu} ClearTranslationCache
    Execute Command                 ${cpu} PC 0x1000
    Execute Command                 ${cpu} Step

RCP Register Should Equal
    [Arguments]                     ${register}  ${expected}  ${cpu}=cpu0
    ${actual}=                      Execute Command  ${cpu} GetRegister "${register}"
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

RCP Memory Should Equal
    [Arguments]                     ${address}  ${expected}  ${cpu}=cpu0
    ${actual}=                      Execute Command  sysbus ReadDoubleWord ${address} context=${cpu}
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

Seed RCP
    [Arguments]                     ${target}=0
    Execute Command                 cpu0 SetRegister "r0" 0x89abcdef
    Execute Command                 cpu0 SetRegister "r1" 0x01234567
    ${opcode}=                      Evaluate  hex(0xfc410780 | int($target))
    Issue RCP Instruction           ${opcode}

RCP Should Enter NMI
    RCP Register Should Equal       PC  0x4000
    RCP Memory Should Equal         0xe000ed28  0

RCP Should Have Usage Fault
    [Arguments]                     ${status}  ${cpu}=cpu0
    RCP Register Should Equal       PC  0x2000  ${cpu}
    RCP Memory Should Equal         0xe000ed28  ${status}  ${cpu}

Enter Non Secure RCP
    Execute Command                 cpu0 SAUControl 2
    Execute Command                 cpu0 SecureState false
    Execute Command                 cpu0 VectorTableOffset 0
    Execute Command                 cpu0 SP 0x8000
    Execute Command                 sysbus WriteDoubleWord 0xe000ed24 0x40000 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0xc000 context=cpu0

*** Test Cases ***
Should Report Salt Invalid And Valid Using Official Encodings
    Create RCP Machine
    Issue RCP Instruction           0xfe300710
    RCP Register Should Equal       R0  0x00c300c3
    Seed RCP
    Issue RCP Instruction           0xfe300710
    RCP Register Should Equal       R0  0xa500a500

Should Generate Exact Salt And Tag Dependent Canary
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe132734
    RCP Register Should Equal       R2  0x9f8eef00
    Issue RCP Instruction           0xfe032734
    RCP Register Should Equal       PC  0x1004

Should Fault On Mismatched Canary And Link Peer NMI
    Create RCP Machine
    Seed RCP
    Execute Command                 cpu0 SetRegister "r2" 0
    Issue RCP Instruction           0xfe032734
    RCP Should Enter NMI
    Execute Command                 cpu1 Step
    RCP Register Should Equal       PC  0x4000  cpu1

Should Fault On Canary With Different Tag
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe132734
    Issue RCP Instruction           0xfe032735
    RCP Should Enter NMI

Should Check Sequence And Wrap At Eight Bits
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe8f071f
    Issue RCP Instruction           0xfeaf073f
    Issue RCP Instruction           0xfea00730
    RCP Register Should Equal       PC  0x1004

Should Fault On Missing Sequence Step
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe830714
    Issue RCP Instruction           0xfea30736
    RCP Should Enter NMI

Should Check Equal Integers
    Create RCP Machine
    Seed RCP
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 cpu0 SetRegister "r1" 0x12345678
    Issue RCP Instruction           0xfc410770
    RCP Register Should Equal       PC  0x1004

Should Fault On Unequal Integers
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfc410770
    RCP Should Enter NMI

Should Reject Poison Boolean
    Create RCP Machine
    Seed RCP
    Execute Command                 cpu0 SetRegister "r0" 1
    Issue RCP Instruction           0xfe200710
    RCP Should Enter NMI

Should Validate Boolean And Redundant Integer Operations
    Create RCP Machine
    Seed RCP
    Execute Command                 cpu0 SetRegister "r0" 0xa500a500
    Issue RCP Instruction           0xfe200710
    Issue RCP Instruction           0xfe400710
    Execute Command                 cpu0 SetRegister "r1" 0x00c300c3
    Issue RCP Instruction           0xfc410708
    Issue RCP Instruction           0xfc410720
    Execute Command                 cpu0 SetRegister "r0" 0x12345678
    Execute Command                 cpu0 SetRegister "r1" 0x8434c078
    Issue RCP Instruction           0xfc410768
    RCP Register Should Equal       PC  0x1004

Should Reject Unseeded Assertions
    Create RCP Machine
    Execute Command                 cpu0 SetRegister "r1" 0
    Issue RCP Instruction           0xfc410770
    RCP Should Enter NMI

Should Reject Salt Rewrite
    Create RCP Machine
    Seed RCP
    Seed RCP
    RCP Should Enter NMI

Should Keep Core Salts And Counters Independent
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe300710  cpu1
    RCP Register Should Equal       R0  0x00c300c3  cpu1
    Seed RCP                        1
    Issue RCP Instruction           0xfe300710  cpu1
    RCP Register Should Equal       R0  0xa500a500  cpu1
    Issue RCP Instruction           0xfe830714
    Issue RCP Instruction           0xfea30734
    Issue RCP Instruction           0xfea00730  cpu1
    RCP Register Should Equal       PC  0x1004  cpu1

Should Reject Salt Writes Through Core One
    Create RCP Machine
    Issue RCP Instruction           0xfc410780  cpu1
    RCP Register Should Equal       PC  0x4000  cpu1

Should Preserve Generic CortexM33 Unsupported Behavior
    Create RCP Machine              cortex-m33
    Issue RCP Instruction           0xfe300710
    RCP Should Have Usage Fault     0x80000

Should Reject Disabled CPACR
    Create RCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0 context=cpu0
    Issue RCP Instruction           0xfe300710
    RCP Should Have Usage Fault     0x80000

Should Reject Reserved CPACR
    Create RCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x8000 context=cpu0
    Issue RCP Instruction           0xfe300710
    RCP Should Have Usage Fault     0x80000

Should Reject Privileged Permission From Unprivileged Thread
    Create RCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x4000 context=cpu0
    Execute Command                 cpu0 Control 1
    Issue RCP Instruction           0xfe300710
    RCP Should Have Usage Fault     0x80000

Should Allow Full Permission From Unprivileged Thread
    Create RCP Machine
    Execute Command                 cpu0 Control 1
    Issue RCP Instruction           0xfe300710
    RCP Register Should Equal       PC  0x1004

Should Fault On Invalid Parity
    Create RCP Machine
    Issue RCP Instruction           0xfe300730
    RCP Should Enter NMI

Should Fault On Invalid Pair Read
    Create RCP Machine
    Issue RCP Instruction           0xfc510780
    RCP Should Enter NMI

Should Fault On Invalid Tag For Status
    Create RCP Machine
    Issue RCP Instruction           0xfe310710
    RCP Should Enter NMI

Should Mask Non Secure Reads And Ignore Invalid Data
    Create RCP Machine
    Seed RCP
    Execute Command                 cpu0 NSACR 0x80
    Enter Non Secure RCP
    Issue RCP Instruction           0xfe300710
    RCP Register Should Equal       R0  0
    Issue RCP Instruction           0xfe032734
    RCP Register Should Equal       PC  0x1004
    Issue RCP Instruction           0xfc410780
    RCP Register Should Equal       PC  0x1004

Should Reject Non Secure Access Without NSACR Permission
    Create RCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed8c 0 context=cpu0
    Enter Non Secure RCP
    Issue RCP Instruction           0xfe300710
    RCP Should Have Usage Fault     0x80000

Should Fault Invalid Non Secure Instruction Without RCP NMI
    Create RCP Machine
    Execute Command                 cpu0 NSACR 0x80
    Enter Non Secure RCP
    Issue RCP Instruction           0xfe300730
    RCP Should Have Usage Fault     0x10000
    Execute Command                 sysbus WriteWord 0x5000 0xbf00
    Execute Command                 cpu1 PC 0x5000
    Execute Command                 cpu1 Step
    RCP Register Should Equal       PC  0x5002  cpu1

Should Clear Local Salt And Fault On Reset
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfc410770
    RCP Should Enter NMI
    Execute Command                 cpu0 Reset
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0xc000 context=cpu0
    Issue RCP Instruction           0xfe300710
    RCP Register Should Equal       R0  0x00c300c3
    RCP Register Should Equal       PC  0x1004

Should Stall Panic Without Retiring Following Instruction
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe000720
    RCP Register Should Equal       PC  0x1000
    Execute Command                 cpu0 Step
    RCP Register Should Equal       PC  0x1000

Should Generate Documented Nonlinear PRNG Sequence
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe500710
    RCP Register Should Equal       R0  0x7b
    Issue RCP Instruction           0xfe500710
    RCP Register Should Equal       R0  0xfe
    Issue RCP Instruction           0xfe500710
    RCP Register Should Equal       R0  0x44
    Issue RCP Instruction           0xfe500710
    RCP Register Should Equal       R0  0x0b

Should Set APSR Flags From Canary Status
    Create RCP Machine
    Issue RCP Instruction           0xfe30f710
    ${status}=                      Execute Command  cpu0 XProgramStatusRegister
    ${flags}=                       Evaluate  int($status.strip(), 0) & 0xf0000000
    Should Be Equal As Integers      ${flags}  0
    Seed RCP
    Issue RCP Instruction           0xfe30f710
    ${status}=                      Execute Command  cpu0 XProgramStatusRegister
    ${flags}=                       Evaluate  int($status.strip(), 0) & 0xf0000000
    Should Be Equal As Integers      ${flags}  0xa0000000

Should Keep Non Secure Counter Writes From Changing Secure State
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfe830714
    Execute Command                 cpu0 NSACR 0x80
    Enter Non Secure RCP
    Issue RCP Instruction           0xfe800710
    Execute Command                 cpu0 SecureState true
    Execute Command                 cpu0 SAUControl 0
    Issue RCP Instruction           0xfea30734
    RCP Register Should Equal       PC  0x1004

Should Validate Boolean Pair And Xor Variants
    Create RCP Machine
    Seed RCP
    Execute Command                 cpu0 SetRegister "r0" 0xa500a500
    Execute Command                 cpu0 SetRegister "r1" 0xa500a500
    Issue RCP Instruction           0xfc410710
    Execute Command                 cpu0 SetRegister "r0" 0
    Issue RCP Instruction           0xfc410738
    Issue RCP Instruction           0xfc410740
    Execute Command                 cpu0 SetRegister "r1" 0x00c300c3
    Issue RCP Instruction           0xfc410758
    Execute Command                 cpu0 SetRegister "r0" 0x00c300c3
    Issue RCP Instruction           0xfe600730
    RCP Register Should Equal       PC  0x1004

Should Fault On Invalid Redundant Integer
    Create RCP Machine
    Seed RCP
    Execute Command                 cpu0 SetRegister "r0" 0
    Execute Command                 cpu0 SetRegister "r1" 0
    Issue RCP Instruction           0xfc410768
    RCP Should Enter NMI

Should Observe Revocation In Already Translated Instruction
    Create RCP Machine
    Issue RCP Instruction           0xfe300710
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0 context=cpu0
    Execute Command                 cpu0 PC 0x1000
    Execute Command                 cpu0 Step
    RCP Should Have Usage Fault     0x80000

Should Reject Reserved RCP Operation
    Create RCP Machine
    Issue RCP Instruction           0xfec00730
    RCP Should Enter NMI

Should Stall Further RCP Instructions After Fault
    Create RCP Machine
    Seed RCP
    Issue RCP Instruction           0xfc410770
    RCP Should Enter NMI
    Execute Command                 sysbus WriteDoubleWord 0x4000 0x0720fe00
    Execute Command                 cpu0 ClearTranslationCache
    Execute Command                 cpu0 Step
    RCP Register Should Equal       PC  0x4000
    Execute Command                 sysbus WriteWord 0x4000 0xbf00
    Execute Command                 cpu0 ClearTranslationCache
    Execute Command                 cpu0 Step
    RCP Register Should Equal       PC  0x4000
