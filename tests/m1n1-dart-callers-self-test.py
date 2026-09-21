#!/usr/bin/env python3
"""Execute selected actual caller bodies with owned fakes: SOURCE. No target access."""
import ast
from collections import defaultdict, deque
from pathlib import Path
from types import SimpleNamespace as NS
import os
import subprocess
import sys
import tempfile


def section(text, start, end):
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError(f'ambiguous source section: {start}')
    return start + text.split(start, 1)[1].split(end, 1)[0]


def method_scope(path, names, namespace, class_name):
    tree = ast.parse(path.read_text())
    found = [node for cls in tree.body if isinstance(cls, ast.ClassDef) and cls.name == class_name
             for node in cls.body if isinstance(node, ast.FunctionDef) and node.name in names]
    assert sorted(n.name for n in found) == sorted(names)
    body = ast.Module(body=found, type_ignores=[])
    exec(compile(ast.fix_missing_locations(body), str(path), 'exec'), namespace)
    return namespace


def python_callers(source):
    proxy = method_scope(source / 'proxyclient/m1n1/proxy.py', ['dart_init'],
                         {'DART': NS(T8020=0)}, 'M1N1Proxy')
    calls = []
    target = NS(P_DART_INIT=3, request=lambda *args: calls.append(args) or 7)
    for kind in range(3):
        for keep in (False, True):
            assert proxy['dart_init'](target, 0x10000, 5, kind, keep) == 7
            assert calls[-1] == (3, 0x10000, 5, keep, kind)
    assert proxy['dart_init'](target, 0x10000, 5) == 7
    assert calls[-1] == (3, 0x10000, 5, False, 0)
    print('PASS: Python DART wire arguments (7 cases)')

    class SharedMemory:
        def add_item(self, *args): pass
        def finalize(self): return b'test'
    namespace = method_scope(source / 'proxyclient/m1n1/hw/sep.py',
        ['__init__', 'map_sepfw', 'unmap_sepfw', 'create_shmem'],
        {'ASCRegs': lambda *args: None, 'defaultdict': defaultdict, 'deque': deque,
         'SEPShMem': SharedMemory, 'align_up': lambda n, a: (n + a - 1) & -a}, 'SEP')
    allocations = []
    def allocate(alignment, size):
        assert alignment == 0x4000 and size == 0x30000
        allocations.append(0x200000); return allocations[-1]
    tree = {'/arm-io/sep': NS(get_reg=lambda n: (0x10000,)),
            '/arm-io/dart-sep': NS(get_reg=lambda n: (0x20000,)),
            '/chosen/memory-map': NS(SEPFW=(0x30000, 0x4000)),
            '/chosen/boot-object-manifests': NS(lpol=(1, 1), ibot=(2, 1))}
    utils = NS(adt=tree, heap=NS(memalign=allocate))
    iface = NS(readmem=lambda addr, size: b'x', writemem=lambda addr, data: None)
    def must_raise(call):
        try: call()
        except RuntimeError: return
        raise AssertionError('caller continued after failed DART result')
    for handle in (0, 7):
        target = NS(FW_IOVA=0xDEAD0000, SHMEM_IOVA=0xBEEF0000)
        p = NS(dart_init=lambda *args: handle)
        if not handle:
            must_raise(lambda: namespace['__init__'](target, p, iface, utils))
        else:
            namespace['__init__'](target, p, iface, utils)
            assert target.dart_handle == handle
    for result in (-3, -1, 0, 1):
        target.p.dart_map = lambda *args: result
        target.p.dart_unmap = lambda *args: result
        if result == 0: namespace['map_sepfw'](target)
        else: must_raise(lambda: namespace['map_sepfw'](target))
        if result == 1: namespace['unmap_sepfw'](target)
        else: must_raise(lambda: namespace['unmap_sepfw'](target))
        target.shmem = None; previous = len(allocations)
        if result == 0: namespace['create_shmem'](target)
        else: must_raise(lambda: namespace['create_shmem'](target))
        assert target.shmem == 0x200000 and len(allocations) == previous + 1
        must_raise(lambda: namespace['create_shmem'](target))
        assert len(allocations) == previous + 1
    print('PASS: Python SEP failed-result/retained-allocation guards (18 cases)')


def main():
    if len(sys.argv) != 2: raise SystemExit(__doc__)
    source = Path(sys.argv[1]).resolve(strict=True)
    python_callers(source)
    usb = (source / 'src/usb.c').read_text()
    kboot = (source / 'src/kboot.c').read_text()
    proxy = (source / 'src/proxy.c').read_text()
    with tempfile.TemporaryDirectory(prefix='dart-callers-') as directory:
        temporary = Path(directory)
        assert usb.count('void usb_iodev_init(void)') == 1
        (temporary / 'usb.inc').write_text('void usb_iodev_init(void)' +
                                          usb.split('void usb_iodev_init(void)', 1)[1])
        cleanup = section(kboot, 'err:\n    if (!dart_shutdown(dart_dcp))', '\nstatic int dt_carveout_reserved_regions(')
        (temporary / 'kboot.inc').write_text(cleanup.split('err:\n', 1)[1])
        branches = section(proxy, '        case P_DART_SHUTDOWN:', '\n        case P_HV_INIT:')
        (temporary / 'proxy.inc').write_text(branches)
        executable = temporary / 'callers'
        subprocess.run(['gcc', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-fno-builtin',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        '-I', str(temporary), str(Path(__file__).with_suffix('.c')), '-o', str(executable)], check=True)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1'))
        if result.returncode or result.stderr: raise AssertionError(result.stdout + result.stderr)
        print(result.stdout.strip())


if __name__ == '__main__':
    main()
