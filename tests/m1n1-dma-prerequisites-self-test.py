#!/usr/bin/env python3
"""Offline ASC/T8110 regressions: CLIENT [decoded J514sap ADT].

Imports actual client code; all registers, physical memory and allocations are
owned fakes. This is not a model of DMA concurrency, cache coherency or teardown.
"""
import hashlib
import os
from pathlib import Path
import struct
import sys
from types import SimpleNamespace as NS
import unittest


def offline_only(event, args):
    if event in {'socket.connect', 'subprocess.Popen', 'os.system'}:
        raise RuntimeError('offline DMA test forbids connections/execution')
    if event == 'open' and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith('/dev/') and path not in {'/dev/null', '/dev/urandom', '/dev/random'}:
            raise RuntimeError('offline DMA test forbids device access')


if len(sys.argv) not in (2, 3):
    raise SystemExit(__doc__)
client = Path(sys.argv[1]).resolve(strict=True)
adt_path = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) == 3 else None
sys.argv[1:] = []
sys.dont_write_bytecode = True
sys.path.insert(0, str(client))
sys.addaudithook(offline_only)
from m1n1.fw.asc import StandardASC
from m1n1.fw.dcp.client import DCPClient
from m1n1.hw.dart8110 import DART8110, R_TCR, R_TTBR

PAGE = 0x4000
PA = 0x800000000
IOVA = 0x80000000


class Forbidden:
    def __getattr__(self, name):
        raise AssertionError(f'unexpected target operation: {name}')


class FakeDART:
    def __init__(self, fail=None):
        self.calls = []
        self.fail = fail

    def iomap(self, stream, addr, size):
        self.calls.append(('map', stream, addr, size))
        if self.fail == 'map':
            raise RuntimeError('injected mapping failure')
        return IOVA

    def invalidate_streams(self, mask):
        self.calls.append(('invalidate', mask))
        if self.fail == 'invalidate':
            raise RuntimeError('injected invalidation failure')


def asc(cls=StandardASC, dart=None, **kwargs):
    # Real constructors, with a backend that rejects every actual register I/O.
    def no_register_io(*args, **kwargs):
        raise AssertionError('unexpected register I/O')
    u = NS(proxy=Forbidden(), iface=Forbidden(), read=no_register_io, write=no_register_io)
    u.memalign = lambda align, size: PA
    return cls(u, 0, dart=dart, **kwargs)


class StreamSelection(unittest.TestCase):
    def test_standard_asc_invalidation_matches_mapping(self):
        for stream in (0, 5, 15, 31, 32, 255):
            with self.subTest(stream=stream):
                dart = FakeDART()
                obj = asc(dart=dart, stream=stream)
                obj.dva_offset = 1 << 40
                self.assertEqual(obj.iomap(PA, PAGE), (1 << 40) | IOVA)
                self.assertEqual(dart.calls, [('map', stream, PA, PAGE), ('invalidate', 1 << stream)])

    def test_dcp_constructor_preserves_default_and_display_dart(self):
        display = object()
        for kwargs, stream in (({}, 0), ({'stream': 5}, 5)):
            with self.subTest(stream=stream):
                dart = FakeDART()
                obj = asc(DCPClient, dart, disp_dart=display, **kwargs)
                self.assertIs(obj.disp_dart, display)
                self.assertEqual(obj.stream, stream)
                self.assertEqual(obj.ioalloc(PAGE), (PA, IOVA))
                self.assertEqual(dart.calls, [('map', stream, PA, PAGE), ('invalidate', 1 << stream)])

    def test_no_dart_preserves_physical_path(self):
        for cls in (StandardASC, DCPClient):
            obj = asc(cls)
            obj.dva_offset = 1 << 40
            self.assertEqual(obj.iomap(PA, PAGE), PA)
            self.assertEqual(obj.ioalloc(PAGE), (PA, PA))

    def test_failures_propagate_without_success(self):
        for stage in ('map', 'invalidate'):
            with self.subTest(stage=stage):
                dart = FakeDART(stage)
                obj = asc(dart=dart, stream=5)
                with self.assertRaisesRegex(RuntimeError, f'injected {"mapping" if stage == "map" else "invalidation"} failure'):
                    obj.iomap(PA, PAGE)
                expected = [('map', 5, PA, PAGE)]
                if stage == 'invalidate':
                    expected.append(('invalidate', 1 << 5))
                self.assertEqual(dart.calls, expected)

    @unittest.skipUnless(adt_path, 'optional exact Apple metadata')
    def test_exact_target_stream_metadata(self):
        from m1n1.adt import load_adt
        raw = adt_path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
                         '4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478')
        adt = load_adt(raw)
        mapper = adt['/arm-io/dart-dcp/mapper-dcp']
        self.assertEqual(adt.model, 'Mac15,6')
        self.assertEqual(adt['/arm-io/dcp'].getprop('iommu-parent'), mapper.getprop('AAPL,phandle'))
        self.assertEqual(mapper.reg, 5)
        self.assertEqual(adt['/arm-io/dart-dcp'].getprop('page-size'), PAGE)


class Reg:
    def __init__(self, kind, writes, name, value=0):
        self.kind, self.writes, self.name, self.value = kind, writes, name, value
        self.fail_write = False

    @property
    def val(self):
        return self.value

    @val.setter
    def val(self, value):
        if self.fail_write:
            raise RuntimeError('injected register-write failure')
        self.value = int(value)
        self.writes.append((self.name, self.value))

    @property
    def reg(self):
        return self.kind(self.value)  # register snapshots must not alias

    @reg.setter
    def reg(self, value):
        self.val = value


class Memory:
    def __init__(self):
        self.pages = {}
        self.writes = []
        self.allocations = []

    def memalign(self, align, size):
        if align != PAGE or size != PAGE:
            raise AssertionError('unexpected table allocation')
        addr = 0x100000000 + len(self.pages) * PAGE
        self.pages[addr] = bytes([0xa5]) * PAGE  # allocator is NOT zero-filled
        self.allocations.append(addr)
        return addr

    def readmem(self, addr, size):
        if size != PAGE or addr not in self.pages:
            raise AssertionError('read outside owned table memory')
        return self.pages[addr]

    def writemem(self, addr, data):
        if len(data) != PAGE or addr not in self.pages:
            raise AssertionError('write outside owned table memory')
        self.pages[addr] = bytes(data)
        self.writes.append(addr)

    def seed(self, entries):
        addr = self.memalign(PAGE, PAGE)
        table = [0] * 2048
        for index, value in entries.items():
            table[index] = value
        self.pages[addr] = struct.pack('<2048Q', *table)
        return addr


def dart_fixture(four=False, enabled=0, tcr=None):
    memory, writes = Memory(), []
    regs = NS(ENABLE_STREAMS=[Reg(int, writes, f'enable{i}', (enabled >> (i * 32)) & 0xffffffff) for i in range(8)],
              TCR=[Reg(R_TCR, writes, f'tcr{i}', (9 if four else 1) if tcr is None else tcr) for i in range(256)],
              TTBR=[Reg(R_TTBR, writes, f'ttbr{i}') for i in range(256)])
    obj = DART8110(memory, regs, memory)
    return obj, memory, writes


def retained(obj, memory, stream, iova, four):
    # Encode page tables independently of the implementation's PTE constructor.
    pte = lambda pa: ((pa >> 14) << 10) | 1
    leaf = memory.seed({7: (0xfff << 40) | pte(PA + 7 * PAGE)})
    middle = memory.seed({(iova >> 25) & 2047: pte(leaf)})
    root = memory.seed({(iova >> 36) & 2047: pte(middle)}) if four else middle
    obj.regs.TTBR[stream].value = ((root >> 14) << 2) | 1
    return leaf


def walk(memory, root, iova, four):
    # Inspect flushed bytes, not the client's cache or translator.
    for shift in ((36, 25, 14) if four else (25, 14)):
        word, = struct.unpack_from('<Q', memory.pages[root], ((iova >> shift) & 2047) * 8)
        if not word & 1:
            return None
        root = ((word >> 10) & ((1 << 28) - 1)) << 14
    return root + (iova & (PAGE - 1))


class PageTables(unittest.TestCase):
    def test_fresh_and_retained_tables_across_boundaries(self):
        for four in (False, True):
            addresses = [IOVA, (1 << 25) - PAGE, (1 << 36) - 2 * PAGE]
            if four:
                addresses += [(1 << 36) - PAGE, (1 << 40) + IOVA, (1 << 44) - 2 * PAGE]
            for existing in (False, True):
                for iova in addresses:
                    with self.subTest(four=four, retained=existing, iova=hex(iova)):
                        obj, memory, writes = dart_fixture(four, enabled=1 << 3)
                        leaf = retained(obj, memory, 5, iova, four) if existing else None
                        neighbor = memory.pages[leaf][56:64] if leaf else None
                        obj.iomap_at(5, iova, PA, PAGE + 23)
                        root = obj.regs.TTBR[5].reg.ADDR << 14
                        for offset in (0, 13, PAGE - 1, PAGE, PAGE + 22):
                            self.assertEqual(walk(memory, root, iova + offset, four), PA + offset)
                        self.assertEqual(obj.iotranslate(5, iova + 13, PAGE + 10), [(PA + 13, PAGE + 10)])
                        self.assertEqual(obj.enabled_streams, (1 << 3) | (1 << 5))
                        self.assertEqual([item for item in writes if item[0].startswith('enable')], [('enable0', 40)])
                        if leaf:
                            self.assertEqual(memory.pages[leaf][56:64], neighbor)
                        obj.invalidate_cache()
                        self.assertEqual(obj.iotranslate(5, iova, PAGE + 23), [(PA, PAGE + 23)])

    def test_repeat_mapping_does_not_allocate_or_reenable(self):
        for four in (False, True):
            obj, memory, writes = dart_fixture(four)
            obj.iomap_at(5, IOVA, PA, PAGE)
            allocation_count, write_count = len(memory.allocations), len(writes)
            obj.iomap_at(5, IOVA + PAGE, PA + PAGE, PAGE)
            self.assertEqual(len(memory.allocations), allocation_count)
            self.assertEqual(len(writes), write_count)
            self.assertEqual(obj.iotranslate(5, IOVA, 2 * PAGE), [(PA, 2 * PAGE)])

    def test_invalid_modes_and_alignment_do_not_write(self):
        for tcr, iova, addr in [(0, IOVA, PA), (2, IOVA, PA), (3, IOVA, PA),
                                (1, IOVA + 1, PA), (1, IOVA, PA + 1)]:
            with self.subTest(tcr=tcr, iova=iova, addr=addr):
                obj, memory, writes = dart_fixture(tcr=tcr)
                with self.assertRaises(Exception):
                    obj.iomap_at(5, iova, addr, PAGE)
                self.assertEqual(writes, [])
                self.assertEqual(memory.pages, {})
                self.assertEqual(obj.enabled_streams, 0)

    def test_invalid_ranges_do_not_write(self):
        for four in (False, True):
            limit = 1 << (44 if four else 36)
            cases = [(-1, IOVA, PA, PAGE), (256, IOVA, PA, PAGE),
                     (5.0, IOVA, PA, PAGE), (5, float(IOVA), PA, PAGE),
                     (5, IOVA, float(PA), PAGE), (5, IOVA, PA, 1.5),
                     (5, -PAGE, PA, PAGE), (5, IOVA, -PAGE, PAGE),
                     (5, IOVA, PA, -1), (5, limit, PA, PAGE),
                     (5, limit - PAGE, PA, PAGE + 1),
                     (5, IOVA, 1 << 42, PAGE), (5, IOVA, (1 << 42) - PAGE, PAGE + 1)]
            for args in cases:
                with self.subTest(four=four, args=args):
                    obj, memory, writes = dart_fixture(four)
                    with self.assertRaises((ValueError, TypeError)):
                        obj.iomap_at(*args)
                    self.assertEqual(writes, [])
                    self.assertEqual(memory.pages, {})
                    self.assertEqual(obj.enabled_streams, 0)

    def test_failed_enable_does_not_cache_success(self):
        obj, memory, writes = dart_fixture(enabled=1 << 3)
        obj.regs.ENABLE_STREAMS[0].fail_write = True
        with self.assertRaisesRegex(RuntimeError, 'injected register-write failure'):
            obj.iomap_at(5, IOVA, PA, PAGE)
        self.assertEqual(obj.enabled_streams, 1 << 3)
        self.assertEqual(writes, [])
        self.assertEqual(memory.pages, {})

    def test_zero_length_remains_noop(self):
        obj, memory, writes = dart_fixture()
        obj.iomap_at(5, IOVA, PA, 0)
        self.assertEqual(writes, [])
        self.assertEqual(memory.pages, {})
        self.assertEqual(obj.iotranslate(5, IOVA, 0), [])

    def test_physical_zero_is_not_an_unmapped_page(self):
        for four in (False, True):
            obj, memory, writes = dart_fixture(four)
            obj.iomap_at(5, IOVA, 0, PAGE)
            obj.invalidate_cache()
            self.assertEqual(obj.iotranslate(5, IOVA + 17, 19), [(17, 19)])
            self.assertEqual(obj.iotranslate(5, IOVA + PAGE + 17, 19), [(None, 19)])


if __name__ == '__main__':
    unittest.main(verbosity=2)
