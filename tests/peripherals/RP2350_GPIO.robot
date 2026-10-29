*** Variables ***
${GPIO_PLATFORM}                    SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic0
...  cpu1: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}nvic: nvic1
...  ${SPACE*4}cpuId: 1
...  nvic0: IRQControllers.NVIC @ { sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu0 } }
...  ${SPACE*4}-> cpu0@0
...  nvic1: IRQControllers.NVIC @ { sysbus new Bus.BusPointRegistration { address: 0xe000e000; cpu: cpu1 } }
...  ${SPACE*4}-> cpu1@0
...  access: Miscellaneous.RP2350_AccessControl @ sysbus 0x40060000
...  gpio: GPIOPort.RP2_GPIOBank0 @ sysbus 0x40028000
...  ${SPACE*4}rp2350: true
...  ${SPACE*4}numberOfPins: @PINS@
...  ${SPACE*4}accessControl: access
...  pads: GPIOPort.RP2_PadsBank0 @ sysbus 0x40038000
...  ${SPACE*4}rp2350: true
...  ${SPACE*4}rp2350A2PadRemap: @REMAP@
...  ${SPACE*4}gpio: gpio

*** Keywords ***
Create GPIO Machine
    [Arguments]                     ${pins}=48  ${remap}=false
    Execute Command                 mach create
    ${platform}=                    Evaluate  $GPIO_PLATFORM.replace('@PINS@', str($pins)).replace('@REMAP@', str($remap))
    Execute Command                 machine LoadPlatformDescriptionFromString """${platform}"""
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true

GPIO Memory Should Equal
    [Arguments]                     ${address}  ${expected}  ${cpu}=cpu0
    ${actual}=                      Execute Command  sysbus ReadDoubleWord ${address} context=${cpu}
    Should Be Equal As Integers      ${actual.strip()}  ${expected}

GPIO IRQ Should Equal
    [Arguments]                     ${irq}  ${expected}
    ${actual}=                      Execute Command  gpio ${irq} IsSet
    Should Be Equal                 ${actual.strip()}  ${expected}

*** Test Cases ***
Should Filter Forced Non Secure Core Without Changing Its Architectural State
    Create GPIO Machine
    Execute Command                 sysbus WriteDoubleWord 0x40060004 0xacce0002 context=cpu0
    GPIO Memory Should Equal        0x40028004  0  cpu1
    GPIO Memory Should Equal        0x40028004  0x1f  cpu0
    Execute Command                 sysbus WriteDoubleWord 0x40060010 0x8000 context=cpu0
    GPIO Memory Should Equal        0x4002817c  0x1f  cpu1
    Execute Command                 sysbus WriteDoubleWord 0x4002817c 5 context=cpu1
    GPIO Memory Should Equal        0x4002817c  5
    ${secure}=                      Execute Command  cpu1 SecureState
    Should Be Equal                 ${secure.strip()}  True

Should Preserve Secure Interrupt Fields During Non Secure Writes
    Create GPIO Machine
    Execute Command                 sysbus WriteDoubleWord 0x40060010 0x8000 context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0x40028274 0x02000000 context=cpu0
    Execute Command                 cpu1 SecureState false
    Execute Command                 sysbus WriteDoubleWord 0x40028274 0xffffffff context=cpu1
    GPIO Memory Should Equal        0x40028274  0xf2000000
    GPIO Memory Should Equal        0x40028274  0xf0000000  cpu1
    GPIO IRQ Should Equal           Core0IRQ  True
    GPIO IRQ Should Equal           Core0NonSecureIRQ  True
    GPIO Memory Should Equal        0x4002820c  0x8000  cpu1
    GPIO Memory Should Equal        0x40028204  0  cpu1
    Execute Command                 sysbus WriteDoubleWord 0x40028274 0 context=cpu1
    GPIO IRQ Should Equal           Core0IRQ  True
    GPIO IRQ Should Equal           Core0NonSecureIRQ  False

Should Use Qfn60 A2 Pad Mask Remapping When Selected
    Create GPIO Machine             pins=30  remap=true
    Execute Command                 sysbus WriteDoubleWord 0x4006000c 0x100 context=cpu0
    Execute Command                 cpu1 SecureState false
    GPIO Memory Should Equal        0x40038004  0x116  cpu1
    GPIO Memory Should Equal        0x40028004  0  cpu1
    GPIO Memory Should Equal        0x40038024  0  cpu1
    GPIO Memory Should Equal        0x40028044  0x1f  cpu1

Should Disconnect Secure Peripheral From Non Secure GPIO
    Create GPIO Machine
    Execute Command                 sysbus WriteDoubleWord 0x4002817c 1 context=cpu0
    GPIO Memory Should Equal        0x4002817c  1
    Execute Command                 sysbus WriteDoubleWord 0x40060010 0x8000 context=cpu0
    GPIO Memory Should Equal        0x4002817c  0x1f
    Execute Command                 cpu1 SecureState false
    Execute Command                 sysbus WriteDoubleWord 0x4002817c 1 context=cpu1
    GPIO Memory Should Equal        0x4002817c  0x1f
    Execute Command                 sysbus WriteDoubleWord 0x40060094 0xacce00ff context=cpu0
    Execute Command                 sysbus WriteDoubleWord 0x4002817c 1 context=cpu1
    GPIO Memory Should Equal        0x4002817c  1
    Execute Command                 sysbus WriteDoubleWord 0x40060094 0xacce00fd context=cpu0
    GPIO Memory Should Equal        0x4002817c  0x1f
