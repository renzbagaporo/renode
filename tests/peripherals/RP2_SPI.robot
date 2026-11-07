*** Variables ***
${SPI}                              0x4003c000
${PLATFORM}                         SEPARATOR=\n
...  gpio: GPIOPort.RP2_GPIOBank0 @ sysbus 0x40014000
...  spi0: SPI.RP2_SPI @ sysbus 0x4003c000
...  ${SPACE*4}gpio: gpio
...  ${SPACE*4}index: 0
...  ${SPACE*4}frequency: 125000000

*** Keywords ***
Create SPI Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""

Select SPI Function
    [Arguments]                     ${pin}
    # IO_BANK0 GPIOn_CTRL.FUNCSEL = 1 (SPI)
    ${offset}=                      Evaluate  0x40014004 + 8 * ${pin}
    Execute Command                 sysbus WriteDoubleWord ${offset} 1

Wire TX To RX
    # SPI0 TX on GP3 drives SPI0 RX on GP0; SCK on GP2.
    Execute Command                 emulation CreateDigitalWire "data" false
    Execute Command                 data Connect gpio 3
    Execute Command                 data Connect gpio 0
    Select SPI Function             0
    Select SPI Function             2
    Select SPI Function             3

Configure SPI
    [Arguments]                     ${cr0}  ${prescale}  ${cr1}=0x2
    Execute Command                 sysbus WriteDoubleWord ${SPI} ${cr0}
    ${cpsr}=                        Evaluate  ${SPI} + 0x10
    Execute Command                 sysbus WriteDoubleWord ${cpsr} ${prescale}
    ${cr1_reg}=                     Evaluate  ${SPI} + 0x4
    Execute Command                 sysbus WriteDoubleWord ${cr1_reg} ${cr1}

Send Frames
    [Arguments]                     @{values}
    ${dr}=                          Evaluate  ${SPI} + 0x8
    FOR  ${value}  IN  @{values}
        Execute Command             sysbus WriteDoubleWord ${dr} ${value}
    END

Received Frame Should Be
    [Arguments]                     ${expected}
    ${dr}=                          Evaluate  ${SPI} + 0x8
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${dr}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Status Should Be
    [Arguments]                     ${mask}  ${expected}
    ${sr}=                          Evaluate  ${SPI} + 0xc
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${sr}
    ${bits}=                        Evaluate  int(${value.strip()}) & ${mask}
    Should Be Equal As Integers      ${bits}  ${expected}

Loop Back Frames In Mode
    [Arguments]                     ${cr0}
    Create SPI Machine
    Wire TX To RX
    Configure SPI                   ${cr0}  2
    Send Frames                     0x8001  0x1234  0xfedc
    Execute Command                 emulation RunFor "0.0001"
    Received Frame Should Be        0x8001
    Received Frame Should Be        0x1234
    Received Frame Should Be        0xfedc
    # RNE clear, TFE set, BSY clear
    Status Should Be                0x15  0x1

*** Test Cases ***
Should Loop Back 8-Bit Frames Through Pins
    Create SPI Machine
    Wire TX To RX
    # DSS=7 (8 bits), Motorola mode 0, SCR=0; CPSDVSR=2
    Configure SPI                   0x7  2
    Send Frames                     0xa5  0x3c  0x00  0xff
    Execute Command                 emulation RunFor "0.0001"
    Received Frame Should Be        0xa5
    Received Frame Should Be        0x3c
    Received Frame Should Be        0x00
    Received Frame Should Be        0xff

Should Loop Back 16-Bit Frames In Mode 0
    Loop Back Frames In Mode        0x0f

Should Loop Back 16-Bit Frames In Mode 1
    Loop Back Frames In Mode        0x8f

Should Loop Back 16-Bit Frames In Mode 2
    Loop Back Frames In Mode        0x4f

Should Loop Back 16-Bit Frames In Mode 3
    Loop Back Frames In Mode        0xcf

Should Loop Back Internally
    Create SPI Machine
    # LBM | SSE
    Configure SPI                   0x7  2  0x3
    Send Frames                     0x5a
    Execute Command                 emulation RunFor "0.0001"
    Received Frame Should Be        0x5a

Should Clock A Frame At The Configured Rate
    Create SPI Machine
    Execute Command                 emulation SetGlobalQuantum "0.000001"
    Wire TX To RX
    # 125 MHz / (250 * (1 + 4)) = 100 kHz, so an 8-bit frame takes 80 us.
    Configure SPI                   0x407  250
    Send Frames                     0x81
    Execute Command                 emulation RunFor "0.00007"
    Status Should Be                0x14  0x10
    Execute Command                 emulation RunFor "0.00002"
    Status Should Be                0x14  0x4
    Received Frame Should Be        0x81

Should Sample Receive Data After The Input Delay
    Create SPI Machine
    Wire TX To RX
    # A 10 us bit period and a 10 us input delay read each next transmitted bit.
    Execute Command                 spi0 InputDelayNanoseconds 10000
    Configure SPI                   0x407  250
    Send Frames                     0xa5  0xa5
    Execute Command                 emulation RunFor "0.0003"
    Received Frame Should Be        0x4b
    Received Frame Should Be        0x4b

Should Report Receive Overrun
    Create SPI Machine
    Configure SPI                   0x7  2  0x3
    Send Frames                     1  2  3  4  5  6  7  8
    Execute Command                 emulation RunFor "0.0001"
    Send Frames                     9  10
    Execute Command                 emulation RunFor "0.0001"
    # RORRIS
    ${ris}=                         Execute Command  sysbus ReadDoubleWord 0x4003c018
    Should Be True                  (int(${ris.strip()}) & 1) != 0
    Received Frame Should Be        1
