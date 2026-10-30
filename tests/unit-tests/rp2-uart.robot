*** Keywords ***
Check UART Mapping
    [Arguments]                     ${board}  ${address}  ${resets}  ${reset_bit}  ${irq}  ${uart}
    ${flags_address}=               Evaluate  int($address, 0) + 0x18
    ${control_address}=             Evaluate  int($address, 0) + 0x30
    ${control_set_address}=         Evaluate  int($address, 0) + 0x2030
    ${mask_address}=                Evaluate  int($address, 0) + 0x38
    ${reset_clear_address}=         Evaluate  int($resets, 0) + 0x3000
    ${reset_mask}=                  Evaluate  1 << int($reset_bit)
    ${irq_mask}=                    Evaluate  1 << int($irq)
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @platforms/boards/${board}.repl
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    ${flags}=                       Execute Command  sysbus ReadDoubleWord ${flags_address}
    Should Be Equal As Integers      ${flags.strip()}  0x90
    # Held reset inhibits writes until this controller's reset line is released.
    Execute Command                 sysbus WriteDoubleWord ${control_address} 0x301
    ${control}=                     Execute Command  sysbus ReadDoubleWord ${control_address}
    Should Be Equal As Integers      ${control.strip()}  0x300
    Execute Command                 sysbus WriteDoubleWord ${reset_clear_address} ${reset_mask}
    Execute Command                 sysbus WriteDoubleWord ${control_set_address} 1
    ${control}=                     Execute Command  sysbus ReadDoubleWord ${control_address}
    Should Be Equal As Integers      ${control.strip()}  0x301
    # CTS is a real modem source; the combined interrupt reaches both NVICs.
    Execute Command                 sysbus WriteDoubleWord ${mask_address} 2
    Execute Command                 ${uart} OnGPIO 0 false
    FOR  ${core}  IN  cpu0  cpu1
        ${pending}=                 Execute Command  sysbus ReadDoubleWord 0xe000e200 ${core}
        ${bank}=                    Execute Command  sysbus ReadDoubleWord 0xe000e204 ${core}
        ${actual}=                  Evaluate  (int($pending.strip(), 0) | (int($bank.strip(), 0)<<32)) & $irq_mask
        Should Be Equal As Integers  ${actual}  ${irq_mask}
    END

*** Test Cases ***
Should Map Pico UART0 With Reset And Both Interrupts
    Check UART Mapping              raspberry_pi_pico  0x40034000  0x4000c000  22  20  uart0

Should Map Pico UART1 With Reset And Both Interrupts
    Check UART Mapping              raspberry_pi_pico  0x40038000  0x4000c000  23  21  uart1

Should Map Pico2 UART0 With Reset And Both Interrupts
    Check UART Mapping              raspberry_pi_pico2  0x40070000  0x40020000  26  33  uart0

Should Map Pico2 UART1 With Reset And Both Interrupts
    Check UART Mapping              raspberry_pi_pico2  0x40078000  0x40020000  27  34  uart1
