*** Keywords ***
Create System Reset Machine
    Execute Command                 path add @${CURDIR}/../..
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @${CURDIR}/../../platforms/boards/raspberry_pi_pico2.repl
    Execute Python                  self.Machine['sysbus.cpu0'].CpuWaitSignal.Set(True)
    Execute Python                  self.Machine['sysbus.cpu1'].CpuWaitSignal.Set(True)
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Trigger Watchdog
    Execute Command                 sysbus WriteDoubleWord 0x400d8000 0x80000000
    Execute Command                 emulation RunFor "0.00001"

*** Test Cases ***
Should Reset Boot Security Flops And Preserve Boot RAM Words Watchdog And PSM
    Create System Reset Machine
    Execute Command                 sysbus WriteDoubleWord 0x400e0020 0xabcdef12
    Execute Command                 sysbus WriteDoubleWord 0x400e0800 0x11
    Execute Command                 sysbus WriteDoubleWord 0x400e0804 0x22
    Read Should Equal               0x400e0814  4
    Read Should Equal               0x400e0808  0xfb
    Execute Command                 sysbus WriteDoubleWord 0x400d801c 0x6ab73121
    Execute Command                 sysbus WriteDoubleWord 0x40018008 0x200
    Trigger Watchdog
    Read Should Equal               0x400e0800  0
    Read Should Equal               0x400e0804  0
    Read Should Equal               0x400e0808  0xff
    Read Should Equal               0x400e0020  0xabcdef12
    Read Should Equal               0x400d801c  0x6ab73121
    Read Should Equal               0x400d8008  2
    Read Should Equal               0x400d8000  0
    Read Should Equal               0x40018008  0x200

Should Preserve Boot Security Flops Clocks And Ticks For Processor Only Reset
    Create System Reset Machine
    Execute Command                 sysbus WriteDoubleWord 0x400e0800 1
    Read Should Equal               0x400e0814  4
    Execute Command                 sysbus WriteDoubleWord 0x40010034 0x30000
    Execute Command                 sysbus WriteDoubleWord 0x40108034 12
    Execute Command                 sysbus WriteDoubleWord 0x40018008 0x800000
    Trigger Watchdog
    Read Should Equal               0x400e0800  1
    Read Should Equal               0x400e0808  0xfb
    Read Should Equal               0x40010034  0x30000
    Read Should Equal               0x40108034  12

Should Reset Clocks And Ticks While Retaining Oscillators SRAM NOR And Power Scratch
    Create System Reset Machine
    ${image}=                       Evaluate  bytes.fromhex('78563412')
    ${nor}=                         Allocate Temporary File
    Evaluate                        open(r'${nor}', 'wb').write($image)
    Execute Command                 xipMemory LoadBinary @${nor}
    Read Should Equal               0x14000000  0x12345678
    Execute Command                 sysbus WriteDoubleWord 0x40048000 0xfabaa0
    Execute Command                 sysbus WriteDoubleWord 0x40010030 2
    Execute Command                 sysbus WriteDoubleWord 0x40010034 0x30000
    Execute Command                 sysbus WriteDoubleWord 0x40010040 0x28000
    Execute Command                 sysbus WriteDoubleWord 0x40108034 12
    Execute Command                 sysbus WriteDoubleWord 0x40108030 1
    Execute Command                 sysbus WriteDoubleWord 0x20001000 0x89abcdef
    Execute Command                 sysbus WriteDoubleWord 0x401000b0 0x76543210
    Execute Command                 sysbus WriteDoubleWord 0x400d801c 0x6ab73121
    Execute Command                 sysbus WriteDoubleWord 0x40018008 0x20
    Trigger Watchdog
    Read Should Equal               0x40048000  0xfabaa0
    Read Should Equal               0x40010030  0
    Read Should Equal               0x40010034  0x10000
    Read Should Equal               0x40010040  0x10000
    Read Should Equal               0x40108030  0
    Read Should Equal               0x40108034  0
    Read Should Equal               0x20001000  0x89abcdef
    Read Should Equal               0x401000b0  0x76543210
    Read Should Equal               0x400d801c  0x6ab73121
    Read Should Equal               0x400d8008  2
    Read Should Equal               0x14000000  0x12345678

Should Pulse Independent Subsystem WDSEL With No System Selection
    Create System Reset Machine
    Execute Command                 sysbus WriteDoubleWord 0x40020000 0
    Execute Command                 sysbus WriteDoubleWord 0x40070030 0x301
    Execute Command                 sysbus WriteDoubleWord 0x40078030 0x301
    Execute Command                 sysbus WriteDoubleWord 0x40020004 0x4000000
    Trigger Watchdog
    Read Should Equal               0x40070030  0x300
    Read Should Equal               0x40078030  0x301
    Read Should Equal               0x40020000  0
    Read Should Equal               0x40020004  0x4000000

Should Restart The Master Subsystem Reset Controller And Assert Individual Holds
    Create System Reset Machine
    Execute Command                 sysbus WriteDoubleWord 0x40020000 0
    Execute Command                 sysbus WriteDoubleWord 0x40070030 0x301
    Execute Command                 sysbus WriteDoubleWord 0x40020004 0x4000000
    Execute Command                 sysbus WriteDoubleWord 0x40018008 0x10
    Trigger Watchdog
    Read Should Equal               0x40020000  0x1fffffff
    Read Should Equal               0x40020004  0
    ${held}=                        Execute Command  uart0 ResetHeld
    Should Be Equal                 ${held.strip()}  True
    Execute Command                 sysbus WriteDoubleWord 0x40070030 0x301
    Read Should Equal               0x40070030  0x300
    Execute Command                 sysbus WriteDoubleWord 0x40020000 0
    Read Should Equal               0x40070030  0x300

Should Reset SIO And Access Control While Preserving Upstream Domains
    Create System Reset Machine
    Execute Command                 sysbus WriteDoubleWord 0x400e0800 1
    Execute Command                 sysbus WriteDoubleWord 0x40010034 0x30000
    Execute Command                 sysbus WriteDoubleWord 0x400d0014 0x000b
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 0x1234
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x5678
    Execute Command                 sysbus WriteDoubleWord 0x40018008 0x200000
    Trigger Watchdog
    Read Should Equal               0xd0000010  0
    Read Should Equal               0x4006000c  0
    Read Should Equal               0x400e0800  1
    Read Should Equal               0x40010034  0x30000
    Read Should Equal               0x400d0014  0x000b

Should Reset XIP And QMI Configuration With Downstream SIO And Access Control
    Create System Reset Machine
    Execute Command                 sysbus WriteDoubleWord 0x400e0800 1
    Execute Command                 sysbus WriteDoubleWord 0x400c8000 0x81
    Execute Command                 sysbus WriteDoubleWord 0x400d0014 0x000b
    Execute Command                 sysbus WriteDoubleWord 0xd0000010 0x1234
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x5678
    Execute Command                 sysbus WriteDoubleWord 0x40018008 0x100000
    Trigger Watchdog
    Read Should Equal               0x400c8000  0x83
    Read Should Equal               0x400d0014  0xa003
    Read Should Equal               0xd0000010  0
    Read Should Equal               0x4006000c  0
    Read Should Equal               0x400e0800  1

Should Reset OTP Software Locks Only When Its Stage Is Selected
    Create System Reset Machine
    Execute Command                 sysbus WriteDoubleWord 0x40120000 3
    Execute Command                 sysbus WriteDoubleWord 0x40018008 4
    Trigger Watchdog
    Read Should Equal               0x40120000  3
    Execute Command                 sysbus WriteDoubleWord 0x40018008 2
    Trigger Watchdog
    Read Should Equal               0x40120000  0
