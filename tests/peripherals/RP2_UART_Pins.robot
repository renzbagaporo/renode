*** Variables ***
${UART0}                            0x40034000
${UART1}                            0x40038000
${PLATFORM}                         SEPARATOR=\n
...  gpio: GPIOPort.RP2_GPIOBank0 @ sysbus 0x40014000
...  uart0: UART.RP2_UART @ sysbus 0x40034000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}index: 0
...  ${SPACE*4}frequency: 125000000
...  uart1: UART.RP2_UART @ sysbus 0x40038000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}index: 1
...  ${SPACE*4}frequency: 125000000

${RP2350_PLATFORM}                  SEPARATOR=\n
...  gpio: GPIOPort.RP2_GPIOBank0 @ sysbus 0x40014000
...  ${SPACE*4}rp2350: true
...  uart0: UART.RP2_UART @ sysbus 0x40034000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}index: 0
...  ${SPACE*4}rp2350: true
...  ${SPACE*4}frequency: 125000000
...  uart1: UART.RP2_UART @ sysbus 0x40038000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}index: 1
...  ${SPACE*4}rp2350: true
...  ${SPACE*4}frequency: 125000000

*** Keywords ***
Create UART Machine
    [Arguments]                     ${name}
    Execute Command                 mach create "${name}"
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""

Select UART Function
    [Arguments]                     ${pin}  ${function}=2
    # IO_BANK0 GPIOn_CTRL.FUNCSEL = 2 (UART) or 11 (RP2350 UART_AUX)
    ${offset}=                      Evaluate  0x40014004 + 8 * ${pin}
    Execute Command                 sysbus WriteDoubleWord ${offset} ${function}

Configure UART
    [Arguments]                     ${base}  ${ibrd}  ${fbrd}  ${lcr}=0x70
    ${ibrd_reg}=                    Evaluate  ${base} + 0x24
    ${fbrd_reg}=                    Evaluate  ${base} + 0x28
    ${lcr_reg}=                     Evaluate  ${base} + 0x2c
    ${cr_reg}=                      Evaluate  ${base} + 0x30
    Execute Command                 sysbus WriteDoubleWord ${ibrd_reg} ${ibrd}
    Execute Command                 sysbus WriteDoubleWord ${fbrd_reg} ${fbrd}
    Execute Command                 sysbus WriteDoubleWord ${lcr_reg} ${lcr}
    Execute Command                 sysbus WriteDoubleWord ${cr_reg} 0x301

Send Bytes
    [Arguments]                     ${base}  @{values}
    FOR  ${value}  IN  @{values}
        Execute Command             sysbus WriteDoubleWord ${base} ${value}
    END

Received Data Should Be
    [Arguments]                     ${base}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${base}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Receive FIFO Should Be Empty
    [Arguments]                     ${base}
    ${fr_reg}=                      Evaluate  ${base} + 0x18
    ${flags}=                       Execute Command  sysbus ReadDoubleWord ${fr_reg}
    Should Be True                  (int(${flags.strip()}) & 0x10) != 0

Wire UART0 TX To UART1 RX
    Execute Command                 emulation CreateDigitalWire "line" true
    Execute Command                 line Connect gpio 0
    Execute Command                 line Connect gpio 5
    Select UART Function            0
    Select UART Function            5

*** Test Cases ***
Should Transfer Bytes Between UART Pins
    Create UART Machine             board
    Wire UART0 TX To UART1 RX
    # 115200 baud at 125 MHz
    Configure UART                  ${UART0}  67  52
    Configure UART                  ${UART1}  67  52
    Send Bytes                      ${UART0}  0x5a  0xc3  0x00  0xff
    Execute Command                 emulation RunFor "0.0005"
    Received Data Should Be         ${UART1}  0x5a
    Received Data Should Be         ${UART1}  0xc3
    Received Data Should Be         ${UART1}  0x00
    Received Data Should Be         ${UART1}  0xff
    Receive FIFO Should Be Empty    ${UART1}

Should Receive A Frame Only After Its Bit Time
    Create UART Machine             board
    Execute Command                 emulation SetGlobalQuantum "0.000001"
    Wire UART0 TX To UART1 RX
    Configure UART                  ${UART0}  67  52
    Configure UART                  ${UART1}  67  52
    Send Bytes                      ${UART0}  0x41
    # One 8N1 frame at 115200 baud takes 86.8 us; the stop bit is sampled at 82.5 us.
    Execute Command                 emulation RunFor "0.00008"
    Receive FIFO Should Be Empty    ${UART1}
    Execute Command                 emulation RunFor "0.00001"
    Received Data Should Be         ${UART1}  0x41

Should Report Parity Errors
    Create UART Machine             board
    Wire UART0 TX To UART1 RX
    # Even parity on the transmitter, odd on the receiver.
    Configure UART                  ${UART0}  67  52  0x76
    Configure UART                  ${UART1}  67  52  0x72
    Send Bytes                      ${UART0}  0x03
    Execute Command                 emulation RunFor "0.0002"
    # DR carries the character with PE (bit 9).
    Received Data Should Be         ${UART1}  0x203

Should Report A Break
    Create UART Machine             board
    Wire UART0 TX To UART1 RX
    Configure UART                  ${UART0}  67  52
    Configure UART                  ${UART1}  67  52
    # LCR_H.BRK holds TX low for longer than a frame.
    Execute Command                 sysbus WriteDoubleWord 0x4003402c 0x71
    Execute Command                 emulation RunFor "0.0002"
    Execute Command                 sysbus WriteDoubleWord 0x4003402c 0x70
    Execute Command                 emulation RunFor "0.0001"
    # BE (bit 10) and FE (bit 8) with a zero character.
    Received Data Should Be         ${UART1}  0x500

Should Transfer A Fast Burst Between Machines
    Create UART Machine             harness
    Create UART Machine             dut
    Execute Command                 emulation SetGlobalQuantum "0.0001"
    Execute Command                 emulation CreateDelayedDigitalWire "line" true 300
    Execute Command                 mach set "harness"
    Execute Command                 line Connect gpio 0
    Select UART Function            0
    # 921600 baud at 125 MHz
    Configure UART                  ${UART0}  8  31
    Execute Command                 mach set "dut"
    Execute Command                 line Connect gpio 1
    Select UART Function            1
    Configure UART                  ${UART0}  8  31
    Execute Command                 mach set "harness"
    Send Bytes                      ${UART0}  0x01  0x80  0x55  0xaa  0xfe  0x7f  0x10  0x08
    Execute Command                 emulation RunFor "0.001"
    Execute Command                 mach set "dut"
    FOR  ${value}  IN  0x01  0x80  0x55  0xaa  0xfe  0x7f  0x10  0x08
        Received Data Should Be     ${UART0}  ${value}
    END
    Receive FIFO Should Be Empty    ${UART0}

Should Overrun The Receive FIFO Between Machines
    Create UART Machine             harness
    Create UART Machine             dut
    Execute Command                 emulation SetGlobalQuantum "0.0001"
    Execute Command                 emulation CreateDelayedDigitalWire "line" true 300
    Execute Command                 mach set "harness"
    Execute Command                 line Connect gpio 0
    Select UART Function            0
    Configure UART                  ${UART0}  67  52
    Execute Command                 mach set "dut"
    Execute Command                 line Connect gpio 1
    Select UART Function            1
    Configure UART                  ${UART0}  67  52
    Execute Command                 mach set "harness"
    FOR  ${index}  IN RANGE  32
        Send Bytes                  ${UART0}  ${index}
    END
    Execute Command                 emulation RunFor "0.003"
    Send Bytes                      ${UART0}  0x80  0x81
    Execute Command                 emulation RunFor "0.003"
    Execute Command                 mach set "dut"
    # The FIFO keeps the first 32 characters; RSR.OE (bit 3) is set.
    ${rsr}=                         Execute Command  sysbus ReadDoubleWord 0x40034004
    Should Be True                  (int(${rsr.strip()}) & 8) != 0
    FOR  ${index}  IN RANGE  32
        Received Data Should Be     ${UART0}  ${index}
    END
    Receive FIFO Should Be Empty    ${UART0}

Should Transfer Bytes Over RP2350 UART_AUX Pins
    Execute Command                 mach create "board"
    Execute Command                 machine LoadPlatformDescriptionFromString """${RP2350_PLATFORM}"""
    # UART_AUX puts UART0 TX on its CTS pin (GPIO2) and UART1 RX on its RTS pin (GPIO7).
    Execute Command                 emulation CreateDigitalWire "line" true
    Execute Command                 line Connect gpio 2
    Execute Command                 line Connect gpio 7
    # RP2350 pads reset isolated with input disabled; release both.
    Execute Command                 gpio SetPadConfiguration 2 0x56
    Execute Command                 gpio SetPadConfiguration 7 0x56
    Select UART Function            2  11
    Select UART Function            7  11
    Configure UART                  ${UART0}  67  52
    Configure UART                  ${UART1}  67  52
    Send Bytes                      ${UART0}  0x5a  0xc3
    Execute Command                 emulation RunFor "0.0005"
    Received Data Should Be         ${UART1}  0x5a
    Received Data Should Be         ${UART1}  0xc3
    Receive FIFO Should Be Empty    ${UART1}
    # Function 2 on the same pins is CTS and RTS, which carry no data.
    Select UART Function            2
    Select UART Function            7
    Send Bytes                      ${UART0}  0x81
    Execute Command                 emulation RunFor "0.0005"
    Receive FIFO Should Be Empty    ${UART1}
