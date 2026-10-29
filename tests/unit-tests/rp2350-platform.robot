*** Test Cases ***
Should Discover Separate Working FPB Units On Both Pico2 Cores
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @platforms/boards/raspberry_pi_pico2.repl
    Execute Command                 emulation CreateDigitalWire "swclk" false
    Execute Command                 swclk Connect debug_port 0
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    FOR  ${core}  IN  cpu0  cpu1
        ${ctrl}=                    Execute Command  sysbus ReadDoubleWord 0xe0002000 ${core}
        Should Be Equal As Integers  ${ctrl.strip()}  0x10000080
        ${entry}=                   Execute Command  sysbus ReadDoubleWord 0xe00ff004 ${core}
        Should Be Equal As Integers  ${entry.strip()}  0xfff03003
    END
    Execute Command                 sysbus WriteDoubleWord 0xe0002000 3 cpu0
    ${core0}=                       Execute Command  sysbus ReadDoubleWord 0xe0002000 cpu0
    ${core1}=                       Execute Command  sysbus ReadDoubleWord 0xe0002000 cpu1
    Should Be Equal As Integers      ${core0.strip()}  0x10000081
    Should Be Equal As Integers      ${core1.strip()}  0x10000080
