#!/usr/bin/env python3
"""Actual loader reserved-memory helpers with real libfdt: SOURCE [--baseline].

No ADT capture, target access or device initialization. DART/ADT services are
owned fakes. Baseline mode requires each named predecessor defect to reproduce.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile


def section(text, start, end):
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError(f'ambiguous source section: {start}')
    return start + text.split(start, 1)[1].split(end, 1)[0]


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--baseline'):
        raise SystemExit(__doc__)
    source = Path(sys.argv[1]).resolve(strict=True)
    text = (source / 'src/kboot.c').read_text()
    selected = {
        'tuple': ('static int dt_device_set_reserved_mem(', '\nstatic int dt_device_set_reserved_mem_from_dart('),
        'nodes': ('static int dt_get_or_add_reserved_mem(', '\nstatic int dt_set_dcp_firmware('),
        'regions': ('struct disp_mapping {', '\nstatic int dt_carveout_reserved_regions('),
        'asc': ('static int dt_reserve_asc_firmware(', '\nstatic const char dcpext_aliases'),
    }
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('existing C compiler required')
    libfdt = source / 'src/libfdt'
    with tempfile.TemporaryDirectory(prefix='reserved-record-') as name:
        temporary = Path(name)
        for key, bounds in selected.items():
            (temporary / (key + '.inc')).write_text(section(text, *bounds) + '\n')
        command = [compiler, '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-Wall', '-Wextra', '-Werror', '-g',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(temporary), '-I', str(libfdt),
                   str(Path(__file__).with_suffix('.c'))]
        command += [str(libfdt / (part + '.c')) for part in
                    ('fdt', 'fdt_ro', 'fdt_rw', 'fdt_wip', 'fdt_sw', 'fdt_empty_tree', 'fdt_strerror')]
        executable = temporary / 'reserved-record'
        command += ['-o', str(executable)]
        subprocess.run(command, check=True)
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1'))
        modes = ('tuple', 'display', 'asc') if len(sys.argv) == 3 else ('all',)
        for mode in modes:
            run = subprocess.run([str(executable), mode], text=True, capture_output=True, env=env)
            if len(sys.argv) == 3:
                marker = {'tuple': 'complete IOMMU record', 'display': 'display reservation failure',
                          'asc': 'ASC reservation failure'}[mode]
                if run.returncode == 0 or marker not in run.stderr:
                    raise AssertionError(f'{mode}: expected named assertion, got {run.returncode}: {run.stderr}')
                print(json.dumps({'predecessor_defect': mode, 'reproduced': True}))
            else:
                if run.returncode or run.stderr:
                    raise AssertionError(f'{run.returncode}: {run.stderr}')
                print(run.stdout.strip())


if __name__ == '__main__':
    main()
