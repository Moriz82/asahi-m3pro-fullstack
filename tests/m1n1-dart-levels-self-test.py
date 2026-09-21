#!/usr/bin/env python3
"""Actual C retained-level/lifecycle tests on AArch64 Linux: SOURCE [--baseline]."""
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
    text = (source / 'src/kboot.c').read_text()
    start, end = 'static u64 dart_get_mapping(', '\nstatic int dt_device_set_reserved_mem('
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError('ambiguous mapping helper')
    helper = start + text.split(start, 1)[1].split(end, 1)[0]
    with tempfile.TemporaryDirectory(prefix='dart-levels-') as temporary:
        temporary = Path(temporary)
        (temporary / 'mapping.inc').write_text(helper)
        executable = temporary / 'levels'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-no-pie', '-fno-pie',
                   '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'), '-I', str(temporary),
                   f'-DM1N1_DART_SOURCE="{source / "src/dart.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        subprocess.run(command, check=True)
        modes = ['four-level-translation', 'four-level-search', 'nonzero-root-unmap'] if baseline else ['all']
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
