#!/usr/bin/env python3
"""Actual D006/D576 schemas and manager: CLIENT PROFILE [--baseline]. No target I/O."""
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
        raise RuntimeError("metadata test forbids connections/execution")
    if event == "open" and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith("/dev/") and path not in {"/dev/null", "/dev/urandom", "/dev/random"}:
            raise RuntimeError("metadata test forbids device access")


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

TARGET = profile == "V14_7"
FRAME = ipc.UPPipeAP_H13P.D006
HOTPLUG = ipc.IOMobileFramebufferAP.D576
NAMES = ("IOMFBTestBacklightDimValue", "IOMFBBrightnessLevel", "APTPDCBrightness",
         "Brightness_Scale", "BLNitsCap", "RTPLCBLNitsScaler", "twilightStrength",
         "ammoliteStrength", "IOMFBIndicatorBrightnessNits",
         "IOMFBSecureContentFactor", "IOMFBSecureIndicatorFactor")
VALUES = tuple((i * 0x10010203 + 0x80000123) & 0xffffffff for i in range(11))


def frame_packet(mask=2047, null=False):
    if not TARGET:
        return bytes(range(28)) + bytes([null]) + bytes(3)
    return (struct.pack("<11I", *VALUES) +
            bytes(i + 1 if mask & (1 << i) else 0 for i in range(11)) +
            bytes([0xa7, null, 0, 0, 0]))


def hotplug_packet(connection=1, null=False, flag=False):
    if profile == "V12_3":
        return struct.pack("<Q", connection)
    size = 75 if TARGET else 76 if profile == "V13_5" else 80
    blob = bytes((i * 13 + 11) & 255 for i in range(size))
    if TARGET:
        return struct.pack("<Q", connection) + blob + bytes([flag, null, 0, 0, 0])
    return struct.pack("<I", connection) + blob + bytes([null, 0, 0, 0])


def state(tag, raw):
    return NS(tag=tag, in_len=len(raw), out_len=56 if tag == "D006" else 76, in_data=raw)


def fields(layout):
    result, offset = {}, 0
    for field in layout.subcons:
        if field.name:
            if field.name in result:
                raise ValueError("duplicate wire field")
            result[field.name] = (offset, field.sizeof())
        offset += field.sizeof()
    return result


class MetadataABI(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def test_frame_layout(self):
        size = 56 if TARGET else 28
        self.assertEqual(FRAME.in_struct.sizeof(), size + 4)
        self.assertEqual(FRAME.out_struct.sizeof(), size)
        self.assertEqual(fields(FRAME.in_struct), {"props": (0, size), "props_null": (size, 1)})
        if TARGET:
            self.assertEqual(fields(ipc.frame_sync_props_t),
                             {"values": (0, 44), "updated": (44, 11), "reserved": (55, 1)})

    def test_hotplug_layout(self):
        if profile == "V12_3":
            expected, sizes = {"arg0": (0, 8)}, (8, 0)
        elif TARGET:
            expected = {"arg0": (0, 8), "arg1": (8, 75), "arg2": (83, 1), "arg1_null": (84, 1)}
            sizes = (88, 76)
        else:
            size = 76 if profile == "V13_5" else 80
            expected = {"arg0": (0, 4), "arg1": (4, size), "arg1_null": (4 + size, 1)}
            sizes = (size + 8, size)
        self.assertEqual(fields(HOTPLUG.in_struct), expected)
        self.assertEqual((HOTPLUG.in_struct.sizeof(), HOTPLUG.out_struct.sizeof()), sizes)

    def test_frame_manager(self):
        if not TARGET:
            # Previously unsupported manager operation stays unsupported.
            mgr = DCPManager(NS(asc=NS()), compatible="t6030")
            with self.assertRaises(NotImplementedError):
                mgr.set_frame_sync_props(None)
            return
        mgr = DCPManager(NS(asc=NS()), compatible="t6030")
        for mask in range(2048):
            raw = frame_packet(mask)
            mgr.iomfb_prop.clear()
            expected = raw[:44] + bytes(11) + raw[55:56]
            self.assertEqual(mgr.handle_cb(state("D006", raw)), expected)
            self.assertEqual(mgr.iomfb_prop,
                             {name: VALUES[i] for i, name in enumerate(NAMES) if mask & (1 << i)})
            self.assertEqual(mgr.in_callback, 0)
            self.assertEqual(raw, frame_packet(mask))
        before = mgr.iomfb_prop.copy()
        self.assertEqual(mgr.handle_cb(state("D006", frame_packet(null=True))), bytes(56))
        self.assertEqual(mgr.iomfb_prop, before)

    def test_frame_callback_null_and_roundtrip(self):
        for null in (False, True):
            raw, seen = frame_packet(null=null), []
            result = FRAME.callback(lambda props: seen.append(props), raw)
            size = 56 if TARGET else 28
            self.assertEqual(result, bytes(size) if null else raw[:size])
            if null:
                self.assertIsNone(seen[0])
            else:
                self.assertEqual(ipc.frame_sync_props_t.build(seen[0].val), raw[:size])

    def test_hotplug_manager(self):
        mgr = DCPManager(NS(asc=NS()), compatible="t6030")
        values = (0, 1, 0x100000000, 0xffffffffffffffff) if TARGET or profile == "V12_3" else (0, 1, 0xffffffff)
        for connection in values:
            for null in (False, True):
                for flag in (False, True):
                    raw = hotplug_packet(connection, null, flag)
                    cbstate = state("D576", raw)
                    cbstate.out_len = HOTPLUG.out_struct.sizeof()
                    before = vars(mgr).copy()
                    if profile in {"V13_5", "V14_8"}:
                        # Prior manager rejected all extra arguments, including
                        # null records. Do not enable unverified profiles.
                        with self.assertRaisesRegex(TypeError, "Hotplug metadata requires"):
                            mgr.handle_cb(cbstate)
                        self.assertEqual(vars(mgr), before)
                        continue
                    result = mgr.handle_cb(cbstate)
                    if profile == "V12_3":
                        expected = b""
                    elif TARGET:
                        expected = (bytes(75) if null else raw[8:83]) + bytes(1)
                    else:
                        expected = bytes(cbstate.out_len) if null else raw[4:4+cbstate.out_len]
                    self.assertEqual(result, expected)
                    self.assertEqual(vars(mgr), before)
                    seen = []
                    HOTPLUG.callback(lambda *args: seen.append(args), raw)
                    self.assertEqual(seen[0][0], connection)
                    if profile != "V12_3":
                        if null:
                            self.assertIsNone(seen[0][1])
                        else:
                            self.assertEqual(seen[0][1].val, expected[:75] if TARGET else expected)
                    if TARGET:
                        self.assertEqual(seen[0][2], flag)

    def test_malformed_before_manager_side_effects(self):
        if not TARGET:
            return
        mgr = DCPManager(NS(asc=NS()), compatible="t6030")
        for tag, raw in (("D006", frame_packet()), ("D576", hotplug_packet())):
            for name, value in (("in_data", b""), ("in_data", raw[:-1]), ("in_data", raw+b"\0"),
                                ("in_len", len(raw)-1), ("in_len", len(raw)+1),
                                ("out_len", 0), ("out_len", 77)):
                invalid = state(tag, raw)
                setattr(invalid, name, value)
                before, props = vars(mgr).copy(), mgr.iomfb_prop.copy()
                with self.assertRaisesRegex(ValueError, "Invalid display metadata callback size"):
                    mgr.handle_cb(invalid)
                self.assertEqual(vars(mgr), before)
                self.assertEqual(mgr.iomfb_prop, props)

    def test_callback_failure_restores_nesting(self):
        if not TARGET:
            return
        mgr = DCPManager(NS(asc=NS()), compatible="t6030")
        def fail(*args, **kwargs):
            raise RuntimeError("fixture failure")
        for tag, method, raw in (("D006", "set_frame_sync_props", frame_packet()),
                                 ("D576", "hotPlug_notify_gated", hotplug_packet())):
            setattr(mgr, method, fail)
            with self.assertRaisesRegex(RuntimeError, "fixture failure"):
                mgr.handle_cb(state(tag, raw))
            self.assertEqual(mgr.in_callback, 0)

    def test_no_hardware_setup(self):
        self.assertNotIn("m1n1.setup", sys.modules)


if __name__ == "__main__":
    if baseline:
        names = {"test_frame_layout", "test_hotplug_layout", "test_frame_manager", "test_hotplug_manager"}
        result = unittest.TextTestRunner(stream=io.StringIO()).run(
            unittest.TestSuite(MetadataABI(name) for name in sorted(names)))
        failed = {case._testMethodName for case, trace in result.failures + result.errors}
        if failed != names:
            raise AssertionError(f"expected four predecessor faults, got {failed}")
        for case, trace in result.errors:
            expected = "Unimplemented callback" if case._testMethodName == "test_frame_manager" else "TypeError"
            if expected not in trace:
                raise AssertionError(trace)
        print("PASS: predecessor frame/hotplug layouts and both real-manager callback faults reproduced")
    else:
        unittest.main(verbosity=2)
