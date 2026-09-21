#!/usr/bin/env python3
"""Actual IOVA allocator plus RTKit integration: SOURCE [--baseline], AArch64 Linux."""
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
    with tempfile.TemporaryDirectory(prefix='iova-test-') as temporary:
        display = (source / 'src/display.c').read_text()
        start, end = '    if (fb_size < size) {', '        // Swap!'
        if display.count(start) != 1 or display.count(end) != 1:
            raise ValueError('ambiguous display allocation block')
        prefix = start + display.split(start, 1)[1].split(end, 1)[0]
        (Path(temporary) / 'display-allocation.inc').write_text(prefix)
        executable = Path(temporary) / 'test'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                   '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'), '-I', temporary,
                   f'-DM1N1_IOVA_SOURCE="{source / "src/iova.c"}"',
                   f'-DM1N1_RTKIT_SOURCE="{source / "src/rtkit.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        if baseline:
            command.insert(1, '-DBASELINE')
        if 'bool dart_unmap(' in (source / 'src/dart.h').read_text():
            command.insert(1, '-DDART_LIFECYCLE')
        subprocess.run(command, check=True)
        modes = ['high-bounds', 'exact-reserve', 'tail-free', 'zero-base',
                 'unaligned-reserve', 'shutdown-wrap', 'display-exhaustion'] if baseline else ['all']
        for mode in modes:
            result = subprocess.run([str(executable), mode], capture_output=True, text=True,
                                    env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            if baseline:
                if result.returncode == 0 or 'assertion' not in result.stderr.lower():
                    raise AssertionError(f'original {mode} not reproduced: {result.stderr}')
                print(f'PASS: original {mode} failure reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(result.stderr)
            else:
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
