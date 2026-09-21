#!/usr/bin/env python3
"""Compile/run the real D411 callback offline: PREPARED_APPLE_DRIVER_DIRECTORY.

Fake DMA API on owned state only. Does not execute a kernel or firmware.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def between(source, start, end):
    if source.count(start) != 1:
        raise ValueError(f'ambiguous source marker: {start}')
    return source.split(start, 1)[1].split(end, 1)[0]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    driver = Path(sys.argv[1])
    header = (driver / 'iomfb_template.h').read_text()
    source = (driver / 'iomfb_template.c').read_text()
    structs = ''
    for name in ('dcp_map_reg_req', 'dcp_map_reg_resp'):
        start = f'struct DCP_FW_NAME({name}) {{'
        structs += start + between(header, start, '} __packed;') + '} __packed;\n'
    start = 'static struct DCP_FW_NAME(dcp_map_reg_resp) dcpep_cb_map_reg('
    body = start + between(source, start, '\nstatic struct dcp_read_edt_data_resp')
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('C compiler required')
    fixture = Path(__file__).parent / 'fixtures/dcp/map-registers.c'
    cases = 0
    with tempfile.TemporaryDirectory(prefix='dcp-registers-') as tmp:
        tmp = Path(tmp)
        for version in ((12, 3, 0), (13, 3, 0), (14, 7, 0)):
            controls = ['none']
            if version == (14, 7, 0):
                controls += ['success-on-failure', 'always-dma', 'always-physical']
            for control in controls:
                candidate = body
                if control != 'none':
                    old, new = {
                        'success-on-failure': ('if (dma_mapping_error(dcp->dev, dva))',
                                              'if (dma_mapping_error(dcp->dev, dva) && 0)'),
                        'always-dma': ('if (!(req->flags & BIT(31)))', 'if (0)'),
                        'always-physical': ('if (!(req->flags & BIT(31)))', 'if (1)'),
                    }[control]
                    if candidate.count(old) != 1:
                        raise ValueError(f'mutation site changed: {control}')
                    candidate = candidate.replace(old, new)
                (tmp / 'callback.c').write_text(structs + candidate)
                subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                    f'-DDCP_FW_VER=(({version[0]}<<16)|({version[1]}<<8)|{version[2]})',
                    '-I', str(tmp), str(fixture), '-o', str(tmp / 'case')],
                    check=True, capture_output=True)
                result = subprocess.run([str(tmp / 'case')], capture_output=True)
                if control == 'none':
                    if result.returncode or result.stderr:
                        raise AssertionError((version, result.returncode, result.stderr.decode()))
                elif (result.returncode == 0 or b'assertion' not in result.stderr.lower() or
                      b'failed' not in result.stderr.lower()):
                    raise AssertionError((version, control, result.returncode, result.stderr.decode()))
                cases += 1
    print(f'PASS: {cases} ASan/UBSan executables; 3 firmware profiles and 3 rejected mutants')


if __name__ == '__main__':
    main()
