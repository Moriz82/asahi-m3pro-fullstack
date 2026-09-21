#!/usr/bin/env python3
"""Actual AFK C ring/handshake tests on AArch64 Linux: SOURCE [--baseline]."""
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
    with tempfile.TemporaryDirectory(prefix='afk-ring-') as temporary:
        executable = Path(temporary) / 'test'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                   '-Wno-calloc-transposed-args',  # Existing unrelated allocation spelling.
                   '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'),
                   f'-DM1N1_AFK_SOURCE="{source / "src/afk.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        if baseline:
            command.insert(1, '-DBASELINE')
        subprocess.run(command, check=True)
        modes = ['window', 'address', 'wrap', 'uncommitted', 'position', 'ack',
                 'duplicate', 'block128', 'send-failure'] if baseline else ['all']
        for mode in modes:
            result = subprocess.run([str(executable), mode], capture_output=True, text=True,
                                    env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            if baseline:
                if result.returncode == 0 or 'assertion' not in result.stderr.lower():
                    raise AssertionError(f'original {mode} not reproduced: {result.stderr}')
                print(f'PASS: original {mode} failure reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(f'{mode}: {result.stdout}\n{result.stderr}')
            else:
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
