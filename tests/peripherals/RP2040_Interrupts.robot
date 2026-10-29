*** Keywords ***
Create Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @platforms/boards/raspberry_pi_pico.repl
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true

Pending Should Equal
    [Arguments]                     ${core}  ${mask}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord 0xe000e200 ${core}
    ${masked}=                      Evaluate  int("${value.strip()}", 0) & int("${mask}", 0)
    Should Be Equal As Integers      ${masked}  ${expected}

*** Test Cases ***
Should Route All Timer Alarms To Both Cores
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x200000
    Execute Command                 sysbus WriteDoubleWord 0x4005403c 0xf
    Pending Should Equal            cpu0  0xf  0xf
    Pending Should Equal            cpu1  0xf  0xf

Should Route Both FIFO Interrupts To Both Cores
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000054 0x12345678 cpu0
    Pending Should Equal            cpu0  0x10000  0x10000
    Pending Should Equal            cpu1  0x10000  0x10000
    Execute Command                 sysbus WriteDoubleWord 0xd0000054 0x87654321 cpu1
    Pending Should Equal            cpu0  0x18000  0x18000
    Pending Should Equal            cpu1  0x18000  0x18000

Should Route USB Interrupts To Both Cores
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x1000000
    Execute Command                 sysbus WriteDoubleWord 0x50110094 1
    Pending Should Equal            cpu0  0x20  0x20
    Pending Should Equal            cpu1  0x20  0x20

Should Route RTC Interrupts To Both Cores
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x8000
    Execute Command                 sysbus WriteDoubleWord 0x4005c028 1
    Pending Should Equal            cpu0  0x2000000  0x2000000
    Pending Should Equal            cpu1  0x2000000  0x2000000

Should Route SSI Interrupts To Both Cores
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x18000008 1
    Pending Should Equal            cpu0  0x40  0x40
    Pending Should Equal            cpu1  0x40  0x40

Should Route Both PIO Interrupt Lines From Both Blocks To Both Cores
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0xc00
    Execute Command                 sysbus WriteDoubleWord 0x50200130 1
    Execute Command                 sysbus WriteDoubleWord 0x5020013c 1
    Execute Command                 sysbus WriteDoubleWord 0x50300130 1
    Execute Command                 sysbus WriteDoubleWord 0x5030013c 1
    Pending Should Equal            cpu0  0x780  0x780
    Pending Should Equal            cpu1  0x780  0x780

Should Route Both DMA Interrupt Lines To Both Cores
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 4
    Execute Command                 sysbus WriteDoubleWord 0x50000408 1
    Execute Command                 sysbus WriteDoubleWord 0x50000418 1
    Pending Should Equal            cpu0  0x1800  0x1800
    Pending Should Equal            cpu1  0x1800  0x1800

Should Keep GPIO Interrupts Specific To Each Core
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x20
    Execute Command                 sysbus WriteDoubleWord 0x40014110 2
    Pending Should Equal            cpu0  0x2000  0x2000
    Pending Should Equal            cpu1  0x2000  0

Should Resample Held FIFO IRQ Across NVIC Reset
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000054 0x12345678 cpu0
    Execute Command                 nvic1 Reset
    Pending Should Equal            cpu1  0x10000  0x10000
    ${enabled}=                     Execute Command  sysbus ReadDoubleWord 0xe000e100 cpu1
    Should Be Equal As Integers      ${enabled.strip()}  0

Should Resample Held FIFO IRQ Across PSM Core Reset
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000054 0x12345678 cpu0
    Execute Command                 sysbus WriteDoubleWord 0x40012004 0x10000
    Pending Should Equal            cpu1  0x10000  0x10000
    Execute Command                 sysbus WriteDoubleWord 0x40013004 0x10000
    Pending Should Equal            cpu1  0x10000  0x10000

Should Clear Software Pending State When Physical IRQ Is Low At Reset
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0xe000e200 0x10000 cpu1
    Execute Command                 nvic1 Reset
    Pending Should Equal            cpu1  0x10000  0

Should Clear FIFO IRQ When The Whole Machine Resets Its Peripheral Source
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000054 0x12345678 cpu0
    Execute Command                 machine Reset
    Pending Should Equal            cpu0  0x18000  0
    Pending Should Equal            cpu1  0x18000  0

Should Clear Reset Peripheral Levels Without Cross-Pending Other Sources
    Create Machine
    Execute Command                 sysbus WriteDoubleWord 0xd0000054 0x12345678 cpu0
    Execute Command                 sysbus WriteDoubleWord 0x4000f000 0x1208000
    Execute Command                 sysbus WriteDoubleWord 0x4005403c 0xf
    Execute Command                 sysbus WriteDoubleWord 0x50110094 1
    Execute Command                 sysbus WriteDoubleWord 0x4005c028 1
    Execute Command                 machine Reset
    Pending Should Equal            cpu0  0x201802f  0
    Pending Should Equal            cpu1  0x201802f  0
