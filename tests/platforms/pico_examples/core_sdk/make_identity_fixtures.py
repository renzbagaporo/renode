#!/usr/bin/env python3
"""Generate two declared OTP chip-ID fixtures using the pinned ROM ECC scheme.

Usage: make_identity_fixtures.py --rom-source REPO --sdk SDK --output NEW_DIR
The fixtures are hardware inputs, not verifier outcomes. Each image contains
4096 little-endian32-bit raw OTP rows; only CHIPID rows0..3 are programmed.
"""
import argparse
import json
from pathlib import Path
import re
import struct
import subprocess

from core_sdk_common import sha


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['rom-source', 'sdk', 'output']:
        ap.add_argument('--' + name, type=Path, required=True)
    args = ap.parse_args()
    for name in ['rom_source', 'sdk', 'output']:
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=False)
    source = args.rom_source / 'src/main/arm/varm_otp.c'
    constants = args.sdk / 'src/rp2350/hardware_regs/include/hardware/regs/otp_data.h'
    sdk_source = args.sdk / 'src/rp2_common/pico_unique_id/unique_id.c'
    table_text = re.search(r'otp_ecc_parity_table\[6\]\s*=\s*\{([^}]+)\}', source.read_text())
    if table_text is None:
        raise ValueError('ROM parity table absent')
    masks = [int(value, 2) for value in re.findall(r'0b([01]+)', table_text[1])]
    if len(masks) != 6:
        raise ValueError('Expected the six sequential parity equations')
    for row in range(4):
        if not re.search(rf'#define OTP_DATA_CHIPID{row}_ROW\s+_u\(0x0*{row:x}\)', constants.read_text()):
            raise ValueError('SDK CHIPID row mapping differs')
    revision = subprocess.check_output(['git', '-C', str(args.rom_source), 'rev-parse', 'HEAD'], text=True).strip()
    record = dict(rom_revision=revision, references={str(p):sha(p) for p in [source, constants, sdk_source]},
                  encoding='Sequential ROM22-bit ECC, virgin raw OTP rows, uint32 little-endian containers; no bit-repair inversion.', fixtures=[])
    for identity in [0x0123456789abcdef, 0xfedcba9876543210]:
        rows = []
        for i in range(4):
            value = (identity >> (16 * i)) & 0xffff
            encoded = value
            for bit, mask in enumerate(masks):
                encoded |= ((encoded & mask).bit_count() & 1) << (16 + bit)
            rows.append(encoded)
        image = struct.pack('<4I', *rows) + b'\0' * (4096 * 4 - 16)
        path = args.output / f'chip_id_{identity:016x}.bin'
        path.write_bytes(image)
        text = f'{identity:016x}'
        record['fixtures'].append(dict(identity='0x' + text, expected_uart='Unique identifier: ' + ' '.join(text[i:i + 2] for i in range(0, 16, 2)),
                                       decoded_rows=[f'0x{(identity >> (16 * i)) & 0xffff:04x}' for i in range(4)],
                                       raw_rows=[f'0x{value:06x}' for value in rows], path=str(path), bytes=len(image), sha256=sha(path)))
    (args.output / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
