#!/usr/bin/env python3
# Usage: gen_rp2_chip_repl.py PREFIX BOARD_REPL > chip.repl
# Flattens a board description with the CPU description it uses, prefixes
# every peripheral name with PREFIX_, registers the CPUs in PREFIX_cluster,
# and scopes every sysbus address registration to that cluster and to the
# chip's DMA, so two chips can share one machine with each chip's cores
# and DMA seeing their own map.
import re, sys

prefix, board = sys.argv[1], sys.argv[2]
# The processor types that join the chip's cluster.
CORE_TYPES = {'CPU.CortexM', 'CPU.RP2350_Hazard3'}
def read(path):
    out = []
    for line in open(path):
        m = re.match(r'\s*using\s+"([^"]+)"', line)
        if m:
            out += read(m.group(1))
        else:
            out.append(line.rstrip('\n'))
    return out

lines = read(board)
names = {m.group(1) for l in lines if (m := re.match(r'^([A-Za-z_][A-Za-z0-9_]*):', l))}
word = re.compile(r'\b(' + '|'.join(sorted(names, key=len, reverse=True)) + r')\b')
def rename(text):
    return word.sub(lambda m: f'{prefix}_{m.group(1)}', text)

def registration(text):
    # "sysbus 0x..." (alone or inside { ... }) -> cluster-scoped point registration.
    # The chip's DMA, a bus master that is not a CPU, gets the same map.
    pair = lambda a: (f'sysbus new Bus.BusPointRegistration {{ address: {a}; cluster: {prefix}_cluster }}; '
                      f'sysbus new Bus.BusPointRegistration {{ address: {a}; cpu: {prefix}_dma_bus }}')
    multi = re.fullmatch(r'(\s*)sysbus new Bus\.BusMultiRegistration \{([^}]*)\}(\s*;?\s*)', text)
    if multi and 'cpu:' not in multi.group(2) and 'cluster:' not in multi.group(2):
        body = multi.group(2).strip().rstrip(';')
        return rename(f'{multi.group(1)}sysbus new Bus.BusMultiRegistration {{ {body}; cluster: {prefix}_cluster }}; '
                      f'sysbus new Bus.BusMultiRegistration {{ {body}; cpu: {prefix}_dma_bus }}{multi.group(3)}')
    if re.fullmatch(r'\s*sysbus\s+(0x[0-9a-fA-F]+|\d+)\s*', text):
        text = '{ ' + pair(text.split()[1]) + ' }'
    else:
        text = re.sub(r'\bsysbus\s+(0x[0-9a-fA-F]+|\d+)\b', lambda m: pair(m.group(1)), text)
    return rename(text)

out = [f'{prefix}_chip: Miscellaneous.RP2_Chip @ sysbus', f'    prefix: "{prefix}_"',
       f'{prefix}_cluster: CPU.Cluster @ sysbus', f'{prefix}_dma_bus: Miscellaneous.RP2_BusMaster @ sysbus', '']
for l in lines:
    s = l.split('//', 1)[0] if not l.lstrip().startswith('"') else l
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*([A-Za-z0-9_.]+)?\s*(@\s*(.*))?$', s)
    if m and not l.startswith(' '):
        name, typ, _, reg = m.groups()
        line = f'{prefix}_{name}:'
        if typ: line += f' {typ}'
        if reg is not None:
            if typ in CORE_TYPES and reg.strip() == 'sysbus':
                line += f' @ {prefix}_cluster'
            else:
                line += ' @ ' + registration(reg)
        out.append(line)
        if name == 'dma': out.append(f'    busContext: {prefix}_dma_bus')
        continue
    if re.match(r'^\s+sysbus\b', s):
        out.append(registration(s))
        continue
    m = re.match(r'^(\s+)([A-Za-z_][A-Za-z0-9_]*)(\s*:\s*)(.*)$', s)
    if m and not s.strip().startswith('->') and not s.strip().startswith('['):
        ind, key, sep, val = m.groups()
        out.append(f'{ind}{key}{sep}{rename(val)}')
        continue
    m = re.match(r'^(\s+)(.*->.*)$', s)
    if m:
        out.append(m.group(1) + re.sub(r'->\s*(.*)$', lambda x: '-> ' + rename(x.group(1)), m.group(2)) if m.group(2).lstrip().startswith('->')
                   else m.group(1) + rename(m.group(2)))
        continue
    out.append(rename(s) if s.strip() else s)
print('\n'.join(out))
