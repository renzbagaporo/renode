*** Variables ***
${SIO}                              0xd0000000
${PLATFORM}                         SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m0+"
...  ${SPACE*4}nvic: nvic0
...  ${SPACE*4}id: 0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m0+"
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}id: 1
...  nvic0: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 }
...  ${SPACE*4}-> cpu1@0
...  sio: Miscellaneous.RP2040_SIO @ sysbus 0xd0000000
...  ${SPACE*4}Core0IRQ -> nvic0@15
...  ${SPACE*4}Core1IRQ -> nvic1@16

*** Keywords ***
Create Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    Execute Command                 emulation SetGlobalAdvanceImmediately true

Read SIO Should Equal
    [Arguments]                     ${offset}  ${expected}  ${core}=cpu0
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${{${SIO} + ${offset}}} context=${core}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Write SIO
    [Arguments]                     ${offset}  ${value}  ${core}=cpu0
    Execute Command                 sysbus WriteDoubleWord ${{${SIO} + ${offset}}} ${value} context=${core}

FIFO IRQ Should Equal
    [Arguments]                     ${core}  ${expected}
    ${value}=                       Execute Command  sio Core${core}IRQ IsSet
    Should Be Equal                 ${value.strip()}  ${expected}

*** Test Cases ***
Should Identify Both Cores
    Create Machine
    Read SIO Should Equal           0x0  0  cpu0
    Read SIO Should Equal           0x0  1  cpu1

Should Transfer Eight FIFO Words And Keep Overflow Sticky
    Create Machine
    FOR  ${word}  IN RANGE  8
        Write SIO                   0x54  ${word}
    END
    Read SIO Should Equal           0x50  0  cpu0
    Read SIO Should Equal           0x50  3  cpu1
    FIFO IRQ Should Equal           0  False
    FIFO IRQ Should Equal           1  True
    Write SIO                       0x54  0xdeadbeef
    Read SIO Should Equal           0x50  4  cpu0
    FIFO IRQ Should Equal           0  True
    FOR  ${word}  IN RANGE  8
        Read SIO Should Equal       0x58  ${word}  cpu1
    END
    FIFO IRQ Should Equal           1  False
    Read SIO Should Equal           0x50  6  cpu0
    Write SIO                       0x50  0
    Read SIO Should Equal           0x50  6  cpu0
    Write SIO                       0x50  4
    Read SIO Should Equal           0x50  2  cpu0
    FIFO IRQ Should Equal           0  False

Should Keep Underflow Sticky And Core Local
    Create Machine
    Read SIO Should Equal           0x58  0  cpu1
    Read SIO Should Equal           0x50  10  cpu1
    Read SIO Should Equal           0x50  2  cpu0
    FIFO IRQ Should Equal           1  True
    Write SIO                       0x54  0x12345678
    Read SIO Should Equal           0x58  0x12345678  cpu1
    Read SIO Should Equal           0x50  10  cpu1
    Write SIO                       0x50  8  cpu0
    Read SIO Should Equal           0x50  10  cpu1
    Write SIO                       0x50  8  cpu1
    FIFO IRQ Should Equal           1  False

Should Reset Queues Errors And Spinlocks
    Create Machine
    Write SIO                       0x54  0x12345678
    Read SIO Should Equal           0x58  0  cpu0
    Read SIO Should Equal           0x17c  0x80000000
    Execute Command                 sio Reset
    Read SIO Should Equal           0x50  2  cpu0
    Read SIO Should Equal           0x50  2  cpu1
    Read SIO Should Equal           0x5c  0
    FIFO IRQ Should Equal           0  False
    FIFO IRQ Should Equal           1  False

Should Claim Spinlocks Atomically Across Cores
    Create Machine
    Read SIO Should Equal           0x100  1  cpu0
    Read SIO Should Equal           0x100  0  cpu1
    Read SIO Should Equal           0x5c  1  cpu1
    Write SIO                       0x100  0  cpu1
    Read SIO Should Equal           0x100  1  cpu1
    Read SIO Should Equal           0x100  0  cpu0
    Read SIO Should Equal           0x17c  0x80000000  cpu0
    Read SIO Should Equal           0x5c  0x80000001

Should Maintain GPIO Output And Enable Independently
    Create Machine
    Write SIO                       0x14  0x2000001
    Read SIO Should Equal           0x10  0x2000001
    Read SIO Should Equal           0x20  0
    Write SIO                       0x24  0x2000000
    Write SIO                       0x18  1
    Write SIO                       0x1c  0x2000002
    Read SIO Should Equal           0x10  2
    Read SIO Should Equal           0x20  0x2000000
    Write SIO                       0x28  0x2000000
    Read SIO Should Equal           0x20  0

Should Complete Division In Eight System Clock Cycles
    Create Machine
    # At 1 MHz, completion is observable across individual microseconds.
    Execute Command                 sio Frequency 1000000
    Write SIO                       0x60  23
    Write SIO                       0x64  5
    Read SIO Should Equal           0x78  2
    Execute Command                 emulation RunFor "0.000007"
    Read SIO Should Equal           0x78  2
    Execute Command                 emulation RunFor "0.000001"
    Read SIO Should Equal           0x78  3
    Read SIO Should Equal           0x74  3
    Read SIO Should Equal           0x78  3
    Read SIO Should Equal           0x70  4
    Read SIO Should Equal           0x78  1

Should Bank Divider Operands And Results Per Core
    Create Machine
    Write SIO                       0x60  23  cpu0
    Write SIO                       0x64  5  cpu0
    Write SIO                       0x68  0xffffffe9  cpu1
    Write SIO                       0x6c  5  cpu1
    Execute Command                 emulation RunFor "0.000001"
    Read SIO Should Equal           0x60  23  cpu0
    Read SIO Should Equal           0x60  0xffffffe9  cpu1
    Read SIO Should Equal           0x74  3  cpu0
    Read SIO Should Equal           0x70  4  cpu0
    Read SIO Should Equal           0x74  0xfffffffd  cpu1
    Read SIO Should Equal           0x70  0xfffffffc  cpu1

Should Handle Divider Zero And Signed Overflow
    Create Machine
    Write SIO                       0x60  17
    Write SIO                       0x64  0
    Execute Command                 emulation RunFor "0.000001"
    Read SIO Should Equal           0x74  17
    Read SIO Should Equal           0x70  0xffffffff
    Write SIO                       0x68  0xfffffff0
    Write SIO                       0x6c  0
    Execute Command                 emulation RunFor "0.000001"
    Read SIO Should Equal           0x74  0xfffffff0
    Read SIO Should Equal           0x70  1
    Write SIO                       0x68  0x80000000
    Write SIO                       0x6c  0xffffffff
    Execute Command                 emulation RunFor "0.000001"
    Read SIO Should Equal           0x74  0
    Read SIO Should Equal           0x70  0x80000000

Should Cancel Divider Operation When Restoring Results
    Create Machine
    Write SIO                       0x60  23
    Write SIO                       0x64  5
    Write SIO                       0x74  0x12345678
    Write SIO                       0x70  0xabcdef01
    Read SIO Should Equal           0x78  3
    Execute Command                 emulation RunFor "0.000001"
    Read SIO Should Equal           0x74  0x12345678
    Read SIO Should Equal           0x70  0xabcdef01
