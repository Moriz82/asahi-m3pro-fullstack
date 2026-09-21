#!/usr/bin/env python3
"""Test actual loader clock publication with real libfdt and parsed ADT fixtures.

Usage: M1N1_SOURCE CLIENT DECODED_ADT CLOCK_METADATA_JSON J514S_DTB [APPLE_DRIVER]
ADT C API is stubbed with Python-parser-derived properties; no hardware calls.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) not in (6, 7):
        raise SystemExit(__doc__)
    source, client, adt_file, metadata_file, dtb = [Path(p).resolve(strict=True) for p in sys.argv[1:6]]
    driver = Path(sys.argv[6]).resolve(strict=True) if len(sys.argv) == 7 else None
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(client))
    from m1n1.adt import load_adt
    raw = adt_file.read_bytes()
    if hashlib.sha256(raw).hexdigest() != '4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478':
        raise ValueError('wrong Apple ADT fixture')
    adt = load_adt(raw)
    if adt.model != 'Mac15,6' or list(adt['/arm-io/disp0'].getprop('clock-ids')) != [348, 412]:
        raise ValueError('wrong display clock provider')
    if adt['/arm-io/dcp'].getprop('clock-ids') is not None:
        raise ValueError('unexpected DCP clock IDs')
    if adt['/arm-io'].getprop('clock-frequencies-nclk') is not None:
        raise ValueError('template unexpectedly contains a runtime type table')
    raw_metadata = metadata_file.read_bytes()
    if hashlib.sha256(raw_metadata).hexdigest() != '56e99ffdc6a5d7c448f1d340e055095953a5b7730042988b7cae1800bbbb3efa':
        raise ValueError('wrong recorded metadata fixture')
    metadata = json.loads(raw_metadata)
    if metadata['macos_build'] != '25G227' or metadata['for_future_boot_constants']:
        raise ValueError('metadata provenance changed')
    arrays = {'template_freq': list(adt['/arm-io'].getprop('clock-frequencies'))}
    for name, key in [('recorded_freq','clock-frequencies'), ('recorded_kinds','clock-frequencies-nclk')]:
        raw_property = bytes.fromhex(metadata['properties_hex']['arm-io'][key])
        arrays[name] = list(struct.unpack('<' + 'I' * (len(raw_property) // 4), raw_property))
    source_text = (source / 'src/kboot.c').read_text()
    start, end = 'static int dt_set_display_clocks(void)', '\nstatic int dt_set_display(void)'
    if source_text.count(start) != 1:
        raise ValueError('missing/ambiguous loader helper')
    helper = start + source_text.split(start, 1)[1].split(end, 1)[0]
    if 'if (dt_set_display_clocks())\n        return -1;\n    if (dt_set_display())' not in source_text:
        raise ValueError('clock publication must precede display handoff')
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('existing compiler required')
    libfdt = source / 'src/libfdt'
    fixture = Path(__file__).parent / 'fixtures/dcp/clock-handoff.c'
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1'))
    with tempfile.TemporaryDirectory(prefix='dcp-clock-handoff-') as temporary:
        temporary = Path(temporary)
        (temporary / 'helper.inc').write_text(helper + '\n')
        (temporary / 'inputs.inc').write_text('\n'.join(
            'static const u32 ' + name + '[] = {' + ','.join(map(str, values)) + '};'
            for name, values in arrays.items()) + '\n')
        executable = temporary / 'handoff'
        command = [compiler, '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-Wall', '-Wextra', '-Werror',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(temporary), '-I', str(libfdt), str(fixture)]
        command += [str(libfdt / (name + '.c')) for name in
                    ['fdt', 'fdt_ro', 'fdt_rw', 'fdt_wip', 'fdt_sw', 'fdt_empty_tree', 'fdt_strerror']]
        command += ['-o', str(executable)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        result = subprocess.run([str(executable), str(dtb)], capture_output=True, text=True, env=env)
        if result.returncode or result.stderr:
            raise AssertionError(result.stderr)
        result = json.loads(result.stdout)
        if result['recorded_fixture_rates'] != [712000000, 0] or not result['all_hardware_nodes_disabled']:
            raise AssertionError(result)
        if driver is not None:
            # Feed actual FDT readback into the real Linux callback fixture.
            # Kernel clock services remain stubs, not a live OF/CCF test.
            command = [sys.executable, '-B', str(Path(__file__).with_name('dcp-clock-self-test.py')),
                       str(driver), *map(str, result['recorded_fixture_rates'])]
            consumer = subprocess.run(command, capture_output=True, text=True, env=env)
            if consumer.returncode or consumer.stderr:
                raise AssertionError(consumer.stderr)
            result['linux_callback_from_fdt_readback'] = consumer.stdout.strip().splitlines()
        print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
