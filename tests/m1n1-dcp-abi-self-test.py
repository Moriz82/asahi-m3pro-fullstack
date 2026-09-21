#!/usr/bin/env python3
"""Offline V14.7 A407 layout contract, checked against T6030/T8122 23J220.

Usage: AGX_FWVER=V14_7 python3 -B tests/m1n1-dcp-abi-self-test.py PROXYCLIENT
The unpatched 60e53e7 client must fail. No target or firmware is executed.
"""
import contextlib
import io
import os
from pathlib import Path
import struct
import sys
import unittest


def offline_only(event, args):
    if event in {"socket.connect", "subprocess.Popen", "os.system"}:
        raise RuntimeError("offline ABI test forbids external execution and connections")
    if event == "open" and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith("/dev/") and path not in {"/dev/null", "/dev/urandom", "/dev/random"}:
            raise RuntimeError("offline ABI test forbids device access")


if len(sys.argv) != 2:
    raise SystemExit(__doc__)
client = Path(sys.argv.pop()).resolve(strict=True)
sys.dont_write_bytecode = True
sys.path.insert(0, str(client))
os.environ["AGX_FWVER"] = "V14_7"
os.environ["AGX_GPU"] = "G13"  # DCP layout does not use the GPU-generation selector.
sys.addaudithook(offline_only)
from m1n1.fw.dcp.ipc import ByRef, IOMobileFramebufferAP, IOMFBSwapRec, IOSurface

METHOD = IOMobileFramebufferAP.A407


def fields(layout):
    offset = 0
    result = {}
    for field in layout.subcons:
        if field.name:
            if field.name in result:
                raise AssertionError(f"duplicate wire field: {field.name}")
            result[field.name] = (offset, field.sizeof())
        offset += field.sizeof()
    return result


class SwapABI(unittest.TestCase):
    def test_input_layout(self):
        self.assertEqual(METHOD.in_struct.sizeof(), 7000)
        layout = fields(METHOD.in_struct)
        expected = {
            "swap_rec": (0, 1288), "surfaces": (1288, 2224),
            "surfAddr": (3512, 32), "unkU64Array": (3544, 32),
            "surfaces2": (3576, 3336), "surfAddr2": (6912, 48),
            "unkBool": (6960, 1), "unkFloat": (6961, 8),
            "unkU64": (6969, 8), "unkBool2": (6977, 1),
            "clear_surfs": (6978, 4), "unkCUintArray": (6982, 4),
            "swap_rec_null": (6986, 1), "surfaces_null": (6987, 4),
            "surfaces2_null": (6991, 6), "unkOutBool_null": (6997, 1),
            "unkCUintArray_null": (6998, 1), "unkUintPtr_null": (6999, 1),
        }
        self.assertEqual(layout, expected)

    def test_output_layout(self):
        self.assertEqual(METHOD.out_struct.sizeof(), 12)
        self.assertEqual(fields(METHOD.out_struct), {
            "unkOutBool": (0, 1), "unkUintPtr": (1, 4), "ret": (5, 4),
        })

    def test_call_roundtrip(self):
        out_bool, out_uint = ByRef(False), ByRef(0)
        sixth = IOSurface.parse(bytes(IOSurface.sizeof()))
        sixth.surface_id = 0x13579BDF
        reply = struct.pack("<BII3x", 1, 0x12345678, 0x87654321)
        seen = []

        def transport(data):
            self.assertEqual(len(data), 7000)
            self.assertEqual(data[6991:6997], bytes([1, 1, 1, 1, 1, 0]))
            self.assertEqual(data[6997:7000], bytes(3))
            self.assertEqual(struct.unpack_from("<Q", data, 6952)[0], 0x1020304050607080)
            self.assertEqual(struct.unpack_from("<I", data, 6978)[0], 0x11223344)
            self.assertEqual(struct.unpack_from("<I", data, 6982)[0], 0x55667788)
            parsed = METHOD.parse_input(data)
            self.assertEqual(parsed.surfaces2[5].surface_id, sixth.surface_id)
            self.assertEqual(METHOD.in_struct.build(parsed), data)
            seen.append(data)
            return reply

        with contextlib.redirect_stdout(io.StringIO()):
            result = METHOD.call(
                transport, swap_rec=IOMFBSwapRec.parse(bytes(IOMFBSwapRec.sizeof())),
                surfaces=[None] * 4, surfAddr=[0] * 4, unkU64Array=[0] * 4,
                surfaces2=[None] * 5 + [sixth],
                surfAddr2=[0] * 5 + [0x1020304050607080],
                unkBool=False, unkFloat=0.0, unkU64=0, unkBool2=False,
                clear_surfs=0x11223344, unkOutBool=out_bool,
                unkCUintArray=0x55667788, unkUintPtr=out_uint,
            )
        self.assertEqual(len(seen), 1)
        self.assertEqual(result, 0x87654321)
        self.assertTrue(out_bool.val)
        self.assertEqual(out_uint.val, 0x12345678)

    def test_truncated_reply_rejected(self):
        from construct import StreamError
        with self.assertRaises(StreamError):
            METHOD.parse_output(bytes(8), {})

    def test_no_hardware_setup(self):
        self.assertNotIn("m1n1.setup", sys.modules)


if __name__ == "__main__":
    unittest.main(verbosity=2)
