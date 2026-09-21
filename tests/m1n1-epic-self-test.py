#!/usr/bin/env python3
"""Actual AFK/EPIC and property-parser C tests: SOURCE [--baseline]."""
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
    with tempfile.TemporaryDirectory(prefix='epic-') as temporary:
        executable = Path(temporary) / 'test'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                   '-Wno-calloc-transposed-args',
                   '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'),
                   f'-DM1N1_AFK_SOURCE="{source / "src/afk.c"}"',
                   f'-DM1N1_PARSER_SOURCE="{source / "src/dcp/parser.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        if baseline:
            command.insert(1, '-DBASELINE')
            command.insert(1, '-Wno-sign-compare')  # Existing predecessor parser loop.
        subprocess.run(command, check=True)
        modes = ['envelope', 'lifetime', 'notify-channel', 'reply-channel', 'reply-sequence',
                 'reply-address', 'skip-truncated', 'duplicate-property', 'parser-oom',
                 'interface-timeout', 'parser-unaligned', 'work-noise', 'command-nested'] if baseline else ['all']
        for mode in modes:
            try:
                result = subprocess.run([str(executable), mode], capture_output=True, text=True,
                                        timeout=3 if baseline else 30,
                                        env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            except subprocess.TimeoutExpired:
                if baseline and mode in ('interface-timeout', 'work-noise'):
                    print(f'PASS: original {mode} failure reproduced')
                    continue
                raise
            if baseline:
                if result.returncode == 0 or not any(marker in result.stderr.lower() for marker in
                        ['assertion', 'runtime error:', 'addresssanitizer', 'leaksanitizer']):
                    raise AssertionError(f'original {mode} not reproduced: {result.stderr}')
                print(f'PASS: original {mode} failure reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(f'{mode}: {result.stdout}\n{result.stderr}')
            else:
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
