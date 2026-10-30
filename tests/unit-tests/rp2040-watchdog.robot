*** Keywords ***
Create Watchdog Machine
    Execute Command                 path add @${CURDIR}/../..
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @platforms/boards/raspberry_pi_pico.repl
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    ${image}=                       Evaluate  bytes.fromhex('0000042001010000') + bytes(248) + bytes.fromhex('fee7')
    ${rom}=                         Allocate Temporary File
    Evaluate                        open(r'${rom}', 'wb').write($image)
    Execute Command                 sysbus LoadBinary @${rom} 0

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Trigger Watchdog
    Execute Command                 sysbus WriteDoubleWord 0x40058000 0x80000000
    Execute Command                 emulation RunFor "0.00001"

*** Test Cases ***
Should Expire After Ten Microseconds And Retain Cause Scratch And Enable
    Create Watchdog Machine
    Execute Command                 sysbus WriteDoubleWord 0x4005801c 0x6ab73121
    Execute Command                 sysbus WriteDoubleWord 0x4005802c 0x206
    Execute Command                 sysbus WriteDoubleWord 0x40058004 20
    Execute Command                 sysbus WriteDoubleWord 0x40058000 0x47000000
    Execute Command                 emulation RunFor "0.000009"
    Read Should Equal               0x40058008  0
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x40058008  1
    Read Should Equal               0x40058000  0x47000000
    Read Should Equal               0x4005801c  0x6ab73121

Should Reset Only Processor Zero When Selected
    Create Watchdog Machine
    Execute Command                 cpu0 SetRegister "R0" 0x1234
    Execute Command                 cpu1 SetRegister "R0" 0x5678
    Execute Command                 sysbus WriteDoubleWord 0x40010008 0x8000
    Trigger Watchdog
    ${core0}=                       Execute Command  cpu0 GetRegister "R0"
    ${core1}=                       Execute Command  cpu1 GetRegister "R0"
    Should Be Equal As Integers      ${core0.strip()}  0
    Should Be Equal As Integers      ${core1.strip()}  0x5678
    Read Should Equal               0x40058008  2

Should Reset Selected UART Without Restarting Processors
    Create Watchdog Machine
    Execute Command                 cpu0 SetRegister "R0" 0x1234
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x400000
    Execute Command                 sysbus WriteDoubleWord 0x40034030 0x301
    Read Should Equal               0x40034030  0x301
    Execute Command                 sysbus WriteDoubleWord 0x4000c004 0x400000
    Trigger Watchdog
    Read Should Equal               0x40034030  0x300
    Read Should Equal               0x4000c004  0x400000
    ${core0}=                       Execute Command  cpu0 GetRegister "R0"
    Should Be Equal As Integers      ${core0.strip()}  0x1234

Should Reset Downstream Domains And Retain Oscillators Scratch And SRAM
    Create Watchdog Machine
    Execute Command                 sysbus WriteDoubleWord 0x40024000 0xfabaa0
    Execute Command                 sysbus WriteDoubleWord 0x40008034 0x200
    Execute Command                 sysbus WriteDoubleWord 0x40008040 0x700
    Execute Command                 sysbus WriteDoubleWord 0x4005801c 0x6ab73121
    Execute Command                 sysbus WriteDoubleWord 0x20001000 0x89abcdef
    Execute Command                 sysbus WriteDoubleWord 0x4000c000 0
    Execute Command                 sysbus WriteDoubleWord 0x40034030 0x301
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 0x1234
    Execute Command                 sysbus WriteDoubleWord 0x40010008 4
    Trigger Watchdog
    Read Should Equal               0x40024000  0xfabaa0
    Read Should Equal               0x40008034  0x200
    Read Should Equal               0x40008040  0x700
    Read Should Equal               0x4005801c  0x6ab73121
    Read Should Equal               0x40058008  2
    Read Should Equal               0x20001000  0x89abcdef
    Read Should Equal               0xd0000010  0
    Read Should Equal               0x4000c000  0x1ffffff
    Read Should Equal               0x40034030  0x300

Should Preserve External NOR Across A PSM Restart
    Create Watchdog Machine
    ${flash}=                       Allocate Temporary File
    Evaluate                        open(r'${flash}', 'wb').write(bytes.fromhex('12345678'))
    Execute Command                 xipMemory LoadBinary @${flash}
    Execute Command                 sysbus WriteDoubleWord 0x40010008 4
    Trigger Watchdog
    ${value}=                       Execute Python  str(self.Machine['sysbus.ssi.flash'].UnderlyingMemory.ReadDoubleWord(0))
    Should Be Equal As Integers      ${value}  0x78563412
