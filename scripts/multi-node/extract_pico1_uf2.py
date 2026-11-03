#!/usr/bin/env python3
"""Extract exact RP2040 UF2 flash payloads without loading firmware RAM.

Usage: extract_pico1_uf2.py INPUT_UF2 OUTPUT_BINARY
Holes between UF2 flash blocks are erased bytes (0xff). Prints a provenance
record with input/output hashes; rejects malformed, duplicate or foreign blocks.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys


if len(sys.argv) != 3:
    sys.exit(__doc__)
source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
if not data or len(data) % 512:
    raise ValueError('UF2 length must be a positive multiple of 512')
blocks = {}
seen = set()
for start in range(0, len(data), 512):
    block = data[start:start + 512]
    magic0, magic1, flags, address, count, index, total, family = struct.unpack_from('<8I', block)
    if (magic0, magic1, struct.unpack_from('<I', block, 508)[0]) != (0x0a324655, 0x9e5d5157, 0x0ab16f30):
        raise ValueError(f'Invalid UF2 magic in block {start // 512}')
    if flags != 0x2000 or family != 0xe48bff56:
        raise ValueError('Expected an RP2040 main-flash UF2 image')
    if total != len(data) // 512 or index >= total or index in seen:
        raise ValueError('Invalid or repeated UF2 block number')
    if count != 256 or address % 256 or not 0x10000000 <= address <= 0x10200000 - count:
        raise ValueError('UF2 payload is outside Pico1 flash or not a 256-byte flash block')
    if address in blocks:
        raise ValueError('Overlapping UF2 payloads')
    seen.add(index)
    blocks[address] = block[32:32 + count]
end = max(address + len(payload) for address, payload in blocks.items())
result = bytearray([0xff]) * (end - 0x10000000)
for address, payload in blocks.items():
    result[address - 0x10000000:address - 0x10000000 + len(payload)] = payload
with destination.open('xb') as output:
    output.write(result)
print(json.dumps(dict(input=str(source.resolve()), input_sha256=hashlib.sha256(data).hexdigest(),
                      output=str(destination.resolve()), output_sha256=hashlib.sha256(result).hexdigest(),
                      base_address='0x10000000', payload_blocks=len(blocks), binary_bytes=len(result))))
