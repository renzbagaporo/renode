*** Variables ***
${PLATFORM}                         SEPARATOR=\n
...  cpu: CPU.CortexM @ sysbus
...  ${SPACE*4}cpuType: "cortex-m33-rp2350"
...  ${SPACE*4}nvic: nvic
...  nvic: IRQControllers.NVIC @ sysbus 0xe000e000
...  ${SPACE*4}-> cpu@0
...  sram: Memory.MappedMemory @ sysbus 0x20000000
...  ${SPACE*4}size: 0x10000
...  storage: Memory.MappedMemory
...  ${SPACE*4}size: 0x400000
...  flash: SPI.WinbondW25QFlash
...  ${SPACE*4}underlyingMemory: storage
...  qmi: MemoryControllers.RP2350_QMI @ sysbus 0x400d0000
...  ${SPACE*4}flash: flash
...  cache: MemoryControllers.RP2350_XIP @ sysbus 0x400c8000
...  maintenance: MemoryControllers.RP2350_XIPMaintenance @ sysbus 0x18000000
...  ${SPACE*4}xip: cache
...  xip: Memory.RP2350_XIPMemory @ sysbus 0x10000000
...  ${SPACE*4}flash: flash
...  ${SPACE*4}qmi: qmi
...  ${SPACE*4}xip: cache
...  uncached: Memory.RP2350_XIPMemory @ sysbus 0x14000000
...  ${SPACE*4}flash: flash
...  ${SPACE*4}qmi: qmi
...  ${SPACE*4}xip: cache
...  ${SPACE*4}useCache: false
...  untranslated: Memory.RP2350_XIPMemory @ sysbus 0x1c000000
...  ${SPACE*4}flash: flash
...  ${SPACE*4}qmi: qmi
...  ${SPACE*4}xip: cache
...  ${SPACE*4}untranslated: true
...  ${SPACE*4}useCache: false
...  cacheRam: Memory.RP2350_XIPMemory @ sysbus 0x12000000
...  ${SPACE*4}flash: flash
...  ${SPACE*4}qmi: qmi
...  ${SPACE*4}xip: cache
...  ${SPACE*4}windowOffset: 0x2000000
...  reserved: Memory.RP2350_XIPMemory @ sysbus 0x16000000
...  ${SPACE*4}flash: flash
...  ${SPACE*4}qmi: qmi
...  ${SPACE*4}xip: cache
...  ${SPACE*4}windowOffset: 0x2000000
...  ${SPACE*4}useCache: false

*** Keywords ***
Create XIP Machine
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString """${PLATFORM}"""
    Execute Command                 cpu IsHalted true

Read Should Equal
    [Arguments]                     ${address}  ${expected}
    ${value}=                       Execute Command  sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers      ${value.strip()}  ${expected}

Start CPU Reader
    [Arguments]                     ${address}
    # Loop in SRAM: load ${address} and store it to 0x20000100.
    Execute Command                 sysbus WriteDoubleWord 0x20000000 0x4a034802
    Execute Command                 sysbus WriteDoubleWord 0x20000004 0x60116801
    Execute Command                 sysbus WriteDoubleWord 0x20000008 0xbf00e7fc
    Execute Command                 sysbus WriteDoubleWord 0x2000000c ${address}
    Execute Command                 sysbus WriteDoubleWord 0x20000010 0x20000100
    Execute Command                 sysbus WriteDoubleWord 0x20000100 0xdeadbeef
    Execute Command                 cpu PC 0x20000000
    Execute Command                 cpu IsHalted false

CPU Read Should Equal
    [Arguments]                     ${expected}
    Execute Command                 sysbus WriteDoubleWord 0x20000100 0xdeadbeef
    Execute Command                 emulation RunFor "0.0001"
    Read Should Equal               0x20000100  ${expected}

Load Distinct Flash Pages
    ${image}=                       Evaluate  struct.pack("<I", 0x11111111) + bytes(0xffc) + struct.pack("<I", 0x22222222)  modules=struct
    Create Binary File              ${TEMPDIR}/rp2350_xip_pages.bin  ${image}
    Execute Command                 xip LoadBinary @${TEMPDIR}/rp2350_xip_pages.bin

*** Test Cases ***
ShouldRequirePinnedTagAndEnabledCacheForSRAM
    Create XIP Machine
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x13ffc000
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    Execute Command                 sysbus WriteDoubleWord 0x13ffc000 0x12345678
    Read Should Equal               0x13ffc000  0x12345678
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x17ffc000
    Execute Command                 sysbus WriteDoubleWord 0x400c8000 8
    Read Should Equal               0x400c8000  8
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x13ffc000
    Execute Command                 sysbus WriteDoubleWord 0x400c8000 1
    Read Should Equal               0x13ffc000  0x12345678

ShouldReplaceTagAtSameSetAndWayWithoutDiscardingData
    Create XIP Machine
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    Execute Command                 sysbus WriteDoubleWord 0x13ffc000 0x12345678
    Execute Command                 sysbus WriteByte 0x1bff8007 0
    Read Should Equal               0x13ff8000  0x12345678
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x13ffc000
    Execute Command                 sysbus WriteByte 0x18000000 0
    Run Keyword And Expect Error    *Bus access failed*  Execute Command  sysbus ReadDoubleWord 0x13ff8000
    Execute Command                 sysbus WriteByte 0x1bff8007 0
    Read Should Equal               0x13ff8000  0x12345678

ShouldRetainPinnedTagAndDataAcrossCoreDomainReset
    Create XIP Machine
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    Execute Command                 sysbus WriteDoubleWord 0x13ffc000 0x87654321
    Execute Command                 machine Reset
    Read Should Equal               0x13ffc000  0x87654321

ShouldFetchInstructionsFromPinnedCacheSRAM
    Create XIP Machine
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    Execute Command                 sysbus WriteDoubleWord 0x13ffc000 0xe7fe202a
    Execute Command                 sysbus WriteDoubleWord 0x20000000 0x20008000
    Execute Command                 sysbus WriteDoubleWord 0x20000004 0x13ffc001
    Execute Command                 cpu VectorTableOffset 0x20000000
    Execute Command                 cpu IsHalted false
    Execute Command                 emulation RunFor "0.00001"
    ${r0}=                          Execute Command  cpu GetRegister "R0"
    Should Be Equal As Integers      ${r0.strip()}  42

ShouldPublishMaintenanceAndConfigurationCallbacksOutsideStateLock
    Execute Command                 include @${CURDIR}/RP2350XIPNotificationProbe.cs
    Create XIP Machine
    Execute Command                 machine LoadPlatformDescriptionFromString "probe: Miscellaneous.RP2350XIPNotificationProbe @ sysbus 0x60000000 { cache: cache }"
    Execute Command                 sysbus WriteDoubleWord 0x400c8000 0x83
    ${status}=                      Execute Command  probe Status
    Should Be Equal As Integers      ${status.strip()}  1
    Execute Command                 probe Reset
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    ${status}=                      Execute Command  probe Status
    Should Be Equal As Integers      ${status.strip()}  1
    Execute Command                 probe Reset
    Execute Command                 sysbus WriteDoubleWord 0x13ffc000 0x12345678
    ${status}=                      Execute Command  probe Status
    Should Be Equal As Integers      ${status.strip()}  1
    Execute Command                 probe Reset
    Execute Command                 cache Reset
    ${status}=                      Execute Command  probe Status
    Should Be Equal As Integers      ${status.strip()}  1

ShouldPublishCompleteCacheWordAfterOneBusStore
    Execute Command                 include @${CURDIR}/RP2350XIPNotificationProbe.cs
    Create XIP Machine
    Execute Command                 sysbus WriteByte 0x1bffc007 0
    Execute Command                 machine LoadPlatformDescriptionFromString "probe: Miscellaneous.RP2350XIPNotificationProbe @ sysbus 0x60000000 { cache: cache; memory: cacheRam }"
    Execute Command                 probe ExpectedWord 0x12345678
    Execute Command                 sysbus WriteDoubleWord 0x13ffc000 0x12345678
    ${mixed}=                       Execute Command  probe ObservedPartialWord
    Should Be Equal                 ${mixed.strip()}  False

ShouldFollowQMIReadConfigurationInCPUReads
    Create XIP Machine
    Load Distinct Flash Pages
    Start CPU Reader                0x10000000
    CPU Read Should Equal           0x11111111
    # A DTR read format is not modelled, so reads return the undriven bus.
    Execute Command                 sysbus WriteDoubleWord 0x400d0010 0x10001000
    CPU Read Should Equal           0xffffffff
    Execute Command                 sysbus WriteDoubleWord 0x400d0010 0x1000
    CPU Read Should Equal           0x11111111

ShouldFollowAddressTranslationInCPUReads
    Create XIP Machine
    Load Distinct Flash Pages
    Start CPU Reader                0x10000000
    CPU Read Should Equal           0x11111111
    Execute Command                 sysbus WriteDoubleWord 0x400d0034 0x04000001
    CPU Read Should Equal           0x22222222
    Execute Command                 sysbus WriteDoubleWord 0x400d0034 0x04000000
    CPU Read Should Equal           0x11111111

ShouldReadUntranslatedAliasThroughAddressTranslation
    Create XIP Machine
    Load Distinct Flash Pages
    Execute Command                 sysbus WriteDoubleWord 0x400d0034 0x04000001
    Start CPU Reader                0x1c000000
    CPU Read Should Equal           0x11111111

ShouldReadPinnedLineInFlashWindowInCPUReads
    Create XIP Machine
    Load Distinct Flash Pages
    Start CPU Reader                0x10000000
    CPU Read Should Equal           0x11111111
    Execute Command                 sysbus WriteByte 0x18000007 0
    CPU Read Should Equal           0
    Execute Command                 sysbus WriteByte 0x18000000 0
    CPU Read Should Equal           0x11111111

ShouldCountCPUReadsAfterCountersAreCleared
    Create XIP Machine
    Load Distinct Flash Pages
    Start CPU Reader                0x14000000
    CPU Read Should Equal           0x11111111
    Execute Command                 sysbus WriteDoubleWord 0x400c8010 0
    CPU Read Should Equal           0x11111111
    ${accesses}=                    Execute Command  sysbus ReadDoubleWord 0x400c8010
    Should Be True                  ${accesses.strip()} > 0
