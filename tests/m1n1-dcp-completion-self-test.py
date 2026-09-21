#!/usr/bin/env python3
"""Actual D589 schema/manager: CLIENT PROFILE [--baseline]. No target I/O."""
import contextlib
import io
import os
from pathlib import Path
import struct
import sys
from types import SimpleNamespace as NS
import unittest


def offline_only(event, args):
    if event in {"socket.connect", "subprocess.Popen", "os.system"}:
        raise RuntimeError("completion test forbids connections/execution")
    if event == "open" and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith("/dev/") and path not in {"/dev/null", "/dev/urandom", "/dev/random"}:
            raise RuntimeError("completion test forbids device access")


if len(sys.argv) not in (3, 4) or sys.argv[2] not in {"V12_3", "V13_5", "V14_7", "V14_8"}:
    raise SystemExit(__doc__)
client = Path(sys.argv[1]).resolve(strict=True)
profile = sys.argv[2]
baseline = len(sys.argv) == 4
if baseline and (sys.argv[3] != "--baseline" or profile != "V14_7"):
    raise SystemExit(__doc__)
sys.argv[:] = sys.argv[:1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(client))
os.environ["AGX_FWVER"], os.environ["AGX_GPU"] = profile, "G13"
sys.addaudithook(offline_only)
from m1n1.constructutils import Ver
if profile == "V14_8":
    Ver.MATRIX["V"] = [*Ver.MATRIX["V"], "V14_8"]  # Test-only, not future support.
from m1n1.fw.dcp import ipc
from m1n1.fw.dcp.manager import DCPManager

METHOD = ipc.IOMobileFramebufferAP.D589
TARGET = profile == "V14_7"
DATA_SIZE = 34 if TARGET else 18
INFO_SIZE = 1728 if TARGET else 1732 if profile == "V12_3" else 1748
INFO_OFFSET = 5 + DATA_SIZE
COUNT_OFFSET = INFO_OFFSET + INFO_SIZE
NULL_OFFSET = COUNT_OFFSET + (5 if TARGET else 4)
WIRE_SIZE = (NULL_OFFSET + 4) & ~3


def packet(ident=0x12345678, null=False, flags=0, count=8):
    data = bytearray((i * 29 + 7) & 255 for i in range(WIRE_SIZE))
    struct.pack_into("<I", data, 0, ident)
    data[4] = flags & 1
    struct.pack_into("<I", data, COUNT_OFFSET, count)
    if TARGET:
        data[COUNT_OFFSET + 4] = (flags >> 1) & 1
    data[NULL_OFFSET] = null
    data[NULL_OFFSET + 1:] = bytes(WIRE_SIZE - NULL_OFFSET - 1)
    return bytes(data)

def state(data):
    return NS(tag="D589", in_len=len(data), out_len=0, in_data=data)


class CompletionABI(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def test_wire_fields(self):
        expected = {"swap_id": (0, 4), "unkBool": (4, 1), "swap_data": (5, DATA_SIZE),
                    "swap_info": (INFO_OFFSET, INFO_SIZE), "unkUint": (COUNT_OFFSET, 4),
                    "swap_data_null": (NULL_OFFSET, 1)}
        if TARGET:
            expected["unkBool2"] = (COUNT_OFFSET + 4, 1)
        offset, fields = 0, {}
        for field in METHOD.in_struct.subcons:
            if field.name:
                fields[field.name] = (offset, field.sizeof())
            offset += field.sizeof()
        self.assertEqual(fields, expected)
        self.assertEqual(offset, WIRE_SIZE)
        self.assertEqual(METHOD.out_struct.sizeof(), 0)

    def test_callback_fields(self):
        for ident in (0, 0x12345678, 0xffffffff):
            for flags in range(4 if TARGET else 2):
                raw, seen = packet(ident=ident, flags=flags), []
                self.assertEqual(METHOD.callback(lambda **values: seen.append(values), raw), b"")
                value = seen[0]
                self.assertEqual(value["swap_id"], ident)
                self.assertEqual(value["unkBool"], bool(flags & 1))
                self.assertEqual(value["swap_data"], raw[5:INFO_OFFSET])
                self.assertEqual(ipc.SwapInfoBlob.build(value["swap_info"]), raw[INFO_OFFSET:COUNT_OFFSET])
                self.assertEqual(value["unkUint"], 8)
                if TARGET:
                    self.assertEqual(value["unkBool2"], bool(flags & 2))

    def test_null_flag(self):
        seen = []
        self.assertEqual(METHOD.callback(lambda **values: seen.append(values), packet(null=True)), b"")
        self.assertIsNone(seen[0]["swap_data"])

    def test_actual_manager(self):
        mgr = DCPManager(NS(asc=NS()), compatible="t6030")
        for ident, null in ((0, False), (0xffffffff, True)):
            self.assertEqual(mgr.handle_cb(state(packet(ident, null))), b"")
            self.assertEqual(mgr.frame, ident)
            self.assertEqual(mgr.in_callback, 0)
        self.assertEqual(mgr.swaps, 2)

    def test_malformed_before_manager_side_effects(self):
        if not TARGET:
            return  # Strict size gate is only established for 23J220.
        mgr = DCPManager(NS(asc=NS()), compatible="t6030")
        valid = packet()
        for raw in (b"", valid[:4], valid[:-1], valid + b"\0"):
            before = vars(mgr).copy()
            with self.assertRaisesRegex(ValueError, "Invalid swap completion callback size"):
                mgr.handle_cb(state(raw))
            self.assertEqual(vars(mgr), before)
        for name, value in (("in_len", 0), ("in_len", WIRE_SIZE + 1), ("out_len", 4)):
            invalid = state(valid)
            setattr(invalid, name, value)
            before = vars(mgr).copy()
            with self.assertRaisesRegex(ValueError, "Invalid swap completion callback size"):
                mgr.handle_cb(invalid)
            self.assertEqual(vars(mgr), before)

    def test_callback_error_restores_nesting(self):
        mgr = DCPManager(NS(asc=NS()), compatible="t6030")
        def fail(**values):
            raise RuntimeError("fixture callback failure")
        mgr.swap_complete_ap_gated = fail
        with self.assertRaisesRegex(RuntimeError, "fixture callback failure"):
            mgr.handle_cb(state(packet()))
        self.assertEqual(mgr.in_callback, 0)
        self.assertEqual(mgr.swaps, 0)

    def test_no_hardware_setup(self):
        self.assertNotIn("m1n1.setup", sys.modules)


if __name__ == "__main__":
    if baseline:
        names = {"test_wire_fields", "test_null_flag", "test_actual_manager"}
        result = unittest.TextTestRunner(stream=io.StringIO()).run(
            unittest.TestSuite(CompletionABI(name) for name in sorted(names)))
        failed = {case._testMethodName for case, trace in result.failures + result.errors}
        if failed != names:
            raise AssertionError(f"expected three predecessor failures, got {failed}")
        for case, trace in result.errors:
            if case._testMethodName != "test_actual_manager" or "KeyError" not in trace:
                raise AssertionError(trace)
        print("PASS: predecessor field/null decoding and real-manager callback faults reproduced")
    else:
        unittest.main(verbosity=2)
