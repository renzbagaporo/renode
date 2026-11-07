*** Variables ***
${CONTROLLER}                       0x40044000
${TARGET}                           0x40048000
${PLATFORM}                         SEPARATOR=\n
...  gpio: GPIOPort.RP2_GPIOBank0 @ sysbus 0x40014000
...  i2c0: I2C.RP2_I2C @ sysbus 0x40044000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}index: 0
...  ${SPACE*4}frequency: 125000000
...  i2c1: I2C.RP2_I2C @ sysbus 0x40048000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}index: 1
...  ${SPACE*4}frequency: 125000000

*** Keywords ***
Write Register
    [Arguments]                     ${base}  ${offset}  ${value}
    ${address}=                     Evaluate  ${base} + ${offset}
    Execute Command                 sysbus WriteDoubleWord ${address} ${value}

Read Register
    [Arguments]                     ${base}  ${offset}
    ${address}=                     Evaluate  ${base} + ${offset}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    ${value}=                       Evaluate  int(${value.strip()})
    RETURN                          ${value}

Register Should Be
    [Arguments]                     ${base}  ${offset}  ${expected}
    ${value}=                       Read Register  ${base}  ${offset}
    Should Be Equal As Integers     ${value}  ${expected}

Bits Should Be
    [Arguments]                     ${base}  ${offset}  ${mask}  ${expected}
    ${value}=                       Read Register  ${base}  ${offset}
    ${bits}=                        Evaluate  ${value} & ${mask}
    Should Be Equal As Integers     ${bits}  ${expected}

Select Function
    [Arguments]                     ${pin}  ${function}
    # IO_BANK0 GPIOn_CTRL.FUNCSEL
    ${offset}=                      Evaluate  0x40014004 + 8 * ${pin}
    Execute Command                 sysbus WriteDoubleWord ${offset} ${function}

Create I2C Machine
    [Arguments]                     ${quantum}=0.00001
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 emulation SetGlobalQuantum "${quantum}"
    # I2C0 on GP4/GP5 and I2C1 on GP6/GP7 share one bus.
    Execute Command                 emulation CreateDelayedI2CBus "bus" 50
    Execute Command                 bus Connect i2c0 4 5
    Execute Command                 bus Connect i2c1 6 7
    FOR  ${pin}  IN RANGE  4  8
        Select Function             ${pin}  3
    END
    # Controller: MASTER_MODE, standard speed, RESTART_EN, SLAVE_DISABLE,
    # target 0x76; SCL high 500 + 7 + 7 and low 651 cycles of 125 MHz.
    Write Register                  ${CONTROLLER}  0x00  0x63
    Write Register                  ${CONTROLLER}  0x04  0x76
    Write Register                  ${CONTROLLER}  0x14  500
    Write Register                  ${CONTROLLER}  0x18  650
    Write Register                  ${CONTROLLER}  0x6c  1
    # Target: fast speed, RX_FIFO_FULL_HLD_CTRL, address 0x76.
    Write Register                  ${TARGET}  0x00  0x204
    Write Register                  ${TARGET}  0x08  0x76
    Write Register                  ${TARGET}  0x6c  1

*** Test Cases ***
Should Write Bytes To A Target
    Create I2C Machine
    Write Register                  ${CONTROLLER}  0x10  0x10
    # Data 0x20 with STOP
    Write Register                  ${CONTROLLER}  0x10  0x220
    Execute Command                 emulation RunFor "0.002"
    Register Should Be              ${TARGET}  0x78  2
    # FIRST_DATA_BYTE marks the first byte after the address.
    Register Should Be              ${TARGET}  0x10  0x810
    Register Should Be              ${TARGET}  0x10  0x20
    # START_DET and STOP_DET on the target; STOP_DET and no TX_ABRT on the controller.
    Bits Should Be                  ${TARGET}  0x34  0x600  0x600
    Bits Should Be                  ${CONTROLLER}  0x34  0x240  0x200
    Bits Should Be                  ${CONTROLLER}  0x70  0x21  0

Should Read Bytes Queued By The Target
    Create I2C Machine
    Write Register                  ${TARGET}  0x10  0xab
    Write Register                  ${TARGET}  0x10  0xcd
    Write Register                  ${CONTROLLER}  0x10  0x100
    # Read with STOP
    Write Register                  ${CONTROLLER}  0x10  0x300
    Execute Command                 emulation RunFor "0.003"
    Register Should Be              ${CONTROLLER}  0x78  2
    Register Should Be              ${CONTROLLER}  0x10  0x8ab
    Register Should Be              ${CONTROLLER}  0x10  0xcd
    # RX_DONE without RD_REQ on the target, which had the data ready.
    Bits Should Be                  ${TARGET}  0x34  0xa0  0x80

Should Hold A Read Until The Target Answers
    Create I2C Machine
    Write Register                  ${CONTROLLER}  0x10  0x300
    Execute Command                 emulation RunFor "0.001"
    # RD_REQ on the target while the controller waits with MST_ACTIVITY.
    Bits Should Be                  ${TARGET}  0x34  0x20  0x20
    Register Should Be              ${CONTROLLER}  0x78  0
    Bits Should Be                  ${CONTROLLER}  0x70  0x20  0x20
    Read Register                   ${TARGET}  0x50
    Write Register                  ${TARGET}  0x10  0x5a
    Execute Command                 emulation RunFor "0.001"
    Register Should Be              ${CONTROLLER}  0x10  0x85a
    Bits Should Be                  ${CONTROLLER}  0x70  0x20  0

Should Write Then Read With A Repeated Start
    Create I2C Machine
    Write Register                  ${TARGET}  0x10  0x50
    Write Register                  ${CONTROLLER}  0x10  0xd0
    # RESTART, read and STOP
    Write Register                  ${CONTROLLER}  0x10  0x700
    Execute Command                 emulation RunFor "0.003"
    Register Should Be              ${TARGET}  0x10  0x8d0
    # RESTART_DET on the target
    Bits Should Be                  ${TARGET}  0x34  0x1000  0x1000
    Register Should Be              ${CONTROLLER}  0x10  0x850

Should Abort When No Target Acknowledges The Address
    Create I2C Machine
    Write Register                  ${CONTROLLER}  0x6c  0
    Write Register                  ${CONTROLLER}  0x04  0x50
    Write Register                  ${CONTROLLER}  0x6c  1
    Write Register                  ${CONTROLLER}  0x10  0x211
    Execute Command                 emulation RunFor "0.001"
    # TX_ABRT and STOP_DET; ABRT_7B_ADDR_NOACK
    Bits Should Be                  ${CONTROLLER}  0x34  0x240  0x240
    Bits Should Be                  ${CONTROLLER}  0x80  0x1  0x1
    Read Register                   ${CONTROLLER}  0x54
    Register Should Be              ${CONTROLLER}  0x80  0
    Bits Should Be                  ${CONTROLLER}  0x34  0x40  0
    Register Should Be              ${TARGET}  0x78  0

Should Not Answer Through Unrouted Pins
    Create I2C Machine
    # GP6 back to SIO detaches the target.
    Select Function                 6  5
    Write Register                  ${CONTROLLER}  0x10  0x211
    Execute Command                 emulation RunFor "0.001"
    Bits Should Be                  ${CONTROLLER}  0x80  0x1  0x1
    Bits Should Be                  ${TARGET}  0x34  0x400  0

Should Deliver The Address After The Bits And The Latency
    Create I2C Machine              quantum=0.000001
    Write Register                  ${CONTROLLER}  0x10  0x211
    # START and eight address bits at 9.32 us per bit end at 79.2 us; the
    # target sees them 50 us later.
    Execute Command                 emulation RunFor "0.000125"
    Bits Should Be                  ${TARGET}  0x34  0x400  0
    Execute Command                 emulation RunFor "0.00001"
    Bits Should Be                  ${TARGET}  0x34  0x400  0x400
