#!/usr/bin/env python3
"""Offline D408 tests: CLIENT [DECODED_ADT [CLOCK_METADATA_JSON]].

Runs the real manager and wire codec. No target access or hardware setup.
"""
import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import sys
from types import SimpleNamespace as NS
import unittest


def offline_only(event, args):
    if event in {'socket.connect', 'subprocess.Popen', 'os.system'}:
        raise RuntimeError('offline clock test forbids connections/execution')
    if event == 'open' and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith('/dev/') and path not in {'/dev/null', '/dev/urandom', '/dev/random'}:
            raise RuntimeError('offline clock test forbids device access')


if len(sys.argv) not in (2, 3, 4):
    raise SystemExit(__doc__)
paths = [Path(p).resolve(strict=True) for p in sys.argv[1:]]
client = paths[0]
adt_path = paths[1] if len(paths) > 1 else None
metadata_path = paths[2] if len(paths) > 2 else None
sys.argv[1:] = []
sys.dont_write_bytecode = True
sys.path.insert(0, str(client))
os.environ.setdefault('AGX_FWVER', 'V14_7')
os.environ['AGX_GPU'] = 'G13'
sys.addaudithook(offline_only)
from m1n1.fw.dcp.ipc import ALL_METHODS, Ver
from m1n1.fw.dcp.manager import DCPManager
from construct import StreamError

METHOD = ALL_METHODS['D408'][1]
TARGET = Ver.check('V == V14_7')


class Node(NS):
    def getprop(self, name):
        return self.props.get(name)


class Tree(dict):
    model = 'Mac15,6'
    compatible = ['J514sAP', 'Mac15,6', 'AppleARM']


def fixture(count=176):
    # Distinct neighbors detect wrong ID base, wrong element size and arg reuse.
    return Tree({
        '/arm-io': Node(compatible=['arm-io,t6030'], props={
            'clock-frequencies': [100_000_000 + i * 1_000_000 for i in range(count)],
            'clock-frequencies-nclk': [i % 4 for i in range(count)],
        }),
        '/arm-io/disp0': Node(compatible=['disp0,t6030'], props={'clock-ids': [348, 412]}),
    })


def manager(tree=None, chip='t6030'):
    # No transport, memory proxy, register backend or DART is provided.
    return DCPManager(NS(asc=NS(u=NS(adt=tree if tree is not None else fixture()))), chip)


class ClockContract(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    @unittest.skipUnless(TARGET, 'target V14.7 callback')
    def test_wire_layout_index_and_dynamic_values(self):
        self.assertEqual((METHOD.in_struct.sizeof(), METHOD.out_struct.sizeof()), (8, 8))
        tree = fixture()
        mgr = manager(tree)
        for pair in [(192_000_000, 256_000_000), (712_000_000, 0), (0, 0xffffffff)]:
            frequencies = tree['/arm-io'].props['clock-frequencies']
            frequencies[92], frequencies[156] = pair
            saved = copy.deepcopy(tree)
            for index, expected in enumerate(pair):
                request = METHOD.in_struct.build(dict(obj='PROV', arg=index))
                self.assertEqual(request, struct.pack('<II', 0x50524f56, index))
                self.assertEqual(mgr.handle_cb(NS(tag='D408', in_data=request)), struct.pack('<Q', expected))
                self.assertEqual(mgr.in_callback, 0)
                self.assertEqual(tree, saved)

    @unittest.skipUnless(TARGET, 'target V14.7 callback')
    def test_declared_clock_outside_published_table_returns_zero(self):
        for count in [1, 92, 93, 156, 157, 176]:
            tree = fixture(count)
            for arg, slot in enumerate([92, 156]):
                with self.subTest(count=count, arg=arg):
                    expected = 100_000_000 + slot * 1_000_000 if slot < count else 0
                    self.assertEqual(manager(tree).sr_getClockFrequency('PROV', arg), expected)

    def test_unsupported_requests_and_firmware(self):
        for obj, arg in [('NOPE', 0), ('PROV', -1), ('PROV', 2), ('PROV', 0xffffffff),
                         ('PROV', True), ('PROV', 0.0), ('PROV', None), ('PROV', '0')]:
            with self.subTest(obj=obj, arg=arg), self.assertRaises(ValueError):
                manager().sr_getClockFrequency(obj, arg)
        if not TARGET:
            with self.assertRaises(ValueError):
                manager().sr_getClockFrequency('PROV', 0)

    @unittest.skipUnless(TARGET, 'target V14.7 callback')
    def test_malformed_metadata(self):
        variants = []
        for key, value in [('model', 'Mac15,3'), ('compatible', ['J516sAP'])]:
            tree = fixture(); setattr(tree, key, value); variants.append(tree)
        for path in ['/arm-io', '/arm-io/disp0']:
            tree = fixture(); del tree[path]; variants.append(tree)
            tree = fixture(); tree[path].compatible = ['wrong']; variants.append(tree)
        for ids in [None, [], [348], [348, 412, 413], [347, 412], [348, 413], [348.0, 412], '348,412']:
            tree = fixture(); tree['/arm-io/disp0'].props['clock-ids'] = ids; variants.append(tree)
        for name in ['clock-frequencies', 'clock-frequencies-nclk']:
            for value in [None, [], b'\0' * 176, 'bad', [0] * 175]:
                tree = fixture(); tree['/arm-io'].props[name] = value; variants.append(tree)
            for value in [-1, True, 1.0, '1', None, 0x100000000 if name == 'clock-frequencies' else 4]:
                tree = fixture(); tree['/arm-io'].props[name][0] = value; variants.append(tree)
        for n, tree in enumerate(variants):
            with self.subTest(variant=n), self.assertRaises(ValueError):
                manager(tree).sr_getClockFrequency('PROV', 0)
        self.assertEqual(len(variants), 36)

    @unittest.skipUnless(TARGET, 'target V14.7 callback')
    def test_error_depth_and_recovery(self):
        mgr = manager()
        for depth in [0, 2]:
            mgr.in_callback = depth
            for request, error in [(struct.pack('<II', 0x50524f56, 2), ValueError), (bytes(3), StreamError)]:
                with self.assertRaises(error):
                    mgr.handle_cb(NS(tag='D408', in_data=request))
                self.assertEqual(mgr.in_callback, depth)
                self.assertEqual(mgr.handle_cb(NS(tag='D408', in_data=struct.pack('<II', 0x50524f56, 0))),
                                 struct.pack('<Q', 192_000_000))
                self.assertEqual(mgr.in_callback, depth)

    def test_legacy_reply_unchanged(self):
        for chip in ['t8103', 't600x', 't8112', 't6020']:
            mgr = manager(chip=chip)
            for index in [0, 1, 7]:
                self.assertEqual(mgr.handle_cb(NS(tag='D408', in_data=struct.pack('<II', 0x50524f56, index))),
                                 struct.pack('<Q', 533333328))

    @unittest.skipUnless(TARGET and adt_path, 'optional exact ADT not supplied')
    def test_exact_template_fails_without_runtime_type_table(self):
        from m1n1.adt import load_adt
        raw = adt_path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), '4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478')
        with self.assertRaises(ValueError):
            manager(load_adt(raw)).sr_getClockFrequency('PROV', 0)

    @unittest.skipUnless(TARGET and metadata_path, 'optional recorded runtime metadata not supplied')
    def test_recorded_runtime_tables_with_real_adt_parser(self):
        from m1n1.adt import load_adt, parse_prop
        raw = metadata_path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), '56e99ffdc6a5d7c448f1d340e055095953a5b7730042988b7cae1800bbbb3efa')
        snapshot = json.loads(raw)
        self.assertEqual(snapshot['macos_build'], '25G227')
        self.assertFalse(snapshot['for_future_boot_constants'])
        tree = load_adt(adt_path.read_bytes())
        # Unit-test overlay only: 25G227 cached tables are not a 23J220 boot.
        for node_name in ['arm-io', 'disp0']:
            node = tree['/arm-io' + ('/disp0' if node_name == 'disp0' else '')]
            for key, value in snapshot['properties_hex'][node_name].items():
                _, parsed = parse_prop(node, node._path, node.name, key, bytes.fromhex(value), False)
                node._properties[key] = parsed
        mgr = manager(tree)
        self.assertEqual([mgr.sr_getClockFrequency('PROV', i) for i in [0, 1]], [712_000_000, 0])

    def test_no_hardware_setup(self):
        self.assertNotIn('m1n1.setup', sys.modules)


if __name__ == '__main__':
    unittest.main(verbosity=2)
