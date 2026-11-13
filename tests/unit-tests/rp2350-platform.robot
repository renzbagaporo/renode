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

Should Describe The RP2354B On The Metalclaw Carrier
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescription @platforms/boards/metalclaw_pico_rp2.repl
    Execute Command                 cpu0 IsHalted true
    Execute Command                 cpu1 IsHalted true
    # SYSINFO.PACKAGE_SEL is 0 for QFN-80.
    ${package}=                     Execute Command  sysbus ReadDoubleWord 0x40000004
    Should Be Equal As Integers     ${package.strip()}  0
    # All 48 bank 0 GPIOs are bonded: GPIO47_CTRL resets to FUNCSEL null.
    ${ctrl}=                        Execute Command  sysbus ReadDoubleWord 0x4002817c
    Should Be Equal As Integers     ${ctrl.strip()}  0x1f
    # The in-package flash identifies as a 2 MiB W25Q16 (JEDEC EF 40 15).
    Execute Command                 sysbus WriteDoubleWord 0x400d0000 0x01800005
    FOR  ${byte}  IN  0x9f  0  0  0
        Execute Command             sysbus WriteDoubleWord 0x400d0004 ${byte}
    END
    Execute Command                 emulation RunFor "0.0001"
    FOR  ${expected}  IN  0xff  0xef  0x40  0x15
        ${value}=                   Execute Command  sysbus ReadDoubleWord 0x400d0008
        Should Be Equal As Integers  ${value.strip()}  ${expected}
    END
