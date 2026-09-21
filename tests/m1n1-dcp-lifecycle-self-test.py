#!/usr/bin/env python3
"""Actual DCP/RTKit owner and endpoint-client lifecycle functions: SOURCE [--baseline]."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


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
    header = (source / 'src/dcp.h').read_text()
    display = (source / 'src/display.c').read_text()
    rtkit = (source / 'src/rtkit.c').read_text()
    main_source = (source / 'src/main.c').read_text()
    with tempfile.TemporaryDirectory(prefix='dcp-lifecycle-') as temporary:
        temporary = Path(temporary)
        (temporary / 'types.inc').write_text(section(header, 'typedef struct {', '\nint dcp_connect_dptx('))
        (temporary / 'lifecycle.inc').write_text(
            section(dcp, 'static char dcp_pmgr_dev', '\nstatic int dcp_hdmi_dptx_init(') +
            'dcp_dev_t *dcp_init(' + dcp.split('dcp_dev_t *dcp_init(', 1)[1])
        (temporary / 'display.inc').write_text(section(display, 'int display_start_dcp(void)', '\nstruct display_options') +
            section(display, ('void' if baseline else 'int') + ' display_shutdown(', '\n}') + '\n}\n')
        free_start = ('void' if baseline else 'bool') + ' rtkit_free('
        (temporary / 'rtkit-free.inc').write_text(section(rtkit, free_start, '\nbool rtkit_send('))
        if not baseline:
            start = ('    while (dart_has_faults()' if 'dart_has_faults()' in main_source else
                     '    while (display_shutdown(DCP_SLEEP_IF_EXTERNAL)')
            guard = section(main_source, start, '\n#endif')
            if '!nvme_shutdown()' not in guard:
                assert main_source.index(guard) < main_source.index('    nvme_shutdown();')
            assert main_source.index(guard) < main_source.index('    exception_shutdown();')
            (temporary / 'handoff.inc').write_text(guard)
            hv = (source / 'src/hv.c').read_text()
            init = section(hv, 'int hv_init(void)', '\nstatic void hv_set_gxf_vbar(')
            assert init.index('hv_initialized = false;') < init.index('display_shutdown(') < init.index('pcie_shutdown();')
            if '!nvme_shutdown()' in guard:
                assert init.index('display_shutdown(') < init.index('!nvme_shutdown()') < init.index('pcie_shutdown();')
            assert init.index('hv_initialized = true;') > init.index('sysop("isb");')
            for name in ['void hv_start(void *entry, u64 regs[4])', 'void hv_start_secondary(int cpu, void *entry, u64 regs[4])']:
                assert hv.split(name + '\n{', 1)[1].lstrip().startswith('if (!hv_initialized)')
            proxy = (source / 'src/proxy.c').read_text()
            for case, call in [('P_HV_INIT', 'hv_init()'), ('P_DISPLAY_SHUTDOWN', 'display_shutdown(request->args[0])'),
                               ('P_DISPLAY_START_DCP', 'display_start_dcp()')]:
                assert f'case {case}:\n            reply->retval = {call};' in proxy
            if '!nvme_shutdown()' in guard:
                assert 'case P_NVME_SHUTDOWN:\n            reply->retval = nvme_shutdown();' in proxy
        for mode in ['owners', 'display', 'rtkit-free'] + ([] if baseline else ['handoff']):
            executable = temporary / mode
            command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-fno-builtin',
                       '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                       '-I', str(temporary), f'-DTEST_{mode.upper().replace("-", "_")}',
                       str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
            if baseline:
                command.insert(1, '-DBASELINE')
            if 'smc_shutdown(NULL)' in dcp:
                command.insert(1, '-DSTORAGE_LIFECYCLE')
            if 'bool dart_unmap(' in (source / 'src/dart.h').read_text():
                command.insert(1, '-DDART_LIFECYCLE')
            subprocess.run(command, check=True)
            modes = {'owners': ['child', 'afk', 'power', 'free'],
                     'display': ['display-failure'], 'rtkit-free': ['buffer-free']}[mode] if baseline else ['all']
            for case in modes:
                result = subprocess.run([str(executable), case], capture_output=True, text=True,
                                        timeout=30, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
                if baseline:
                    if result.returncode == 0 or not any(marker in result.stderr.lower() for marker in
                            ['assertion', 'runtime error:', 'addresssanitizer', 'leaksanitizer']):
                        raise AssertionError(f'original {case} not reproduced: {result.stderr}')
                    print(f'PASS: original {case} ownership failure reproduced')
                elif result.returncode or result.stderr:
                    raise AssertionError(f'{case}: {result.stdout}\n{result.stderr}')
                else:
                    print(result.stdout.strip())


if __name__ == '__main__':
    main()
