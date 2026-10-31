#!/usr/bin/env python3
"""Capture one actual Linux USB/IP CDC or BOOTSEL exchange inside the guest.

Usage (guest only): guest_capture.py --mode cdc|bootsel --port USBIP_PORT
 --output NEW_OUTPUT_DIRECTORY [--timeout WALL_SECONDS]
Only the named remote USB/IP import is detached. No host USB is exposed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def invoke(record, command, timeout=10):
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    record['commands'].append(dict(command=command, returncode=result.returncode,
        output=result.stdout + result.stderr, elapsed_seconds=time.monotonic() - started))
    return result


def devices():
    return {p.name: p for p in Path('/sys/bus/usb/devices').iterdir()
            if (p / 'idVendor').is_file() and not p.name.startswith('usb')}


def read_text(path):
    return path.read_text().strip() if path.exists() else None


def detach(record, command, target):
    ports = invoke(record, command + ['port'])
    selected = None
    for line in ports.stdout.splitlines():
        match = re.match(r'Port (\d+):', line.strip())
        if match:
            selected = match.group(1)
        elif target in line and selected is not None:
            invoke(record, command + ['detach', '-p', selected])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['cdc', 'bootsel'], required=True)
    parser.add_argument('--host', default='10.0.2.2')
    parser.add_argument('--expected-line', default='Hello, world!')
    parser.add_argument('--busid', default='1-0')
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=900)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    deadline = started + args.timeout
    record = dict(mode=args.mode, commands=[], status='incomplete', lines=[],
                  started_monotonic=started, kernel=os.uname().release)
    def interrupted(signum, _frame):
        raise InterruptedError(f'Guest USB capture received signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    command = ['usbip', '--tcp-port', str(args.port)]
    target = f'usbip://{args.host}:{args.port}/{args.busid}'
    before = {name: read_text(path / 'devnum') for name, path in devices().items()}
    attached = False
    trace = trace_log = None
    raw = bytearray()
    try:
        module = invoke(record, ['modprobe', 'usbmon'])
        if module.returncode:
            raise RuntimeError('Linux USB monitor module is unavailable')
        mounted = invoke(record, ['mountpoint', '-q', '/sys/kernel/debug'])
        if mounted.returncode:
            mounted = invoke(record, ['mount', '-t', 'debugfs', 'none', '/sys/kernel/debug'])
            if mounted.returncode:
                raise RuntimeError('Guest debugfs could not be mounted for USB traffic capture')
        trace_log = (args.output / 'usbmon.txt').open('wb')
        trace = subprocess.Popen(['cat', '/sys/kernel/debug/usb/usbmon/0u'], stdout=trace_log, stderr=subprocess.STDOUT)
        probe = invoke(record, command + ['port'])
        if target in probe.stdout:
            raise RuntimeError('The requested remote USB/IP bus already has an owner')
        attached_result = invoke(record, command + ['attach', '-r', args.host, '-b', args.busid], timeout=30)
        if attached_result.returncode:
            raise RuntimeError(attached_result.stdout + attached_result.stderr)
        attached = True
        new = None
        while time.monotonic() < deadline:
            candidates = [path for name, path in devices().items()
                          if before.get(name) != read_text(path / 'devnum')]
            if len(candidates) > 1:
                raise RuntimeError('Unexpected multiple USB devices in isolated guest')
            if candidates and (candidates[0] / 'descriptors').exists():
                new = candidates[0]
                descriptor = (new / 'descriptors').read_bytes()
                if len(descriptor) >= 18:
                    break
            time.sleep(.1)
        if new is None:
            raise TimeoutError('Linux did not enumerate the imported USB device')
        (args.output / 'descriptors.bin').write_bytes(descriptor)
        record['enumeration'] = {name: read_text(new / name) for name in
            ['idVendor', 'idProduct', 'manufacturer', 'product', 'serial', 'bDeviceClass', 'bNumConfigurations', 'speed', 'authorized']}
        record['enumeration']['sysfs'] = str(new)
        record['enumeration']['resolved_sysfs'] = str(new.resolve())
        record['enumeration']['descriptors_sha256'] = hashlib.sha256(descriptor).hexdigest()
        record['enumeration']['interface_classes'] = [read_text(path / 'bInterfaceClass') for path in
            Path('/sys/bus/usb/devices').glob(new.name + ':*') if (path / 'bInterfaceClass').exists()]
        vid, pid = record['enumeration']['idVendor'], record['enumeration']['idProduct']
        invoke(record, ['lsusb', '-v', '-d', f'{vid}:{pid}'], timeout=60)
        if args.mode == 'cdc':
            import serial
            port = None
            while time.monotonic() < deadline:
                candidates = [p for p in Path('/sys/class/tty').glob('ttyACM*')
                              if new.resolve() in (p / 'device').resolve().parents]
                if len(candidates) == 1:
                    port = Path('/dev') / candidates[0].name
                    break
                time.sleep(.1)
            if port is None:
                raise TimeoutError('Linux cdc-acm did not provide a tty')
            record['tty'] = str(port)
            data = bytearray()
            with serial.Serial(str(port), 115200, timeout=.2) as console:
                console.dtr = True
                while time.monotonic() < deadline:
                    fragment = console.read(1024)
                    if not fragment:
                        continue
                    raw.extend(fragment)
                    data.extend(fragment)
                    while b'\n' in data:
                        line, _, rest = data.partition(b'\n')
                        data = bytearray(rest)
                        value = bytes(line).replace(b'\r', b'').decode('ascii', errors='replace')
                        record['lines'].append(dict(text=value, wall_seconds=time.monotonic() - started))
                    if sum(line['text'] == args.expected_line for line in record['lines']) >= 3:
                        break
            if sum(line['text'] == args.expected_line for line in record['lines']) < 3:
                raise TimeoutError('Fewer than three actual CDC greetings')
        else:
            if vid != '2e8a' or 'boot' not in (record['enumeration']['product'] or '').lower():
                raise AssertionError('USB device does not identify as Raspberry Pi BOOTSEL')
            block = None
            while time.monotonic() < deadline:
                candidates = [p for p in Path('/sys/class/block').iterdir()
                              if new.resolve() in (p / 'device').resolve().parents]
                if candidates:
                    block = Path('/dev') / candidates[0].name
                    break
                time.sleep(.1)
            if block is None:
                raise TimeoutError('BOOTSEL did not enumerate a mass-storage block device')
            record['block_device'] = str(block)
            with block.open('rb', buffering=0) as source:
                bootsector = source.read(512)
            (args.output / 'msc_bootsector.bin').write_bytes(bootsector)
            record['msc_bootsector_sha256'] = hashlib.sha256(bootsector).hexdigest()
            if len(bootsector) != 512 or bootsector[510:512] != b'\x55\xaa':
                raise RuntimeError('ROM BOOTSEL block device returned no valid boot sector')
        record['status'] = 'passed'
    except BaseException as error:
        record.update(status='failed', error=str(error))
        raise
    finally:
        if attached:
            try:
                detach(record, command, target)
            except Exception as error:
                record['detach_error'] = str(error)
        if trace is not None:
            trace.terminate()
            try:
                trace.wait(timeout=3)
            except subprocess.TimeoutExpired:
                trace.kill()
                trace.wait(timeout=3)
        if trace_log is not None:
            trace_log.close()
            traffic = (args.output / 'usbmon.txt').read_bytes()
            record['usbmon_sha256'] = hashlib.sha256(traffic).hexdigest()
            traffic_text = traffic.decode(errors='replace')
            counts = dict(get_descriptor=len(re.findall(r'\bS Ci:\S+ s 80 06 ', traffic_text)),
                          set_configuration=len(re.findall(r'\bS Co:\S+ s 00 09 ', traffic_text)),
                          bulk_in_completions=len(re.findall(r'\bC Bi:', traffic_text)),
                          bulk_out_submissions=len(re.findall(r'\bS Bo:', traffic_text)))
            record['usbmon_transfers'] = counts
            if record['status'] == 'passed' and (not all(counts[name] for name in
                    ['get_descriptor', 'set_configuration', 'bulk_in_completions'])
                    or (args.mode == 'bootsel' and not counts['bulk_out_submissions'])):
                record.update(status='failed', error='USB monitor did not record complete control/bulk traffic')
        if args.mode == 'cdc':
            (args.output / 'cdc_bytes.bin').write_bytes(raw)
            record['cdc_bytes_sha256'] = hashlib.sha256(raw).hexdigest()
        record['elapsed_seconds'] = time.monotonic() - started
        record['final_ports'] = invoke(record, command + ['port']).stdout
        (args.output / 'capture.json').write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record, indent=2), flush=True)
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
