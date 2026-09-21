#!/usr/bin/env python3
"""Actual storage callers and Rust cache with fake dependencies: SOURCE [--baseline]."""
import ast
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace


def section(text, start, end):
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError(f'ambiguous source section: {start}')
    return start + text.split(start, 1)[1].split(end, 1)[0]


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--baseline'):
        raise SystemExit(__doc__)
    source = Path(sys.argv[1]).resolve(strict=True)
    baseline = len(sys.argv) == 3
    dcp = (source / 'src/dcp.c').read_text()
    chain = (source / 'src/chainload.c').read_text().split('#ifdef CHAINLOADING\n\n', 1)[1].split('#else', 1)[0]
    parts = {
        'pmgr': section((source / 'src/pmgr.c').read_text(), 'int pmgr_reset(', '\nint pmgr_power_on('),
        'hdmi': section(dcp, 'struct adt_function_smc_gpio {', '\nstatic char dcp_pmgr_dev') +
                section(dcp, 'static int dcp_hdmi_dptx_init(', '\nint dcp_connect_dptx('),
        'chainload': chain,
    }
    with tempfile.TemporaryDirectory(prefix='storage-integration-') as temporary:
        temporary = Path(temporary)
        for mode, text in parts.items():
            (temporary / 'integration.inc').write_text(text)
            executable = temporary / mode
            command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                       '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                       '-I', str(temporary), '-I', str(source / 'src'), f'-DTEST_{mode.upper()}',
                       str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
            if baseline:
                command.insert(1, '-DBASELINE')
            subprocess.run(command, check=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30,
                                    env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
            if baseline:
                if result.returncode == 0 or 'assertion' not in result.stderr.lower():
                    raise AssertionError(f'original {mode} control did not fail: {result.stderr}')
                print(f'PASS: original {mode} contract failure reproduced')
            elif result.returncode or result.stderr:
                raise AssertionError(f'{mode}: {result.stdout}\n{result.stderr}')
            else:
                print(result.stdout.strip())
        rust_source = (source / 'rust/src/nvme.rs').as_posix()
        (temporary / 'nvme-source.rs').write_text(f'#[path = "{rust_source}"]\nmod nvme;\n')
        rust_fixture = Path(__file__).with_suffix('.rs').read_text()
        (temporary / 'test.rs').write_text(rust_fixture)
        executable = temporary / 'rust-cache'
        subprocess.run(['rustc', '--edition=2021', '-Dwarnings', '-Copt-level=2',
                        '-Coverflow-checks=yes', str(temporary / 'test.rs'), '-o', str(executable)], check=True)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
        if baseline:
            if not result.returncode or 'assertion' not in result.stderr:
                raise AssertionError(f'original Rust cache did not fail: {result.stderr}')
            print('PASS: original Rust failed-read cache hit reproduced')
        elif result.returncode or result.stderr:
            raise AssertionError(f'Rust: {result.stdout}\n{result.stderr}')
        else:
            print(result.stdout.strip())

    text = (source / 'proxyclient/m1n1/proxyutils.py').read_text()
    methods = [n for n in ast.walk(ast.parse(text)) if isinstance(n, ast.FunctionDef) and n.name == 'get_gigalocker']
    assert len(methods) == 1
    method = methods[0]
    scope = {'struct': struct}
    exec(compile(ast.Module(body=[method], type_ignores=[]), str(source / 'proxyclient/m1n1/proxyutils.py'), 'exec'), scope)
    for ready in (False, True):
        calls = []
        def readmem(address, size):
            calls.append('read')
            return struct.pack('QQ', 0x1000, 4) if size == 16 else b'data'
        proxy = SimpleNamespace(nvme_init=lambda: ready, read_gigalocker=lambda arg: calls.append('load'),
                                free_gigalocker=lambda arg: calls.append('free'))
        obj = SimpleNamespace(proxy=proxy, iface=SimpleNamespace(readmem=readmem), glk_arg_buf=0x2000)
        try:
            value = scope['get_gigalocker'](obj)
        except RuntimeError:
            assert not ready and not calls
        else:
            if not ready:
                if baseline:
                    print('PASS: original Python helper ignored initialization failure')
                    return
                raise AssertionError('Python helper used failed NVMe owner')
            assert value == b'data' and calls == ['load', 'read', 'read', 'free']
    if baseline:
        raise AssertionError('original Python helper unexpectedly rejected failure')
    print('Python gigalocker initialization gate: PASS (2 scenarios)')


if __name__ == '__main__':
    main()
