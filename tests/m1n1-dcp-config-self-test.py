#!/usr/bin/env python3
"""Run actual display selection and DCP lifecycle with fake dependencies.

Usage: SOURCE CLIENT DECODED_ADT [--baseline]
No device access; C stubs replace every hardware-facing dependency.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def section(text, start, end):
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError(f'ambiguous source section: {start}')
    return start + text.split(start, 1)[1].split(end, 1)[0]


def main():
    if len(sys.argv) not in (4, 5) or (len(sys.argv) == 5 and sys.argv[4] != '--baseline'):
        raise SystemExit(__doc__)
    source, client, adt_file = [Path(p).resolve(strict=True) for p in sys.argv[1:4]]
    baseline = len(sys.argv) == 5
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(client))
    from m1n1.adt import load_adt
    raw = adt_file.read_bytes()
    if hashlib.sha256(raw).hexdigest() != '4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478':
        raise ValueError('wrong exact-target Apple tree')
    adt = load_adt(raw)
    if list(adt.compatible) != ['J514sAP', 'Mac15,6', 'AppleARM']:
        raise ValueError('wrong target identity')
    devices = {d.id2: d for d in adt['/arm-io/pmgr'].devices}
    gate, = adt['/arm-io/dcp'].getprop('clock-gates')
    virtual = devices[gate]
    parent = devices[virtual.parents_un.u16id.parents[0]]
    if not virtual.flags.no_ps or parent.flags.no_ps or parent.name != 'DISP_CPU':
        raise ValueError('unexpected DCP power dependency')
    if any(d.name == 'DISP0_CPU0' for d in devices.values()):
        raise ValueError('old reset target unexpectedly exists')
    for path in ['/arm-io/dcp', '/arm-io/dart-dcp', '/arm-io/dart-disp0']:
        adt[path]

    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('existing C compiler required')
    header = section((source / 'src/dcp.h').read_text(), 'typedef struct {', '\nint dcp_connect_dptx(')
    display = (source / 'src/display.c').read_text()
    configs = section(display, 'static const display_config_t display_config_m1', '\n#define abs(')
    selector = section(display, 'const display_config_t *display_get_config(void)', '\nint display_start_dcp(')
    dcp = (source / 'src/dcp.c').read_text()
    globals_ = section(dcp, 'static char dcp_pmgr_dev', '\nstatic int dcp_hdmi_dptx_init(')
    lifecycle = dcp.split('dcp_dev_t *dcp_init(', 1)
    if len(lifecycle) != 2 or lifecycle[1].count('int dcp_shutdown(') != 1:
        raise ValueError('DCP lifecycle source changed')
    lifecycle = 'dcp_dev_t *dcp_init(' + lifecycle[1]
    fixture = Path(__file__).parent / 'fixtures/dcp/m1n1-config.c'
    completed = 0
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1'))
    with tempfile.TemporaryDirectory(prefix='m1n1-dcp-config-') as temporary:
        temporary = Path(temporary)
        (temporary / 'types.inc').write_text(header)
        (temporary / 'lifecycle.inc').write_text(globals_ + '\n' + lifecycle)
        # Construct malformed values at initialization: production fields are const.
        names = ['static const display_config_t varied_names[] = {']
        for length in range(25):
            chars = ["'x'"] * length + (['0'] if length < 24 else [])
            names.append('{.dcp="/arm-io/dcp", .dcp_dart="/arm-io/dart-dcp", '
                         '.disp_dart="/arm-io/dart-disp0", .dcp_alias="dcp", '
                         '.pmgr_dev={' + ','.join(chars) + '}},')
        (temporary / 'names.inc').write_text('\n'.join(names) + '\n};\n')
        for external in [0, 1]:
            if configs.count('#define USE_DCPEXT 1') != 1:
                raise ValueError('external selector changed')
            (temporary / 'display.inc').write_text(configs.replace('#define USE_DCPEXT 1', f'#define USE_DCPEXT {external}') + selector)
            executable = temporary / f'case-{external}'
            command = [compiler, '-std=c11', '-D_POSIX_C_SOURCE=200809L',
                            '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                            '-fno-sanitize-recover=all', '-I', str(temporary),
                            str(fixture), '-o', str(executable)]
            if 'static dcp_dev_t *active_dcp;' in globals_:
                command.append('-DDCP_LIFECYCLE_V2')
            if 'bool dart_unmap(' in (source / 'src/dart.h').read_text():
                command.append('-DDART_LIFECYCLE')
            if baseline:
                # Old USE_DCPEXT=0 repeats two identical initializers.
                version = subprocess.check_output([compiler, '--version'], text=True)
                command.append('-Wno-error=' + ('initializer-overrides' if 'clang' in version else 'override-init'))
            built = subprocess.run(command, capture_output=True, text=True)
            if built.returncode:
                raise AssertionError(built.stderr)
            if built.stderr:
                print(built.stderr, end='', file=sys.stderr)
            modes = ['j514s', 'internal'] if baseline else ['all']
            for mode in modes:
                result = subprocess.run([str(executable), mode], capture_output=True, text=True, env=env)
                if baseline:
                    if result.returncode == 0 or 'assertion' not in result.stderr.lower():
                        raise AssertionError(f'baseline fault not reproduced: {mode}: {result.stderr}')
                elif result.returncode or result.stderr:
                    raise AssertionError(result.stderr)
                else:
                    value = json.loads(result.stdout)
                    if value['target'] != parent.name or value['sid'] != adt['/arm-io/dart-dcp/mapper-dcp'].reg:
                        raise AssertionError('C configuration disagrees with exact ADT')
                    print(f'USE_DCPEXT={external}: {value["cases"]} lifecycle/selector cases pass')
                completed += 1
    print(f'PASS: {completed} sanitizer runs; ' + ('both original faults reproduced in both external configurations' if baseline else 'exact ADT, selectors, reset routing, invalid-input rejection, firmware gate and failure cleanup'))


if __name__ == '__main__':
    main()
