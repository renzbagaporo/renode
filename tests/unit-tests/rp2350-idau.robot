*** Variables ***
${IDAU_PLATFORM}                    SEPARATOR=\n
...  cpu0: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "@TYPE@"
...  ${SPACE*4}enableTrustZone: true
...  ${SPACE*4}numberOfMPURegions: @MPU@
...  ${SPACE*4}nvic: nvic0
...  nvic0: IRQControllers.NVIC @ sysbus 0xe000e000
...  ${SPACE*4}-> cpu0@0
...  rom: Memory.MappedMemory @ sysbus 0
...  ${SPACE*4}size: 0x8000
...  ram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x4000
...  peripheralData: Memory.MappedMemory @ {sysbus 0x400e0000; sysbus 0x50100000; sysbus 0xd0000000}
...  ${SPACE*4}size: 0x1000

*** Keywords ***
Create IDAU Machine
    [Arguments]                     ${type}=cortex-m33-rp2350  ${mpu}=0
    Execute Command                 mach create
    ${platform}=                    Evaluate  $IDAU_PLATFORM.replace('@TYPE@', $type).replace('@MPU@', str($mpu))
    Execute Command                 machine LoadPlatformDescriptionFromString """${platform}"""
    Execute Command                 cpu0 IsHalted true
    Execute Command                 sysbus WriteDoubleWord 0 0x20004000
    Execute Command                 sysbus WriteDoubleWord 4 0x101
    Execute Command                 sysbus WriteDoubleWord 0xc 0x301
    Execute Command                 sysbus WriteDoubleWord 0x14 0x301
    Execute Command                 sysbus WriteDoubleWord 0x1c 0x301
    Execute Command                 sysbus WriteDoubleWord 0x100 0xbf00202a
    Execute Command                 sysbus WriteDoubleWord 0x300 0xe7fe2777
    Execute Command                 cpu0 VectorTableOffset 0
    Execute Command                 cpu0 SP 0x20004000
    Execute Command                 cpu0 PC 0x100
    Execute Command                 cpu0 IsHalted false
    Execute Command                 cpu0 Step
    Execute Command                 cpu0 SetRegister "R0" 0

Add Nonsecure SAU Region
    [Arguments]                     ${number}  ${base}  ${limit}
    Execute Command                 cpu0 SAURegionNumber ${number}
    Execute Command                 cpu0 SAURegionBaseAddress ${base}
    Execute Command                 cpu0 SAURegionLimitAddress ${{(int($limit, 0) & ~0x1f) | 1}}
    Execute Command                 cpu0 SAUControl 1

Register Should Equal
    [Arguments]                     ${register}  ${expected}
    ${value}=                       Execute Command  cpu0 GetRegister "${register}"
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Fault Bits Should Equal
    [Arguments]                     ${address}  ${mask}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address} cpu0
    ${masked}=                      Evaluate  int($value.strip(), 0) & int($mask, 0)
    Should Be Equal As Integers      ${masked}  ${expected}

*** Test Cases ***
Should Execute Exempt Arm ROM In Secure State Despite Nonsecure SAU
    Create IDAU Machine
    Add Nonsecure SAU Region        0  0  0x7fff
    Execute Command                 cpu0 PC 0x100
    Execute Command                 cpu0 Step
    Register Should Equal           R0  42
    Fault Bits Should Equal         0xe000ede4  0xff  0

Should Retain Generic CortexM SAU Attribution
    Create IDAU Machine             cortex-m33
    Execute Command                 sysbus WriteDoubleWord 0xc 0x20000301
    Execute Command                 sysbus WriteDoubleWord 0x1c 0x20000301
    Execute Command                 sysbus WriteDoubleWord 0x20000300 0xe7fe2777
    Add Nonsecure SAU Region        0  0  0x7fff
    Execute Command                 cpu0 PC 0x100
    Execute Command                 cpu0 Step
    Register Should Equal           R0  0
    Fault Bits Should Equal         0xe000ede4  0x10  0x10

Should Execute Exempt Arm ROM In Nonsecure State Despite Secure SAU
    Create IDAU Machine
    Add Nonsecure SAU Region        0  0x20000000  0x20003fff
    Execute Command                 cpu0 SetRegister "MSPNS" 0x20004000
    Execute Command                 cpu0 SecureState false
    Execute Command                 cpu0 PC 0x100
    Execute Command                 cpu0 Step
    Register Should Equal           R0  42

Should Exempt USB ROM Data Loads Without Making Its Instructions Exempt
    Create IDAU Machine
    Add Nonsecure SAU Region        0  0x20000000  0x20003fff
    Execute Command                 sysbus WriteDoubleWord 0x20000100 0xbf006808
    Execute Command                 sysbus WriteDoubleWord 0x5000 0x12345678
    Execute Command                 cpu0 SetRegister "MSPNS" 0x20004000
    Execute Command                 cpu0 SetRegister "R1" 0x5000
    Execute Command                 cpu0 SecureState false
    Execute Command                 cpu0 PC 0x20000100
    Execute Command                 cpu0 Step
    Register Should Equal           R0  0x12345678
    # The SAU still marks this code Secure. A prior data access must not
    # populate an executable TLB entry that bypasses instruction attribution.
    Execute Command                 sysbus WriteDoubleWord 0x5000 0xbf00202a
    Execute Command                 cpu0 SetRegister "R0" 0
    Execute Command                 cpu0 PC 0x5000
    Execute Command                 cpu0 Step
    Register Should Equal           R0  0
    Fault Bits Should Equal         0xe000ede4  1  1

Should Enter Secure State Through Fixed Gateway With Nonsecure SAU
    Create IDAU Machine
    Add Nonsecure SAU Region        0  0  0x7fff
    Add Nonsecure SAU Region        1  0x20000000  0x20003fff
    Execute Command                 sysbus WriteDoubleWord 0x7f00 0xe97fe97f
    Execute Command                 cpu0 SetRegister "MSPNS" 0x20004000
    Execute Command                 cpu0 SecureState false
    Execute Command                 cpu0 PC 0x7f00
    Execute Command                 cpu0 Step
    ${secure}=                      Execute Command  cpu0 SecureState
    Should Be True                  ${secure}
    Fault Bits Should Equal         0xe000ede4  0xff  0

Should Reject Nonsecure Data Reads Of Fixed Gateway
    Create IDAU Machine
    Add Nonsecure SAU Region        0  0  0x7fff
    Add Nonsecure SAU Region        1  0x20000000  0x20003fff
    Execute Command                 sysbus WriteDoubleWord 0x20000100 0xbf006808
    Execute Command                 sysbus WriteDoubleWord 0x7f00 0x12345678
    Execute Command                 cpu0 SetRegister "MSPNS" 0x20004000
    Execute Command                 cpu0 SetRegister "R1" 0x7f00
    Execute Command                 cpu0 SecureState false
    Execute Command                 cpu0 PC 0x20000100
    Execute Command                 cpu0 Step
    Register Should Equal           R0  0
    Fault Bits Should Equal         0xe000ede4  0x48  0x48

Should Preserve Fixed Attribution Across A Core Reset
    Create IDAU Machine
    Execute Command                 cpu0 Reset
    Execute Command                 cpu0 IsHalted false
    Add Nonsecure SAU Region        0  0  0x7fff
    Execute Command                 cpu0 SetRegister "R0" 0
    Execute Command                 cpu0 PC 0x100
    Execute Command                 cpu0 Step
    Register Should Equal           R0  42

Should BusFault On APB Fetch After Data Access
    Check Peripheral Fetch          0x400e0000

Should BusFault On AHB Fetch After Data Access
    Check Peripheral Fetch          0x50100000

Should BusFault On SIO Fetch After Data Access
    Check Peripheral Fetch          0xd0000000

Should Reject MPU XN Fetch Before Issuing A Peripheral Bus Request
    Check MPU Fetch Precedence      1  true  1

Should Reject An Unmapped MPU Region Before Issuing A Peripheral Bus Request
    Check MPU Fetch Precedence      0  false  1

Should BusFault When MPU Allows Peripheral Execution
    Check MPU Fetch Precedence      0  true  0x100

*** Keywords ***
Check Peripheral Fetch
    [Arguments]                     ${address}
    Create IDAU Machine
    Execute Command                 sysbus WriteDoubleWord ${address} 0xbf00202a
    Execute Command                 sysbus WriteDoubleWord 0x20000100 0xbf006808
    Execute Command                 cpu0 SetRegister "R1" ${address}
    Execute Command                 cpu0 PC 0x20000100
    Execute Command                 cpu0 Step
    Register Should Equal           R0  0xbf00202a
    Execute Command                 cpu0 SetRegister "R0" 0
    Execute Command                 cpu0 PC ${address}
    Execute Command                 cpu0 Step
    Register Should Equal           R0  0
    Fault Bits Should Equal         0xe000ed28  0x100  0x100
    Fault Bits Should Equal         0xe000ede4  0xff  0

Set MPU Region
    [Arguments]                     ${number}  ${base}  ${limit}
    Execute Command                 cpu0 PmsaV8Rnr ${number}
    Execute Command                 cpu0 PmsaV8Rbar ${base}
    Execute Command                 cpu0 PmsaV8Rlar ${limit}

Check MPU Fetch Precedence
    [Arguments]                     ${flags}  ${region_present}  ${expected}
    Create IDAU Machine             cortex-m33-rp2350  8
    Execute Command                 sysbus WriteDoubleWord 0x400e0000 0xbf00202a
    Execute Command                 cpu0 PmsaV8Mair0 0x44
    Set MPU Region                  0  ${{0x400e0000 | int($flags, 0)}}  0x400e0fe1
    Set MPU Region                  1  0x20000002  0x20003fe1
    Set MPU Region                  2  2  0x7fe1
    IF  '${region_present}' == 'false'
        Set MPU Region              0  0x400e0000  0
    END
    Execute Command                 cpu0 PmsaV8Ctrl 1
    Execute Command                 cpu0 PC 0x400e0000
    Execute Command                 cpu0 Step
    Register Should Equal           R0  0
    Fault Bits Should Equal         0xe000ed28  0x101  ${expected}
    Fault Bits Should Equal         0xe000ede4  0xff  0
