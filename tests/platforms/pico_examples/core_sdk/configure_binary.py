#!/usr/bin/env python3
"""Apply published picotool binary configuration and prove data-only changes.

Usage inside run_isolated.py: configure_binary.py --source-elf FILE --board
 pico|pico2 --picotool TOOL --settings JSON_FILE --output NEW_DIRECTORY
The settings file maps the example's bi_ptr variable names to integers/strings.
The original ELF remains unchanged; a matching UF2 is generated from the copy.
"""
import argparse
import json
from pathlib import Path
import shutil
import struct
import subprocess

from core_sdk_common import sha, symbols


def file_offset(data, address, count):
    phoff = struct.unpack_from('<I', data, 28)[0]
    phsize, phcount = struct.unpack_from('<HH', data, 42)
    matches = []
    for index in range(phcount):
        typ, off, va, pa, filesz, memsz, flags, align = struct.unpack_from('<8I', data, phoff + index * phsize)
        if typ == 1 and va <= address and address + count <= va + filesz:
            matches.append(off + address - va)
    if len(matches) != 1:
        raise ValueError(f'No unique file-backed segment for symbol address {address:x}')
    return matches[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['source-elf', 'picotool', 'settings', 'output']:
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--board', choices=['pico', 'pico2'], required=True)
    args = ap.parse_args()
    for name in ['source_elf', 'picotool', 'settings', 'output']:
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=False)
    settings = json.loads(args.settings.read_text())
    if not isinstance(settings, dict):
        raise ValueError('A settings object is required')
    original = args.source_elf.read_bytes()
    expected = bytearray(original)
    named = symbols(args.source_elf)
    record = dict(board=args.board, status='incomplete', commands=[], settings=settings,
                  original_elf=dict(path=str(args.source_elf), sha256=sha(args.source_elf)),
                  picotool=dict(path=str(args.picotool), sha256=sha(args.picotool)),
                  settings_input=dict(path=str(args.settings), sha256=sha(args.settings)), changes=[])
    copy = args.output / args.source_elf.name
    shutil.copy2(args.source_elf, copy)
    try:
        for key, value in settings.items():
            matches = [(name, addr) for name, addr in named.items() if name == key or name.startswith(key + '.')]
            if len(matches) != 1:
                raise ValueError(f'No unique ELF symbol for {key}: {matches}')
            name, addr = matches[0]
            if isinstance(value, int):
                data = struct.pack('<I', value)
            elif isinstance(value, str):
                data = value.encode('ascii') + b'\0'
                if len(data) > 256:
                    raise ValueError('Configured string exceeds example text capacity')
            else:
                raise ValueError('Only integer and ASCII text configuration supported')
            offset = file_offset(original, addr, len(data))
            expected[offset:offset + len(data)] = data
            record['changes'].append(dict(variable=key, symbol=name, address=addr,
                                          file_offset=offset, original=original[offset:offset + len(data)].hex(), expected=data.hex()))
        commands = [[str(args.picotool), 'info', '-a', str(copy)],
                    [str(args.picotool), 'config', str(copy)]]
        commands += [[str(args.picotool), 'config', '-s', key, str(value), str(copy)] for key, value in settings.items()]
        commands += [[str(args.picotool), 'config', str(copy)],
                     [str(args.picotool), 'uf2', 'convert', str(copy), str(copy.with_suffix('.uf2')),
                      '--family', 'rp2040' if args.board == 'pico' else 'rp2350-arm-s'] + ([] if args.board == 'pico' else ['--abs-block'])]
        for cmd in commands:
            result = subprocess.run(cmd, capture_output=True, text=True)
            record['commands'].append(dict(command=cmd, returncode=result.returncode, output=result.stdout + result.stderr))
            if result.returncode:
                raise RuntimeError(f'picotool failed: {cmd}: {result.stdout + result.stderr}')
        if args.source_elf.read_bytes() != original:
            raise AssertionError('Original ELF changed')
        actual = copy.read_bytes()
        if actual != expected:
            raise AssertionError('Configured ELF differs outside exact expected variable data changes')
        record.update(status='configured', data_only_changes_proved=True,
                      configured_elf=dict(path=str(copy), sha256=sha(copy)),
                      uf2=dict(path=str(copy.with_suffix('.uf2')), sha256=sha(copy.with_suffix('.uf2'))))
    except BaseException as exc:
        record.update(status='failed', error=str(exc))
        raise
    finally:
        (args.output / 'configuration.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
