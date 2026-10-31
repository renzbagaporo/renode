#!/usr/bin/env python3
"""Run a command with private HOME/XDG/TMP and retain a command ledger.

Usage: run_isolated.py --output OUTPUT --scratch SCRATCH [--timeout SECONDS]
       [--cwd DIRECTORY] -- COMMAND [ARG ...]
OUTPUT and SCRATCH must be new directories. A timeout terminates this child's
process group, never other task processes.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--scratch', type=Path, required=True)
    ap.add_argument('--cwd', type=Path, default=Path.cwd())
    ap.add_argument('--timeout', type=float, default=900)
    ap.add_argument('command', nargs=argparse.REMAINDER)
    args = ap.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or args.timeout <= 0:
        ap.error('a command and positive timeout are required')
    output, scratch = args.output.resolve(), args.scratch.resolve()
    output.mkdir(parents=True, exist_ok=False)
    scratch.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    paths = {}
    for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME',
                'XDG_STATE_HOME', 'XDG_RUNTIME_DIR', 'TMPDIR', 'DOTNET_CLI_HOME', 'NUGET_PACKAGES']:
        dest = scratch / key.lower()
        dest.mkdir(mode=0o700)
        env[key] = paths[key] = str(dest)
    env.update(DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
               DOTNET_NOLOGO='1', PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1',
               CMAKE_BUILD_PARALLEL_LEVEL='4')
    command = [c.replace('{scratch}', str(scratch)).replace('{output}', str(output))
               for c in command]
    record = dict(command=command, cwd=str(args.cwd.resolve()), isolated_paths=paths,
                  started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  timeout_seconds=args.timeout)
    proc = None
    started = time.monotonic()

    def interrupt(signum, _frame):
        raise InterruptedError(f'received signal {signum}')

    signal.signal(signal.SIGTERM, interrupt)
    try:
        with (output / 'command.log').open('wb') as log:
            proc = subprocess.Popen(command, cwd=args.cwd, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            record['pid'] = proc.pid
            (output / 'command.json').write_text(json.dumps(record, indent=2) + '\n')
            try:
                record['returncode'] = proc.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                record.update(timed_out=True, returncode=124)
    except BaseException as error:
        record.update(error=str(error), returncode=1)
        raise
    finally:
        if proc is not None and proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)
        record['elapsed_seconds'] = time.monotonic() - started
        (output / 'command.json').write_text(json.dumps(record, indent=2) + '\n')
        print(output, flush=True)
    return record['returncode']


if __name__ == '__main__':
    sys.exit(main())
