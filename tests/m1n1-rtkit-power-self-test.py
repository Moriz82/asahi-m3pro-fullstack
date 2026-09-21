#!/usr/bin/env python3
"""Actual RTKit power/receive C checks on AArch64 Linux: SOURCE [--baseline]."""
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
    with tempfile.TemporaryDirectory(prefix='rtkit-power-') as temporary:
        executable = Path(temporary) / 'test'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                   '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'),
                   f'-DM1N1_RTKIT_SOURCE="{source / "src/rtkit.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        if baseline:
            command.insert(1, '-DBASELINE')
        if 'bool dart_unmap(' in (source / 'src/dart.h').read_text():
            command.insert(1, '-DDART_LIFECYCLE')
        subprocess.run(command, check=True)
        modes = ['sleep-success', 'sleep-send-failure', 'crashed-sleep', 'ap-timeout',
                 'iop-timeout', 'stale-cache', 'system-flood', 'invalid-flood',
                 'early-iop'] if baseline else ['all']
        timeouts = {'ap-timeout', 'iop-timeout', 'system-flood', 'invalid-flood', 'early-iop'}
        for mode in modes:
            try:
                result = subprocess.run([str(executable), mode], capture_output=True, text=True,
                                        timeout=2 if baseline else 30,
                                        env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            except subprocess.TimeoutExpired:
                if baseline and mode in timeouts:
                    print(f'PASS: original {mode} unbounded wait reproduced')
                    continue
                raise
            if baseline:
                if result.returncode == 0 or not any(marker in result.stderr.lower() for marker in
                        ['assertion', 'runtime error:', 'addresssanitizer']):
                    raise AssertionError(f'original {mode} not reproduced: {result.stderr}')
                print(f'PASS: original {mode} failure reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(f'{mode}: {result.stdout}\n{result.stderr}')
            else:
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
