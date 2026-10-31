# Core SDK and FreeRTOS example coverage

The acceptance catalog defines 18 example targets and 32 applicable Pico/Pico 2
cases. Several cases contain multiple independent configuration/reset scenarios.
The catalog and execution profiles are frozen inputs; a diagnostic run does not
count as an accepted case.

The examples are pinned to `0d62f75bafc2c8120d3276c3343d1a9195e909e9`, Pico SDK to
`98a542c1a62fb549ffb5d66a3e5892b06276b670`, and FreeRTOS Kernel to
`ca759444e9ca59cfa3a9faa6cb8b49e0772ca520`. Builds use Arm GNU 14.2.Rel1,
CMake/Ninja, the SDK's matching picotool/pioasm CMake packages, and Release flags.
Runtime tests require Python 3, a compatible .NET runtime, a built Renode runtime,
the matching Renode platform checkout, and the board's actual mask ROM image.
Pico uses the B2 mask-ROM ELF; Pico 2 uses the A2 combined mask-ROM binary.

Catalog source names beginning with `.dev/resources/` are canonical labels from
the original inventory. `build_examples.py` resolves those labels through its
explicit `--examples`, `--sdk`, and `--kernel` roots; the checkout locations are
not fixed. Its manifest records the actual files and hashes used.

## Build

Every command/test gets a new private HOME, XDG directories, temporary directory,
and .NET/NuGet directories. The isolated runner records the actual command and
terminal status. Builds and logs belong under caller-owned task directories.

```sh
python3 tests/platforms/pico_examples/core_sdk/run_isolated.py \
  --output .dev/outputs/core_sdk_freertos/build_pico \
  --scratch .dev/tmp/core_sdk_freertos/build_pico_environment \
  --timeout 1800 \
  -- \
  python3 tests/platforms/pico_examples/core_sdk/build_examples.py \
  --examples /path/to/pico-examples \
  --sdk /path/to/pico-sdk \
  --kernel /path/to/FreeRTOS-Kernel \
  --toolchain /path/to/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi \
  --picotool-dir /path/to/picotool/cmake/package \
  --pioasm-dir /path/to/pioasm/cmake/package \
  --catalog tests/platforms/pico_examples/core_sdk/acceptance_catalog.json \
  --board pico \
  --build '{scratch}/build' \
  --isolation-root '{scratch}'
```

Use a separate build and environment for Pico 2. The build manifest contains
ELF/UF2 hashes and effective FreeRTOS macro dumps from each target's actual
compiler command. An approved example source exception is supplied explicitly
with `--source-exception`; its ledger must declare `status: approved`, the pinned
`original_revision`, and exact `modified_files` hashes. SDK/kernel source edits,
extra example edits, and changed source revisions are rejected.

## Prepare binary configuration and identity inputs

`prepare_metadata.py` creates the catalog's LED pin and UART/USB configuration
variants through official picotool commands. It proves the ELF differs only in
the declared variable data and regenerates matching UF2 files. Original firmware
artifacts remain unchanged.

```sh
python3 tests/platforms/pico_examples/core_sdk/prepare_metadata.py \
  --build /path/to/board/build \
  --board pico \
  --picotool /path/to/picotool \
  --isolator tests/platforms/pico_examples/core_sdk/run_isolated.py \
  --output .dev/outputs/core_sdk_freertos/metadata_pico \
  --scratch .dev/tmp/core_sdk_freertos/metadata_pico
```

`make_identity_fixtures.py` generates the two predeclared chip identities from
the actual pinned ROM ECC parity equations and SDK CHIPID row map. The ROM source
revision used for this oracle is `fd6104450fa8f55c11c0c9b54dbc69a27537130f`.
The output manifest describes hardware inputs, not observed verifier results.
Run this script inside the isolated runner as well.

```sh
python3 tests/platforms/pico_examples/core_sdk/run_isolated.py \
  --output .dev/outputs/core_sdk_freertos/identity_fixture_generation \
  --scratch .dev/tmp/core_sdk_freertos/identity_fixture_generation \
  -- \
  python3 tests/platforms/pico_examples/core_sdk/make_identity_fixtures.py \
  --rom-source /path/to/pico-bootrom-rp2350 \
  --sdk /path/to/pico-sdk \
  --output '{scratch}/fixtures'
```

## Run acceptance

Ordinary cases load only file-backed ELF segments into NOR and execute the
official ROM. The loader does not initialize application SRAM or patch CPU
architectural state. Read-only hooks record UART, GPIO, native access widths,
interrupts, function entry/return, and task context evidence. Terminal/error
address hooks halt the relevant CPU as debugger breakpoints.

```sh
python3 tests/platforms/pico_examples/core_sdk/run_acceptance.py \
  --repository /path/to/renode \
  --runtime /path/to/built/renode/runtime \
  --dotnet /path/to/dotnet \
  --board pico \
  --build-manifest /path/to/board/build/build_manifest.json \
  --catalog tests/platforms/pico_examples/core_sdk/acceptance_catalog.json \
  --profiles tests/platforms/pico_examples/core_sdk/execution_profiles.json \
  --metadata-ledger /path/to/metadata/metadata.json \
  --identity-fixtures /path/to/identity/fixtures/manifest.json \
  --rom /path/to/rp2040_b2.elf \
  --isolator tests/platforms/pico_examples/core_sdk/run_isolated.py \
  --output .dev/outputs/core_sdk_freertos/acceptance_pico \
  --scratch .dev/tmp/core_sdk_freertos/acceptance_pico \
  --rpc-port 19321
```

`--cases` selects named targets for a bounded work batch. The result ledger lists
every selected scenario, actual wrapper/Renode exit status, and hashes of the
frozen inputs and copied helper scripts. `working_tree_revisions` identifies the
checkout present during execution; compile provenance comes from the selected
runtime's build evidence and mapped binary hashes.

Double-tap and `hello_anything` use the USB/reset integration driver because
their acceptance includes real Linux USB transfers. They are excluded from this
regular-case driver, with their requirements preserved in the same catalog.
The Linux guest and every USB/IP import require exclusive ownership.

FreeRTOS success covers all ten main-task counts, completed context
deinitialization, actual self deletion, and eleven further virtual seconds of
other-task progress. The original task-return defect is a negative control.
The example source exception requires independent adversarial approval; its
failure is never counted as a passing case. Randomness uses the declared seed0
and all 500000 source samples with the original integer distribution assertions.
RTC repetition runs for the catalog's full 185 virtual seconds.

Scheduling quantum is chosen by the frozen per-case profile, separately from
hardware clock configuration. Requested and actual quantum, child environment,
loaded native modules, ROM/firmware/runtime hashes, and raw observations are
recorded. Failures and interrupted attempts remain separate from selected
passing evidence. All generated builds and runtime artifacts remain outside
tracked source.
