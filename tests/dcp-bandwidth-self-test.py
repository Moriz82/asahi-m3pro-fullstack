#!/usr/bin/env python3
"""Compile the actual bandwidth callback/resource parser: APPLE_DRIVER [--baseline]."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def section(source, start, end):
    if source.count(start) != 1:
        raise ValueError(f'ambiguous source marker: {start}')
    return start + source.split(start, 1)[1].split(end, 1)[0]


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--baseline'):
        raise SystemExit(__doc__)
    driver = Path(sys.argv[1])
    baseline = len(sys.argv) == 3
    header = (driver / ('iomfb.h' if baseline else 'iomfb_template.h')).read_text()
    name = 'struct dcp_rt_bandwidth {' if baseline else 'struct DCP_FW_NAME(dcp_rt_bandwidth) {'
    declaration = section(header, name, '} __packed;') + '} __packed;\n'
    source = (driver / 'iomfb_template.c').read_text()
    name = 'static struct dcp_rt_bandwidth dcpep_cb_rt_bandwidth(' if baseline else 'static struct DCP_FW_NAME(dcp_rt_bandwidth) dcpep_cb_rt_bandwidth('
    # The following frame-sync response is versioned in the metadata patch.
    callback = section(source, name, '\nstatic struct ')
    parser = section((driver / 'dcp.c').read_text(),
                     'static int dcp_get_bw_scratch_reg(', '\nstatic int dcp_get_bw_doorbell_reg')
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('C compiler required')
    fixture = Path(__file__).parent / 'fixtures/dcp/bandwidth.c'
    completed = 0
    with tempfile.TemporaryDirectory(prefix='dcp-bandwidth-') as directory:
        directory = Path(directory)
        for major, minor in [(12, 3), (13, 3), (14, 7)]:
            controls = ['none']
            if not baseline and (major, minor) == (14, 7):
                controls += ['missing-width', 'wrong-status', 'short-bounds']
            for control in controls:
                candidate = declaration + parser + callback
                if control != 'none':
                    old, new = {
                        'missing-width': ('rt_bw.scratch_size = 8;', 'rt_bw.scratch_size = 0;'),
                        'wrong-status': ('rt_bw.scratch_size = 8;', 'rt_bw.scratch_size = 8;\n\trt_bw.ret = 1;'),
                        'short-bounds': ('? 8 : 4;', '? 4 : 4;'),
                    }[control]
                    if candidate.count(old) != 1:
                        raise ValueError(f'mutation site changed: {control}')
                    candidate = candidate.replace(old, new)
                (directory / 'callback.c').write_text(candidate)
                command = [compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                           '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                           f'-DDCP_FW_VER=(({major}<<16)|({minor}<<8))',
                           '-I', str(directory), str(fixture), '-o', str(directory / 'case')]
                if baseline:
                    command.append('-DBASELINE')
                result = subprocess.run(command, capture_output=True, text=True)
                if result.returncode:
                    raise AssertionError(result.stderr)
                result = subprocess.run([str(directory / 'case')], capture_output=True, text=True)
                if baseline or control != 'none':
                    if result.returncode == 0 or 'assertion' not in result.stderr.lower():
                        raise AssertionError(f'negative control did not reproduce: {result.stderr}')
                elif result.returncode or result.stderr:
                    raise AssertionError(result.stderr)
                completed += 1
    print(f'PASS: {completed} ASan/UBSan executables; {"baseline faults reproduced" if baseline else "3 profiles, 131 resource cases per profile, 3 rejected mutants"}')


if __name__ == '__main__':
    main()
