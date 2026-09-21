#!/usr/bin/env python3
"""Actual SART and RTKit map/unmap with owned fake registers: SOURCE [--baseline]."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--baseline'):
        raise SystemExit(__doc__)
    source = Path(sys.argv[1]).resolve(strict=True)
    baseline = len(sys.argv) == 3
    with tempfile.TemporaryDirectory(prefix='sart-owned-') as temporary:
        executable = Path(temporary) / 'sart'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                   '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'),
                   f'-DM1N1_SART_SOURCE="{source / "src/sart.c"}"',
                   f'-DM1N1_RTKIT_SOURCE="{source / "src/rtkit.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        if baseline:
            command.insert(1, '-DBASELINE')
        if 'bool dart_unmap(' in (source / 'src/dart.h').read_text():
            command.insert(1, '-DDART_LIFECYCLE')
        subprocess.run(command, check=True)
        modes = ['wide-address', 'empty-region', 'foreign-free', 'foreign-remove',
                 'clear-order', 'opaque-flags', 'cleanup-failure', 'duplicate'] if baseline else ['all']
        for mode in modes:
            result = subprocess.run([str(executable), mode], capture_output=True, text=True,
                                    timeout=30, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            if baseline:
                if not result.returncode or 'assertion' not in result.stderr.lower():
                    raise AssertionError(f'predecessor {mode} did not fail: {result.stderr}')
                print(f'PASS: predecessor SART/{mode} defect reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(f'{mode}: {result.stdout}\n{result.stderr}')
            else:
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
