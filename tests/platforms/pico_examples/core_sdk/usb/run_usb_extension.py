#!/usr/bin/env python3
"""Observe metadata CDC output or double-tap BOOTSEL using an isolated USB guest.

Run under run_isolated.py with --repository, --runtime, --board, --target,
--elf, --rom, --output, --scratch, --vm-directory and --vm-output. The target is
hello_anything or hello_double_tap. For double-tap choose --reset-control
inside, outside or cold. Each control cold-boots a separate Renode process.
No SRAM/application register injection is performed. RUN is the sole reset
stimulus; observation hooks never provide responses to the firmware.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import core_sdk_common as common
import vm


def events(runtime, args):
    observed = json.loads(runtime.run('observer GetEvents').strip())
    (args.output / 'events.json').write_text(json.dumps(observed, indent=2) + '\n')
    (args.output / 'uart.txt').write_text(common.uart_text(observed))
    return observed


def check_errors(observed):
    errors = {'panic', 'hard_assertion_failure', '__assert_func', 'panic_unsupported',
              '__unhandled_user_irq', 'prvTaskExitError'}
    common.check(not any(e.get('label') in errors for e in observed),
                 'Firmware reached an error path')
    faults = {1, 3, 4, 7, 16, 17, 18, 19, 20, 21}
    common.check(not any(e.get('kind') == 'interrupt' and e['exception_kind'] in faults
                         for e in observed), 'Unexpected architectural fault')


def prepare_metadata(args, record):
    common.check(args.configuration is not None, 'hello_anything requires its official picotool configuration ledger')
    configuration = json.loads(args.configuration.read_text())
    common.check(configuration['status'] == 'configured' and configuration['board'] == args.board,
                 'Wrong or incomplete metadata configuration')
    common.check(configuration['data_only_changes_proved'], 'Metadata configuration changed executable code')
    common.check(configuration['configured_elf']['sha256'] == common.sha(args.elf), 'Configured ELF hash differs')
    common.check(configuration['uf2']['sha256'] == common.sha(args.elf.with_suffix('.uf2')), 'Configured UF2 hash differs')
    original = Path(configuration['original_elf']['path'])
    common.check(common.sha(original) == configuration['original_elf']['sha256'], 'Original ELF changed')
    for path in [args.configuration.resolve(), original.resolve(), args.elf.with_suffix('.uf2')]:
        record['inputs'][str(path)] = dict(bytes=path.stat().st_size, sha256=common.sha(path))
    patched = bytearray(original.read_bytes())
    defaults = dict(text='Hello, world!', uart_num=0, uart_tx=0, uart_rx=1,
                    uart_baud=115200, use_uart=1, use_usb=1)
    wanted = dict(defaults)
    if args.variant == 'configured_dual_stdio':
        wanted.update(text='Goodbye, world!', uart_num=1, uart_tx=4, uart_rx=5, uart_baud=57600)
    elif args.variant == 'uart_only':
        wanted['use_usb'] = 0
    elif args.variant == 'usb_only':
        wanted['use_uart'] = 0
    actual = dict(defaults)
    actual.update(configuration['settings'])
    common.check(actual == wanted, 'Metadata values do not match the frozen scenario')
    for change in configuration['changes']:
        common.check(change['variable'] in defaults, 'Unexpected configured variable')
        start = change['file_offset']
        before, after = bytes.fromhex(change['original']), bytes.fromhex(change['expected'])
        common.check(patched[start:start + len(before)] == before, 'Original metadata bytes differ')
        patched[start:start + len(after)] = after
    common.check(bytes(patched) == args.elf.read_bytes(), 'ELF contains changes outside declared metadata')
    args.expected_line = wanted['text']
    record['metadata_configuration'] = dict(path=str(args.configuration), sha256=common.sha(args.configuration), settings=wanted)
    return wanted


def check_stdio(runtime, args, record, observed, settings):
    mains = [e for e in observed if e.get('label') == 'main' and e.get('core') == 0]
    common.check(len(mains) == 1, 'Metadata example did not enter main once')
    selected = 'uart' + str(settings['uart_num'])
    app_uart = [e for e in observed if e.get('kind') == 'uart' and e['seconds'] >= mains[0]['seconds']]
    if settings['use_uart']:
        common.check(all(e.get('uart') == selected for e in app_uart), 'Wrong UART emitted application bytes')
        greetings = [(line, stamp) for line, stamp in common.uart_lines(app_uart) if line]
        common.check(len(greetings) >= 3 and all(line == settings['text'] for line, _ in greetings),
                     'Missing or incorrect actual UART greeting bytes')
        periods = [b[1] - a[1] for a, b in zip(greetings, greetings[1:])]
        common.check(all(.95 <= value <= 1.05 for value in periods), 'Incorrect UART greeting cadence')
        record['uart_greeting_periods'] = periods
        baud = int(runtime.run(f'{selected} BaudRate'), 0)
        common.check(abs(baud - settings['uart_baud']) <= settings['uart_baud'] * .01,
                     'UART baud divider does not implement the configured baud rate')
        gpio_base = 0x40014000 if args.board == 'pico' else 0x40028000
        for pin in [settings['uart_tx'], settings['uart_rx']]:
            ctrl = int(runtime.run(f'sysbus ReadDoubleWord 0x{gpio_base + 8 * pin + 4:x}'), 0)
            common.check(ctrl & 31 == 2, f'GPIO{pin} is not muxed to UART')
    else:
        common.check(not app_uart, 'Disabled UART emitted application bytes')
    for uart in [0, 1]:
        base = (0x40034000 if args.board == 'pico' else 0x40070000) + uart * (0x4000 if args.board == 'pico' else 0x8000)
        control = int(runtime.run(f'sysbus ReadDoubleWord 0x{base + 0x30:x}'), 0)
        enabled = bool(control & 1)
        common.check(enabled == bool(settings['use_uart'] and uart == settings['uart_num']),
                     f'UART{uart} enabled state differs from metadata')
    if settings['use_usb']:
        writes = [e for e in observed if e.get('label') == 'usb_write' and e.get('r1', 0) >= len(settings['text'])]
        common.check(len(writes) >= 3, 'Fewer than three actual USB greeting writes')
        periods = [b['seconds'] - a['seconds'] for a, b in zip(writes, writes[1:])]
        common.check(all(.95 <= value <= 1.05 for value in periods), 'Incorrect USB greeting virtual cadence')
        record['usb_greeting_periods'] = periods
    else:
        common.check(runtime.run('usb IsConnected').strip() == 'False', 'Disabled USB exposed a device')


def blink(observed, main):
    edges = []
    for e in observed:
        if e.get('kind') != 'gpio' or not e['enabled'] or e['seconds'] < main:
            continue
        if not edges and not e['level']:
            continue
        if not edges or edges[-1]['level'] != e['level']:
            edges.append(e)
    common.check(len(edges) >= 7, 'Fewer than three full LED cycles')
    intervals = [b['seconds'] - a['seconds'] for a, b in zip(edges, edges[1:])]
    common.check(all(.2375 <= v <= .2625 for v in intervals),
                 f'Double-tap normal LED periods: {intervals}')


def pulse(runtime, args, record):
    endpoint = 'psm' if args.board == 'pico' else 'debug_port'
    pin = 0 if args.board == 'pico' else 2
    before = runtime.run('machine ElapsedVirtualTime').strip()
    runtime.run(f'{endpoint} OnGPIO {pin} false')
    runtime.seconds(.001)
    runtime.run(f'{endpoint} OnGPIO {pin} true')
    record.setdefault('run_pulses', []).append(dict(endpoint=endpoint, pin=pin,
        active_low=True, held_virtual_seconds=.001, before=before,
        after=runtime.run('machine ElapsedVirtualTime').strip()))


def run_resets(runtime, args, record, names):
    common.check('boot_double_tap_check' in names, 'Missing SDK double-tap constructor')
    runtime.run(f'observer ObserveAddress cpu0 0x{names["boot_double_tap_check"]:x} "double_tap_constructor" false')
    # Start with an ordinary boot beyond the constructor window. This also
    # establishes that a token was produced and cleared by the firmware itself.
    runtime.seconds(2)
    observed = events(runtime, args)
    check_errors(observed)
    mains = [e for e in observed if e.get('label') == 'main' and e.get('core') == 0]
    common.check(len(mains) == 1, 'Initial cold boot did not enter main once')
    blink(observed, mains[0]['seconds'])
    if args.board == 'pico2' and args.reset_control == 'inside':
        status = int(runtime.run('otp ReadDoubleWord 0x15c'), 0)
        common.check(status == 0, 'Default Pico 2 did not cold-boot with Arm selected')
        record['cold_architecture_status'] = status
        for core in [0, 1]:
            common.check(int(runtime.run(f'riscv{core} ExecutedInstructions'), 0) == 0,
                         'Deselected RISC-V engine executed before the double tap')
    if args.reset_control == 'cold':
        return False
    pulse(runtime, args, record)
    elapsed = 2.001
    # Locate the actual constructor entry instead of including ROM startup in
    # the prescribed 100/300 ms interval. Hooks remain observation-only.
    for _ in range(100):
        ctors = [e for e in events(runtime, args) if e.get('label') == 'double_tap_constructor']
        if len(ctors) == 2:
            break
        runtime.seconds(.001)
        elapsed += .001
    common.check(len(ctors) == 2, 'First RUN tap did not reach the constructor')
    offset = .1 if args.reset_control == 'inside' else .3
    remaining = ctors[-1]['seconds'] + offset - elapsed
    common.check(remaining > 0, 'Constructor observation exceeded the reset interval')
    runtime.seconds(remaining)
    record['second_reset_offset_from_constructor_seconds'] = offset
    after_first = events(runtime, args)
    ctors = [e for e in after_first if e.get('label') == 'double_tap_constructor']
    common.check(len(ctors) == 2, 'First physical RUN tap did not reenter SDK constructor')
    new_mains = [e for e in after_first if e.get('label') == 'main' and e.get('core') == 0]
    common.check(len(new_mains) == (1 if args.reset_control == 'inside' else 2),
                 'Constructor did not obey its 200 ms pre-main window')
    pulse(runtime, args, record)
    runtime.seconds(2)
    observed = events(runtime, args)
    check_errors(observed)
    common.check(len([e for e in observed if e.get('label') == 'double_tap_constructor']) == 3,
                 'Second physical RUN tap did not reenter SDK constructor')
    mains = [e for e in observed if e.get('label') == 'main' and e.get('core') == 0]
    if args.reset_control == 'outside':
        common.check(len(mains) == 3, 'Outside-window taps did not boot the application')
        blink(observed, mains[-1]['seconds'])
        common.check(runtime.run('usb IsConnected').strip() == 'False',
                     'Outside-window control unexpectedly enabled ROM USB')
        return False
    common.check(len(mains) == 1, 'Inside-window second boot entered application main')
    processor = 'cpu0'
    if args.board == 'pico2':
        status = int(runtime.run('otp ReadDoubleWord 0x15c'), 0)
        record['post_double_tap_architecture_status'] = status
        common.check(status & 1 != 0, 'Default activity-LED workaround did not select RISC-V')
        common.check(runtime.run('riscv0 ArchitectureEnabled').strip() == 'True',
                     'Selected RISC-V engine is disabled')
        common.check(int(runtime.run('riscv0 ExecutedInstructions'), 0) > 0,
                     'Selected RISC-V engine did not execute the ROM')
        processor = 'riscv0'
        record['arm_instructions_before_usb'] = []
        for core in [0, 1]:
            if status & (1 << core):
                common.check(runtime.run(f'cpu{core} HasAnyHaltingCondition').strip() == 'True',
                             'Deselected Arm engine has no active execution hold')
                record['arm_instructions_before_usb'].append(dict(core=core,
                    instructions=int(runtime.run(f'cpu{core} ExecutedInstructions'), 0)))
    record['post_double_tap_processor'] = processor
    record['post_double_tap_pc'] = int(runtime.run(f'{processor} PC').strip(), 0)
    common.check(0 <= record['post_double_tap_pc'] < (0x4000 if args.board == 'pico' else 0x8000),
                 'Double-tap did not enter the official ROM')
    return True


def capture(runtime, args, record):
    lease = (args.vm_directory / 'usb_capture.lock').open('a')
    began = time.monotonic()
    while True:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() - began >= args.timeout:
                lease.close()
                raise TimeoutError('Exclusive guest USB capture lease')
            time.sleep(.1)
    record['guest_lease_wait_seconds'] = time.monotonic() - began
    guest_root = args.vm_output / 'guest_outputs'
    task_id = hashlib.sha256(str(args.output).encode()).hexdigest()[:16]
    guest_dir = guest_root / (task_id + '_' + args.output.name)
    guest_dir.mkdir(parents=True, exist_ok=False)
    helper = Path(__file__).with_name('guest_capture.py')
    shutil.copy2(helper, guest_dir / helper.name)
    shutil.copy2(Path(__file__).with_name('guest_run.py'), guest_dir / 'guest_run.py')
    guest_path = '/mnt/guest_outputs/' + guest_dir.relative_to(guest_root).as_posix()
    command = ['python3', guest_path + '/guest_capture.py', '--mode',
        'cdc' if args.target == 'hello_anything' else 'bootsel', '--port', str(args.usb_port),
        '--output', guest_path + '/capture', '--timeout', str(args.timeout),
        '--expected-line', args.expected_line]
    supervised = ['python3', guest_path + '/guest_run.py', guest_path, *command]
    launch = ('import subprocess; p=subprocess.Popen(' + repr(supervised)
        + ',stdout=open(' + repr(guest_path + '/guest.log')
        + ',"w"),stderr=subprocess.STDOUT,start_new_session=True); print(p.pid)')
    guest_pid = None
    try:
        runtime.run(f'emulation CreateUSBIPServer {args.usb_port} "core_sdk"')
        runtime.run('host.core_sdk Register usb 0 Full')
        runtime.run('start')
        status, result = vm.run_guest(args.vm_directory, 'python3 -c ' + shlex.quote(launch), 30)
        common.check(status == 0, 'Guest capture launch failed: ' + result)
        guest_pid = int(result.strip())
        record['guest_launch'] = dict(command=command, returncode=status, pid=guest_pid)
        final = guest_dir / 'capture/capture.json'
        terminal = guest_dir / 'guest_terminal.json'
        deadline = time.monotonic() + args.timeout + 30
        while not terminal.is_file():
            common.check(runtime.proc.poll() is None, 'Renode exited during USB capture')
            if time.monotonic() >= deadline:
                raise TimeoutError('Guest capture did not finish')
            time.sleep(.2)
        completion = json.loads(terminal.read_text())
        record['guest_terminal'] = dict(path=str(terminal), sha256=common.sha(terminal), result=completion)
        common.check(completion['returncode'] == 0, 'Actual guest capture process exited unsuccessfully')
        common.check(final.is_file(), 'Guest capture exited without a result')
        guest = json.loads(final.read_text())
        record['guest_capture'] = dict(path=str(final), sha256=common.sha(final), result=guest)
        common.check(guest['status'] == 'passed' and not guest.get('detach_error'),
                     'Guest USB capture failed: ' + str(guest))
        runtime.run('pause')
        check_errors(events(runtime, args))
    finally:
        if guest_pid is not None and not (guest_dir / 'guest_terminal.json').is_file():
            stop = ('import os,signal; p=' + str(guest_pid)
                    + '; os.killpg(p,signal.SIGTERM) if os.path.exists(f"/proc/{p}") else None')
            status, result = vm.run_guest(args.vm_directory, 'python3 -c ' + shlex.quote(stop), 30)
            record['guest_cleanup'] = dict(returncode=status, output=result)
        lease.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['repository', 'runtime', 'elf', 'rom', 'output', 'scratch', 'vm-directory', 'vm-output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--dotnet', type=Path, required=True)
    parser.add_argument('--board', choices=['pico', 'pico2'], required=True)
    parser.add_argument('--target', choices=['hello_anything', 'hello_double_tap'], required=True)
    parser.add_argument('--reset-control', choices=['cold', 'inside', 'outside'], default='inside')
    parser.add_argument('--variant', choices=['default_dual_stdio', 'configured_dual_stdio', 'uart_only', 'usb_only'], default='default_dual_stdio')
    parser.add_argument('--configuration', type=Path)
    parser.add_argument('--catalog', type=Path)
    parser.add_argument('--profiles', type=Path)
    parser.add_argument('--expected-line', default='Hello, world!')
    parser.add_argument('--rpc-port', type=int, default=19501)
    parser.add_argument('--usb-port', type=int, default=3351)
    parser.add_argument('--rpc-timeout', type=float, default=120)
    parser.add_argument('--timeout', type=float, default=900)
    parser.add_argument('--diagnostic-only', action='store_true')
    args = parser.parse_args()
    for name in ['repository', 'runtime', 'elf', 'rom', 'output', 'scratch', 'vm_directory', 'vm_output', 'dotnet']:
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    args.scratch.mkdir(parents=True, exist_ok=True)
    record = dict(board=args.board, target=args.target, reset_control=args.reset_control,
                  variant=args.variant, observations=[], inputs={}, status='incomplete')
    for path in [args.runtime / 'Infrastructure.dll', args.runtime / 'Renode.dll', Path(__file__).resolve(),
                 Path(common.__file__).resolve(), Path(__file__).with_name('vm.py'),
                 Path(__file__).with_name('guest_capture.py'), Path(__file__).with_name('guest_run.py'),
                 *[args.runtime / 'platform-lib' / prefix / f'translate-{arch}-le.so'
                   for arch in ['arm-m', 'arm', 'riscv32'] for prefix in ['', 'linux-x64']]]:
        if path.is_file():
            record['inputs'][str(path)] = dict(bytes=path.stat().st_size, sha256=common.sha(path))
    settings = prepare_metadata(args, record) if args.target == 'hello_anything' else None
    if not args.diagnostic_only:
        common.check(args.catalog is not None and args.profiles is not None, 'Frozen catalog and profiles are required for acceptance')
    if args.catalog:
        common.check(args.profiles is not None, 'Frozen execution profiles are required with a catalog')
        catalog = json.loads(args.catalog.read_text())
        case = next(c for c in catalog['cases'] if c['id'] == f'{args.board}/{args.target}')
        scenario = args.variant if settings is not None else {
            'cold': 'cold_normal_blink', 'inside': 'two_run_taps_inside_window', 'outside': 'two_run_taps_outside_window'}[args.reset_control]
        common.check(scenario in case['scenarios'], 'Scenario is absent from frozen catalog')
        profiles = json.loads(args.profiles.read_text())
        common.check(profiles['catalog_sha256'] == common.sha(args.catalog), 'Profiles belong to a different catalog')
        args.quantum = profiles['case_quantum_seconds'][case['id']]
        record['catalog'] = dict(path=str(args.catalog), sha256=common.sha(args.catalog))
        record['execution_profile'] = dict(path=str(args.profiles), sha256=common.sha(args.profiles))
    for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'TMPDIR']:
        path = Path(os.environ[key]).resolve()
        common.check(path.is_relative_to(args.scratch.parent), f'Unisolated {key}: {path}')
    try:
        with common.Runtime(args, record) as runtime:
            names = common.boot(runtime, args, record)
            want_usb = True
            if args.target == 'hello_double_tap':
                want_usb = run_resets(runtime, args, record, names)
            else:
                if settings['uart_num'] == 1:
                    runtime.run('observer ObserveUART uart1')
                common.check('stdio_usb_out_chars' in names, 'Missing actual USB output function')
                runtime.run(f'observer ObserveAddress cpu0 0x{names["stdio_usb_out_chars"]:x} "usb_write" false')
                runtime.seconds(.05)
                want_usb = bool(settings['use_usb'])
                if not want_usb:
                    runtime.seconds(4)
            if want_usb:
                common.check(runtime.run('usb IsConnected').strip() == 'True', 'USB is not enabled')
                capture(runtime, args, record)
            observed = events(runtime, args)
            check_errors(observed)
            if settings is not None:
                check_stdio(runtime, args, record, observed, settings)
            if args.target == 'hello_double_tap':
                for item in record.get('arm_instructions_before_usb', []):
                    common.check(int(runtime.run(f'cpu{item["core"]} ExecutedInstructions'), 0) == item['instructions'],
                                 'Deselected Arm engine executed during RISC-V USB traffic')
                size = 0x200000 if args.board == 'pico' else 0x400000
                final = args.output / 'final_nor.bin'
                runtime.run(f'observer DumpObservedMemory "{final}" 0 {size}')
                expected, _ = common.extract_flash(args.elf, args.board)
                common.check(final.read_bytes() == bytes(expected) + b'\xff' * (size - len(expected)),
                             'RUN/BOOTSEL changed the physical NOR array')
                record['final_nor_sha256'] = common.sha(final)
            runtime.capture_native()
            record['status'] = 'diagnostic_only' if args.diagnostic_only else 'passed'
        for path, entry in record['inputs'].items():
            common.check(common.sha(Path(path)) == entry['sha256'], 'Input changed during USB scenario: ' + path)
    except BaseException as error:
        record.update(status='failed', error=str(error))
        raise
    finally:
        (args.output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
