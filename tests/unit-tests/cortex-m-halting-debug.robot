*** Settings ***
Library                             OperatingSystem

*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33"
...  ${SPACE*4}nvic: nvic0
...  ${SPACE*4}InitVectorTableOffset: 0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33"
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}cpuId: 1
...  ${SPACE*4}InitVectorTableOffset: 0
...  nvic0: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 }
...  ${SPACE*4}-> cpu1@0
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x1000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x2000

*** Keywords ***
Create Test Machine
    [Arguments]                     ${breakpoint}=00
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 emulation SetGlobalAdvanceImmediately true
    Execute Command                 emulation SetGlobalQuantum "0.000001"
    # MOVS r0,16; BKPT imm; MOVS r1,42; B .
    ${code}=                        Evaluate  bytes.fromhex("1020${breakpoint}be2a21fee7")
    Create Binary File              ${TEMPDIR}/halting_debug_code.bin  ${code}
    Execute Command                 sysbus LoadBinary @${TEMPDIR}/halting_debug_code.bin 0x100
    Execute Command                 sysbus WriteDoubleWord 0 0x20002000
    Execute Command                 sysbus WriteDoubleWord 4 0x101
    Execute Command                 sysbus WriteDoubleWord 0xc 0x201
    # HardFault handler: MOVS r7,119; B .
    Execute Command                 sysbus WriteDoubleWord 0x200 0xe7fe2777

Enable External Debug
    Execute Command                 cpu0 EnableMemoryMappedDebug true
    Execute Command                 nvic0 WriteDoubleWord 0xdf0 0xa05f0001

Debug Halt Should Equal
    [Arguments]                     ${expected}
    ${status}=                      Execute Command  nvic0 ReadDoubleWord 0xdf0
    ${halted}=                      Evaluate  (int("${status.strip()}", 0) >> 17) & 1
    Should Be Equal As Integers      ${halted}  ${expected}

Wait For Debug Halt
    [Arguments]                     ${expected}=1
    Wait Until Keyword Succeeds     5s  0.01s  Debug Halt Should Equal  ${expected}

Register Should Equal
    [Arguments]                     ${cpu}  ${register}  ${expected}
    ${actual}=                      Execute Command  ${cpu} GetRegister ${register}
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

Core Should Be Halted At Breakpoint
    Wait For Debug Halt
    ${halted}=                      Execute Command  cpu0 HaltedByDebugger
    Should Be Equal                 ${halted.strip()}  True
    Register Should Equal           cpu0  15  0x102
    Register Should Equal           cpu0  0  16
    Register Should Equal           cpu0  1  0
    ${status}=                      Execute Command  nvic0 ReadDoubleWord 0xd30
    Should Be Equal As Integers      ${status.strip()}  2

Prepare Single Step Program
    [Arguments]                     ${hex}=002001300230fee7
    Create Test Machine
    ${code}=                        Evaluate  bytes.fromhex("${hex}")
    Create Binary File              ${TEMPDIR}/halting_debug_step.bin  ${code}
    Execute Command                 sysbus LoadBinary @${TEMPDIR}/halting_debug_step.bin 0x100
    Enable External Debug
    Execute Command                 emulation RunFor "0.0001"
    Execute Command                 nvic0 WriteDoubleWord 0xdf0 0xa05f0003
    Wait For Debug Halt
    Execute Command                 cpu0 SetRegister 15 0x100
    Execute Command                 cpu0 SetRegister 0 0
    Execute Command                 cpu0 SetRegister 1 0

Step One Instruction
    ${before}=                      Execute Command  cpu0 ExecutedInstructions
    Execute Command                 nvic0 WriteDoubleWord 0xdf0 0xa05f000d
    Wait For Debug Halt             0
    Execute Command                 emulation RunFor "0.0001"
    Wait For Debug Halt
    ${after}=                       Execute Command  cpu0 ExecutedInstructions
    ${retired}=                     Evaluate  int("${after.strip()}",0) - int("${before.strip()}",0)
    Should Be Equal As Integers      ${retired}  1
    ${halted}=                      Execute Command  cpu0 HaltedByDebugger
    Should Be Equal                 ${halted.strip()}  True

*** Test Cases ***
Should Halt On BKPT With External Debug Enabled
    Create Test Machine
    Enable External Debug
    Execute Command                 emulation RunFor "0.0001"
    Core Should Be Halted At Breakpoint

Should Give Halting Debug Priority Over Semihosting
    Create Test Machine             ab
    Enable External Debug
    Execute Command                 emulation RunFor "0.0001"
    Core Should Be Halted At Breakpoint

Should Resume From An Explicit Debugger Program Counter
    Create Test Machine
    Enable External Debug
    Execute Command                 emulation RunFor "0.0001"
    Core Should Be Halted At Breakpoint
    Execute Command                 cpu0 SetRegister 15 0x104
    Execute Command                 nvic0 WriteDoubleWord 0xdf0 0xa05f0001
    Wait For Debug Halt             0
    Execute Command                 emulation RunFor "0.0001"
    Register Should Equal           cpu0  1  42
    ${halted}=                      Execute Command  cpu0 HaltedByDebugger
    Should Be Equal                 ${halted.strip()}  False

Should Preserve Fault Behavior On The Other Core Without External Debug
    Create Test Machine
    Enable External Debug
    Execute Command                 emulation RunFor "0.0001"
    Core Should Be Halted At Breakpoint
    Wait For Debug Halt
    ${halted}=                      Execute Command  cpu1 HaltedByDebugger
    Should Be Equal                 ${halted.strip()}  False
    Register Should Equal           cpu1  7  119

Should Preserve Semihosting Without External Debug
    Create Test Machine             ab
    Execute Command                 emulation RunFor "0.0001"
    Register Should Equal           cpu0  1  42
    ${halted}=                      Execute Command  cpu0 HaltedByDebugger
    Should Be Equal                 ${halted.strip()}  False

Should Execute Exactly One Real Instruction Per Debug Step
    Prepare Single Step Program
    Step One Instruction
    Register Should Equal           cpu0  15  0x102
    Register Should Equal           cpu0  0  0
    Step One Instruction
    Register Should Equal           cpu0  15  0x104
    Register Should Equal           cpu0  0  1
    Step One Instruction
    Register Should Equal           cpu0  15  0x106
    Register Should Equal           cpu0  0  3

Should Mask Pending Interrupts During A Debug Step And Restore Them On Run
    Prepare Single Step Program
    Execute Command                 cpu0 SetRegister 15 0x102
    Execute Command                 sysbus WriteDoubleWord 0x44 0x301
    Execute Command                 sysbus WriteDoubleWord 0x300 0xe7fe2666
    Execute Command                 nvic0 WriteDoubleWord 0x100 2
    Execute Command                 nvic0 WriteDoubleWord 0x200 2
    Step One Instruction
    Register Should Equal           cpu0  15  0x104
    Register Should Equal           cpu0  6  0
    Execute Command                 nvic0 WriteDoubleWord 0xdf0 0xa05f0001
    Wait For Debug Halt             0
    Execute Command                 emulation RunFor "0.0001"
    Register Should Equal           cpu0  6  102
    # Pending IRQ must enter before the ADD at the resumed PC can retire.
    Register Should Equal           cpu0  0  1

Should Step A Sleeping Core Without Requiring An Interrupt
    Prepare Single Step Program     30bf2a21fee7
    Step One Instruction
    Register Should Equal           cpu0  15  0x102
    Register Should Equal           cpu0  1  0
    Step One Instruction
    Register Should Equal           cpu0  15  0x104
    Register Should Equal           cpu0  1  42
