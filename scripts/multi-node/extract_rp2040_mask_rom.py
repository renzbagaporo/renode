#!/usr/bin/env python3
"""Extract the 16 KiB RP2040 mask ROM image from the B2 boot ROM ELF.

Usage: extract_rp2040_mask_rom.py INPUT_ELF OUTPUT_BINARY
Writes only the file-backed segment at physical address 0. The ELF's other
loadable segment is the boot ROM's USB DPRAM .bss, which has no file bytes and
is not part of the mask ROM. Prints a provenance record with input/output hashes.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROM_SIZE = 0x4000

if len(sys.argv) != 3:
    sys.exit(__doc__)
source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
if data[:6] != b'\x7fELF\x01\x01':
    raise ValueError('Expected a 32-bit little-endian ELF')
phoff = struct.unpack_from('<I', data, 28)[0]
phentsize, phnum = struct.unpack_from('<HH', data, 42)
if phentsize != 32 or phoff + phnum * phentsize > len(data):
    raise ValueError('Invalid ELF program headers')
rom = []
for index in range(phnum):
    kind, offset, _, paddr, filesz, memsz, _, _ = struct.unpack_from('<8I', data, phoff + index * phentsize)
    if kind != 1 or not filesz:
        continue
    if paddr != 0 or filesz != ROM_SIZE or memsz != filesz or offset + filesz > len(data):
        raise ValueError(f'Unexpected file-backed segment at 0x{paddr:08x} ({filesz} bytes)')
    rom.append(data[offset:offset + filesz])
if len(rom) != 1:
    raise ValueError('Expected exactly one file-backed mask ROM segment')
with destination.open('xb') as output:
    output.write(rom[0])
print(json.dumps(dict(input=str(source.resolve()), input_sha256=hashlib.sha256(data).hexdigest(),
                      output=str(destination.resolve()), output_sha256=hashlib.sha256(rom[0]).hexdigest(),
                      load_address='0x00000000', binary_bytes=len(rom[0]))))
