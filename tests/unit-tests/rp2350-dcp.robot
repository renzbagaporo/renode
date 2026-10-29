*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "@MODEL@"
...  ${SPACE*4}enableTrustZone: @TRUSTZONE@
...  ${SPACE*4}nvic: nvic
...  nvic: IRQControllers.NVIC @ sysbus 0xe000e000
...  ${SPACE*4}-> cpu@0
...  mem: Memory.MappedMemory @ sysbus 0x0
...  ${SPACE*4}size: 0x10000
...  sram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x10000

*** Keywords ***
Create DCP Machine
    [Arguments]                     ${model}=cortex-m33-rp2350  ${trustzone}=false
    Execute Command                 mach create
    ${platform}=                    Evaluate  $PLATFORM.replace('@MODEL@', $model).replace('@TRUSTZONE@', str($trustzone).lower())
    Execute Command                 machine LoadPlatformDescriptionFromString """${platform}"""
    Execute Command                 sysbus WriteDoubleWord 0x0 0x20010000
    Execute Command                 sysbus WriteDoubleWord 0x4 0x1001
    Execute Command                 sysbus WriteDoubleWord 0xc 0x3001
    Execute Command                 sysbus WriteDoubleWord 0x18 0x2001
    Execute Command                 sysbus WriteWord 0x2000 0xe7fe
    Execute Command                 sysbus WriteWord 0x3000 0xe7fe
    Execute Command                 sysbus WriteDoubleWord 0xe000ed24 0x40000 context=cpu
    Execute Command                 cpu VectorTableOffset 0
    Execute Command                 cpu SP 0x20010000

Issue Instruction
    [Arguments]                     ${opcode}
    ${word}=                        Evaluate  ((int($opcode, 0) & 0xffff) << 16) | (int($opcode, 0) >> 16)
    Execute Command                 sysbus WriteDoubleWord 0x1000 ${word}
    Execute Command                 cpu ClearTranslationCache
    Execute Command                 cpu PC 0x1000
    Execute Command                 cpu Step

Read Register Should Equal
    [Arguments]                     ${register}  ${expected}
    ${actual}=                      Execute Command  cpu GetRegister "${register}"
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

Read Memory Should Equal
    [Arguments]                     ${address}  ${expected}
    ${actual}=                      Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

Should Have Usage Fault
    [Arguments]                     ${status}
    Read Register Should Equal      PC  0x2000
    Read Memory Should Equal        0xe000ed28  ${status}

*** Test Cases ***
Should Report RP2350 CortexM33 Revision
    Create DCP Machine
    Read Memory Should Equal        0xe000ed00  0x411fd210

Should Execute Startup RCMP Without Enabling FPU
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Execute Command                 cpu SetRegister "r0" 0xdeadbeef
    Issue Instruction               0xee100430
    Read Register Should Equal      PC  0x1004
    Read Register Should Equal      R0  0

Should Keep Generic CortexM33 Coprocessor Behavior
    Create DCP Machine              cortex-m33
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Issue Instruction               0xee100430
    Should Have Usage Fault         0x80000

Should Reject DCP When CPACR Disables It
    Create DCP Machine
    Issue Instruction               0xee100430
    Should Have Usage Fault         0x80000

Should Observe Permission Changes In Already Translated Instruction
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Issue Instruction               0xee100430
    Read Register Should Equal      PC  0x1004
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0 context=cpu
    Execute Command                 cpu PC 0x1000
    Execute Command                 cpu Step
    Should Have Usage Fault         0x80000

Should Preserve Engaged During Peek And Clear It On RCMP
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Execute Command                 cpu SetRegister "r0" 0x01234567
    Execute Command                 cpu SetRegister "r1" 0x89abcdef
    Issue Instruction               0xec410400
    Issue Instruction               0xfe102430
    Read Register Should Equal      R2  0x80000000
    Issue Instruction               0xfe102430
    Read Register Should Equal      R2  0x80000000
    Issue Instruction               0xee103430
    Read Register Should Equal      R3  0x80000000
    Issue Instruction               0xfe104430
    Read Register Should Equal      R4  0
    Issue Instruction               0xec576408
    Read Register Should Equal      R6  0x01234567
    Read Register Should Equal      R7  0x89abcdef

Should Set Processor Flags From Processed Status
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Issue Instruction               0xec410400
    Issue Instruction               0xfe10f430
    ${status}=                      Execute Command  cpu XProgramStatusRegister
    ${flags}=                       Evaluate  int($status.strip(), 0) & 0xf0000000
    Should Be Equal As Integers      ${flags}  0x80000000
    Issue Instruction               0xee10f430
    Issue Instruction               0xfe10f430
    ${status}=                      Execute Command  cpu XProgramStatusRegister
    ${flags}=                       Evaluate  int($status.strip(), 0) & 0xf0000000
    Should Be Equal As Integers      ${flags}  0

Should Peek Y Without Ending An Operation
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Execute Command                 cpu SetRegister "r2" 0x76543210
    Execute Command                 cpu SetRegister "r3" 0xfedcba98
    Issue Instruction               0xec432401
    Issue Instruction               0xfc554409
    Read Register Should Equal      R4  0x76543210
    Read Register Should Equal      R5  0xfedcba98
    Issue Instruction               0xfe106430
    Read Register Should Equal      R6  0x80000000
    Issue Instruction               0xec576409
    Issue Instruction               0xfe108430
    Read Register Should Equal      R8  0

Should Initialize DCP State With INIT
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Execute Command                 cpu SetRegister "r0" 0x12345678
    Execute Command                 cpu SetRegister "r1" 0x87654321
    Issue Instruction               0xec410400
    Issue Instruction               0xee000400
    Issue Instruction               0xec554408
    Read Register Should Equal      R4  0
    Read Register Should Equal      R5  0
    Issue Instruction               0xfe106430
    Read Register Should Equal      R6  0

Should Fault On Unsupported Arithmetic
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Issue Instruction               0xee000401
    Should Have Usage Fault         0x10000

Should Reject CP5 From Non Secure Code
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0xc00 context=cpu
    Issue Instruction               0xee100530
    Should Have Usage Fault         0x80000

Should Keep Secure And Non Secure DCP Instances Separate
    Create DCP Machine              trustzone=true
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0xf00 context=cpu
    Execute Command                 cpu SetRegister "r0" 1
    Execute Command                 cpu SetRegister "r1" 2
    Issue Instruction               0xec410400
    Execute Command                 cpu SetRegister "r0" 3
    Execute Command                 cpu SetRegister "r1" 4
    Issue Instruction               0xec410500
    Issue Instruction               0xec554408
    Read Register Should Equal      R4  1
    Read Register Should Equal      R5  2
    Issue Instruction               0xec576508
    Read Register Should Equal      R6  3
    Read Register Should Equal      R7  4

Should Reject Reserved CPACR Permission
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x200 context=cpu
    Issue Instruction               0xee100430
    Should Have Usage Fault         0x80000

Should Allow Privileged Only Permission In Privileged Code
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x100 context=cpu
    Issue Instruction               0xee100430
    Read Register Should Equal      PC  0x1004

Should Reject Privileged Only Permission In Unprivileged Code
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x100 context=cpu
    Execute Command                 cpu Control 1
    Issue Instruction               0xee100430
    Should Have Usage Fault         0x80000

Should Allow Full Permission In Unprivileged Code
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Execute Command                 cpu Control 1
    Issue Instruction               0xee100430
    Read Register Should Equal      PC  0x1004

Should Reset DCP State And Preserve Its Implementation
    Create DCP Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Execute Command                 cpu SetRegister "r0" 0x12345678
    Execute Command                 cpu SetRegister "r1" 0x87654321
    Issue Instruction               0xec410400
    Execute Command                 machine Reset
    Execute Command                 cpu SP 0x20010000
    Execute Command                 sysbus WriteDoubleWord 0xe000ed88 0x300 context=cpu
    Issue Instruction               0xfe106430
    Read Register Should Equal      R6  0
    Issue Instruction               0xec554408
    Read Register Should Equal      R4  0
    Read Register Should Equal      R5  0

Should Respect NSACR Denial In Non Secure State
    Create DCP Machine              trustzone=true
    Execute Command                 sysbus WriteDoubleWord 0xe000edd0 2 context=cpu
    Execute Command                 cpu CPACR_NS 0x300
    Execute Command                 cpu NSACR 0
    Execute Command                 cpu SecureState false
    Execute Command                 sysbus WriteDoubleWord 0xe000ed24 0x40000 context=cpu
    Issue Instruction               0xee100430
    Should Have Usage Fault         0x80000

Should Allow NSACR Granted Access In Non Secure State
    Create DCP Machine              trustzone=true
    Execute Command                 sysbus WriteDoubleWord 0xe000edd0 2 context=cpu
    Execute Command                 cpu CPACR_NS 0x300
    Execute Command                 cpu NSACR 0x10
    Execute Command                 cpu SecureState false
    Issue Instruction               0xee100430
    Read Register Should Equal      PC  0x1004
