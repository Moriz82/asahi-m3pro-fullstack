#!/usr/bin/env python3
"""Offline actual-collector tests. Requires the pinned m1n1 proxyclient on PYTHONPATH."""

import copy
import contextlib
import importlib.abc
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.dont_write_bytecode = True


def blocked(*args, **kwargs):
    raise RuntimeError("offline test forbids target access")


def audit(event, args):
    if event in {"socket.connect", "socket.bind", "socket.getaddrinfo"}:
        blocked()
    if event == "open" and isinstance(args[0], (str, bytes)):
        path = os.fsdecode(args[0])
        if path.startswith("/dev/") and path not in {"/dev/null", "/dev/urandom", "/dev/random"}:
            blocked()


class NoSetup(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if fullname in {"m1n1.setup", "m1n1.proxyutils"}:
            blocked()
        return None


sys.addaudithook(audit)
sys.meta_path.insert(0, NoSetup())
import serial
serial.Serial.__new__ = staticmethod(blocked)
serial.Serial.open = blocked
serial.serial_for_url = blocked
from m1n1.adt import ADTNodeStruct
from m1n1.hw.dart8110 import DART8110, R_TCR, R_TTBR, PTE
from m1n1.tgtypes import BootArgs_r1, BootArgs_r2, BootArgs_r3

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("snapshot", ROOT / "scripts/retained-dart-snapshot.py")
snap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snap)
PAGE = snap.PAGE
RAM = 0x10000000000
PA = RAM + 0x200000


def u32(value):
    return struct.pack("<I", value)


def u64s(*values):
    return struct.pack("<" + "Q" * len(values), *values)


def string(value):
    return value.encode() + b"\0"


def node(name, props=None, children=()):
    props = {"name": string(name), **(props or {})}
    return dict(property_count=len(props), child_count=len(children),
                properties=[dict(name=k, size=len(v), value=v) for k, v in props.items()], children=children)


def entry(pa, flags=1):
    return ((pa >> 14) << 10) | flags


class FakeProxy:
    """Only the exact collector operations exist. Every address is allowlisted."""
    REQ_NOP = 0xAA55FF
    debug = False
    enabled_features = 1

    def __init__(self, revision=3, change=None):
        self.iface = self
        self.calls, self.regs, self.memory, self.reads = [], {}, {}, {}
        self.negotiated = 0
        self.exception = 0
        self.fault_address = None
        self.change = change
        self.ba_address, self.adt_address = RAM + 0x4000, RAM + 0x8000
        self.regions = [RAM + 0x100000 + index * 2 * PAGE for index in range(3)]
        dart_nodes = []
        for indices, dart in (((0,), "dart-dcp"), ((1, 2), "dart-disp0")):
            props = {"reg": u64s(snap.STREAMS[indices[0]][4], PAGE), "compatible": string("dart,t8110")}
            children = []
            for index in indices:
                _, _, mapper, sid, base = snap.STREAMS[index]
                start = self.regions[index]
                props[f"pt-region-{sid}"] = u64s(start, start + 2 * PAGE)
                props[f"l2-tt-{sid}"] = u64s(start, 2)
                children.append(node(mapper, {"reg": u32(sid), "AAPL,phandle": u32(275 + index)}))
                table = bytearray(2 * PAGE)
                for root_index in (3, 7):
                    struct.pack_into("<Q", table, root_index * 8, entry(start + PAGE))
                if index != 2:
                    struct.pack_into("<Q", table, PAGE + 4 * 8, entry(PA, (0xFFF << 40) | 1))
                if index == 0:
                    struct.pack_into("<Q", table, PAGE + 5 * 8, entry(PA + PAGE, (0xFFF << 40) | 9))
                self.memory[start] = bytes(table)
                self.regs.update({base: 14 << 24, base + 4: 0, base + 8: (42 << 24) | (36 << 16),
                                  base + 12: 256, base + 0x200: 1, base + 0xC00: 0x31,
                                  base + 0x1000 + 4 * sid: 1,
                                  base + 0x1400 + 4 * sid: ((start >> 14) << 2) | 1})
            dart_nodes.append(node(dart, props, children))
        chosen = node("chosen", {"chip-id": u32(0x6030), "board-id": u32(4),
                                 "firmware-version": string(snap.FIRMWARE)}, [
            node("carveout-memory-map", {"region-id-14": u64s(PA + 123, PAGE + 333),
                                          "region-id-0": u64s(0, 0)})])
        arm = node("arm-io", {"compatible": string("arm-io,t6030"), "#address-cells": u32(2),
                              "#size-cells": u32(2), "ranges": u64s(0, 0, 1 << 42)}, [
            *dart_nodes, node("pmgr", {"devices": bytes(2 * 48)}),
            node("dcp", {"iommu-parent": u32(275)}, [node("iop-dcp-nub", {
                "segment-ranges": struct.pack("<QQQII", PA, (1 << 64) - 1, 0x60010000, 2 * PAGE, 0x24)})]),
            node("disp0", {"iommu-parent": struct.pack("<II", 276, 277)})])
        self.tree = node("device-tree", {"model": string("Mac15,6"),
                                        "compatible": b"J514sAP\0Mac15,6\0AppleARM\0",
                                        "#address-cells": u32(2), "#size-cells": u32(2)},
                         [chosen, arm, node("vram", {"reg": u64s(PA, 2 * PAGE)})])
        self.ba = dict(revision=revision, version=2, phys_base=RAM, virt_base=0xFFFFFE0000000000,
                       mem_size=4 << 30, mem_size_actual=8 << 30, top_of_kernel_data=RAM + 0x400000,
                       video=dict(base=PA, display=1, stride=0, width=0, height=0, depth=0),
                       machine_type=0, devtree=0xFFFFFE0000008000, devtree_size=0,
                       cmdline="PRIVATE-CMDLINE-DO-NOT-EXPORT", boot_flags=0)
        self.rebuild()

    def rebuild(self):
        self.memory[self.adt_address] = ADTNodeStruct.build(self.tree)
        self.ba["devtree_size"] = len(self.memory[self.adt_address])
        self.memory[self.ba_address] = {1: BootArgs_r1, 2: BootArgs_r2, 3: BootArgs_r3}[self.ba["revision"]].build(self.ba)

    def prop(self, path, key, value):
        current = self.tree
        for name in path.split("/"):
            if name:
                current = next(c for c in current["children"]
                               if next(p["value"] for p in c["properties"] if p["name"] == "name") == string(name))
        prop = next(p for p in current["properties"] if p["name"] == key)
        prop.update(value=value, size=len(value))
        self.rebuild()

    def cmd(self, opcode, payload):
        if opcode != self.REQ_NOP or payload != u64s(0):
            blocked()
        self.calls.append(("checksum-negotiate",))

    def reply(self, opcode):
        if opcode != self.REQ_NOP:
            blocked()
        return u64s(self.negotiated, 0, 0)

    def get_bootargs(self):
        self.calls.append(("get_bootargs",))
        return self.ba_address

    def get_exc_count(self):
        self.calls.append(("get_exc_count",))
        result, self.exception = self.exception, 0
        return result

    def read32(self, address):
        if address not in self.regs:
            blocked()
        self.calls.append(("read32", address))
        if address == self.fault_address:
            self.exception = 1
        key = ("reg", address)
        self.reads[key] = self.reads.get(key, 0) + 1
        value = self.regs[address]
        if self.change == "register" and self.reads[key] > 1:
            value ^= 1
        return value

    def readmem(self, address, size):
        if self.enabled_features != 0:
            blocked()
        self.calls.append(("readmem", address, size))
        key = (address, size)
        self.reads[key] = self.reads.get(key, 0) + 1
        for start, data in self.memory.items():
            if start <= address and address + size <= start + len(data):
                value = data[address - start:address - start + size]
                if self.change == "short" and address in self.regions:
                    return value[:-1]
                if self.change == "fault" and address in self.regions:
                    raise OSError("synthetic guarded memory read fault")
                if self.change == "table" and address in self.regions and self.reads[key] > 1:
                    return value[:-1] + bytes([value[-1] ^ 1])
                if self.change == "adt" and address == self.adt_address and self.reads[key] > 1:
                    # Fresh identity must fail; no cached metadata is allowed.
                    return value.replace(b"Mac15,6", b"Mac15,7")
                return value
        blocked()

    def __getattr__(self, name):
        blocked()


def captured(proxy=None):
    return snap.capture(proxy or FakeProxy(), approved_stage=snap.STAGE)


def mutate_entry(snapshot, offset, value):
    stream = snapshot["streams"][0]
    data = bytearray.fromhex(stream["data_hex"])
    struct.pack_into("<Q", data, offset, value)
    stream.update(data_hex=data.hex(), sha256=snap.digest(data))


class Tests(unittest.TestCase):
    def test_tripwires(self):
        for action in (lambda: serial.Serial("/dev/no-target"),
                       lambda: __import__("m1n1.setup"), lambda: __import__("m1n1.proxyutils"),
                       lambda: os.open("/dev/no-target", os.O_RDONLY)):
            with self.subTest(action=action), self.assertRaisesRegex(RuntimeError, "forbids target"):
                action()

    def test_approval_precedes_all_io(self):
        p = FakeProxy()
        for stage in (None, True, "before-linux", ""):
            with self.subTest(stage=stage), self.assertRaisesRegex(ValueError, "approval"):
                snap.capture(p, approved_stage=stage)
        self.assertEqual(p.calls, [])

    def test_capture_all_bootargs_layouts(self):
        for revision in (1, 2, 3):
            with self.subTest(revision=revision):
                p = FakeProxy(revision)
                result = captured(p)
                text = str(result)
                self.assertNotIn("PRIVATE-CMDLINE", text)
                self.assertNotIn("devtree", result)
                self.assertFalse(result["hardware_acceptance"])
                self.assertFalse(result["atomic_snapshot"])
                reads = [c for c in p.calls if c[0] == "readmem" and c[1] in p.regions]
                self.assertEqual(reads, [("readmem", a, 2 * PAGE) for a in p.regions] * 2)
                self.assertEqual(len([c for c in p.calls if c[0] == "read32"]), 3 * 3 * 8)
                report = snap.analyze(result)["streams"]
                self.assertEqual(report["dcp"]["valid_leaf_entries"], 4)
                self.assertEqual(report["display"]["valid_leaf_entries"], 2)
                self.assertEqual(report["piodma"]["valid_leaf_entries"], 0)
                match = report["dcp"]["extents"][0]
                self.assertEqual(match["address_coverage_bytes"], PAGE + 333)
                self.assertEqual(match["full_contiguous_address_aliases"],
                                 [(i << 25) + 4 * PAGE + 123 for i in (3, 7)])
                self.assertEqual(report["display"]["extents"][0]["address_coverage_bytes"], PAGE - 123)
                self.assertEqual(report["display"]["extents"][0]["full_contiguous_address_aliases"], [])

    def test_identity_metadata_fail_before_mmio(self):
        cases = [("", "model", string("Mac15,7")), ("", "compatible", string("J516sAP")),
                 ("chosen", "chip-id", u32(0)), ("chosen", "board-id", u32(0)),
                 ("chosen", "firmware-version", string("mBoot-unsupported")),
                 ("arm-io", "compatible", string("arm-io,t6020")),
                 ("arm-io/dart-dcp", "reg", u64s(0x28D300000, PAGE)),
                 ("arm-io/dart-dcp/mapper-dcp", "reg", u32(4)),
                 ("arm-io/dcp", "iommu-parent", u32(777)),
                 ("arm-io/disp0", "iommu-parent", u64s(0)),
                 ("arm-io/dart-dcp", "pt-region-5", b""),
                 ("arm-io/dart-dcp", "pt-region-5", u64s(0x28D304000, 0x28D308000)),
                 ("arm-io/dart-dcp", "pt-region-5", u64s(RAM + 0x100000, RAM + 0x100001)),
                 ("arm-io/dart-dcp", "pt-region-5", u64s(RAM + 0x100000, RAM + 0x204000)),
                 ("arm-io/dart-dcp", "l2-tt-5", u64s(RAM + 0x100000, 3)),
                 ("arm-io/dart-disp0", "pt-region-0", u64s(RAM + 0x100000, RAM + 0x110000)),
                 ("chosen/carveout-memory-map", "region-id-14", u64s(RAM, 0)),
                 ("arm-io/dcp/iop-dcp-nub", "segment-ranges", b"bad")]
        for path, key, value in cases:
            with self.subTest(path=path, key=key, value=value):
                p = FakeProxy()
                p.prop(path, key, value)
                with self.assertRaises((ValueError, KeyError)):
                    captured(p)
                self.assertFalse(any(c[0] == "read32" for c in p.calls))

    def test_bootargs_bounds(self):
        p = FakeProxy()
        p.ba_address = 0x28D304000
        with self.assertRaisesRegex(ValueError, "address extent"):
            captured(p)
        self.assertFalse(any(c[0] == "readmem" for c in p.calls))
        for key, value in (("mem_size_actual", 0), ("mem_size_actual", 129 << 30),
                           ("phys_base", 0x200000000), ("mem_size", 9 << 30),
                           ("devtree", 0xFFFFFDFFFFFF0000)):
            with self.subTest(key=key):
                p = FakeProxy()
                p.ba[key] = value
                p.rebuild()
                with self.assertRaises(ValueError):
                    captured(p)
                self.assertFalse(any(c[0] == "read32" for c in p.calls))

    def test_transport_rejections(self):
        for field, value in (("debug", True), ("negotiated", 1), ("exception", 1)):
            with self.subTest(field=field):
                p = FakeProxy()
                setattr(p, field, value)
                with self.assertRaises(ValueError):
                    captured(p)
                self.assertFalse(any(c[0] == "readmem" for c in p.calls))
        p = FakeProxy()
        p.fault_address = snap.STREAMS[0][4]
        with self.assertRaisesRegex(ValueError, "register read fault"):
            captured(p)
        self.assertFalse(any(c[0] == "readmem" and c[1] in p.regions for c in p.calls))

    def test_register_gate_before_tables(self):
        for offset, value in ((0, 12 << 24), (8, (40 << 24) | (36 << 16)),
                              (8, (42 << 24) | (35 << 16)), (12, 5), (0xC00, 0),
                              (0x1014, 0), (0x1014, 3), (0x1014, 0x81), (0x1014, 9),
                              (0x1014, 0x11), (0x1414, 0), (0x1414, 3),
                              (0x1414, ((RAM >> 14) << 2) | 1)):
            with self.subTest(offset=offset, value=value):
                p = FakeProxy()
                p.regs[snap.STREAMS[0][4] + offset] = value
                with self.assertRaises(ValueError):
                    captured(p)
                self.assertFalse(any(c[0] == "readmem" and c[1] in p.regions for c in p.calls))

    def test_read_failures_and_changes(self):
        for change in ("short", "fault", "table", "register", "adt"):
            with self.subTest(change=change), self.assertRaises((ValueError, OSError)):
                captured(FakeProxy(change=change))

    def test_bad_tables_and_budgets(self):
        source = captured()
        start = source["streams"][0]["start"]
        for value, message in ((entry(PA), "outside declared"), (entry(start), "cycle")):
            with self.subTest(message=message):
                result = copy.deepcopy(source)
                mutate_entry(result, 3 * 8, value)
                with self.assertRaisesRegex(ValueError, message):
                    snap.analyze(result)
        for field, value in (("sha256", "0" * 64), ("data_hex", "00"), ("adt_root", start + PAGE)):
            result = copy.deepcopy(source)
            result["streams"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                snap.analyze(result)
        for key in ("MAX_VISITS", "MAX_LEAVES"):
            old = getattr(snap, key)
            try:
                setattr(snap, key, 1)
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, "budget"):
                    snap.analyze(source)
            finally:
                setattr(snap, key, old)

    def test_actual_upstream_translation_crosscheck(self):
        p = FakeProxy()
        result = captured(p)
        for stream in result["streams"]:
            regs = SimpleNamespace(ENABLE_STREAMS=[SimpleNamespace(val=0x31)] * 8,
                                   TCR={stream["sid"]: SimpleNamespace(reg=R_TCR(stream["registers"]["tcr"]))},
                                   TTBR={stream["sid"]: SimpleNamespace(reg=R_TTBR(stream["registers"]["ttbr"]))})
            dart = DART8110(p, regs)
            for mapping in snap.walk(stream)[0]:
                # This is the existing upstream walker against the same fake
                # bytes, not another reimplementation of its PTE bitfields.
                for offset, length in ((0, mapping["size"]), (17, mapping["size"] - 31)):
                    self.assertEqual(dart.iotranslate(stream["sid"], mapping["iova"] + offset, length),
                                     [(mapping["pa"] + offset, length)])
            self.assertEqual(dart.iotranslate(stream["sid"], 0, PAGE), [(None, PAGE)])
        self.assertEqual(PTE(entry(PA, 15)).OFFSET << 14, PA)

    def test_correlate_gaps_aliases_and_flag_splits(self):
        item = dict(name="extent", pa=PA + 10, size=2 * PAGE - 10)
        base = [dict(iova=0x10000, pa=PA, size=PAGE, flags=1),
                dict(iova=0x14000, pa=PA + PAGE, size=PAGE, flags=9)]
        self.assertEqual(snap.correlate(item, base)["full_contiguous_address_aliases"], [0x1000A])
        for key, value in (("iova", 0x18000), ("pa", PA + 2 * PAGE)):
            changed = copy.deepcopy(base)
            changed[1][key] = value
            self.assertEqual(snap.correlate(item, changed)["full_contiguous_address_aliases"], [])

    def test_publication_no_clobber_or_partial_file(self):
        source = captured()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "snapshot.json"
            snap.save_new(source, path)
            first = path.read_bytes()
            self.assertEqual(json.loads(first), source)
            self.assertEqual(path.stat().st_mode & 0o777, 0o400)
            with self.assertRaises(FileExistsError):
                snap.save_new(source, path)
            self.assertEqual(path.read_bytes(), first)
            self.assertEqual(list(Path(tmp).iterdir()), [path])
            invalid = copy.deepcopy(source)
            invalid["hardware_acceptance"] = True
            with self.assertRaises(ValueError):
                snap.save_new(invalid, Path(tmp) / "bad.json")
            self.assertFalse((Path(tmp) / "bad.json").exists())

    def test_offline_cli_and_claim_rejections(self):
        source = captured()
        for key in ("hardware_acceptance", "atomic_snapshot", "cache_coherency_proven",
                    "remote_loader_identity_verified"):
            changed = copy.deepcopy(source)
            changed[key] = True
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "claims"):
                snap.analyze(changed)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "snapshot.json"
            snap.save_new(source, path)
            old = sys.argv
            try:
                sys.argv = ["retained-dart-snapshot.py", str(path)]
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    snap.main()
                self.assertEqual(json.loads(output.getvalue()), snap.analyze(source))
                oversized = Path(tmp) / "oversized.json"
                with oversized.open("wb") as out:
                    out.write(b" " * (snap.MAX_FILE + 1))
                sys.argv = ["retained-dart-snapshot.py", str(oversized)]
                with self.assertRaisesRegex(ValueError, "file budget"):
                    snap.main()
            finally:
                sys.argv = old

    def test_actual_transport_checksums(self):
        from m1n1.proxy import UartInterface, UartChecksumError
        data = b"synthetic table bytes"
        packet = SimpleNamespace(enabled_features=0, debug=False, REQ_MEMREAD=UartInterface.REQ_MEMREAD,
                                 cmd=lambda opcode, args: None, readfull=lambda size: data)
        packet.data_checksum = lambda value: UartInterface.checksum(packet, value)
        packet.reply = lambda opcode: u32(packet.data_checksum(data))
        self.assertEqual(UartInterface.readmem(packet, RAM, len(data)), data)
        packet.reply = lambda opcode: u32(packet.data_checksum(data) ^ 1)
        with self.assertRaises(UartChecksumError):
            UartInterface.readmem(packet, RAM, len(data))

    def test_provenance_required_not_attestation(self):
        source = captured()
        for key in ("captured_utc", "collector_sha256", "bootargs_sha256", "adt_sha256",
                    "controller_sources_sha256"):
            for value in (None, "bad"):
                changed = copy.deepcopy(source)
                if value is None:
                    changed.pop(key)
                else:
                    changed[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    snap.analyze(changed)
        for value in ("2026-09-06T01:00:00", "2026-09-06T01:00:00+01:00"):
            changed = copy.deepcopy(source)
            changed["captured_utc"] = value
            with self.subTest(timestamp=value), self.assertRaisesRegex(ValueError, "UTC"):
                snap.analyze(changed)
        for value in (-1, True, 1 << 32):
            changed = copy.deepcopy(source)
            changed["streams"][0]["registers"]["params4"] = value
            with self.subTest(register=value), self.assertRaisesRegex(ValueError, "register words"):
                snap.analyze(changed)


if __name__ == "__main__":
    unittest.main()
