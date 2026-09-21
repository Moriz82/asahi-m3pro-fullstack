#!/usr/bin/env python3
"""Actual USB DWC3/ringbuffer C, fake hardware only: SOURCE [--baseline]."""
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
    cases = ['halt', 'reset', 'end-transfer', 'unmap-1', 'unmap-2', 'unmap-3',
             'unmap-4', 'dart-shutdown', 'invalid-core', 'constructor-oom', 'map-uncertain']
    cases += ['callback-' + name for name in ('events', 'get', 'put', 'read', 'write', 'queue', 'flush')]
    if not baseline:
        cases += ['allocation-' + str(i) for i in range(1, 14)]
        cases += ['map-safe-' + str(i) for i in range(1, 5)]
        cases += ['duplicate', 'invalid-pipe', 'shutdown-reentry']
    with tempfile.TemporaryDirectory(prefix='usb-lifecycle-') as directory:
        temporary = Path(directory)
        (temporary / 'include').mkdir()
        (temporary / 'build').mkdir()
        (temporary / 'build/build_tag.h').write_text('#define BUILD_TAG "offline-test"\n')
        executable = temporary / 'usb'
        command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-multichar',
                   '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(source / 'src'), '-I', str(temporary / 'include'),
                   f'-DM1N1_USB_SOURCE="{source / "src/usb_dwc3.c"}"',
                   f'-DM1N1_RING_SOURCE="{source / "src/ringbuffer.c"}"',
                   str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
        if 'bool usb_dwc3_shutdown(' in (source / 'src/usb_dwc3.h').read_text():
            command.insert(1, '-DUSB_LIFECYCLE')
        if 'bool dart_unmap(' in (source / 'src/dart.h').read_text():
            command.insert(1, '-DDART_LIFECYCLE')
        if baseline:
            # Isolate ownership failures from predecessor's signed (1 << 31) constants.
            # The current source receives the complete UBSan instrumentation.
            command.append('-fno-sanitize=shift-base')
            print('CONTROL: predecessor shift-base sanitizer disabled; ownership assertions remain')
        subprocess.run(command, check=True)
        for case in ['healthy'] + cases:
            result = subprocess.run([str(executable), case], capture_output=True, text=True,
                                    timeout=20, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            if baseline and case != 'healthy':
                if not result.returncode or 'assertion' not in result.stderr.lower():
                    raise AssertionError(f'predecessor {case} not reproduced: {result.stderr}')
                print(f'PASS: predecessor USB/{case} defect reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(f'USB/{case}: {result.stdout}\n{result.stderr}')
            else:
                print(f'PASS: USB/{case}')


if __name__ == '__main__':
    main()
