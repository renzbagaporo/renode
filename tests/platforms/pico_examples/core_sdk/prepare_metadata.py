#!/usr/bin/env python3
"""Prepare the frozen postlink binary-info scenarios with official picotool.

Usage: prepare_metadata.py --build BUILD --board pico|pico2 --picotool TOOL
 --output NEW_LEDGER_DIR --scratch NEW_FIXTURE_DIR --isolator run_isolated.py
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

from core_sdk_common import sha


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['build', 'picotool', 'output', 'scratch', 'isolator']:
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--board', choices=['pico', 'pico2'], required=True)
    args = ap.parse_args()
    for name in ['build', 'picotool', 'output', 'scratch', 'isolator']:
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=False)
    args.scratch.mkdir(parents=True, exist_ok=False)
    tools = args.output / 'tools'
    tools.mkdir()
    for source in [Path(__file__).with_name('configure_binary.py'), Path(__file__).with_name('core_sdk_common.py'), args.isolator]:
        shutil.copy2(source, tools / source.name)
    scenarios = [('blink_any', 'default_gpio25', {}), ('blink_any', 'picotool_config_gpio7', {'LED_PIN': 7}),
                 ('hello_anything', 'default_dual_stdio', {}),
                 ('hello_anything', 'configured_dual_stdio', dict(text='Goodbye, world!', uart_num=1, uart_tx=4, uart_rx=5, uart_baud=57600, use_uart=1, use_usb=1)),
                 ('hello_anything', 'uart_only', {'use_usb': 0}),
                 ('hello_anything', 'usb_only', {'use_uart': 0})]
    record = dict(board=args.board, status='running', results=[], tools={x.name:sha(x) for x in tools.iterdir()})
    ledger = args.output / 'metadata.json'
    for target, scenario, settings in scenarios:
        key = target + '_' + scenario
        settings_path = args.scratch / (key + '_settings.json')
        settings_path.write_text(json.dumps(settings, indent=2) + '\n')
        original = args.build / f'binary_info/{target}/{target}.elf'
        binary_dir = args.scratch / key / 'binary'
        cmd = [sys.executable, str(tools / args.isolator.name), '--output', str(args.output / key),
               '--scratch', str(args.scratch / key / 'environment'), '--timeout', '120', '--',
               sys.executable, str(tools / 'configure_binary.py'), '--source-elf', str(original),
               '--board', args.board, '--picotool', str(args.picotool), '--settings', str(settings_path),
               '--output', str(binary_dir)]
        item = dict(target=target, scenario=scenario, command=cmd, status='running')
        record['results'].append(item)
        ledger.write_text(json.dumps(record, indent=2) + '\n')
        result = subprocess.run(cmd, capture_output=True, text=True)
        item.update(returncode=result.returncode, wrapper_output=result.stdout + result.stderr)
        path = binary_dir / 'configuration.json'
        if path.exists():
            configuration = json.loads(path.read_text())
            item.update(status=configuration['status'], configuration=str(path), configuration_sha256=sha(path))
            shutil.copy2(path, args.output / key / 'configuration.json')
        else:
            item['status'] = 'setup_error'
        print(args.board, key, item['status'], flush=True)
        ledger.write_text(json.dumps(record, indent=2) + '\n')
    record['status'] = 'prepared' if all(x['returncode'] == 0 and x['status'] == 'configured' for x in record['results']) else 'failed'
    ledger.write_text(json.dumps(record, indent=2) + '\n')
    return 0 if record['status'] == 'prepared' else 1


if __name__ == '__main__':
    sys.exit(main())
