*** Settings ***
Library                             OperatingSystem

*** Variables ***
${FPB_PLATFORM}                     SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic0
...  ${SPACE*4}InitVectorTableOffset: 0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}cpuId: 1
...  ${SPACE*4}InitVectorTableOffset: 0
...  nvic0: IRQControllers.NVIC @ { sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 } }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ { sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 } }
...  ${SPACE*4}-> cpu1@0
...  fpb0: CPU.ARM_FlashPatchBreakpoint @ { sysbus new Bus.BusPointRegistration { address: 0xe0002000; cpu: cpu0 } }
...  ${SPACE*4}cpu: cpu0
...  fpb1: CPU.ARM_FlashPatchBreakpoint @ { sysbus new Bus.BusPointRegistration { address: 0xe0002000; cpu: cpu1 } }
...  ${SPACE*4}cpu: cpu1
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x1000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x2000

*** Keywords ***
Create FPB Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${FPB_PLATFORM}"""
    Execute Command                 emulation SetGlobalAdvanceImmediately true
    Execute Command                 emulation SetGlobalQuantum "0.000001"
    Execute Command                 cpu0 EnableMemoryMappedDebug true
    Execute Command                 cpu1 EnableMemoryMappedDebug true
    Execute Command                 sysbus WriteDoubleWord 0 0x20002000
    Execute Command                 sysbus WriteDoubleWord 4 0x101
    Execute Command                 sysbus WriteDoubleWord 0xc 0x301
    Execute Command                 sysbus WriteDoubleWord 0x14 0x401
    Execute Command                 sysbus WriteDoubleWord 0x300 0xe7fe2777
    Execute Command                 sysbus WriteDoubleWord 0x400 0xe7fe2766
    # MOVS r0,16; MOVS r1,42; MOVS r2,59; B .
    Execute Command                 sysbus WriteDoubleWord 0x100 0x212a2010
    Execute Command                 sysbus WriteDoubleWord 0x104 0xe7fe223b

FPB Word Should Equal
    [Arguments]                     ${address}  ${expected}  ${cpu}=cpu0
    ${actual}=                      Execute Command  sysbus ReadDoubleWord ${address} context=${cpu}
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

FPB Register Should Equal
    [Arguments]                     ${register}  ${expected}  ${cpu}=cpu0
    ${actual}=                      Execute Command  ${cpu} GetRegister ${register}
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

FPB Core Should Be Halted
    [Arguments]                     ${pc}=0x102  ${cpu}=cpu0
    ${halted}=                      Execute Command  ${cpu} HaltedByDebugger
    Should Be Equal                 ${halted.strip()}  True
    FPB Register Should Equal       15  ${pc}  ${cpu}
    FPB Word Should Equal           0xe000ed30  2  ${cpu}

FPB Core Should Be Running
    [Arguments]                     ${cpu}=cpu0
    ${halted}=                      Execute Command  ${cpu} HaltedByDebugger
    Should Be Equal                 ${halted.strip()}  False

Enable FPB Debug
    [Arguments]                     ${cpu}=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000edf0 0xa05f0001 context=${cpu}

Set FPB Comparator
    [Arguments]                     ${index}  ${value}  ${cpu}=cpu0
    Execute Command                 sysbus WriteDoubleWord ${{0xe0002008 + int($index) * 4}} ${value} context=${cpu}

Enable FPB
    [Arguments]                     ${cpu}=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe0002000 3 context=${cpu}

Resume FPB Core
    [Arguments]                     ${cpu}=cpu0
    Execute Command                 sysbus WriteDoubleWord 0xe000ed30 0x1f context=${cpu}
    Enable FPB Debug                ${cpu}
    Execute Command                 emulation RunFor "0.0001"

*** Test Cases ***
Should Report Physical FPBv2 Reset Values And ReadOnlyRemap
    Create FPB Machine
    FPB Word Should Equal           0xe0002000  0x10000080
    FPB Word Should Equal           0xe0002004  0
    FOR  ${index}  IN RANGE  8
        FPB Word Should Equal       ${{0xe0002008 + $index * 4}}  0
    END
    Execute Command                 sysbus WriteDoubleWord 0xe0002004 0x3fffffe0 context=cpu0
    FPB Word Should Equal           0xe0002004  0
    FPB Word Should Equal           0xe0002fbc  0x47701a03
    FPB Word Should Equal           0xe0002ff4  0x90

Should Require KeyAndPreserveReadOnlyControlFields
    Create FPB Machine
    Execute Command                 sysbus WriteDoubleWord 0xe0002000 1 context=cpu0
    FPB Word Should Equal           0xe0002000  0x10000080
    Execute Command                 sysbus WriteDoubleWord 0xe0002000 0xffffffff context=cpu0
    FPB Word Should Equal           0xe0002000  0x10000081
    Execute Command                 sysbus WriteDoubleWord 0xe0002000 0 context=cpu0
    FPB Word Should Equal           0xe0002000  0x10000081
    Execute Command                 sysbus WriteDoubleWord 0xe0002000 2 context=cpu0
    FPB Word Should Equal           0xe0002000  0x10000080

Should HaltBeforeExecutingMatchedThumbInstruction
    Create FPB Machine
    Enable FPB Debug
    Set FPB Comparator              0  0x103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted
    FPB Register Should Equal       0  16
    FPB Register Should Equal       1  0
    FPB Register Should Equal       2  0

Should ExecuteAllEightComparators
    Create FPB Machine
    Enable FPB Debug
    FOR  ${index}  IN RANGE  8
        Execute Command             fpb0 Reset
        Set FPB Comparator          ${index}  0x103
        Enable FPB
        Execute Command             cpu0 SetRegister 15 0x100
        Execute Command             cpu0 SetRegister 1 0
        Resume FPB Core
        FPB Core Should Be Halted
        FPB Register Should Equal   1  0
    END

Should IgnoreDisabledComparatorAndDisabledGlobalControl
    Create FPB Machine
    Enable FPB Debug
    Set FPB Comparator              0  0x102
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Running
    FPB Register Should Equal       1  42
    Set FPB Comparator              0  0x103
    Execute Command                 sysbus WriteDoubleWord 0xe0002000 2 context=cpu0
    Execute Command                 cpu0 SetRegister 15 0x100
    Resume FPB Core
    FPB Core Should Be Running

Should ExecuteMatchedInstructionWithDebugDisabled
    Create FPB Machine
    Set FPB Comparator              0  0x103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Running
    FPB Register Should Equal       1  42
    FPB Register Should Equal       2  59
    FPB Word Should Equal           0xe000ed30  0

Should ObserveDebugEnableChangeInAlreadyTranslatedMatch
    Create FPB Machine
    # Keep this core executing while the debugger changes PC and C_DEBUGEN.
    Execute Command                 sysbus WriteWord 0x106 0xbf00
    Execute Command                 sysbus WriteWord 0x108 0xe7fd
    Set FPB Comparator              0  0x103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Running
    Execute Command                 cpu0 SetRegister 15 0x100
    Execute Command                 cpu0 SetRegister 1 0
    Enable FPB Debug
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted
    FPB Register Should Equal       1  0

Should ReplaceAndDisableComparatorWithoutStaleNativeBreakpoint
    Create FPB Machine
    Enable FPB Debug
    Set FPB Comparator              0  0x103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted
    Set FPB Comparator              0  0x105
    Resume FPB Core
    FPB Core Should Be Halted       0x104
    FPB Register Should Equal       1  42
    FPB Register Should Equal       2  0
    Set FPB Comparator              0  0
    Resume FPB Core
    FPB Core Should Be Running
    FPB Register Should Equal       2  59

Should KeepDuplicateComparatorUntilBothAreDisabled
    Create FPB Machine
    Enable FPB Debug
    Set FPB Comparator              0  0x103
    Set FPB Comparator              1  0x103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted
    Set FPB Comparator              0  0
    Execute Command                 cpu0 SetRegister 15 0x100
    Resume FPB Core
    FPB Core Should Be Halted
    Set FPB Comparator              1  0
    Resume FPB Core
    FPB Core Should Be Running
    FPB Register Should Equal       1  42

Should KeepComparatorsAndHaltStatePerCore
    Create FPB Machine
    Enable FPB Debug
    Enable FPB Debug                cpu1
    Set FPB Comparator              0  0x103
    Set FPB Comparator              0  0x105  cpu1
    Enable FPB
    Enable FPB                      cpu1
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted
    FPB Core Should Be Halted       0x104  cpu1
    FPB Register Should Equal       1  0
    FPB Register Should Equal       1  42  cpu1
    FPB Word Should Equal           0xe0002008  0x103
    FPB Word Should Equal           0xe0002008  0x105  cpu1

Should MatchFullAddressRangeIncludingSram
    Create FPB Machine
    Execute Command                 sysbus WriteDoubleWord 0x20000100 0x212a2010
    Execute Command                 sysbus WriteDoubleWord 0x20000104 0xe7fe223b
    Execute Command                 cpu0 PC 0x20000100
    Enable FPB Debug
    Set FPB Comparator              0  0x20000103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted       0x20000102
    FPB Register Should Equal       1  0

Should HaltOnFirstHalfwordOf32BitInstruction
    Create FPB Machine
    Execute Command                 cpu0 AssembleBlock 0x100 "movs r0, #16; movw r1, #0x1234; movs r2, #59; b ."
    Enable FPB Debug
    Set FPB Comparator              0  0x103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted
    FPB Register Should Equal       1  0
    Set FPB Comparator              0  0
    Resume FPB Core
    FPB Register Should Equal       1  0x1234

Should IgnoreSecondHalfwordMatchOf32BitInstruction
    Create FPB Machine
    Execute Command                 cpu0 AssembleBlock 0x100 "movs r0, #16; movw r1, #0x1234; movs r2, #59; b ."
    Enable FPB Debug
    Set FPB Comparator              0  0x105
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Running
    FPB Register Should Equal       1  0x1234
    FPB Register Should Equal       2  59

Should IgnoreDataReadsAtInstructionComparatorAddress
    Create FPB Machine
    Enable FPB Debug
    Set FPB Comparator              0  0x103
    Enable FPB
    FPB Word Should Equal           0x100  0x212a2010
    FPB Core Should Be Running
    FPB Word Should Equal           0xe000ed30  0

Should RetainFPBAcrossWarmCPUReset
    Create FPB Machine
    Enable FPB Debug
    Set FPB Comparator              0  0x101
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted       0x100
    Execute Command                 cpu0 Reset
    FPB Word Should Equal           0xe0002000  0x10000081
    FPB Word Should Equal           0xe0002008  0x101
    Resume FPB Core
    FPB Core Should Be Halted       0x100

Should ClearFPBOnPeripheralColdReset
    Create FPB Machine
    Enable FPB Debug
    Set FPB Comparator              7  0x103
    Enable FPB
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Halted
    Execute Command                 fpb0 Reset
    FPB Word Should Equal           0xe0002000  0x10000080
    FPB Word Should Equal           0xe0002024  0
    Resume FPB Core
    FPB Core Should Be Running
    FPB Register Should Equal       1  42

Should ProgramComparatorFromExecutingCoreBeforeISB
    Create FPB Machine
    Enable FPB Debug
    Execute Command                 cpu0 AssembleBlock 0x100 "movw r0, #0x2008; movt r0, #0xe000; movw r1, #0x11d; str r1, [r0]; subs r0, #8; movs r1, #3; str r1, [r0]; dsb sy; isb sy; movs r2, #42; b ."
    Execute Command                 emulation RunFor "0.0001"
    FPB Word Should Equal           0xe0002000  0x10000081
    FPB Word Should Equal           0xe0002008  0x11d
    FPB Core Should Be Halted       0x11c
    FPB Register Should Equal       2  0

Should FaultUnprivilegedSoftwareAccessToFPB
    Create FPB Machine
    Enable FPB Debug
    Execute Command                 sysbus WriteDoubleWord 0xe000ed24 0x20000 context=cpu0
    Execute Command                 cpu0 AssembleBlock 0x100 "ldr r0, [r1]; b ."
    Execute Command                 cpu0 SetRegister 1 0xe0002000
    Execute Command                 cpu0 Control 1
    Execute Command                 emulation RunFor "0.0001"
    FPB Core Should Be Running
    FPB Register Should Equal       7  102
    FPB Word Should Equal           0xe000ed28  0x8200

Should ReconfigureThroughMemAPWhileCorePollsFPBRegisters
    Create FPB Machine
    Execute Command                 include "${CURDIR}/FPBConcurrency.cs"
    Execute Command                 machine LoadPlatformDescriptionFromString "fpbConcurrency: Miscellaneous.FPBConcurrencyTester @ sysbus 0x50000000 { cpu0: cpu0; cpu1: cpu1 }"
    Execute Command                 fpbConcurrency ReconfigureThroughMemAPWhileCorePollsRegisters

Should SelectIndependentFPBsThroughTheTwoMemAPs
    Create FPB Machine
    Execute Command                 include "${CURDIR}/FPBConcurrency.cs"
    Execute Command                 machine LoadPlatformDescriptionFromString "fpbConcurrency: Miscellaneous.FPBConcurrencyTester @ sysbus 0x50000000 { cpu0: cpu0; cpu1: cpu1 }"
    Execute Command                 fpbConcurrency VerifyMemAPCoreIsolation
