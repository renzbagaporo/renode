#!/usr/bin/env python3
"""Observe a core SDK example cold-booted through its board mask ROM.

Run inside run_isolated.py with private HOME/XDG/TMP. Diagnostic mode records
behavior without an acceptance claim. Acceptance mode requires the frozen
catalog and source-specific checks, supplied by extension_checks.py.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

import core_sdk_common as common


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['repository', 'runtime', 'elf', 'rom', 'output', 'scratch', 'dotnet']:
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--board', choices=['pico', 'pico2'], required=True)
    ap.add_argument('--target', required=True)
    ap.add_argument('--rpc-port', type=int, default=19311)
    ap.add_argument('--rpc-timeout', type=float, default=2700)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--diagnostic-seconds', type=float)
    mode.add_argument('--catalog', type=Path)
    ap.add_argument('--variant', default='default')
    ap.add_argument('--profiles', type=Path)
    ap.add_argument('--flash-unique-id', type=lambda x: int(x, 0))
    ap.add_argument('--otp-image', type=Path)
    ap.add_argument('--observe-pin', type=int, default=25)
    ap.add_argument('--uart', default='uart0')
    ap.add_argument('--trace-functions', action='store_true')
    ap.add_argument('--function', action='append', default=[])
    ap.add_argument('--peripheral', action='append', default=[])
    ap.add_argument('--steps', type=Path, help='Predeclared observer/physical-stimulus phases for diagnostic use')
    args = ap.parse_args()
    for name in ['repository', 'runtime', 'elf', 'rom', 'output', 'scratch', 'dotnet']:
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    args.scratch.mkdir(parents=True, exist_ok=True)
    record = dict(board=args.board, target=args.target, variant=args.variant, status='incomplete',
                  observations=[], inputs={}, isolated_paths={}, working_tree_revisions={})
    for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'TMPDIR']:
        value = Path(os.environ[key]).resolve()
        if not value.is_relative_to(args.scratch.parent):
            raise ValueError(f'{key} is not isolated: {value}')
        record['isolated_paths'][key] = str(value)
    inputs = [args.elf, args.elf.with_suffix('.uf2'), args.rom, args.dotnet,
              args.runtime / 'Infrastructure.dll', args.runtime / 'Renode.dll',
              args.runtime / 'platform-lib/translate-arm-m-le.so',
              args.runtime / 'platform-lib/linux-x64/translate-arm-m-le.so',
              Path(__file__).resolve(), Path(common.__file__).resolve()]
    catalog = None
    if args.catalog:
        args.catalog = args.catalog.resolve()
        inputs.append(args.catalog)
        catalog = json.loads(args.catalog.read_text())
        if not args.profiles:
            raise ValueError('Frozen execution profiles are required for acceptance')
        args.profiles = args.profiles.resolve()
        profiles = json.loads(args.profiles.read_text())
        if profiles['catalog_sha256'] != common.sha(args.catalog):
            raise ValueError('Execution profile belongs to a different catalog')
        args.quantum = profiles['case_quantum_seconds'][f'{args.board}/{args.target}']
        inputs.append(args.profiles)
        record['execution_profile'] = dict(path=str(args.profiles), sha256=common.sha(args.profiles))
        record['catalog'] = dict(path=str(args.catalog), sha256=common.sha(args.catalog))
        from extension_checks import check_events, duration_for
        import extension_checks
        inputs.append(Path(extension_checks.__file__).resolve())
        seconds = duration_for(args, catalog)
    else:
        seconds = args.diagnostic_seconds
    record['requested_virtual_seconds'] = seconds
    steps = []
    if args.steps:
        if args.catalog:
            raise ValueError('Arbitrary diagnostic phases cannot be used for acceptance')
        args.steps = args.steps.resolve()
        inputs.append(args.steps)
        steps = json.loads(args.steps.read_text())
    for path in inputs:
        record['inputs'][str(path)] = dict(bytes=path.stat().st_size, sha256=common.sha(path))
    for path in [Path(__file__).resolve(), Path(common.__file__).resolve(), Path(common.__file__).with_name('ExampleObserver.cs')]:
        copy = args.output / path.name
        if copy != path:
            shutil.copy2(path, copy)
    for name, path in [('renode', args.repository), ('infrastructure', args.repository / 'src/Infrastructure'),
                       ('tlib', args.repository / 'src/Infrastructure/src/Emulator/Cores/tlib')]:
        record['working_tree_revisions'][name] = common.working_tree_revision(path)
    try:
        with common.Runtime(args, record) as r:
            names = common.boot(r, args, record)
            if args.observe_pin != 25:
                r.run(f'observer ObserveGPIO gpio {args.observe_pin}')
            if args.uart != 'uart0':
                r.run(f'observer ObserveUART {args.uart}')
            if args.trace_functions:
                r.run('cpu0 LogFunctionNames true')
                r.run('cpu1 LogFunctionNames true')
            for name in args.function:
                if name not in names:
                    raise ValueError(f'Cannot observe absent ELF symbol: {name}')
                for core in ['cpu0', 'cpu1']:
                    r.run(f'observer ObserveAddress {core} 0x{names[name]:x} "{name}" false')
            for item in args.peripheral:
                peripheral, address = item.split(':', 1)
                r.run(f'observer ObservePeripheral {peripheral} {address}')
            for step in steps:
                if set(step) == {'run_for'}:
                    r.seconds(float(step['run_for']))
                elif set(step) == {'command'}:
                    r.run(step['command'])
                else:
                    raise ValueError(f'Invalid diagnostic phase: {step}')
            if args.target == 'narrow_io_write' and args.catalog:
                base = 0x40058000 if args.board == 'pico' else 0x400d8000
                r.run(f'observer ObservePeripheral watchdog 0x{base:x}')
            if args.target == 'hello_divider' and args.board == 'pico' and args.catalog:
                r.run('observer ObservePeripheral sio 0xd0000000')
            if seconds is None and args.target == 'rand':
                elapsed = 0.0
                while True:
                    r.seconds(.1)
                    elapsed += .1
                    progress = json.loads(r.run('observer GetMilestones'))
                    if any(e['kind'] == 'address' and e['label'] in ['_exit', 'panic', 'hard_assertion_failure', '__assert_func'] for e in progress):
                        break
                    if any(e['kind'] == 'interrupt' for e in progress):
                        break
                args.observed_virtual_seconds = elapsed
            elif seconds is None and args.target.startswith('hello_freertos_'):
                elapsed = 0.0
                while True:
                    r.seconds(.5)
                    elapsed += .5
                    progress = json.loads(r.run('observer GetMilestones'))
                    (args.output / 'lifecycle_progress.json').write_text(json.dumps(dict(observed_virtual_seconds=elapsed, milestones=progress), indent=2) + '\n')
                    if any(e['kind'] == 'interrupt' or e.get('label') in ['panic', 'hard_assertion_failure', '__assert_func', 'panic_unsupported', 'prvTaskExitError'] for e in progress):
                        break
                    if any(e.get('label') == 'async_context_freertos_deinit_return' for e in progress):
                        case = next(c for c in catalog['cases'] if c['id'] == f'{args.board}/{args.target}')
                        post = next(c['post_deinit_observe_seconds'] for c in case['checks'] if c['id'] == 'worker')
                        r.seconds(post)
                        elapsed += post
                        break
                args.observed_virtual_seconds = elapsed
            else:
                r.seconds(seconds)
                args.observed_virtual_seconds = seconds
            if args.catalog and args.target == 'unique_board_id':
                record['physical_run_stimuli'] = []
                peripheral, pin = ('psm', 0) if args.board == 'pico' else ('debug_port', 2)
                for command in [f'{peripheral} OnGPIO {pin} false', 'emulation RunFor "0.001"',
                                f'{peripheral} OnGPIO {pin} true']:
                    item = dict(command=command, before=r.run('emulation GetTimeSourceInfo'))
                    r.run(command)
                    record['physical_run_stimuli'].append(item)
                r.seconds(seconds)
                args.observed_virtual_seconds += .001 + seconds
            r.capture_native()
            record['observed_virtual_seconds'] = args.observed_virtual_seconds
            events = json.loads(r.run('observer GetEvents'))
            (args.output / 'events.json').write_text(json.dumps(events, indent=2) + '\n')
            (args.output / 'uart.txt').write_text(common.uart_text(events))
            record['events_sha256'] = common.sha(args.output / 'events.json')
            if args.catalog:
                record['checks'] = check_events(args, catalog, events, r)
                record['status'] = 'passed'
            else:
                record['status'] = 'diagnostic_only'
            for cmd in ['cpu0 PC', 'cpu0 SP', 'cpu1 PC', 'cpu1 SP', 'cpu0 IsHalted', 'cpu1 IsHalted',
                        'cpu0 ExecutedInstructions', 'cpu1 ExecutedInstructions',
                        'machine ElapsedVirtualTime', 'sio Output', 'sio OutputEnable']:
                r.run(cmd)
            for core in ['cpu0', 'cpu1']:
                for register in ['LR', 'R0', 'R1', 'R2', 'R3', 'R12']:
                    r.run(f'{core} GetRegister "{register}"')
    except BaseException as exc:
        record.update(status='failed', error=str(exc))
        raise
    finally:
        (args.output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda signum, frame: (_ for _ in ()).throw(InterruptedError(f'signal {signum}')))
    sys.exit(main())
