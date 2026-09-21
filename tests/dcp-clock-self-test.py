#!/usr/bin/env python3
"""Actual Linux clock ownership/callback code with fake kernel services.

Usage: APPLE_DRIVER [--baseline | PIXEL_HZ VIDEO_HZ]
No kernel/device execution. Compiles bounded C fixtures under ASan/UBSan.
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
    if len(sys.argv) not in (2, 3, 4) or (len(sys.argv) == 3 and sys.argv[2] != '--baseline'):
        raise SystemExit(__doc__)
    driver = Path(sys.argv[1]).resolve(strict=True)
    baseline = len(sys.argv) == 3
    rates = [int(value) for value in sys.argv[2:]] if len(sys.argv) == 4 else [712000000, 0]
    if any(not 0 <= value <= 0xffffffff for value in rates):
        raise ValueError('fixed-clock rates must fit uint32')
    source = (driver / 'iomfb_template.c').read_text()
    marker = 'static u64 dcpep_cb_get_frequency('
    if baseline:
        handler = section(source, marker, '\nstatic struct DCP_FW_NAME(dcp_map_reg_resp)')
        trampoline = 'TRAMPOLINE_OUT(trampoline_get_frequency, dcpep_cb_get_frequency, u64);\n'
    else:
        handler = section(source, '#if DCP_FW_VER == DCP_FW_VERSION(14, 7, 0)\n' + marker,
                          '\nstatic struct DCP_FW_NAME(dcp_map_reg_resp)')
        trampoline = section(source, '#if DCP_FW_VER == DCP_FW_VERSION(14, 7, 0)\nTRAMPOLINE_INOUT(trampoline_get_frequency',
                             '\nTRAMPOLINE_OUT(trampoline_get_time')
    header = (driver / 'iomfb.h').read_text()
    packet = section(header, 'struct dcp_packet_header {', '\n#define DCP_IS_NULL')
    request = '' if baseline else section(header, 'struct dcp_get_frequency_req {', '\nstruct dcp_get_uint_prop_req')
    internal = (driver / 'iomfb_internal.h').read_text()
    macros = section(internal, '#define TRAMPOLINE_INOUT(', '\n/* Call a DCP function')
    transport = (driver / 'iomfb.c').read_text()
    parser = section(transport, 'int dcp_parse_tag(', '\n/* Ack a callback')
    dispatcher = section(transport, 'static void dcpep_handle_cb(', '\nstatic void dcpep_handle_ack')
    if 'static u16 dcp_packet_end(' in transport:
        dispatcher = section(transport, 'static u16 dcp_packet_end(', '\n/* Call a DCP function') + dispatcher
    owner = ''
    if not baseline:
        dcp = (driver / 'dcp.c').read_text()
        owner = section(dcp, 'static int dcp_get_display_clocks(', '\nstatic int dcp_comp_bind')
        bind = section(dcp, 'static int dcp_comp_bind(', '\n/*\n * We need to shutdown')
        acquire = section(bind, '\tif (!dcp->video_clk) {', '\n\tbitmap_zero')
        unbind = section(dcp, 'static void dcp_comp_unbind(', '\nstatic const struct component_ops')
        release = '\tif (!dcp->video_clk)' + unbind.split('\tif (!dcp->video_clk)', 1)[1].rsplit('\n}', 1)[0]
        owner += '\nstatic int clock_bind(struct apple_dcp *dcp) {\nstruct device *dev=dcp->dev;\n' + acquire + '\nreturn 0;\n}\n'
        owner += '\nstatic void clock_unbind(struct apple_dcp *dcp) {\nstruct device *dev=dcp->dev;\n' + release + '\n}\n'
        probe = section(dcp, 'static int dcp_platform_probe(', '\nstatic void dcp_platform_remove')
        if not probe.index('dcp_get_display_clocks(dcp)') < probe.index('devm_phy_optional_get') < probe.index('component_add'):
            raise ValueError('clock acquisition moved after hardware/component setup')
        if 'if (ret)\n\t\treturn ret;' not in probe.split('dcp_get_display_clocks(dcp);', 1)[1].split('platform_set_drvdata', 1)[0]:
            raise ValueError('clock failure does not stop probe')
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise RuntimeError('existing compiler required')
    fixture = Path(__file__).parent / 'fixtures/dcp/clocks.c'
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1'))
    with tempfile.TemporaryDirectory(prefix='dcp-clocks-') as temporary:
        temporary = Path(temporary)
        (temporary / 'code.inc').write_text('\n'.join([packet, request, owner, handler, macros, trampoline, parser, dispatcher]))
        profiles = [(14, 7)] if baseline else [(12, 3), (13, 3), (14, 7)]
        for major, minor in profiles:
            executable = temporary / f'clocks-{major}-{minor}'
            command = [compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                       '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                       f'-DDCP_FW_VER=(({major}<<16)|({minor}<<8))', '-I', str(temporary),
                       str(fixture), '-o', str(executable)]
            command += [f'-DCLOCK_FIXTURE_PIXEL={rates[0]}ULL', f'-DCLOCK_FIXTURE_VIDEO={rates[1]}ULL']
            if baseline:
                command += ['-DBASELINE']
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(result.stderr)
            for mode in (['index', 'alignment'] if baseline else ['all']):
                result = subprocess.run([str(executable), mode], capture_output=True, text=True, env=env)
                if baseline:
                    diagnostic = 'assertion' if mode == 'index' else 'misaligned'
                    if result.returncode == 0 or diagnostic not in result.stderr.lower():
                        raise AssertionError(f'baseline {mode} not reproduced: {result.stderr}')
                    print(f'PASS: original {mode} fault reproduced')
                elif result.returncode or result.stderr:
                    raise AssertionError(result.stderr)
                else:
                    print(f'{major}.{minor}: {result.stdout.strip()}')


if __name__ == '__main__':
    main()
