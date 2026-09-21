#!/usr/bin/env python3
"""Offline D003 contract: CLIENT [decoded J514sap ADT]. Never contacts a target.

Defaults to V14_7; also run with AGX_FWVER=V12_3 and V13_5 for legacy checks.
V14_8 adds a test-only future version label; it is not a supported firmware.
The optional Apple ADT must match the recorded 23J220 input digest.
"""
import contextlib
import copy
import hashlib
import io
import os
from pathlib import Path
import struct
import sys
from types import SimpleNamespace as NS
import unittest


def offline_only(event, args):
    if event in {"socket.connect", "subprocess.Popen", "os.system"}:
        raise RuntimeError("offline bandwidth test forbids connections/execution")
    if event == "open" and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith("/dev/") and path not in {"/dev/null", "/dev/urandom", "/dev/random"}:
            raise RuntimeError("offline bandwidth test forbids device access")


if len(sys.argv) not in (2, 3):
    raise SystemExit(__doc__)
client = Path(sys.argv[1]).resolve(strict=True)
adt_path = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) == 3 else None
sys.argv[1:] = []
sys.dont_write_bytecode = True
sys.path.insert(0, str(client))
os.environ.setdefault("AGX_FWVER", "V14_7")
os.environ["AGX_GPU"] = "G13"
sys.addaudithook(offline_only)
from m1n1.constructutils import Ver
if os.environ['AGX_FWVER'] == 'V14_8':
    Ver.MATRIX['V'] = [*Ver.MATRIX['V'], 'V14_8']
from m1n1.fw.dcp.ipc import ByRef, UPPipeAP_H13P, Ver, rt_bw_config_t
from m1n1.fw.dcp.manager import DCPManager

METHOD = UPPipeAP_H13P.D003
TARGET = Ver.check("V == V14_7")


class Node(NS):
    def getprop(self, name, default=None):
        return self.__dict__.get(name, default)

    def get_reg(self, index):
        return self.reg[index]


class Tree(dict):
    model = "Mac15,6"
    compatible = ["J514sAP", "Mac15,6", "AppleARM"]


def fixture(base=0x3503c0000):
    def record(device, bandwidth):
        return struct.pack('<31I', device, *([0] * 11), bandwidth, *([0] * 18))

    return Tree({
        '/arm-io/disp0': Node(**{
            'compatible': ['disp0,t6030'],
            'reg': [(0, 0)] * 5 + [(base + 0x10000, 0x4000)],
            'function-bw_req_interrupt0': NS(phandle=167, name='BIRQ', args=[39]),
        }),
        '/arm-io/pmgr': Node(**{
            'compatible': ['pmgr1,t6030'], 'AAPL,phandle': 167, 'pmp': 2,
            'devices': [NS(id1=8, id2=39, name='DISP_SYS')],
            'reg': [(0, 0)] * 40 + [(base, 0x24000)],
            'ptd-ranges': struct.pack('<6I', 10, 11, 12, 13, 2, 4),
        }),
        '/arm-io/pmp/iop-pmp-nub': Node(**{
            'ptd-range': struct.pack('<8I', 13, 304, 8, 0, 0, 0, 0, 0),
            'soc-device': record(1, 0) + record(7, 3) + record(8, 3),
        }),
    })


def manager(tree, compatible='t6030'):
    # No proxy, transport or MMIO methods exist on these fake objects.
    return DCPManager(NS(asc=NS(u=NS(adt=tree))), compatible=compatible)


class Bandwidth(unittest.TestCase):
    def setUp(self):
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.quiet.__enter__()
        self.addCleanup(self.quiet.__exit__, None, None, None)

    def test_wire_schema(self):
        self.assertEqual(METHOD.in_struct.sizeof(), 4)
        self.assertEqual(METHOD.out_struct.sizeof(), 60)
        self.assertEqual(rt_bw_config_t.sizeof(), 56 if TARGET else 60)
        if TARGET:
            def respond(config):
                config.val = dict(reg1=0x1122334455667788, reg2=0, bit=0, scratch_size=8)
                return 17
            data = METHOD.callback(respond, bytes(4))
            self.assertEqual(struct.unpack_from('<I', data, 56)[0], 17)
            parsed = METHOD.parse_output(data, {'config_null': False})
            self.assertEqual(parsed.ret, 17)
            self.assertEqual(parsed.config.scratch_size, 8)
        else:
            self.assertIsNone(METHOD.rtype)

    @unittest.skipUnless(TARGET, 'T6030 contract is pinned to V14.7')
    def test_actual_callback_wire(self):
        mgr = manager(fixture())
        data = mgr.handle_cb(NS(tag='D003', in_data=bytes(4)))
        expected = bytearray(60)
        struct.pack_into('<Q', expected, 8, 0x3503d0988)
        struct.pack_into('<I', expected, 44, 8)
        self.assertEqual(data, bytes(expected))
        self.assertEqual(mgr.in_callback, 0)

    @unittest.skipUnless(TARGET, 'T6030 contract is pinned to V14.7')
    def test_address_comes_from_adt(self):
        for base in (0x2503c0000, 0x4503c0000, 0x10000000000):
            with self.subTest(base=hex(base)):
                out = ByRef(None)
                self.assertEqual(manager(fixture(base)).rt_bandwidth_setup_ap(out), 0)
                self.assertEqual(out.val['reg1'], base + 0x10988)

    @unittest.skipUnless(TARGET, 'T6030 contract is pinned to V14.7')
    def test_malformed_contracts_fail_before_output(self):
        original = fixture()
        changes = []
        def add(path, key, value):
            tree = copy.deepcopy(original)
            setattr(tree[path], key, value)
            changes.append((path + ':' + key + ':' + str(len(changes)), tree))
        disp, pmgr, pmp = '/arm-io/disp0', '/arm-io/pmgr', '/arm-io/pmp/iop-pmp-nub'
        for path, key, vals in (
            (disp, 'compatible', [[], ['disp0,t8122']]),
            (pmgr, 'compatible', [[], ['pmgr1,t6020']]),
            (pmgr, 'pmp', [None, 0, 1, 3]),
            (pmgr, 'pmc', [1, 2]),
            (disp, 'function-bw_req_interrupt0', [None, NS(phandle=1, name='BIRQ', args=[39]),
                NS(phandle=167, name='CIRQ', args=[39]), NS(phandle=167, name='BIRQ', args=[40])]),
            (pmgr, 'devices', [[], [NS(id1=9, id2=39, name='DISP_SYS')],
                [NS(id1=8, id2=39, name='OTHER')], original[pmgr].devices * 2]),
            (pmgr, 'ptd-ranges', [None, b'', bytes(23), bytes(25), bytes(24)]),
            (pmp, 'ptd-range', [None, b'', bytes(31), bytes(33),
                original[pmp].getprop('ptd-range') * 2,
                struct.pack('<8I', 13, 305, 8, 0, 0, 0, 0, 0),
                struct.pack('<8I', 13, 304, 1, 0, 0, 0, 0, 0)]),
            (pmp, 'soc-device', [None, b'', bytes(123), bytes(125),
                original[pmp].getprop('soc-device') * 2, bytes(124)]),
            (disp, 'reg', [original[disp].reg[:5], original[disp].reg + [(0, 0)],
                [(0, 0)] * 5 + [(0x3503d0000, 0x98f)],
                [(0, 0)] * 5 + [(0x3503d0008, 0x4000)],
                [(0, 0)] * 5 + [(0x3503d0000, 0x20000)]]),
            (pmgr, 'reg', [[(0, 0)] * 41, [(0, 0)] * 40 + [(0x3503c0000, 0x10000)]]),
        ):
            for value in vals:
                add(path, key, value)
        for key, value in [('model', 'Mac15,3'), ('compatible', ['J516sAP'])]:
            tree = copy.deepcopy(original)
            setattr(tree, key, value)
            changes.append((key, tree))
        for base in (-0x20000, (1 << 64) - 0x20000):
            changes.append((str(base), fixture(base)))
        for name, tree in changes:
            with self.subTest(contract=name):
                sentinel = object()
                out = ByRef(sentinel)
                with self.assertRaises(ValueError):
                    manager(tree).rt_bandwidth_setup_ap(out)
                self.assertIs(out.val, sentinel)
        self.assertEqual(len(changes), 47)

    def test_legacy_chip_bytes_unchanged(self):
        for chip, scratch, doorbell, bit in [('t8103', 0x23b738014, 0x23bc3c000, 2),
                                             ('t600x', 0x28e3d0988, 0, 0)]:
            with self.subTest(chip=chip):
                data = manager(None, chip).handle_cb(NS(tag='D003', in_data=bytes(4)))
                expected = bytearray(60)
                struct.pack_into('<QQ', expected, 8, scratch, doorbell)
                struct.pack_into('<I', expected, 28, bit)
                self.assertEqual(data, bytes(expected))

    def test_unsupported_chip_and_null_rejected(self):
        with self.assertRaises(ValueError):
            manager(fixture(), 't8122').rt_bandwidth_setup_ap(ByRef(None))
        with self.assertRaises(ValueError):
            manager(fixture()).rt_bandwidth_setup_ap(None)
        if not TARGET:
            with self.assertRaises(ValueError):
                manager(fixture()).rt_bandwidth_setup_ap(ByRef(None))

    @unittest.skipUnless(TARGET and adt_path, 'optional pinned Apple ADT not supplied')
    def test_exact_apple_adt(self):
        from m1n1.adt import load_adt
        raw = adt_path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
                         '4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478')
        out = ByRef(None)
        self.assertEqual(manager(load_adt(raw)).rt_bandwidth_setup_ap(out), 0)
        self.assertEqual(out.val, dict(reg1=0x3503d0988, reg2=0, bit=0, scratch_size=8))

    def test_no_hardware_setup(self):
        self.assertNotIn('m1n1.setup', sys.modules)


if __name__ == '__main__':
    unittest.main(verbosity=2)
