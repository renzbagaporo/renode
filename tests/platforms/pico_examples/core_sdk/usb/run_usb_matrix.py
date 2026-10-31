#!/usr/bin/env python3
"""Run frozen metadata and physical-reset scenarios with an exclusive Linux guest.

Usage: run_usb_matrix.py --repository REPO --runtime DIR --dotnet DOTNET
 --board pico|pico2 --build-manifest FILE --metadata-ledger FILE --catalog FILE
 --profiles FILE --rom FILE --isolator FILE --vm-directory DIR --vm-output DIR
 --output NEW_DIR --scratch NEW_DIR [--cases hello_anything hello_double_tap]
The caller prepares the task-owned VM with vhci_hcd, cdc_acm and guest_outputs
mounted. This driver snapshots its helpers and starts a fresh isolated Renode
process per scenario. Guest captures serialize through a shared capture lease.
"""
import argparse
import datetime
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from core_sdk_common import check, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['repository', 'runtime', 'dotnet', 'build-manifest', 'catalog', 'profiles',
                 'rom', 'isolator', 'vm-directory', 'vm-output', 'output', 'scratch']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--metadata-ledger', type=Path)
    parser.add_argument('--board', choices=['pico', 'pico2'], required=True)
    parser.add_argument('--cases', nargs='+', choices=['hello_anything', 'hello_double_tap'])
    parser.add_argument('--rpc-port', type=int, default=19501)
    parser.add_argument('--usb-port', type=int, default=3351)
    parser.add_argument('--wall-timeout', type=float, default=1800)
    parser.add_argument('--diagnostic-only', action='store_true')
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, name, value.resolve())
    check(args.wall_timeout > 60, 'A wall budget above 60 seconds is required')
    check(not args.cases or len(args.cases) == len(set(args.cases)), 'Duplicate selected case')
    args.output.mkdir(parents=True, exist_ok=False)
    args.scratch.mkdir(parents=True, exist_ok=False)
    catalog = json.loads(args.catalog.read_text())
    profiles = json.loads(args.profiles.read_text())
    check(profiles['catalog_sha256'] == sha(args.catalog), 'Profiles belong to a different catalog')
    build = json.loads(args.build_manifest.read_text())
    check(build['status'] == 'built' and build['board'] == args.board, 'Wrong/incomplete firmware build')
    cases = [c for c in catalog['cases'] if c['board'] == args.board
             and c['target'] in (args.cases or ['hello_anything', 'hello_double_tap'])]
    check(len(cases) == len(args.cases or ['hello_anything', 'hello_double_tap']), 'Missing catalog case')
    metadata = json.loads(args.metadata_ledger.read_text()) if args.metadata_ledger else None
    inputs = [args.catalog, args.profiles, args.build_manifest, args.rom]
    if args.metadata_ledger:
        inputs.append(args.metadata_ledger)
    files = {}
    for target in {c['target'] for c in cases}:
        artifact = next(a for a in build['artifacts'] if a['target'] == target)
        for item in artifact['files']:
            path = Path(item['path'])
            if path.suffix in ['.elf', '.uf2']:
                check(sha(path) == item['sha256'], 'Built firmware changed')
                inputs.append(path)
                if path.suffix == '.elf':
                    files[target] = path
    tools = args.output / 'tools'
    (tools / 'usb').mkdir(parents=True)
    directory = Path(__file__).resolve().parent
    for source in directory.glob('*.py'):
        shutil.copy2(source, tools / 'usb' / source.name)
    for name in ['core_sdk_common.py', 'ExampleObserver.cs']:
        shutil.copy2(directory.parent / name, tools / name)
    shutil.copy2(args.isolator, tools / 'run_isolated.py')
    record = dict(board=args.board, selected_cases=[c['id'] for c in cases], status='running', results=[],
                  inputs={str(p): sha(p) for p in inputs},
                  tools={str(p.relative_to(tools)): sha(p) for p in tools.rglob('*') if p.is_file()})
    ledger = args.output / 'acceptance.json'
    controls = dict(cold_normal_blink='cold', two_run_taps_inside_window='inside',
                    two_run_taps_outside_window='outside')
    try:
        for case in cases:
            target = case['target']
            for scenario in case['scenarios']:
                elf, extra = files[target], []
                if target == 'hello_anything':
                    check(metadata is not None and metadata['status'] == 'prepared'
                          and metadata['board'] == args.board, 'Prepared board metadata is required')
                    selected = [e for e in metadata['results'] if e['target'] == target and e['scenario'] == scenario]
                    check(len(selected) == 1 and selected[0]['returncode'] == 0, 'Missing metadata scenario')
                    configuration = Path(selected[0]['configuration'])
                    check(sha(configuration) == selected[0]['configuration_sha256'], 'Metadata ledger changed')
                    values = json.loads(configuration.read_text())
                    elf = Path(values['configured_elf']['path'])
                    extra += ['--variant', scenario, '--configuration', str(configuration)]
                    record['inputs'][str(configuration)] = sha(configuration)
                else:
                    check(scenario in controls, 'Unknown reset scenario')
                    extra += ['--reset-control', controls[scenario]]
                key = target + '__' + scenario
                command = [sys.executable, str(tools / 'run_isolated.py'), '--output', str(args.output / key),
                           '--scratch', str(args.scratch / key), '--timeout', str(args.wall_timeout), '--',
                           sys.executable, str(tools / 'usb/run_usb_extension.py')]
                for name in ['repository', 'runtime', 'dotnet', 'rom', 'catalog', 'profiles', 'board',
                             'vm_directory', 'vm_output', 'rpc_port', 'usb_port']:
                    command += ['--' + name.replace('_', '-'), str(getattr(args, name))]
                command += ['--target', target, '--elf', str(elf), '--output', '{output}',
                            '--scratch', '{scratch}/scenario', '--rpc-timeout', str(args.wall_timeout - 30),
                            '--timeout', str(args.wall_timeout - 60), *extra]
                if args.diagnostic_only:
                    command.append('--diagnostic-only')
                item = dict(id=case['id'], scenario=scenario, command=command, status='running',
                            started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                record['results'].append(item)
                ledger.write_text(json.dumps(record, indent=2) + '\n')
                proc = subprocess.run(command, capture_output=True, text=True)
                item.update(returncode=proc.returncode, wrapper_output=proc.stdout + proc.stderr,
                            finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                result_path = args.output / key / 'result.json'
                item['status'] = 'setup_error'
                if result_path.is_file():
                    result = json.loads(result_path.read_text())
                    item.update(status=result['status'], renode_returncode=result.get('child_returncode'),
                                result=str(result_path), result_sha256=sha(result_path))
                    for path, entry in result['inputs'].items():
                        check(sha(Path(path)) == entry['sha256'], 'Scenario input changed during execution')
                print(case['id'], scenario, item['status'], flush=True)
                ledger.write_text(json.dumps(record, indent=2) + '\n')
        for path, expected in record['inputs'].items():
            check(sha(Path(path)) == expected, 'Matrix input changed during execution')
        for path, expected in record['tools'].items():
            check(sha(tools / path) == expected, 'Frozen helper changed during execution')
        wanted = 'diagnostic_only' if args.diagnostic_only else 'passed'
        success = all(r['status'] == wanted and r['returncode'] == 0 and r.get('renode_returncode') == 0
                      for r in record['results'])
        record['status'] = wanted if success else 'failed'
    except BaseException as error:
        record.update(status='failed', error=str(error))
        raise
    finally:
        ledger.write_text(json.dumps(record, indent=2) + '\n')
    return 0 if record['status'] in ['passed', 'diagnostic_only'] else 1


if __name__ == '__main__':
    sys.exit(main())
