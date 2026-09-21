#!/usr/bin/env python3
"""Offline D411 register callback tests: CLIENT [decoded J514sap ADT].

Uses the real IPC codec/manager and metadata-only fakes. No target access.
"""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import struct
import sys
from types import SimpleNamespace as NS
import unittest


def offline_only(event, args):
    if event in {'socket.connect', 'subprocess.Popen', 'os.system'}:
        raise RuntimeError('offline register test forbids connections/execution')
    if event == 'open' and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith('/dev/') and path not in {'/dev/null', '/dev/urandom', '/dev/random'}:
            raise RuntimeError('offline register test forbids device access')


if len(sys.argv) not in (2, 3):
    raise SystemExit(__doc__)
client = Path(sys.argv[1]).resolve(strict=True)
adt_path = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) == 3 else None
sys.argv[1:] = []
sys.dont_write_bytecode = True
sys.path.insert(0, str(client))
os.environ.setdefault('AGX_FWVER', 'V14_7')
os.environ['AGX_GPU'] = 'G13'
sys.addaudithook(offline_only)
from m1n1.fw.dcp.ipc import ALL_METHODS, ByRef, Ver
from m1n1.fw.dcp.manager import DCPManager
from construct import StreamError

METHOD = ALL_METHODS['D411'][1]
TARGET = Ver.check('V == V14_7')
REGS = [(0x28c000000, 0x690000), (0x28c800000, 0x690000),
        (0x28d320000, 0x4000), (0x28d344000, 0x4000),
        (0x28e800000, 0x800000), (0x3503d0000, 0x4000)]


class Node(NS):
    def get_reg(self, index):
        return self.reg[index]


class Tree(dict):
    model = 'Mac15,6'
    compatible = ['J514sAP', 'Mac15,6', 'AppleARM']


def fixture():
    return Tree({'/arm-io/disp0': Node(compatible=['disp0,t6030'], reg=list(REGS))})


def manager(tree=None, chip='t6030'):
    return DCPManager(NS(asc=NS(u=NS(adt=tree if tree is not None else fixture()))), chip)


class RegisterMap(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    @unittest.skipUnless(TARGET, 'target V14.7 callback')
    def test_wire_and_repeated_callbacks(self):
        mgr = manager()
        self.assertEqual(METHOD.in_struct.sizeof(), 16)
        self.assertEqual(METHOD.out_struct.sizeof(), 28)
        for repeat in range(3):
            for index, (paddr, size) in enumerate(REGS):
                with self.subTest(repeat=repeat, index=index):
                    request = METHOD.in_struct.build(dict(obj='PROV', index=index, flags=0x100,
                        unk_u64_null=False, addr_null=False, length_null=False))
                    self.assertEqual(request, struct.pack('<III4B', 0x50524f56, index, 0x100, 0, 0, 0, 0))
                    reply = mgr.handle_cb(NS(tag='D411', in_data=request))
                    self.assertEqual(reply, struct.pack('<QQQI', paddr, paddr, size, 0))
                    self.assertEqual(mgr.in_callback, 0)

    def test_rejected_requests_do_not_publish(self):
        changes = [dict(obj='NOPE'), dict(index=-1), dict(index=6), dict(index=0xffffffff),
                   dict(index=True), dict(flags=0), dict(flags=0x80000100), dict(flags=0x101),
                   dict(unk_u64=None), dict(addr=None), dict(length=None)]
        for change in changes:
            with self.subTest(change=change):
                marker = object()
                refs = [ByRef(marker) for _ in range(3)]
                kwargs = dict(obj='PROV', index=0, flags=0x100, unk_u64=refs[0], addr=refs[1], length=refs[2])
                kwargs.update(change)
                with self.assertRaises(ValueError):
                    manager().sr_mapDeviceMemoryWithIndex(**kwargs)
                self.assertTrue(all(ref.val is marker for ref in refs))
        if not TARGET:
            with self.assertRaises(ValueError):
                manager().sr_mapDeviceMemoryWithIndex('PROV', 0, 0x100, ByRef(None), ByRef(None), ByRef(None))

    @unittest.skipUnless(TARGET, 'target V14.7 callback')
    def test_rejected_wire_restores_callback_depth(self):
        for depth in (0, 2):
            for request, error in ((struct.pack('<III4B', 0x50524f56, 0, 0x80000100, 0, 0, 0, 0), ValueError),
                                   (bytes(3), StreamError)):
                with self.subTest(depth=depth, request=request.hex()):
                    mgr = manager()
                    mgr.in_callback = depth
                    with self.assertRaises(error):
                        mgr.handle_cb(NS(tag='D411', in_data=request))
                    self.assertEqual(mgr.in_callback, depth)
                    reply = mgr.handle_cb(NS(tag='D411', in_data=struct.pack('<III4B', 0x50524f56, 0, 0x100, 0, 0, 0, 0)))
                    self.assertEqual(reply, struct.pack('<QQQI', REGS[0][0], REGS[0][0], REGS[0][1], 0))
                    self.assertEqual(mgr.in_callback, depth)

    @unittest.skipUnless(TARGET, 'target V14.7 callback')
    def test_invalid_adt(self):
        trees = []
        for key, value in [('model', 'Mac15,3'), ('compatible', ['J516sAP'])]:
            tree = fixture()
            setattr(tree, key, value)
            trees.append(tree)
        tree = fixture()
        tree['/arm-io/disp0'].compatible = ['disp0,t6020']
        trees.append(tree)
        for regs in [REGS[:5], REGS + [(0, 0)],
                     [(0, 0x4000)] + REGS[1:], [(-0x4000, 0x4000)] + REGS[1:],
                     [(REGS[0][0] + 1, 0x4000)] + REGS[1:], [(REGS[0][0], 0)] + REGS[1:],
                     [(REGS[0][0], 0x4001)] + REGS[1:], [((1 << 64) - 0x4000, 0x8000)] + REGS[1:]]:
            tree = fixture()
            tree['/arm-io/disp0'].reg = regs
            trees.append(tree)
        for index, tree in enumerate(trees):
            with self.subTest(variant=index):
                marker = object()
                refs = [ByRef(marker) for _ in range(3)]
                with self.assertRaises(ValueError):
                    manager(tree).sr_mapDeviceMemoryWithIndex('PROV', 0, 0x100, refs[1], refs[2], refs[0])
                self.assertTrue(all(ref.val is marker for ref in refs))
        self.assertEqual(len(trees), 11)

    def test_legacy_signature_and_new_abi_fail_closed(self):
        addr, length = ByRef(None), ByRef(None)
        mgr = manager(chip='t600x')
        self.assertEqual(mgr.sr_mapDeviceMemoryWithIndex('PROV', 1, 0x100, addr, length), 0)
        self.assertEqual((addr.val, length.val), REGS[1])
        with self.assertRaises(ValueError):
            mgr.sr_mapDeviceMemoryWithIndex('PROV', 1, 0x100, addr, length, ByRef(None))

    @unittest.skipUnless(TARGET and adt_path, 'optional pinned ADT not supplied')
    def test_exact_apple_provider(self):
        from m1n1.adt import load_adt
        raw = adt_path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
                         '4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478')
        mgr = manager(load_adt(raw))
        for index, (paddr, size) in enumerate(REGS):
            reply = mgr.handle_cb(NS(tag='D411', in_data=struct.pack('<III4B', 0x50524f56, index, 0x100, 0, 0, 0, 0)))
            self.assertEqual(reply, struct.pack('<QQQI', paddr, paddr, size, 0))

    def test_no_hardware_setup(self):
        self.assertNotIn('m1n1.setup', sys.modules)


if __name__ == '__main__':
    unittest.main(verbosity=2)
