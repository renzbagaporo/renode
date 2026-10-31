#!/usr/bin/env python3
"""Observe a guest USB capture command's real terminal status.

Usage in the isolated guest: guest_run.py OUTPUT_DIRECTORY COMMAND [ARG ...]
The caller starts this supervisor in a private process group. Its child inherits
that group so bounded host cleanup can stop only this owned capture.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main():
    output = Path(sys.argv[1])
    command = sys.argv[2:]
    if not command:
        raise ValueError('A capture command is required')
    record = dict(command=command, supervisor_pid=os.getpid(), started_unix=time.time())
    with (output / 'guest_capture.log').open('wb') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        record['capture_pid'] = child.pid
        (output / 'guest_process.json').write_text(json.dumps(record, indent=2) + '\n')
        record['returncode'] = child.wait()
    record['finished_unix'] = time.time()
    temporary = output / 'guest_terminal.json.tmp'
    temporary.write_text(json.dumps(record, indent=2) + '\n')
    temporary.rename(output / 'guest_terminal.json')
    return record['returncode']


if __name__ == '__main__':
    sys.exit(main())
