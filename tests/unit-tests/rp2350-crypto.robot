*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  sha: Miscellaneous.RP2350_SHA256 @ sysbus 0x400f8000
...  trng: Miscellaneous.RP2350_TRNG @ sysbus 0x400f0000

*** Keywords ***
Create Crypto Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

*** Test Cases ***
Should Hash Padded ABC Block AndDelayValidUntilCompressionFinishes
    Create Crypto Machine
    Execute Command                 sysbus WriteDoubleWord 0x400f8000 0x1201
    Execute Command                 sysbus WriteDoubleWord 0x400f8004 0x80636261
    FOR  ${i}  IN RANGE  14
        Execute Command             sysbus WriteDoubleWord 0x400f8004 0
    END
    Execute Command                 sysbus WriteDoubleWord 0x400f8004 0x18000000
    Read Should Equal               0x400f8000  0x1200
    Execute Command                 emulation RunFor "0.000009"
    Read Should Equal               0x400f8000  0x1200
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x400f8000  0x1206
    Read Should Equal               0x400f8008  0xba7816bf
    Read Should Equal               0x400f800c  0x8f01cfea
    Read Should Equal               0x400f8010  0x414140de
    Read Should Equal               0x400f8014  0x5dae2223
    Read Should Equal               0x400f8018  0xb00361a3
    Read Should Equal               0x400f801c  0x96177a9c
    Read Should Equal               0x400f8020  0xb410ff61
    Read Should Equal               0x400f8024  0xf20015ad

Should Keep Entropy Invalid Until192SamplesAndRestartAfterLastWord
    Create Crypto Machine
    Execute Command                 sysbus WriteDoubleWord 0x400f0130 0
    Execute Command                 sysbus WriteDoubleWord 0x400f0138 0xe
    Execute Command                 sysbus WriteDoubleWord 0x400f012c 1
    Read Should Equal               0x400f01b8  1
    Read Should Equal               0x400f0110  0
    Execute Command                 emulation RunFor "0.000031"
    Read Should Equal               0x400f01b8  1
    Execute Command                 emulation RunFor "0.000001"
    Read Should Equal               0x400f01b8  0
    Read Should Equal               0x400f0104  1
    Read Should Equal               0x400f0110  1
    Execute Command                 sysbus ReadDoubleWord 0x400f0128
    Read Should Equal               0x400f01b8  1
    Read Should Equal               0x400f0110  0
    Execute Command                 sysbus WriteDoubleWord 0x400f012c 0
    Read Should Equal               0x400f01b8  0
