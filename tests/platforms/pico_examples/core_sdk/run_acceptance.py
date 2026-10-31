#!/usr/bin/env python3
"""Run selected frozen non-USB core SDK cases with private Renode processes.

Usage: run_acceptance.py --repository REPO --runtime DIR --dotnet DOTNET
 --board pico|pico2 --build-manifest MANIFEST --catalog CATALOG --profiles FILE
 --metadata-ledger FILE --identity-fixtures FILE --rom MASK_ROM --isolator FILE
 --output NEW_DIR --scratch NEW_DIR [--cases TARGET ...] [--rpc-port PORT]
Double-tap and hello_anything require the separate USB/reset integration driver.
"""
import argparse
import datetime
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

from core_sdk_common import check, sha


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['repository', 'runtime', 'dotnet', 'build-manifest', 'catalog', 'profiles',
                 'rom', 'isolator', 'output', 'scratch']:
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--metadata-ledger', type=Path)
    ap.add_argument('--identity-fixtures', type=Path)
    ap.add_argument('--board', choices=['pico', 'pico2'], required=True)
    ap.add_argument('--cases', nargs='+')
    ap.add_argument('--rpc-port', type=int, default=19321)
    ap.add_argument('--wall-timeout', type=float, default=43200,
                    help='Predeclared per-scenario wall budget; full 41s FreeRTOS lifecycles can require hours')
    args = ap.parse_args()
    check(math.isfinite(args.wall_timeout) and args.wall_timeout > 30, 'Wall timeout must be finite and exceed 30 seconds')
    for name, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, name, value.resolve())
    args.output.mkdir(parents=True, exist_ok=False)
    args.scratch.mkdir(parents=True, exist_ok=False)
    catalog = json.loads(args.catalog.read_text())
    build = json.loads(args.build_manifest.read_text())
    check(build['status'] == 'built' and build['board'] == args.board, 'Wrong/incomplete build manifest')
    files = {x['target']:next(Path(f['path']) for f in x['files'] if f['path'].endswith('.elf')) for x in build['artifacts']}
    for artifact in build['artifacts']:
        for item in artifact['files']:
            if item['path'].endswith(('.elf', '.uf2')):
                check(sha(Path(item['path'])) == item['sha256'], 'Built firmware artifact hash changed')
    cases = [c for c in catalog['cases'] if c['board'] == args.board and c['target'] not in ['hello_anything', 'hello_double_tap']]
    if args.cases:
        check(len(args.cases) == len(set(args.cases)), 'Duplicate selected target')
        cases = [c for c in cases if c['target'] in args.cases]
        check({c['target'] for c in cases} == set(args.cases), 'Selected case outside this driver scope')
    metadata = json.loads(args.metadata_ledger.read_text()) if args.metadata_ledger else None
    identities = json.loads(args.identity_fixtures.read_text()) if args.identity_fixtures else None
    tools = args.output / 'tools'
    tools.mkdir()
    for source in [Path(__file__).with_name(x) for x in ['run_extension.py', 'core_sdk_common.py', 'ExampleObserver.cs', 'extension_checks.py']] + [args.isolator]:
        shutil.copy2(source, tools / source.name)
    record = dict(board=args.board, status='running', wall_timeout_seconds=args.wall_timeout, selected_cases=[c['id'] for c in cases], results=[],
                  inputs={str(p):sha(p) for p in [args.catalog, args.profiles, args.build_manifest]},
                  tools={x.name:sha(x) for x in tools.iterdir()})
    ledger = args.output / 'acceptance.json'
    for case in cases:
        scenarios = [s for s in case['scenarios'] if s != 'original_task_return_defect_control']
        for scenario in scenarios:
            target = case['target']
            elf = files[target]
            extra = []
            if target == 'blink_any':
                check(metadata is not None and metadata['status'] == 'prepared', 'Prepared metadata fixtures are required')
                entries = [x for x in metadata['results'] if x['target'] == target and x['scenario'] == scenario]
                check(len(entries) == 1 and entries[0]['returncode'] == 0, 'Wrong/incomplete metadata scenario')
                check(sha(Path(entries[0]['configuration'])) == entries[0]['configuration_sha256'], 'Metadata configuration ledger changed')
                configuration = json.loads(Path(entries[0]['configuration']).read_text())
                check(configuration['data_only_changes_proved'], 'Metadata code identity not established')
                elf = Path(configuration['configured_elf']['path'])
                check(sha(elf) == configuration['configured_elf']['sha256'] and sha(elf.with_suffix('.uf2')) == configuration['uf2']['sha256'], 'Configured firmware artifact hash changed')
                extra += ['--observe-pin', '7' if scenario == 'picotool_config_gpio7' else '25']
            if target == 'unique_board_id':
                identity = scenario.removeprefix('identity_')
                if args.board == 'pico':
                    extra += ['--flash-unique-id', '0x' + identity]
                else:
                    check(identities is not None, 'Independent OTP fixture declaration is required')
                    fixture = next(x for x in identities['fixtures'] if x['identity'] == '0x' + identity)
                    check(sha(Path(fixture['path'])) == fixture['sha256'], 'OTP fixture hash changed')
                    extra += ['--otp-image', fixture['path']]
            key = target + '__' + scenario
            cmd = [sys.executable, str(tools / args.isolator.name), '--output', str(args.output / key),
                   '--scratch', str(args.scratch / key), '--timeout', str(args.wall_timeout), '--',
                   sys.executable, str(tools / 'run_extension.py'), '--repository', str(args.repository),
                   '--runtime', str(args.runtime), '--dotnet', str(args.dotnet), '--board', args.board,
                   '--target', target, '--variant', scenario, '--elf', str(elf), '--rom', str(args.rom),
                   '--catalog', str(args.catalog), '--profiles', str(args.profiles),
                   '--output', '{output}', '--scratch', '{scratch}/scenario', '--rpc-port', str(args.rpc_port),
                   '--rpc-timeout', str(args.wall_timeout - 30), *extra]
            item = dict(id=case['id'], scenario=scenario, command=cmd, status='running',
                        started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
            record['results'].append(item)
            ledger.write_text(json.dumps(record, indent=2) + '\n')
            proc = subprocess.run(cmd, capture_output=True, text=True)
            item.update(returncode=proc.returncode, wrapper_output=proc.stdout + proc.stderr,
                        finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
            path = args.output / key / 'result.json'
            if path.exists():
                result = json.loads(path.read_text())
                item.update(status=result['status'], renode_returncode=result.get('child_returncode'), result=str(path), result_sha256=sha(path))
            else:
                item['status'] = 'setup_error'
            print(case['id'], scenario, item['status'], flush=True)
            ledger.write_text(json.dumps(record, indent=2) + '\n')
    record['status'] = 'passed' if all(x['status'] == 'passed' and x['returncode'] == 0 and x.get('renode_returncode') == 0 for x in record['results']) else 'failed'
    ledger.write_text(json.dumps(record, indent=2) + '\n')
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
