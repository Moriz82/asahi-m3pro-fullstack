#!/usr/bin/env python3
"""Actual DART/RTKit failed-invalidation controls, no hardware: SOURCE [--baseline]."""
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
    cases = ['init-flush', 'map-flush', 'rollback-flush', 'rtkit-unmap',
             'rtkit-map', 'free-l2', 'shutdown-flush', 'borrowed-heap']
    with tempfile.TemporaryDirectory(prefix='dart-lifecycle-') as temporary:
        executable = Path(temporary) / 'dart'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                   '-no-pie', '-fno-pie', '-ffunction-sections', '-fdata-sections',
                   '-Wl,--gc-sections', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'),
                   f'-DM1N1_DART_SOURCE="{source / "src/dart.c"}"',
                   f'-DM1N1_RTKIT_SOURCE="{source / "src/rtkit.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        subprocess.run(command, check=True)
        for generation in ('t8020', 't6000', 't8110'):
            healthy = subprocess.run([str(executable), generation, 'healthy'], capture_output=True,
                                     text=True, timeout=30, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            if healthy.returncode or healthy.stderr:
                raise AssertionError(f'{generation}/healthy: {healthy.stdout}\n{healthy.stderr}')
            print(f'PASS: {generation} healthy real DART/RTKit flow')
            generation_cases = list(cases)
            if not baseline:
                generation_cases += ['record-oom-' + str(n) for n in
                                     range(1, 3 if generation == 't8110' else 6)]
                generation_cases += ['map-record-oom']
            for case in generation_cases:
                result = subprocess.run([str(executable), generation, case], capture_output=True,
                                        text=True, timeout=30,
                                        env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
                if baseline:
                    if not result.returncode or 'assertion' not in result.stderr.lower():
                        raise AssertionError(f'predecessor {generation}/{case} not reproduced: {result.stderr}')
                    print(f'PASS: predecessor {generation}/{case} defect reproduced')
                elif result.returncode or result.stderr:
                    raise AssertionError(f'{generation}/{case}: {result.stdout}\n{result.stderr}')
                else:
                    print(f'PASS: {generation}/{case} ownership retained')


if __name__ == '__main__':
    main()
