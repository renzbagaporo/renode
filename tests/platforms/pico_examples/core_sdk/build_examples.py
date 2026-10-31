#!/usr/bin/env python3
"""Build all frozen board-applicable core SDK examples from explicit inputs.

Run inside run_isolated.py. Supply --examples REPO --sdk REPO --kernel REPO
 --toolchain ROOT --picotool-dir CMAKE_PACKAGE --pioasm-dir CMAKE_PACKAGE
 --catalog FILE --board pico|pico2 --build NEW_DIR --isolation-root PRIVATE_DIR.
All source/dependency revisions, commands, effective RTOS macros and binaries
are recorded. A reviewed example source exception requires its explicit ledger.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_state(path):
    return dict(path=str(path), revision=subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip(),
                status=subprocess.check_output(['git', '-C', str(path), 'status', '--short'], text=True))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['examples', 'sdk', 'kernel', 'toolchain', 'picotool-dir', 'pioasm-dir', 'catalog', 'build', 'isolation-root']:
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--source-exception', type=Path,
                    help='Reviewed ledger with original_revision, modified_files mapping relative paths to exact SHA256')
    ap.add_argument('--board', choices=['pico', 'pico2'], required=True)
    args = ap.parse_args()
    for key, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, key, value.resolve())
    args.build.mkdir(parents=True, exist_ok=False)
    catalog = json.loads(args.catalog.read_text())
    cases = [c for c in catalog['cases'] if c['board'] == args.board]
    targets = sorted(c['target'] for c in cases)
    record = dict(board=args.board, targets=targets, status='incomplete', commands=[], sources={},
                  source_files={}, artifacts=[], rtos_profiles={}, inputs={}, isolated_paths={})
    for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'TMPDIR']:
        value = Path(os.environ[key]).resolve()
        if not value.is_relative_to(args.isolation_root) or value == args.isolation_root:
            raise ValueError(f'{key} is not inside the declared private environment')
        record['isolated_paths'][key] = str(value)
    for path in [args.catalog, Path(__file__).resolve(), args.toolchain / 'bin/arm-none-eabi-gcc']:
        record['inputs'][str(path)] = dict(bytes=path.stat().st_size, sha256=sha(path))
    for name, path, revision in [('examples', args.examples, catalog['examples_revision']), ('sdk', args.sdk, catalog['sdk_revision']),
                                 ('freertos_kernel', args.kernel, catalog['freertos_kernel_revision'])]:
        state = source_state(path)
        record['sources'][name] = state
        if state['revision'] != revision:
            raise ValueError(f'{name} revision differs from frozen input')
        if state['status'] and (name != 'examples' or not args.source_exception):
            raise ValueError(f'Dirty unreviewed source: {name}')
    modified = {}
    if args.source_exception:
        review = json.loads(args.source_exception.read_text())
        if review['original_revision'] != catalog['examples_revision'] or review['status'] != 'approved':
            raise ValueError('Example exception is not approved for this pinned source')
        modified = review['modified_files']
        actual_modified = subprocess.check_output(['git', '-C', str(args.examples), 'diff', '--name-only', 'HEAD'], text=True).splitlines()
        untracked = subprocess.check_output(['git', '-C', str(args.examples), 'ls-files', '--others', '--exclude-standard'], text=True).splitlines()
        if set(actual_modified) != set(modified) or untracked:
            raise ValueError('Example changes exceed the approved source exception')
        for relative, expected in modified.items():
            if sha(args.examples / relative) != expected:
                raise ValueError('Approved source exception bytes differ: ' + relative)
        record['source_exception'] = dict(path=str(args.source_exception), sha256=sha(args.source_exception), modified_files=modified)
    prefixes = {'.dev/resources/pico_examples/':args.examples,
                '.dev/resources/pico_examples_inputs/pico_sdk_2_3_0/':args.sdk,
                '.dev/resources/pico_examples_inputs/freertos_kernel/':args.kernel}
    for label, expected in catalog['source_hashes'].items():
        prefix = next((p for p in prefixes if label.startswith(p)), None)
        if prefix is None:
            raise ValueError('Unrecognized frozen source label: ' + label)
        relative = label.removeprefix(prefix)
        path = prefixes[prefix] / relative
        actual = sha(path)
        if prefixes[prefix] == args.examples and relative in modified:
            expected = modified[relative]
        if actual != expected:
            raise ValueError('Source hash differs: ' + str(path))
        record['source_files'][label] = dict(path=str(path), sha256=actual)
    query = args.build / '.cmake/api/v1/query'
    query.mkdir(parents=True)
    (query / 'codemodel-v2').touch()
    configure = ['cmake', '-G', 'Ninja', '-S', str(args.examples), '-B', str(args.build),
                 '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
                 f'-DPICO_BOARD={args.board}', f'-DPICO_SDK_PATH={args.sdk}', f'-DFREERTOS_KERNEL_PATH={args.kernel}',
                 f'-DPICO_TOOLCHAIN_PATH={args.toolchain}', f'-Dpicotool_DIR={args.picotool_dir}', f'-Dpioasm_DIR={args.pioasm_dir}']
    compile_cmd = ['cmake', '--build', str(args.build), '--parallel', '2', '--target', *targets]
    try:
        for cmd in [configure, compile_cmd]:
            item = dict(command=cmd)
            record['commands'].append(item)
            print(json.dumps(cmd), flush=True)
            item['returncode'] = subprocess.run(cmd).returncode
            if item['returncode']:
                raise RuntimeError('Build command failed')
        compile_commands = json.loads((args.build / 'compile_commands.json').read_text())
        for target in targets:
            matches = list(args.build.rglob(target + '.elf'))
            if len(matches) != 1:
                raise ValueError('Wrong ELF count for ' + target)
            elf = matches[0]
            artifacts = [elf, elf.with_suffix('.uf2'), elf.with_suffix('.bin'), elf.with_suffix('.dis'), elf.with_suffix('.elf.map')]
            record['artifacts'].append(dict(target=target, files=[dict(path=str(p), bytes=p.stat().st_size, sha256=sha(p)) for p in artifacts if p.exists()]))
            if target.startswith('hello_freertos_'):
                entries = [e for e in compile_commands if Path(e['file']).name == 'hello_freertos.c' and f'CMakeFiles/{target}.dir/' in e['command']]
                if len(entries) != 1:
                    raise ValueError('Wrong RTOS compile-command count for ' + target)
                entry = entries[0]
                command = shlex.split(entry['command'])
                filtered, skip = [], False
                for token in command:
                    if skip:
                        skip = False
                        continue
                    if token in ['-o', '-MF', '-MT', '-MQ']:
                        skip = True
                    elif token not in ['-c', '-MD', '-MMD', '-MP']:
                        filtered.append(token)
                command = filtered + ['-E', '-dM']
                proc = subprocess.run(command, cwd=entry['directory'], capture_output=True, text=True)
                profile = args.build / (target + '_effective_macros.txt')
                profile.write_text(proc.stdout)
                if proc.returncode:
                    raise RuntimeError('RTOS macro extraction failed: ' + proc.stderr)
                wanted = {'configNUMBER_OF_CORES', 'configSUPPORT_STATIC_ALLOCATION', 'configSUPPORT_DYNAMIC_ALLOCATION',
                          'configTICK_RATE_HZ', 'LED_BUSY_WAIT', 'LED_DELAY_MS', 'USE_LED', 'RUN_FREE_RTOS_ON_CORE',
                          'configUSE_PREEMPTION', 'configUSE_TICKLESS_IDLE', 'configUSE_CORE_AFFINITY',
                          'MAIN_TASK_PRIORITY', 'WORKER_TASK_PRIORITY', 'BLINK_TASK_PRIORITY',
                          'configENABLE_FPU', 'configRUN_FREERTOS_SECURE_ONLY'}
                macros = {}
                for line in proc.stdout.splitlines():
                    match = re.fullmatch(r'#define (\w+) (.*)', line)
                    if match and match[1] in wanted:
                        macros[match[1]] = match[2]
                record['rtos_profiles'][target] = dict(command=command, returncode=proc.returncode,
                                                      macros=macros, raw=str(profile), sha256=sha(profile))
        for name, path in [('examples', args.examples), ('sdk', args.sdk), ('freertos_kernel', args.kernel)]:
            if source_state(path) != record['sources'][name]:
                raise AssertionError('Source revision/status changed during build: ' + name)
        for label, item in record['source_files'].items():
            if sha(Path(item['path'])) != item['sha256']:
                raise AssertionError('Source bytes changed during build: ' + label)
        record['status'] = 'built'
    except BaseException as exc:
        record.update(status='failed', error=str(exc))
        raise
    finally:
        (args.build / 'build_manifest.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
