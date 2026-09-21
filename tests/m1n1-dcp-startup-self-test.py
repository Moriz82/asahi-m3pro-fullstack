#!/usr/bin/env python3
"""Offline real Python startup calls: CLIENT PROFILE [--baseline]. No target I/O."""
import contextlib
import io
import os
from pathlib import Path
import struct
import sys
import unittest


def offline_only(event, args):
    if event in {"socket.connect", "subprocess.Popen", "os.system"}:
        raise RuntimeError("startup ABI test forbids connections and external execution")
    if event == "open" and isinstance(args[0], (str, bytes, os.PathLike)):
        name = os.fsdecode(args[0])
        if name.startswith("/dev/") and name not in {"/dev/null", "/dev/urandom", "/dev/random"}:
            raise RuntimeError("startup ABI test forbids device access")


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
os.environ["AGX_FWVER"] = profile
os.environ["AGX_GPU"] = "G13"
sys.addaudithook(offline_only)
from construct import StreamError
if profile == "V14_8":
    # Test-only hypothetical profile: preserve old behavior, not future support.
    from m1n1.constructutils import Ver
    Ver.MATRIX["V"] = [*Ver.MATRIX["V"], "V14_8"]
from m1n1.fw.dcp.ipc import ByRef, IOMobileFramebufferAP as API

new_abi = profile == "V14_7"
swap = API.A406 if profile in {"V14_7", "V14_8"} else API.A407
power = API.A468 if profile == "V12_3" else API.A472


def fields(layout):
    offset, result = 0, {}
    for field in layout.subcons:
        if field.name:
            if field.name in result:
                raise ValueError("duplicate wire field")
            result[field.name] = (offset, field.sizeof())
        offset += field.sizeof()
    return result


class StartupABI(unittest.TestCase):
    def test_swap_layout(self):
        if profile == "V14_8":
            self.assertEqual(swap.in_struct.sizeof(), 20)
            self.assertEqual(swap.out_struct.sizeof(), 20)
            self.assertEqual(fields(swap.in_struct), {"client": (0, 16), "client_null": (16, 1)})
            self.assertEqual(fields(swap.out_struct), {"client": (0, 16), "ret": (16, 4)})
            return
        self.assertEqual(swap.in_struct.sizeof(), 16 if new_abi else 24)
        self.assertEqual(swap.out_struct.sizeof(), 8 if new_abi else 24)
        expected = {"swap_id": (0, 4), "client": (4, 8 if new_abi else 16),
                    "swap_id_null": (12 if new_abi else 20, 1)}
        if not new_abi:
            expected["client_null"] = (21, 1)
        self.assertEqual(fields(swap.in_struct), expected)
        expected = {"swap_id": (0, 4), "ret": (4 if new_abi else 20, 4)}
        if not new_abi:
            expected["client"] = (4, 16)
        self.assertEqual(fields(swap.out_struct), expected)

    def test_power_layout(self):
        self.assertEqual(power.in_struct.sizeof(), 12)
        self.assertEqual(power.out_struct.sizeof(), 8)
        expected = {"arg0": (0, 8), "arg1": (8, 1)}
        if new_abi:
            expected.update(arg2=(9, 1), arg4=(10, 1), arg3_null=(11, 1))
        else:
            expected["arg2_null"] = (9, 1)
        self.assertEqual(fields(power.in_struct), expected)
        self.assertEqual(fields(power.out_struct), {"arg3" if new_abi else "arg2": (0, 4), "ret": (4, 4)})

    def test_swap_call(self):
        handle, ident, status = 0x1020304050607080, 0x12345678, 0x87654321
        for null in (False, True):
            ref = None if null else ByRef(ident)
            seen = []
            legacy_client = dict(addr=handle, unk=0, flag1=0, flag2=0)
            client_arg = handle if new_abi else ByRef(legacy_client)
            def transport(data):
                if new_abi:
                    self.assertEqual(data, struct.pack("<IQB3x", 0 if null else ident, handle, null))
                    reply = struct.pack("<II", ident + 1, status)
                else:
                    self.assertEqual(data, struct.pack("<IQIBB2xBB2x", 0 if null else ident, handle, 0, 0, 0, null, 0))
                    reply = struct.pack("<IQIBB2xI", ident + 1, handle, 0, 0, 0, status)
                seen.append(data)
                return reply
            if null:
                # Existing generic Method.call cannot serialize a null InOutPtr.
                # Preserve its pre-transport rejection; do not broaden this ABI fix.
                with self.assertRaises(KeyError):
                    swap.call(transport, swap_id=ref, client=client_arg)
                self.assertEqual(seen, [])
                continue
            with contextlib.redirect_stdout(io.StringIO()):
                result = swap.call(transport, swap_id=ref, client=client_arg)
            self.assertEqual(result, status)
            self.assertEqual(len(seen), 1)
            if ref is not None:
                self.assertEqual(ref.val, ident + 1)

    def test_power_calls(self):
        for flags in range(8 if new_abi else 2):
            for null in (False, True):
                output = None if null else ByRef(0)
                args = [1, bool(flags & 1)]
                if new_abi:
                    args += [bool(flags & 2), output, bool(flags & 4)]
                    expected = struct.pack("<QBBBB", 1, flags & 1, bool(flags & 2), bool(flags & 4), null)
                else:
                    args += [output]
                    expected = struct.pack("<QBB2x", 1, flags & 1, null)
                seen = []
                def transport(data):
                    self.assertEqual(data, expected)
                    seen.append(data)
                    return struct.pack("<II", 0x12345678, 0x87654321)
                with contextlib.redirect_stdout(io.StringIO()):
                    result = power.call(transport, *args)
                self.assertEqual(result, 0x87654321)
                self.assertEqual(len(seen), 1)
                if output is not None:
                    self.assertEqual(output.val, 0x12345678)

    def test_truncated_replies(self):
        for method in (swap, power):
            with self.assertRaises(StreamError):
                method.parse_output(bytes(method.out_struct.sizeof() - 1), {})

    def test_legacy_target_call_rejected_before_transport(self):
        if not new_abi:
            return
        def no_transport(data):
            self.fail("invalid signature reached transport")
        with self.assertRaises(KeyError):
            swap.call(no_transport, client=ByRef({}))
        with self.assertRaises(KeyError):
            power.call(no_transport, 1, False, ByRef(0))

    def test_no_hardware_setup(self):
        self.assertNotIn("m1n1.setup", sys.modules)


if __name__ == "__main__":
    if baseline:
        suite = unittest.TestSuite(StartupABI(name) for name in ("test_swap_layout", "test_power_layout"))
        result = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
        if len(result.failures) != 2 or result.errors:
            raise AssertionError("expected two independent predecessor layout failures")
        print("PASS: both predecessor Python wire layouts rejected")
    elif profile == "V14_8":
        suite = unittest.TestSuite(StartupABI(name) for name in ("test_swap_layout", "test_power_layout", "test_no_hardware_setup"))
        if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
            raise SystemExit(1)
    else:
        unittest.main(verbosity=2)
