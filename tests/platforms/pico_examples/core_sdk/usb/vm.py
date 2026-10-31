#!/usr/bin/env python3
"""Manage one task-owned USB/IP Linux guest without host USB passthrough.

Usage: vm.py --directory TASK_VM --output VM_OUTPUT start --backing OLD_GUEST
       --seed OLD_SEED_ISO
       vm.py --directory TASK_VM --output VM_OUTPUT run --timeout 120 'COMMAND'
       vm.py --directory TASK_VM --output VM_OUTPUT stop
The prior guest disk is a read-only qcow2 backing image; all guest writes and
console/output files belong to TASK_VM/VM_OUTPUT. No host packages are installed.
"""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import sys
import time
import uuid


def references(path):
    needle = str(path.resolve()).encode()
    found = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            if needle in (proc / 'cmdline').read_bytes():
                found.append(int(proc.name))
        except OSError:
            pass
    return found


def live_pid(directory):
    path = directory / 'qemu.pid'
    if not path.exists():
        return None
    pid = int(path.read_text())
    try:
        command = Path(f'/proc/{pid}/cmdline').read_bytes()
    except OSError:
        return None
    return pid if str(directory / 'guest.qcow2').encode() in command else None


def run_guest(directory, command, timeout):
    if live_pid(directory) is None:
        raise RuntimeError('Task USB guest is not running')
    lock = (directory / 'console.lock').open('a+')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    marker = '__PICO_USB_' + uuid.uuid4().hex + '__'
    encoded = base64.b64encode(command.encode()).decode()
    shell = f"stty -echo; dmesg -n 1; printf '\\n{marker}BEGIN\\n'; printf '%s' '{encoded}' | base64 -d | bash; result=$?; printf '\\n{marker}END:%s\\n' \"$result\"\n"
    original = Path.cwd()
    try:
        os.chdir(directory)
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect('serial.sock')
            sock.sendall(shell.encode())
            data, started = b'', False
            deadline = time.monotonic() + timeout
            begin = re.compile((marker + r'BEGIN\r*\n').encode())
            end = re.compile((marker + r'END:(\d+)\r*\n').encode())
            while time.monotonic() < deadline:
                if not select.select([sock], [], [], min(1, deadline - time.monotonic()))[0]:
                    continue
                chunk = sock.recv(65536)
                if not chunk:
                    raise RuntimeError('Guest console disconnected')
                data += chunk
                match = begin.search(data) if not started else None
                if match:
                    data, started = data[match.end():], True
                match = end.search(data) if started else None
                if match:
                    return int(match.group(1)), data[:match.start()].replace(b'\r', b'').decode(errors='replace')
            raise TimeoutError('Guest console command timed out; partial output: ' + data.decode(errors='replace'))
    finally:
        os.chdir(original)
        lock.close()


def start(args):
    directory, output = args.directory, args.output
    if live_pid(directory) is not None:
        raise RuntimeError('Task USB guest is already running')
    backing = args.backing.resolve(strict=True)
    seed = args.seed.resolve(strict=True)
    active = references(backing)
    if active:
        raise RuntimeError(f'Backing guest disk is in use by {active}')
    directory.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    overlay = directory / 'guest.qcow2'
    if overlay.exists():
        raise RuntimeError('Refusing to reuse an existing task overlay')
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(backing), str(overlay)], check=True)
    guest_output = output / 'guest_outputs'
    guest_output.mkdir()
    helpers = Path(__file__).resolve().parent
    command = [
        'qemu-system-x86_64', '-enable-kvm', '-machine', 'q35', '-cpu', 'host',
        '-m', str(args.memory), '-smp', '2', '-display', 'none',
        '-drive', f'file={overlay},if=virtio,format=qcow2',
        '-drive', f'file={seed},media=cdrom,readonly=on',
        '-netdev', 'user,id=nat', '-device', 'virtio-net-pci,netdev=nat',
        '-fsdev', f'local,id=helpers,path={helpers},security_model=none,readonly=on',
        '-device', 'virtio-9p-pci,fsdev=helpers,mount_tag=helpers',
        '-fsdev', f'local,id=outputs,path={guest_output},security_model=none',
        '-device', 'virtio-9p-pci,fsdev=outputs,mount_tag=guest_outputs',
        '-chardev', f'socket,id=console,path=serial.sock,server=on,wait=off,logfile={output / "serial.log"},logappend=on',
        '-serial', 'chardev:console', '-qmp', 'unix:qmp.sock,server=on,wait=off',
        '-pidfile', str(directory / 'qemu.pid'), '-daemonize',
    ]
    subprocess.run(command, cwd=directory, check=True)
    manifest = dict(command=command, backing=str(backing), overlay=str(overlay),
                    qemu_pid=live_pid(directory), no_host_usb=True, lease='pico_examples_usb_cases',
                    started_unix=time.time())
    (output / 'vm_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


def stop(args):
    pid = live_pid(args.directory)
    if pid is None:
        print('Task guest is already stopped')
        return
    original = Path.cwd()
    try:
        os.chdir(args.directory)
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect('qmp.sock')
            handle = sock.makefile('rwb', buffering=0)
            handle.readline()
            for command in ['qmp_capabilities', 'system_powerdown']:
                handle.write((json.dumps({'execute': command}) + '\n').encode())
                while True:
                    response = json.loads(handle.readline())
                    if 'return' in response or 'error' in response:
                        break
                if 'error' in response:
                    raise RuntimeError(response)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if live_pid(args.directory) is None:
                print(f'Task guest {pid} shut down')
                return
            time.sleep(.2)
        raise TimeoutError('Guest did not complete graceful powerdown')
    finally:
        os.chdir(original)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    commands = parser.add_subparsers(dest='action', required=True)
    launch = commands.add_parser('start')
    launch.add_argument('--backing', type=Path, required=True)
    launch.add_argument('--seed', type=Path, required=True)
    launch.add_argument('--memory', type=int, default=2048)
    run = commands.add_parser('run')
    run.add_argument('--timeout', type=float, default=120)
    run.add_argument('command')
    commands.add_parser('stop')
    commands.add_parser('status')
    args = parser.parse_args()
    args.directory, args.output = args.directory.resolve(), args.output.resolve()
    if args.action == 'start':
        start(args)
    elif args.action == 'run':
        status, output = run_guest(args.directory, args.command, args.timeout)
        print(output, end='')
        return status
    elif args.action == 'stop':
        stop(args)
    else:
        print(json.dumps(dict(pid=live_pid(args.directory))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
