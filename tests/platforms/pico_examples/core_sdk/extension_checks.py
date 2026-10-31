"""Source-specific runtime oracles for the frozen core SDK acceptance catalog.

Called by run_extension.py; no hardware state or firmware memory is modified.
USB/reset integration scenarios have their own transport-aware drivers.
"""
import re
import struct

import core_sdk_common as common


def selected_case(args, catalog):
    matches = [c for c in catalog['cases'] if c['id'] == f'{args.board}/{args.target}']
    common.check(len(matches) == 1, 'Case is absent or ambiguous in frozen catalog')
    case = matches[0]
    common.check(args.variant in case['scenarios'], 'Scenario is outside frozen catalog')
    return case


def duration_for(args, catalog):
    case = selected_case(args, catalog)
    if args.target == 'rand' or args.target.startswith('hello_freertos_'):
        return None  # Run to observed terminal path, with the outer wall deadline.
    common.check(case['duration_seconds'] is not None, 'Case duration/exception gate is not resolved')
    return case['duration_seconds']


def led_edges(events, pin):
    driven = [e for e in events if e['kind'] == 'gpio' and e['pin'] == pin and e['enabled']]
    first = next((i for i, e in enumerate(driven) if e['level']), len(driven))
    edges = []
    for event in driven[first:]:
        if not edges or event['level'] != edges[-1]['level']:
            edges.append(event)
    return edges


def intervals(times, bounds, message):
    common.check(len(times) >= 2, message + ': insufficient observations')
    actual = [b - a for a, b in zip(times, times[1:])]
    common.check(all(bounds[0] <= x <= bounds[1] for x in actual), message + ': ' + str(actual))
    return actual


def subsequence(actual, wanted):
    position = 0
    for item in actual:
        if position < len(wanted) and item == wanted[position]:
            position += 1
    return position == len(wanted)


def check_events(args, catalog, events, runtime):
    case = selected_case(args, catalog)
    constraints = {c['id']:c for c in case['checks']}
    text = common.uart_text(events)
    lines = common.uart_lines(events)
    addresses = [e for e in events if e['kind'] == 'address']
    interrupts = [e for e in events if e['kind'] == 'interrupt']
    forbidden = {'panic', 'hard_assertion_failure', '__assert_func', 'panic_unsupported',
                 '__unhandled_user_irq', 'prvTaskExitError'}
    errors = [{key:e[key] for key in ['label', 'core', 'pc', 'seconds']}
              for e in addresses if e['label'] in forbidden]
    common.check(not errors, f'Firmware error paths were reached: {errors}')
    common.check(not any(e['exception_kind'] in {1, 3, 4, 7, 16, 17, 18, 19, 20, 21} for e in interrupts),
                 'Unexpected architectural fault exception')
    mains = [e for e in addresses if e['label'] == 'main' and e['core'] == 0]
    common.check(mains, 'CPU0 did not enter main through startup')
    start = mains[0]['seconds']
    exits = [e for e in addresses if e['label'] == '_exit' and e['core'] == 0]
    finite = {'build_variant1', 'build_variant2', 'hello_divider', 'narrow_io_write', 'rand', 'rtc_alarm', 'unique_board_id', 'boot_info'}
    if args.target in finite:
        common.check(exits and all(e['r0'] == 0 for e in exits), 'No observed genuine normal exit with status zero')
    result = dict(no_firmware_error=True, cpu0_main_observed=True)
    if args.target in ['blink_any', 'status_blink']:
        pin = 7 if args.variant == 'picotool_config_gpio7' else 25
        edges = led_edges(events, pin)
        common.check(len(edges) >= 7, 'Fewer than three full driven LED cycles')
        half = constraints['led']['half_period_seconds']
        result['half_periods'] = intervals([e['seconds'] for e in edges], half, 'Incorrect LED period')
        enabled = int(runtime.run('sio OutputEnable'), 0)
        common.check(enabled & (1 << pin), 'Selected LED output direction is not enabled')
        if pin == 7:
            common.check(not led_edges(events, 25), 'Original GPIO25 also blinks in configured variant')
            common.check(not (enabled & (1 << 25)), 'Original GPIO25 output enabled in configured variant')
        result['pin'] = pin
    elif args.target in ['build_variant1', 'build_variant2']:
        expected = constraints['exact_output']['lines']
        common.check([line for line, _ in lines if line] == expected, 'Build variant exact output differs')
        result['exact_lines'] = expected
    elif args.target == 'hello_divider':
        expected = ['Hello, divider!', '123456/-321 = -384 remainder 192',
                    'Working backwards! Result 123456 should equal 123456!',
                    '123456/321 = 384 remainder 192',
                    'Working backwards! Result 123456 should equal 123456!',
                    'Async result 123456/-321 = -384 remainder 192',
                    '123456 / -321 = (by operator -384) (inlined -384)',
                    'inner 123 / 7 = 17', 'outer divide 123456 / -321 = -384']
        common.check([line for line, _ in lines if line] == expected, 'Divider exact numeric output differs')
        if args.board == 'pico':
            mmio = [e for e in events if e['kind'] == 'register' and e['seconds'] >= start and 0xd0000060 <= e['address'] <= 0xd0000078]
            writes = [(e['address'], e['value']) for e in mmio if e['operation'] == 'Write']
            reads = [(e['address'], e['value']) for e in mmio if e['operation'] == 'Read']
            common.check(subsequence(writes, [(0xd0000068, 123456), (0xd000006c, (-321) & 0xffffffff),
                                              (0xd0000060, 123456), (0xd0000064, 321)]), 'Missing actual signed/unsigned divider operations')
            common.check(subsequence(writes, [(0xd0000068, 123), (0xd000006c, 7),
                                              (0xd0000060, 123456), (0xd0000064, (-321) & 0xffffffff),
                                              (0xd0000074, 192), (0xd0000070, (-384) & 0xffffffff)]), 'Missing actual inner division and restored hardware state')
            common.check((0xd0000070, 17) in reads and (0xd0000070, (-384) & 0xffffffff) in reads, 'Missing hardware quotient readbacks')
            result['observed_divider_register_accesses'] = len(mmio)
        result['exact_numeric_lines'] = expected
    elif args.target == 'narrow_io_write':
        for expected in ['Should be 0xdeadbeef: 0xdeadbeef', 'Should be ef be ad de: ef be ad de',
                         'Should be 0xa5a5a5a5: 0xa5a5a5a5', 'Should be 0x3c3c3c3c: 0x3c3c3c3c',
                         'Should be 0xf00df00d: 0xf00df00d']:
            common.check(text.count(expected) == 1, 'Narrow IO result missing or duplicated: ' + expected)
        base = 0x4005800c if args.board == 'pico' else 0x400d800c
        accesses = [(e['operation'], e['width'], e['address'] - base, e['value']) for e in events
                    if e['kind'] == 'register' and e['seconds'] >= start and base <= e['address'] <= base + 3]
        wanted = [('Write', 32, 0, 0xdeadbeef), ('Read', 32, 0, 0xdeadbeef),
                  ('Read', 8, 0, 0xef), ('Read', 8, 1, 0xbe), ('Read', 8, 2, 0xad), ('Read', 8, 3, 0xde),
                  ('Write', 8, 0, 0xa5), ('Read', 32, 0, 0xa5a5a5a5),
                  ('Write', 8, 1, 0x3c), ('Read', 32, 0, 0x3c3c3c3c),
                  ('Write', 16, 0, 0xf00d), ('Read', 32, 0, 0xf00df00d)]
        common.check(subsequence(accesses, wanted), 'Missing exact native-width IO accesses and replicated readbacks')
        result['native_accesses'] = accesses
    elif args.target == 'hello_rtc':
        uart = [e for e in events if e['kind'] == 'uart']
        raw = bytes(e['value'] for e in uart).decode('ascii')
        samples = [(int(m[1]), uart[m.end() - 1]['seconds']) for m in re.finditer(r'Friday 5 June 15:45:(\d{2}) 2020      ', raw)]
        common.check(len(samples) >= 20 and {0, 1, 2}.issubset({s for s, _ in samples}), 'RTC did not expose initial date and three advancing seconds')
        common.check(all(a <= b <= a + 1 for (a, _), (b, _) in zip(samples, samples[1:])), 'RTC samples did not progress monotonically at one second per second')
        result['sample_intervals'] = intervals([t for _, t in samples], constraints['polling']['sample_interval_seconds'], 'RTC polling period mismatch')
        firsts = [next(t for s, t in samples if s == sec) for sec in [0, 1, 2]]
        intervals(firsts, [.9, 1.1], 'RTC progression rate mismatch')
        result['samples'] = samples
    elif args.target in ['rtc_alarm', 'rtc_alarm_repeat']:
        callbacks = [e for e in addresses if e['label'] == 'alarm_callback']
        actual = [(int(m[1]), int(m[2]), t) for line, t in lines
                  if (m := re.fullmatch(r'Alarm Fired At Wednesday 13 January 11:(\d{2}):(\d{2}) 2020', line))]
        common.check(len(actual) == len(callbacks) and len(interrupts) >= len(callbacks), 'Alarm prints/callbacks/real IRQ evidence differ')
        if args.target == 'rtc_alarm':
            common.check(len(actual) == 1 and actual[0][:2] == (20, 5), 'One-shot RTC alarm count/date mismatch')
            lo, hi = constraints['alarm']['alarm_after_seconds']
            common.check(lo <= callbacks[0]['seconds'] - start <= hi, 'RTC alarm did not fire after five virtual seconds')
        else:
            common.check(len(actual) >= 3 and all(s == 0 for m, s, t in actual), 'Minute alarm callbacks missing or off second zero')
            common.check(len({(m, s) for m, s, t in actual}) == len(actual), 'RTC alarm repeated within a matching second')
            boundaries = [(m, t) for m, s, t in actual if m > 20]
            common.check([m for m, _ in boundaries] == [21, 22, 23], 'Three distinct minute-boundary callbacks missing')
            result['minute_intervals'] = intervals([t for _, t in boundaries], constraints['repeat']['interval_between_distinct_minutes_seconds'], 'RTC repeat cadence mismatch')
        result['alarm_outputs'] = actual
    elif args.target == 'simple_at_time_worker':
        callbacks = [e for e in addresses if e['label'] == 'worker_cb']
        common.check(len(callbacks) >= 6 and all(e['ipsr'] != 0 for e in callbacks), 'Background worker callbacks did not run in interrupt context')
        result['callback_intervals'] = intervals([e['seconds'] for e in callbacks], constraints['worker']['callback_interval_seconds'], 'Background worker callback cadence mismatch')
        common.check(.475 <= callbacks[0]['seconds'] - start <= .525, 'First worker callback did not wait 500ms')
        edges = led_edges(events, 25)
        common.check(len(edges) >= 7 and len(edges) == len(callbacks), 'Worker callback and GPIO edge counts differ')
        common.check(all(abs(edge['seconds'] - callback['seconds']) < .005 for edge, callback in zip(edges, callbacks)), 'GPIO output changes do not follow worker callbacks')
        result['worker_callbacks'] = len(callbacks)
    elif args.target == 'rand':
        common.check(re.search(r'^Random 32bits [0-9a-f]{8}$', text, re.M), '32-bit random API output width mismatch')
        common.check(re.search(r'^Random 64bits [0-9a-f]{16}$', text, re.M), '64-bit random API output width mismatch')
        common.check(re.search(r'^Random 128bits [0-9a-f]{32}$', text, re.M), '128-bit random API output width mismatch')
        counts = [(int(i), int(v)) for i, v in re.findall(r'^count of (\d+): (\d+)$', text, re.M)]
        common.check([i for i, _ in counts] == list(range(32)), 'Not all 32 random bins were printed exactly once')
        values = [value for _, value in counts]
        common.check('Generating 500000 random numbers\n' in text and sum(values) == 500000 and all(v > 0 for v in values), 'Random example did not complete all 500000 samples')
        common.check(all(98 <= 1562500 // v <= 101 for v in values), 'Source literal integer distribution check failed')
        common.check(f'Biggest count: {max(values)}\n' in text and f'Smallest count: {min(values)}\n' in text and 'All done\n' in text, 'Random completion/extrema differ')
        result['random_bin_counts'] = values
    elif args.target == 'unique_board_id':
        expected = args.variant.removeprefix('identity_')
        common.check(expected in ['0123456789abcdef', 'fedcba9876543210'], 'Unknown identity fixture')
        greeting = 'Unique identifier: ' + ' '.join(expected[i:i + 2] for i in range(0, 16, 2))
        actual = [line for line, _ in lines if line]
        common.check(actual == [greeting, greeting], 'Exact identity bytes were not retained across physical RUN reset')
        common.check(len(mains) == 2 and len(exits) == 2, 'Identity cold boot and reset did not each execute/exit the firmware')
        common.check(len([e for e in addresses if e['label'] == 'rom_reset']) >= 2, 'Identity reset did not return through actual ROM')
        result['exact_identity'] = expected
    elif args.target.startswith('hello_freertos_'):
        main_lines = [(int(m[1]), t) for line, t in lines if (m := re.fullmatch(r'Hello from main task count=(\d+)', line))]
        common.check([i for i, _ in main_lines] == list(range(10)), 'Full ten-count FreeRTOS main lifecycle missing')
        result['main_intervals'] = intervals([t for _, t in main_lines], constraints['main_lifecycle']['main_interval_seconds'], 'FreeRTOS main task delay differs from 3000 ticks')
        common.check(text.count('main_task is exiting now\n') == 1, 'FreeRTOS main task did not announce final deinitialization')
        returns = [e for e in addresses if e['label'] == 'async_context_freertos_deinit_return']
        common.check(len(returns) == 1, 'No actual completed async-context deinitialization observed')
        completed = returns[0]['seconds']
        common.check(args.observed_virtual_seconds - completed >= constraints['worker']['post_deinit_observe_seconds'], 'Insufficient post-deinitialization observation')
        deleted = [e for e in addresses if e['label'] == 'vTaskDelete' and e['r0'] == 0 and e['seconds'] >= completed]
        common.check(deleted, 'Main task did not delete itself after deinitializing its context')
        worker = [(int(m[1]), t) for line, t in lines if (m := re.fullmatch(r'Hello from worker count=(\d+)', line))]
        common.check([i for i, _ in worker] in [list(range(3)), list(range(4))], 'FreeRTOS worker counts missing, reordered, or duplicated')
        result['worker_intervals'] = intervals([t for _, t in worker], constraints['worker']['worker_interval_seconds'], 'FreeRTOS worker cadence mismatch')
        callbacks = [e for e in addresses if e['label'] == 'do_work']
        common.check(len(callbacks) == len(worker) and all(e['seconds'] <= completed for e in callbacks), 'Worker callbacks continued after deinitialization')
        tasks = [e for e in addresses if e['label'] in ['main_task', 'blink_task', 'do_work', 'prvIdleTask', 'prvPassiveIdleTask']]
        common.check(tasks and all(e['ipsr'] == 0 for e in tasks), 'FreeRTOS task functions did not execute in thread mode')
        common.check(all(e['core'] == 0 for e in tasks if e['label'] == 'main_task'), 'Main task violated its source core affinity')
        if args.target == 'hello_freertos_one_core':
            common.check(all(e['core'] == 0 for e in tasks), 'Single-core FreeRTOS ran task functions on core1')
        else:
            common.check({0, 1}.issubset({e['core'] for e in tasks}), 'SMP FreeRTOS task contexts did not actually execute on both cores')
        common.check(any(e['label'] in ['xPortSysTickHandler', 'SysTick_Handler'] for e in addresses)
                     and any(e['label'] in ['xPortPendSVHandler', 'PendSV_Handler'] for e in addresses)
                     and any(e['label'] == 'vTaskSwitchContext' for e in addresses), 'Actual SysTick/PendSV/context switching evidence missing')
        edges = led_edges(events, 25)
        common.check(len(edges) >= 10, 'Insufficient FreeRTOS blink progress')
        result['blink_half_periods'] = intervals([e['seconds'] for e in edges], constraints['blink']['blink_half_period_seconds'], 'Busy-wait blink cadence mismatch')
        common.check(len([e for e in edges if e['seconds'] > completed]) >= 5, 'Blink task did not keep progressing after main task deletion')
        result['deinitialization_completed_at'] = completed
    elif args.target == 'boot_info':
        common.check('boot_type: 0\n\tnormal\n' in text and 'reboot_params: 0x00000000:0x00000000\n' in text,
                     'Cold boot type/reboot parameters differ')
        common.check('diagnostic_partition_index: -2\n\tslot0\n' in text and 'recent_boot_partition: -2\n\tslot0\n' in text,
                     'Unpartitioned image did not select ROM slot0')
        common.check('recent_boot_tbyb_and_update_info: 0\n\tnone\n' in text and 'watchdog reboot 0 (0x0)\n' in text,
                     'Cold TBYB/watchdog state differs')
        diagnostics = re.search(r'boot_diagnostics 0x([0-9a-f]{8}):\n((?:\t[^\n]+\n)*)', text)
        common.check(diagnostics is not None, 'Boot diagnostics absent')
        bits = {0:'window searched', 1:'invalid block loop', 2:'valid block loop', 3:'valid image def',
                4:'has partition table', 5:'considered', 6:'chosen', 7:'partition table matching key for verify',
                8:'partition table hash for verify', 9:'partition table verified ok', 10:'image def matching key for verify',
                11:'image def hash for verify', 12:'image def verified ok', 13:'load map entries loaded',
                14:'image launched', 15:'image condition failure'}
        value = int(diagnostics[1], 16)
        common.check(diagnostics[2].splitlines() == ['\t' + name for bit, name in bits.items() if value & (1 << bit)], 'Boot diagnostic name decoding differs from numeric flags')
        common.check(value & ((1 << 3) | (1 << 14)) == ((1 << 3) | (1 << 14)), 'ROM did not validate and launch the image')
        result['boot_diagnostic'] = value
        # Fixed by the pinned ROM's actual DWARF bootram_t layout: boot_word
        # +0x358, diagnostic +0x35c, reboot_params +0x340; BOOTRAM_BASE0x400e0000.
        word = int(runtime.run('sysbus ReadDoubleWord 0x400e0358 context=cpu0'), 0)
        diagnostic = int(runtime.run('sysbus ReadDoubleWord 0x400e035c context=cpu0'), 0)
        params = [int(runtime.run(f'sysbus ReadDoubleWord 0x{address:x} context=cpu0'), 0) for address in [0x400e0340, 0x400e0344]]
        common.check(word == 0x00fe00fe and diagnostic == value and params == [0, 0],
                     'Printed boot information differs from actual pinned ROM BootRAM structures')
        result['bootram'] = dict(boot_word=word, boot_diagnostic=diagnostic, reboot_params=params)
    else:
        raise ValueError('Source-specific acceptance requires a dedicated driver: ' + args.target)
    return result
