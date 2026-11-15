#!/usr/bin/env python3
"""Turn a picotool `otp load` JSON file into an RP2350 OTP raw image.

Usage: otp_json_to_raw.py OTP_JSON OUTPUT [--base RAW_IMAGE]

The output is 4096 little-endian 32-bit words, one 24-bit row each, for
run_extension.py --otp-image (`otp LoadRawImage`). Rows start erased, or from
--base. Keys follow picotool: a row or field name (case-insensitive, with or
without OTP_DATA_), a sequence prefix such as bootkey0, or a raw "PAGE:ROW"
address with "ecc" and "value". Values are an integer, a list of bytes, or a
{field: value} object. ECC rows take 2 bytes each and raw rows 4; a single
value repeats over a row's redundant copies. Programming only sets bits, as
in the fuses.

rp2350_otp_map.json lists the rows, sequences and fields. It is derived from
picotool 6f6458d792b93685a11423b244a585eaa99eafcf otp_header_parser/rp2350.json.h,
Copyright (c) 2020 Raspberry Pi (Trading) Ltd., BSD-3-Clause.
"""
import argparse
import json
import struct
from pathlib import Path

ROWS = 4096
PARITY_MASKS = (0x1ad5b, 0x2366d, 0x4c78e, 0x807f0, 0x10f800)


def parity(value):
    return bin(value).count('1') & 1


def encode_ecc(data):
    """The 22-bit SECDED encoding of a 16-bit ECC row (BRBP bits clear)."""
    value = data & 0xffff
    for i, mask in enumerate(PARITY_MASKS):
        value |= parity(data & mask) << (16 + i)
    return value | parity(value) << 21


def load_map():
    return json.loads((Path(__file__).with_name('rp2350_otp_map.json')).read_text())


def resolve(key, otp_map):
    """(first row, entry or None, sequence length) for a JSON key."""
    if ':' in key:
        page, row = key.split(':')
        return int(page, 0) * 64 + int(row, 0), None, 0
    name = key.upper().removeprefix('OTP_DATA_')
    if name in otp_map:
        return otp_map[name]['row'], otp_map[name], 0
    for first in (name + '0', name + '_0'):
        entry = otp_map.get(first)
        if entry and entry['seq_length']:
            return entry['row'], entry, entry['seq_length']
    raise SystemExit(f'{key} does not match an OTP row or sequence')


def to_int(value):
    """An integer, or a string picotool accepts as one ("0x3d3d3d")."""
    return int(value, 0) if isinstance(value, str) else int(value)


def row_bytes(value, size):
    return list((to_int(value) & 0xffffffff).to_bytes(4, 'little')[:size])


def convert(document, rows, otp_map):
    for key, value in document.items():
        first, entry, sequence = resolve(key, otp_map)
        if entry is not None:
            ecc = entry['ecc']
            count = sequence or entry['redundancy'] or 1
        else:
            ecc = bool(value.get('ecc', False))
            count = 1
        size = 2 if ecc else 4
        if entry is None:
            data = value['value']
            if isinstance(data, list):
                data = [to_int(b) for b in data]
                count = len(data) // size
            else:
                count = to_int(value.get('redundancy', 1))
                data = row_bytes(data, size)
        elif isinstance(value, dict):
            word = 0
            covered = 0
            for field, field_value in value.items():
                mask = next((m for n, m in entry['fields'].items() if n.upper() == field.upper()), None)
                if mask is None:
                    raise SystemExit(f'{key}.{field} is not an OTP field')
                low = (mask & -mask).bit_length() - 1
                field_value = to_int(field_value)
                if field_value & ~(mask >> low):
                    raise SystemExit(f'{key}.{field} = {field_value:#x} does not fit its field')
                word |= (field_value << low) & mask
                covered |= mask
            word |= rows[first] & 0xffffff & ~covered
            data = row_bytes(word, size)
        elif isinstance(value, list):
            data = [to_int(b) for b in value]
        else:
            data = row_bytes(value, size)
        if len(data) % size:
            raise SystemExit(f'{key}: data is not a whole number of {size}-byte rows')
        if len(data) == size and count > 1:
            data = data * count
        if len(data) != size * count:
            raise SystemExit(f'{key}: {len(data)} bytes for {count} rows of {size} bytes')
        for i in range(count):
            chunk = data[i * size:(i + 1) * size]
            word = int.from_bytes(bytes(chunk), 'little')
            rows[first + i] |= encode_ecc(word) if ecc else word & 0xffffff


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('otp_json', type=Path)
    ap.add_argument('output', type=Path)
    ap.add_argument('--base', type=Path)
    args = ap.parse_args()
    rows = [0] * ROWS
    if args.base:
        raw = args.base.read_bytes()
        rows = [w & 0xffffff for w in struct.unpack(f'<{ROWS}I', raw)]
    convert(json.loads(args.otp_json.read_text()), rows, load_map())
    args.output.write_bytes(struct.pack(f'<{ROWS}I', *rows))


if __name__ == '__main__':
    main()
