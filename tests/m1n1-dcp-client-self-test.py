#!/usr/bin/env python3
"""Actual DCP endpoint client constructors/destructors: SOURCE [--baseline]."""
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
    clients = [
        ('src/dcp_iboot.c', 'dcp_iboot_if_t', 'dcp_ib', 'iboot_ep', 'iboot_service_ops',
         'struct txcmd {', '\nenum IBootCmd', '\nstatic int dcp_ib_cmd',
         'DCP_IBOOT_ENDPOINT', 'DCP_IBOOT_NUM_SERVICES', 0x23, 1),
        ('src/dcp/system_ep.c', 'dcp_system_if_t', 'dcp_system', 'system_ep', 'dcp_system_ops',
         'typedef struct dcp_system_if {', '\nstatic void system_service_init', None,
         'DCP_SYSTEM_ENDPOINT', 'DCP_SYSTEM_NUM_SERVICES', 0x20, 2),
        ('src/dcp/dpav_ep.c', 'dcp_dpav_if_t', 'dcp_dpav', 'dpav_ep', 'dcp_dpav_ops',
         'typedef struct dcp_dpav_if {', '\nstatic void dpav_init', None,
         'DCP_DPAV_ENDPOINT', 'DCP_DPAV_NUM_SERVICES', 0x24, 4),
        ('src/dcp/dptx_port_ep.c', 'dcp_dptx_if_t', 'dcp_dptx', 'dptx_ep', 'dcp_dptx_ops',
         'typedef struct dptx_port {', '\nstatic int afk_service_call', None,
         'DCP_DPTX_PORT_ENDPOINT', 'TEST_SERVICES', 0x2a, 2),
    ]
    with tempfile.TemporaryDirectory(prefix='dcp-client-') as temporary:
        temporary = Path(temporary)
        for file, type_, name, slot, ops, begin, end, stop, ep_define, count_define, ep, count in clients:
            text = (source / file).read_text()
            constructor = f'{type_} *{name}_init('
            functions = section(text, constructor, stop) if stop else constructor + text.split(constructor, 1)[1]
            complete = 'p->enabled = true' if slot == 'iboot_ep' else 'p->sys_service = (void *)1' if slot == 'system_ep' else '(void)p'
            definitions = (f'#define TXBUF_LEN 0x4000\n#define RXBUF_LEN 0x4000\n'
                           f'#define {ep_define} {ep}\n#define {count_define} {count}\n'
                           f'#define TYPE {type_}\n#define OWNER(p) ((p)->{slot})\n'
                           f'#define CREATE(p) {name}_init(p' + (', 2' if slot == 'dptx_ep' else '') + ')\n'
                           f'#define DESTROY {name}_shutdown\n#define COMPLETE(p) ({complete})\n'
                           f'#define EP {ep}\n#define COUNT {count}\n'
                           f'static const afk_epic_service_ops_t {ops}[] = {{ {{.name = "test"}}, {{}} }};\n')
            (temporary / 'client-types.inc').write_text(definitions + section(text, begin, end))
            (temporary / 'client-functions.inc').write_text(functions)
            executable = temporary / name
            command = ['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-fno-builtin',
                       '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                       '-I', str(temporary), '-I', str(source / 'src'),
                       str(Path(__file__).with_suffix('.c')), '-o', str(executable)]
            if baseline:
                command.insert(1, '-DBASELINE')
            subprocess.run(command, check=True)
            for case in (['shutdown-failure', 'partial-init'] if baseline else ['all']):
                result = subprocess.run([str(executable), case], capture_output=True, text=True,
                                        timeout=30, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
                if baseline:
                    if result.returncode == 0 or 'assertion' not in result.stderr.lower():
                        raise AssertionError(f'original {name}/{case} not reproduced: {result.stderr}')
                    print(f'PASS: original {name}/{case} failure reproduced')
                elif result.returncode or result.stderr:
                    raise AssertionError(f'{name}/{case}: {result.stdout}\n{result.stderr}')
                else:
                    print(name + ': ' + result.stdout.strip())


if __name__ == '__main__':
    main()
