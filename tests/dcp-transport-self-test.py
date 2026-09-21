#!/usr/bin/env python3
"""Actual DCP transport: APPLE_DRIVER [--baseline|--completion-baseline|--metadata-baseline].

No device execution. Extracts unchanged source functions and declarations;
only kernel logging, mailbox transmission and callback bodies are fakes.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def section(text, start, end):
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError(f'ambiguous source section: {start}')
    return start + text.split(start, 1)[1].split(end, 1)[0]


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ('--baseline', '--completion-baseline', '--metadata-baseline')):
        raise SystemExit(__doc__)
    driver = Path(sys.argv[1]).resolve(strict=True)
    baseline = len(sys.argv) == 3
    completion_only = baseline and sys.argv[2] == '--completion-baseline'
    metadata_only = baseline and sys.argv[2] == '--metadata-baseline'
    header = (driver / 'iomfb.h').read_text()
    declarations = section(header, '#define DCP_SHMEM_SIZE', '\n/*\n * IOMFB supports')
    declarations += section(header, '#define IOMFB_MESSAGE_TYPE\t', '\nenum iomfb_property_id')
    declarations += section(header, 'struct dcp_get_frequency_req {', '\nstruct dcp_get_uint_prop_req')
    internal = (driver / 'dcp-internal.h').read_text()
    declarations += section(internal, '#define DCP_MAX_CALL_DEPTH', '\nstruct dcp_fb_reference')
    transport = (driver / 'iomfb.c').read_text()
    code = section(transport, 'static int dcp_tx_offset(', '\n/*\n * Helper to send a DRM hotplug event')
    code += section(transport, 'static void dcpep_handle_cb(', '\nint dcp_get_modes')
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('existing C compiler required')
    fixture = Path(__file__).parent / 'fixtures/dcp/transport.c'
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1'))
    with tempfile.TemporaryDirectory(prefix='dcp-transport-') as directory:
        directory = Path(directory)
        (directory / 'types.inc').write_text(declarations)
        (directory / 'code.inc').write_text(code)
        executable = directory / 'transport'
        command = [compiler, '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                   '-Wno-unused-parameter', '-Wno-unused-function',
                   '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                   '-I', str(directory), str(fixture), '-o', str(executable)]
        if baseline:
            command += ['-DBASELINE']
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        modes = ['short-frame-sync', 'short-hotplug', 'trailing-frame-sync', 'trailing-hotplug'] if metadata_only else ['short-completion', 'trailing-completion'] if completion_only else ['empty-ack', 'deep-callback', 'short-payload', 'nested-window', 'ack-pointer'] if baseline else ['all']
        for mode in modes:
            result = subprocess.run([str(executable), mode], capture_output=True, text=True, env=env)
            if baseline:
                if result.returncode == 0 or not any(word in result.stderr.lower() for word in ['assertion', 'runtime error', 'addresssanitizer']):
                    raise AssertionError(f'baseline {mode} not reproduced: {result.stderr}')
                print(f'PASS: original {mode} fault reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(result.stderr)
            else:
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
