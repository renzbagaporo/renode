#!/usr/bin/env python3
"""Shared cold-NOR loader and observable private Renode runtime.

Import Runtime, boot, symbols, extract_flash, sha, check, uart_text, uart_lines.
The internal _exec_short_tmp entry preserves a private temporary directory fd so
.NET diagnostic socket paths fit Linux Unix-socket limits in long worktree paths.
"""
import hashlib
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import time
import xmlrpc.client

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def working_tree_revision(path):
    path = path.resolve()
    if not path.is_dir():
        return dict(path=str(path), status='unavailable')
    try:
        top = subprocess.check_output(['git', '-C', str(path), 'rev-parse', '--show-toplevel'], stderr=subprocess.PIPE, text=True).strip()
        if Path(top).resolve() != path:
            return dict(path=str(path), status='uninitialized_submodule_or_parent_worktree')
        revision = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], stderr=subprocess.PIPE, text=True).strip()
        return dict(path=str(path), status='initialized', revision=revision)
    except subprocess.CalledProcessError:
        return dict(path=str(path), status='unavailable')


def symbols(elf):
    data = elf.read_bytes()
    shoff = struct.unpack_from('<I', data, 32)[0]
    shsize, shcount = struct.unpack_from('<HH', data, 46)
    if shsize != 40 or shoff + shsize * shcount > len(data):
        raise ValueError('Invalid ELF section table')
    headers = [struct.unpack_from('<10I', data, shoff + i * shsize) for i in range(shcount)]
    found = {}
    for header in headers:
        if header[1] not in [2, 11]:
            continue
        strings = headers[header[6]]
        names = data[strings[4]:strings[4] + strings[5]]
        if header[9] != 16 or header[4] + header[5] > len(data):
            raise ValueError('Invalid ELF symbol table')
        for offset in range(header[4], header[4] + header[5], 16):
            name, value, size, info, other, section = struct.unpack_from('<IIIBBH', data, offset)
            if section == 0 or name == 0:
                continue
            end = names.find(b'\0', name)
            if end < 0:
                raise ValueError('Invalid ELF symbol name')
            found[names[name:end].decode()] = value
    return found


def uart_text(events):
    return bytes(e['value'] for e in events if e['kind'] == 'uart').decode('ascii', errors='replace').replace('\r', '')


def uart_lines(events):
    lines, pending = [], bytearray()
    for event in events:
        if event['kind'] != 'uart':
            continue
        pending.append(event['value'])
        if event['value'] == 10:
            lines.append((pending.decode('ascii', errors='replace').replace('\r', '').rstrip('\n'), event['seconds']))
            pending.clear()
    return lines


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def extract_flash(elf, board):
    data = elf.read_bytes()
    if len(data) < 52 or data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('ELF32 little endian required')
    size = 0x200000 if board == 'pico' else 0x400000
    phoff = struct.unpack_from('<I', data, 28)[0]
    phsize, phcount = struct.unpack_from('<HH', data, 42)
    if phsize != 32 or phoff + phsize * phcount > len(data):
        raise ValueError('Invalid ELF program header table')
    segments = []
    for index in range(phcount):
        typ, off, va, pa, filesz, memsz, flags, align = struct.unpack_from('<8I', data, phoff + index * phsize)
        if typ != 1 or filesz == 0:
            continue
        if filesz > memsz or off + filesz > len(data):
            raise ValueError('Invalid ELF segment')
        if not 0x10000000 <= pa <= 0x10000000 + size - filesz:
            raise ValueError('File-backed ELF PT_LOAD outside board NOR')
        if any(pa < s['paddr'] + s['size'] and pa + filesz > s['paddr'] for s in segments):
            raise ValueError('Overlapping ELF physical segments')
        segments.append(dict(file_offset=off, vaddr=va, paddr=pa, size=filesz))
    if not segments:
        raise ValueError('No file-backed NOR segments')
    payload = bytearray(b'\xff' * (max(s['paddr'] + s['size'] for s in segments) - 0x10000000))
    for segment in segments:
        offset = segment['paddr'] - 0x10000000
        payload[offset:offset + segment['size']] = data[segment['file_offset']:segment['file_offset'] + segment['size']]
    return payload, segments


class Runtime:
    def __init__(self, args, record):
        self.args, self.record, self.proc, self.log = args, record, None, None

    def __enter__(self):
        args = self.args
        self.log = (args.output / 'renode.log').open('w')
        command = [sys.executable, str(Path(__file__).resolve()), '_exec_short_tmp',
                   str(args.dotnet) if getattr(args, 'dotnet', None) else 'dotnet', str(args.runtime / 'Renode.dll'),
                   '--disable-gui', '--hide-monitor', '--port', '-1',
                   '--robot-server-port', str(args.rpc_port)]
        self.record['command'] = command
        self.proc = subprocess.Popen(command, cwd=args.repository, stdout=self.log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
        self.record['pid'] = self.proc.pid
        until = time.monotonic() + 120
        try:
            while True:
                if self.proc.poll() is not None:
                    raise RuntimeError(f'Renode exited with {self.proc.returncode}')
                try:
                    with socket.create_connection(('127.0.0.1', args.rpc_port), timeout=.2):
                        break
                except OSError:
                    if time.monotonic() > until:
                        raise TimeoutError('Renode RPC startup')
                    time.sleep(.1)
            # TCP listening precedes XML-RPC keyword registration. Confirm
            # protocol readiness using metadata only, before any application
            # commands; create a fresh connection for the execution timeout.
            address = f'http://127.0.0.1:{args.rpc_port}'
            previous_timeout = socket.getdefaulttimeout()
            try:
                socket.setdefaulttimeout(10)
                while True:
                    if self.proc.poll() is not None:
                        raise RuntimeError(f'Renode exited with {self.proc.returncode}')
                    try:
                        with xmlrpc.client.ServerProxy(address, allow_none=True) as probe:
                            names = probe.get_keyword_names()
                        if 'ExecuteCommand' in names:
                            self.record['rpc_ready_keyword_count'] = len(names)
                            break
                    except (OSError, xmlrpc.client.Error):
                        pass
                    if time.monotonic() > until:
                        raise TimeoutError('Renode XML-RPC keyword readiness')
                    time.sleep(.1)
            finally:
                socket.setdefaulttimeout(previous_timeout)
            process_environment = dict(item.split(b'=', 1) for item in Path(f'/proc/{self.proc.pid}/environ').read_bytes().split(b'\0') if b'=' in item)
            self.record['process_isolated_environment'] = {}
            for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME',
                        'XDG_STATE_HOME', 'XDG_RUNTIME_DIR', 'TMPDIR', 'DOTNET_CLI_HOME', 'NUGET_PACKAGES']:
                actual = process_environment.get(key.encode(), b'').decode()
                expected = os.environ.get(key, '')
                if not actual or not expected or Path(actual).resolve() != Path(expected).resolve():
                    raise AssertionError(f'Renode process did not inherit isolated {key}: {actual}')
                self.record['process_isolated_environment'][key] = dict(value=actual, resolved=str(Path(actual).resolve()))
            socket.setdefaulttimeout(args.rpc_timeout)
            self.proxy = xmlrpc.client.ServerProxy(address, allow_none=True)
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, *_args):
        if (_args and _args[0] is not None and hasattr(self, 'proxy')
                and not isinstance(_args[1], (OSError, KeyboardInterrupt))):
            self.record['failure_state'] = []
            for command in ['pause', 'cpu0 PC', 'cpu0 SP', 'cpu1 PC',
                            'cpu0 IsHalted', 'machine ElapsedVirtualTime',
                            'sio Output', 'sio OutputEnable']:
                try:
                    self.record['failure_state'].append(dict(command=command, result=self.run(command)))
                except Exception as error:
                    self.record['failure_state'].append(dict(command=command, error=str(error)))
            if self.record.get('observer_created'):
                try:
                    self.record['failure_events'] = json.loads(self.run('observer GetEvents').strip())
                except Exception as error:
                    self.record['failure_events_error'] = str(error)
        if self.proc is not None and self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(timeout=10)
        self.record['child_returncode'] = self.proc.returncode if self.proc else None
        if self.log is not None:
            self.log.close()

    def call(self, name, *args):
        item = dict(keyword=name, arguments=list(args))
        self.record['observations'].append(item)
        response = self.proxy.run_keyword(name, list(args))
        item['response'] = response
        if response.get('status') != 'PASS':
            raise RuntimeError(f'{name}: {response}')
        return response.get('return')

    def run(self, command):
        result = self.call('ExecuteCommand', command)
        return result.strip() if isinstance(result, str) else result

    def seconds(self, duration):
        try:
            requested = Decimal(str(duration))
        except InvalidOperation as exc:
            raise ValueError('Virtual duration must be a finite nonnegative number') from exc
        if not requested.is_finite() or requested < 0:
            raise ValueError('Virtual duration must be a finite nonnegative number')
        # TimeInterval's monitor parser does not accept exponent notation as
        # seconds. Keep even tiny intervals in explicit fixed decimal form.
        text = format(requested if requested else Decimal(0), 'f')
        before = self.virtual_seconds()
        self.run(f'emulation RunFor "{text}"')
        after = self.virtual_seconds()
        self.record.setdefault('run_intervals', []).append(dict(requested_seconds=text,
            before_seconds=str(before), after_seconds=str(after), observed_seconds=str(after - before)))
        check(abs(after - before - requested) <= Decimal('0.000000001'),
              f'Virtual interval mismatch: requested {text}, observed {after - before}')

    def virtual_seconds(self):
        info = self.run('emulation GetTimeSourceInfo')
        match = re.search(r'Elapsed Virtual Time:\s*(?:(\d+)\.)?(\d+):(\d+):(\d+(?:\.\d+)?)', info)
        if match is None:
            raise ValueError('Cannot read actual virtual timestamp: ' + info)
        days, hours, minutes, seconds = match.groups()
        return Decimal(days or 0) * 86400 + Decimal(hours) * 3600 + Decimal(minutes) * 60 + Decimal(seconds)

    def capture_native(self):
        maps = Path(f'/proc/{self.proc.pid}/maps').read_text()
        (self.args.output / 'runtime_maps.txt').write_text(maps)
        loaded = {}
        for line in maps.splitlines():
            fields = line.split(maxsplit=5)
            if len(fields) != 6 or 'x' not in fields[1]:
                continue
            path = Path(fields[5])
            if path.suffix != '.tmp' or not path.parent.name.startswith('renode-'):
                continue
            loaded[str(path)] = dict(path=str(path), mapping=line, bytes=path.stat().st_size, sha256=sha(path))
        engines = json.loads(self.run('observer GetConfiguredNativeEngines'))
        check(bool(engines), 'No configured native engines were found')
        paths = set()
        architectures = []
        for engine in engines:
            path = str(Path(engine['native_path']).resolve(strict=True))
            engine['resolved_native_path'] = path
            architecture = engine['architecture']
            expected_path = self.args.runtime / f'platform-lib/linux-x64/translate-{architecture}-le.so'
            check(expected_path.is_file(), f'Configured engine binary is absent: {expected_path}')
            check(path in loaded, f'Configured engine is missing its executable mapping: {engine}')
            check(loaded[path]['sha256'] == sha(expected_path),
                  f'Actual configured native mapping differs from selected runtime: {engine}')
            check(path not in paths, f'Native engines share a supposedly private library: {engine}')
            paths.add(path)
            architectures.append(architecture)
            engine['sha256'] = loaded[path]['sha256']
            engine['selected_runtime_binary'] = str(expected_path)
            if architecture == 'riscv':
                check(engine['gdb_architecture'] == 'riscv:rv32', f'Unexpected RISC-V engine width: {engine}')
        check(paths == set(loaded), f'Unaccounted native mappings: {set(loaded) - paths}')
        # Inspect actual configuration, including dormant architecture engines.
        # Older two-Arm-engine Pico 2 snapshots remain valid configurations.
        expected = ['arm-m', 'arm-m']
        if self.args.board == 'pico2' and any(item != 'arm-m' for item in architectures):
            expected += ['riscv', 'riscv']
        check(sorted(architectures) == sorted(expected),
              f'Unexpected board native engine configuration: {architectures}')
        self.record['configured_native_engines'] = engines
        self.record['loaded_native_copies'] = list(loaded.values())


def boot(runtime, args, record):
    """Load ELF NOR segments, boot the real mask ROM, and install observations.

    args supplies board, repository, elf, rom, scratch and output Path objects.
    No ELF bytes are written to SRAM and no architectural register is patched.
    Return the original ELF symbols for additional observer-only address hooks.
    """
    args.scratch.mkdir(parents=True, exist_ok=True)
    payload, segments = extract_flash(args.elf, args.board)
    flash = args.scratch / 'initial_nor_payload.bin'
    flash.write_bytes(payload)
    record['loader'] = 'official_rom_coldboot_from_nor'
    record['seed'] = 0
    record['elf_nor_segments'] = segments
    record.setdefault('inputs', {})
    observer = Path(__file__).with_name('ExampleObserver.cs')
    observer_copy = args.output / observer.name
    if observer.resolve() != observer_copy.resolve():
        observer_copy.write_bytes(observer.read_bytes())
    rom_input = args.rom
    if args.board == 'pico':
        raw = args.rom.read_bytes()
        phoff = struct.unpack_from('<I', raw, 28)[0]
        phsize, phcount = struct.unpack_from('<HH', raw, 42)
        if raw[:6] != b'\x7fELF\x01\x01' or phsize != 32 or phoff + phsize * phcount > len(raw):
            raise ValueError('Expected ELF32 RP2040 mask ROM')
        candidates = []
        for index in range(phcount):
            typ, off, va, pa, filesz, memsz, flags, align = struct.unpack_from('<8I', raw, phoff + index * phsize)
            if typ == 1 and filesz:
                if pa != 0 or filesz != 0x4000 or off + filesz > len(raw):
                    raise ValueError('Unexpected RP2040 mask ROM segment')
                candidates.append(raw[off:off + filesz])
        if len(candidates) != 1:
            raise ValueError('Expected one mask ROM segment')
        rom_input = args.scratch / 'rp2040_mask_rom.bin'
        rom_input.write_bytes(candidates[0])
    for path in [flash, args.elf, args.rom, rom_input, observer_copy, Path(__file__).resolve()]:
        record['inputs'][str(path)] = dict(bytes=path.stat().st_size, sha256=sha(path))
    runtime.run('emulation SetSeed 0')
    runtime.run('mach create "pico"')
    runtime.run(f'include @{observer_copy}')
    board = 'raspberry_pi_pico' if args.board == 'pico' else 'raspberry_pi_pico2'
    board_path = args.repository / f'platforms/boards/{board}.repl'
    pending, seen = [board_path], set()
    while pending:
        source = pending.pop().resolve()
        if source in seen:
            continue
        seen.add(source)
        record['inputs'][str(source)] = dict(bytes=source.stat().st_size, sha256=sha(source))
        for included in re.findall(r'^\s*using\s+"([^"]+)"', source.read_text(), re.M):
            candidates = [Path(included)] if Path(included).is_absolute() else [args.repository / included, source.parent / included]
            resolved = next((p for p in candidates if p.is_file()), None)
            if resolved is None:
                raise ValueError('Cannot resolve platform dependency: ' + included)
            pending.append(resolved)
    platform = f'using "{board_path}"\nobserver: Miscellaneous.PicoExampleObserver @ sysbus\n    memory: flashMemory\n'
    if getattr(args, 'flash_unique_id', None) is not None:
        platform += f'flash:\n    uniqueId: 0x{args.flash_unique_id:016x}\n'
        record['flash_unique_id'] = f'{args.flash_unique_id:016x}'
    record['platform_description'] = platform
    runtime.run('machine LoadPlatformDescriptionFromString """' + platform + '"""')
    record['observer_created'] = True
    if getattr(args, 'otp_image', None):
        image = Path(args.otp_image).resolve()
        record['inputs'][str(image)] = dict(bytes=image.stat().st_size, sha256=sha(image))
        runtime.run(f'otp LoadRawImage @{image}')
    runtime.run(f'sysbus LoadBinary @{rom_input} 0' if args.board == 'pico' else f'rom LoadBinary @{args.rom}')
    runtime.run(f'xipMemory LoadBinary @{flash}')
    runtime.run(f'sysbus LoadSymbolsFrom @{args.elf}')
    quantum = float(getattr(args, 'quantum', 0.0001))
    record['requested_quantum_seconds'] = quantum
    runtime.run(f'emulation SetGlobalQuantum "{quantum:.9f}"')
    runtime.run('emulation SetGlobalAdvanceImmediately true')
    record['time_source_info_after_setup'] = runtime.run('emulation GetTimeSourceInfo')
    quantum_text = next(line.split('Quantum:', 1)[1].strip() for line in record['time_source_info_after_setup'].splitlines() if 'Quantum:' in line)
    hours, minutes, seconds = quantum_text.split(':')
    actual_quantum = int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    record['actual_quantum_seconds'] = actual_quantum
    check(abs(actual_quantum - quantum) < 1e-12, 'Actual master scheduling quantum differs from requested profile')
    runtime.run('machine Reset')
    runtime.run('observer ObserveGPIO gpio 25')
    runtime.run('observer ObserveUART uart0')
    for cpu in ['cpu0', 'cpu1']:
        runtime.run(f'observer ObserveCPU {cpu}')
    names = symbols(args.elf)
    stops = {'panic', 'hard_assertion_failure', '__assert_func', 'panic_unsupported',
             '__unhandled_user_irq', '_exit', 'prvTaskExitError'}
    observe = ['main', 'worker_cb', 'alarm_callback', 'do_work', 'main_task', 'blink_task',
               'vLaunch', 'vTaskStartScheduler', 'async_context_deinit', 'async_context_freertos_deinit']
    if args.target.startswith('hello_freertos_'):
        observe += ['xPortSysTickHandler', 'xPortPendSVHandler', 'SysTick_Handler',
                    'PendSV_Handler', 'vTaskSwitchContext', 'vTaskDelete', 'prvIdleTask', 'prvPassiveIdleTask']
    for name in sorted(stops.union(observe)):
        if name in names:
            for cpu in ['cpu0', 'cpu1']:
                runtime.run(f'observer ObserveAddress {cpu} 0x{names[name]:x} "{name}" {str(name in stops).lower()}')
    if 'async_context_freertos_deinit' in names:
        for cpu in ['cpu0', 'cpu1']:
            runtime.run(f'observer ObserveFunctionReturn {cpu} 0x{names["async_context_freertos_deinit"]:x} "async_context_freertos_deinit"')
    reset_pc = struct.unpack_from('<I', rom_input.read_bytes(), 4)[0] & ~1
    runtime.run(f'observer ObserveAddress cpu0 0x{reset_pc:x} "rom_reset" false')
    runtime.capture_native()
    return names


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] != '_exec_short_tmp':
        raise SystemExit(__doc__)
    temporary = Path(os.environ['TMPDIR']).resolve(strict=True)
    if not temporary.is_dir() or temporary == Path('/tmp'):
        raise SystemExit('A private TMPDIR is required')
    directory_fd = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY)
    os.set_inheritable(directory_fd, True)
    os.environ['TMPDIR'] = f'/proc/{os.getpid()}/fd/{directory_fd}'
    os.execvpe(sys.argv[2], sys.argv[2:], os.environ)

