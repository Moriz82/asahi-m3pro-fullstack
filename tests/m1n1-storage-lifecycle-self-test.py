#!/usr/bin/env python3
"""Actual NVMe/SMC lifecycle C with fake hardware: SOURCE [--baseline]."""
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
    controls = {
        'nvme': ['power', 'controller-stop', 'controller-disable', 'buffer-free',
                 'partial-boot', 'queue-oom', 'invalid-tag', 'read-ownership'],
        'smc': ['power', 'buffer-free', 'partial-boot', 'send', 'receive', 'initialize'],
    }
    with tempfile.TemporaryDirectory(prefix='storage-lifecycle-') as temporary:
        for mode in controls:
            executable = Path(temporary) / mode
            command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                       '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                       '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                       '-I', str(source / 'src'), f'-DTEST_{mode.upper()}',
                       f'-DM1N1_STORAGE_SOURCE="{source / "src" / (mode + ".c")}"',
                       str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
            if baseline:
                command.insert(1, '-DBASELINE')
            if 'bool sart_free(' in (source / 'src/sart.h').read_text():
                command.insert(1, '-DSART_LIFECYCLE')
            subprocess.run(command, check=True)
            for case in controls[mode] if baseline else ['all']:
                try:
                    result = subprocess.run([str(executable), case], capture_output=True, text=True,
                                            timeout=3 if baseline else 30,
                                            env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
                except subprocess.TimeoutExpired:
                    if not baseline or mode != 'smc' or case not in ['send', 'receive', 'initialize']:
                        raise
                    print(f'PASS: original {mode}/{case} unbounded wait reproduced')
                    continue
                if baseline:
                    if result.returncode == 0 or 'assertion' not in result.stderr.lower():
                        raise AssertionError(f'original {mode}/{case} not reproduced: {result.stderr}')
                    print(f'PASS: original {mode}/{case} ownership failure reproduced')
                elif result.returncode or result.stderr:
                    raise AssertionError(f'{mode}/{case}: {result.stdout}\n{result.stderr}')
                else:
                    print(result.stdout.strip())


if __name__ == '__main__':
    main()
