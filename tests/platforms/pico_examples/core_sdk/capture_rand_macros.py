#!/usr/bin/env python3
"""Capture actual SDK rand preprocessor inputs without rebuilding firmware.

Run inside run_isolated.py with --build-pico BUILD --build-pico2 BUILD
 --sdk SDK --infrastructure SOURCE --output OUTPUT.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['build-pico', 'build-pico2', 'sdk', 'infrastructure', 'output']:
        ap.add_argument('--' + name, type=Path, required=True)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    record = dict(status='running', boards={}, inputs={})
    for board in ['pico', 'pico2']:
        build = getattr(args, 'build_' + board).resolve()
        commands_path = build / 'compile_commands.json'
        matches = [item for item in json.loads(commands_path.read_text())
                   if item['file'].endswith('/pico_rand/rand.c') and 'system/rand/CMakeFiles/rand.dir/' in item['command']]
        if len(matches) != 1:
            raise ValueError(f'Expected one actual rand SDK compilation for {board}: {len(matches)}')
        original = shlex.split(matches[0]['command'])
        command, index = [], 0
        while index < len(original):
            word = original[index]
            if word in ['-o', '-MF', '-MT', '-MQ']:
                index += 2
                continue
            if word not in ['-c', '-MD', '-MMD', '-MP']:
                command.append(word)
            index += 1
        command += ['-dM', '-E']
        result = subprocess.run(command, cwd=matches[0]['directory'], capture_output=True, text=True)
        stdout = args.output / f'{board}_all_macros.txt'
        stderr = args.output / f'{board}_preprocessor_stderr.txt'
        stdout.write_text(result.stdout)
        stderr.write_text(result.stderr)
        macros = dict(line.split(None, 2)[1:] for line in result.stdout.splitlines()
                      if line.startswith('#define PICO_RAND_'))
        record['boards'][board] = dict(command=command, cwd=matches[0]['directory'], returncode=result.returncode,
            actual_macros=macros, all_macros_sha256=sha(stdout), compile_commands_sha256=sha(commands_path))
        if result.returncode:
            raise RuntimeError('Preprocessor failed: ' + result.stderr)
    sources = [args.sdk / 'src/rp2_common/pico_rand/rand.c',
               args.sdk / 'src/rp2_common/pico_rand/include/pico/rand.h']
    models = args.infrastructure / 'src/Emulator/Peripherals/Peripherals'
    for name in ['RP2040_ROSC.cs', 'RP2350_ROSC.cs', 'RP2350_TRNG.cs', 'RP2_Timer.cs',
                 'RP2350_BootRAM.cs', 'RP2040_BUSCTRL.cs', 'WinbondW25QFlash.cs']:
        matches = list(models.rglob(name))
        if len(matches) != 1 or not matches[0].is_file():
            raise ValueError(f'Expected one existing entropy-input model source: {name}')
        sources.append(matches[0])
    sources.append(Path(__file__))
    record['inputs'] = {str(path.resolve()): sha(path) for path in sources}
    record['modeled_sources'] = {
        'emulation_seed': 0,
        'pico': {
            'runtime': ['ROSC deterministic LFSR, reset 0x3f04b16d, feedback 0x80200003; samples paced by guest virtual time',
                        'RP2_Timer virtual microsecond timestamp',
                        'BUSCTRL SRAM5 completed CPU/DMA data-access event counter'],
            'initial_seed': ['Same ROSC LFSR and virtual timestamp',
                             'SDK sdbm hash of the final 1024 bytes of SRAM, populated by actual ROM/firmware execution',
                             'Winbond flash unique ID default 0x0123456789abcdef'],
        },
        'pico2': {
            'runtime': ['RP2350_TRNG entropy from Emulation seeded PRNG with virtual sampling timer',
                        'RP2_Timer virtual microsecond timestamp'],
            'initial_seed': ['Same modeled TRNG and virtual timestamp',
                             'Boot random words produced by official ROM execution and retrieved through ROM API'],
        },
        'host_entropy': 'No host wall clock or operating-system randomness is supplied by these models',
        'qualification': 'Reproducible functional emulation; these checks do not establish hardware entropy quality or cryptographic security',
    }
    record['status'] = 'captured'
    (args.output / 'rand_macro_inputs.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
