#!/usr/bin/env python3
"""J514s retained DART evidence. CLI analyzes files only; never connects/boots.

capture(proxy, approved_stage=STAGE) is for a separately approved, exclusive
m1n1 proxy session before Linux. No setup/ProxyUtils/DART constructors. Only
checksum negotiation, exception-counter reads/resets, and bounded target reads.
This is not a quiescence, cache-coherency, native-support or boot-safety proof.
"""

import argparse
from bisect import bisect_right
import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import struct
import tempfile

PAGE = 0x4000
MAX_ADT = 4 << 20
MAX_REGION = 1 << 20
MAX_FILE = 8 << 20
MAX_VISITS = 512
MAX_LEAVES = 131072
STAGE = "approved-exclusive-m1n1-before-linux"
FIRMWARE = "iBoot-10151.140.19.700.2"
STREAMS = (("dcp", "dart-dcp", "mapper-dcp", 5, 0x28D30C000),
           ("display", "dart-disp0", "mapper-disp0", 0, 0x28D304000),
           ("piodma", "dart-disp0", "mapper-disp0-piodma", 4, 0x28D304000))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def controller_sources():
    import m1n1.adt
    root = Path(m1n1.adt.__file__).parent
    return {name: digest((root / name).read_bytes()) for name in
            ("adt.py", "tgtypes.py", "utils.py", "hw/dart8110.py", "proxy.py")}


def extent(start, size, lower=0, upper=1 << 42):
    require(isinstance(start, int) and not isinstance(start, bool) and
            isinstance(size, int) and not isinstance(size, bool) and size > 0 and
            lower <= start < start + size <= upper, "invalid address extent")


def raw(node, name):
    from m1n1.adt import build_prop
    require(name in node._properties, f"missing ADT property {name}")
    return build_prop(node._path, name, node.getprop(name),
                      t=node._types.get(name, (None, False))[0])


def metadata(data, ram):
    from m1n1.adt import load_adt
    # The upstream parser prints raw properties on errors. Do not leak them.
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            adt = load_adt(data)
    except Exception:
        raise ValueError("ADT parse failed; raw properties suppressed") from None
    chosen = adt["/chosen"]
    require(adt.model == "Mac15,6" and "J514sAP" in adt.compatible and
            chosen.getprop("chip-id") == 0x6030 and chosen.getprop("board-id") == 4 and
            "arm-io,t6030" in adt["/arm-io"].compatible, "wrong target identity")
    require(raw(chosen, "firmware-version").rstrip(b"\0") == FIRMWARE.encode(),
            "unsupported firmware ABI")
    result = []
    handles = []
    for name, dart, mapper, sid, base in STREAMS:
        node = adt[f"/arm-io/{dart}"]
        child = node[mapper]
        require("dart,t8110" in node.compatible and node.get_reg(0) == (base, PAGE) and
                child.reg == sid, "unexpected DART topology")
        handles.append(child.getprop("AAPL,phandle"))
        region, root = raw(node, f"pt-region-{sid}"), raw(node, f"l2-tt-{sid}")
        require(len(region) == len(root) == 16, "unsupported retained-table metadata")
        start, end = struct.unpack("<QQ", region)
        l2, marker = struct.unpack("<QQ", root)
        extent(start, end - start, *ram)
        require(start % PAGE == end % PAGE == 0 and end - start <= MAX_REGION and
                start <= l2 < end and l2 % PAGE == 0 and marker == 2,
                "unsupported retained-table region")
        result.append(dict(name=name, base=base, sid=sid, start=start, end=end,
                           adt_root=l2, adt_root_marker=marker))
    require(len(set(handles)) == 3 and all(type(h) is int and 0 < h < 1 << 32 for h in handles),
            "invalid mapper handles")
    require(raw(adt["/arm-io/dcp"], "iommu-parent") == struct.pack("<I", handles[0]) and
            raw(adt["/arm-io/disp0"], "iommu-parent") == struct.pack("<II", *handles[1:]),
            "unexpected display mapper membership")
    for index, item in enumerate(result):
        require(all(item["end"] <= other["start"] or other["end"] <= item["start"]
                    for other in result[:index]), "overlapping stream table regions")
    extents = []
    carveouts = adt["/chosen/carveout-memory-map"]
    for key in sorted(carveouts._properties):
        if re.fullmatch(r"region-id-[0-9]+", key):
            value = raw(carveouts, key)
            require(len(value) == 16, "unsupported carveout record")
            pa, size = struct.unpack("<QQ", value)
            if pa == size == 0:
                continue
            extent(pa, size, *ram)
            extents.append(dict(name=key, pa=pa, size=size))
    require(0 < len(extents) <= 128, "missing/excessive runtime carveouts")
    vram = raw(adt["/vram"], "reg")
    require(len(vram) == 16, "unsupported framebuffer extent")
    pa, size = struct.unpack("<QQ", vram)
    extent(pa, size, *ram)
    extents.append(dict(name="vram", pa=pa, size=size))
    segments = raw(adt["/arm-io/dcp/iop-dcp-nub"], "segment-ranges")
    require(0 < len(segments) <= 64 * 32 and len(segments) % 32 == 0,
            "unsupported DCP segment records")
    for index, (pa, iova, remap, size, unknown) in enumerate(struct.iter_unpack("<QQQII", segments)):
        extent(pa, size, *ram)
        extents.append(dict(name=f"dcp-segment-{index}", pa=pa, size=size,
                            reported_iova=iova, reported_remap=remap, unknown=unknown))
    return dict(identity=dict(model="Mac15,6", chip_id=0x6030, board_id=4,
                              firmware=FIRMWARE), ram=list(ram), streams=result, extents=extents)


def read_exact(iface, address, size):
    data = iface.readmem(address, size)
    require(isinstance(data, bytes) and len(data) == size, "short target read")
    return data


def fresh_metadata(proxy):
    from m1n1.tgtypes import BootArgs_r1, BootArgs_r2, BootArgs_r3
    address = proxy.get_bootargs()
    extent(address, 2, 0x800000000)
    revision = struct.unpack("<H", read_exact(proxy.iface, address, 2))[0]
    layout = {1: BootArgs_r1, 2: BootArgs_r2, 3: BootArgs_r3}.get(revision)
    require(layout is not None, "unsupported bootargs revision")
    extent(address, layout.sizeof(), 0x800000000)
    data = read_exact(proxy.iface, address, layout.sizeof())
    ba = layout.parse(data)
    require(ba.revision == revision, "changing bootargs revision")
    # Match m1n1's identity-mapped RAM envelope. This does not prove that MCC
    # permits a particular read; checksum-enabled proxy errors still propagate.
    start = ba.phys_base & ~0xFFFFFFFF
    extent(start, ba.mem_size_actual)
    require(start >= 0x800000000 and ba.mem_size_actual <= 128 << 30,
            "unsupported physical RAM envelope")
    ram = (start, start + ba.mem_size_actual)
    extent(address, len(data), *ram)
    extent(ba.phys_base, ba.mem_size, *ram)
    adt_address = (ba.devtree - ba.virt_base + ba.phys_base) & ((1 << 64) - 1)
    require(0 < ba.devtree_size <= MAX_ADT, "invalid ADT size")
    extent(adt_address, ba.devtree_size, *ram)
    adt = read_exact(proxy.iface, adt_address, ba.devtree_size)
    result = metadata(adt, ram)
    result.update(bootargs_sha256=digest(data), adt_sha256=digest(adt))
    return result


def read_registers(proxy, stream):
    offsets = dict(params0=0, params4=4, params8=8, paramsc=12, protect=0x200,
                   enabled=0xC00 + 4 * (stream["sid"] // 32),
                   tcr=0x1000 + 4 * stream["sid"], ttbr=0x1400 + 4 * stream["sid"])
    result = {}
    for key, offset in offsets.items():
        value = proxy.read32(stream["base"] + offset)
        require(proxy.get_exc_count() == 0, "DART register read fault")
        require(type(value) is int and 0 <= value < 1 << 32, "invalid register response")
        result[key] = value
    return result


def layout(stream, registers):
    tcr, ttbr = registers["tcr"], registers["ttbr"]
    bits = (registers["params8"] >> 16) & 63
    require((registers["params0"] >> 24) & 15 == 14 and
            (registers["params8"] >> 24) & 63 == 42 and 36 <= bits <= 47,
            "unsupported DART address geometry")
    require(registers["paramsc"] & 511 > stream["sid"] and
            registers["enabled"] & (1 << (stream["sid"] % 32)), "stream disabled/absent")
    require(tcr & 1 and not tcr & ~0xD and ttbr & 1 and not ttbr & 0xC0000002,
            "unsupported translation mode/root")
    root = ((ttbr >> 2) & 0xFFFFFFF) << 14
    require(stream["start"] <= root < stream["end"], "root outside declared region")
    four = bool(tcr & 8)
    require(not four or bits > 36, "invalid four-level width")
    # l2-tt is only understood for the legacy two-memory-table format.
    require(not four and root == stream["adt_root"], "unsupported retained metadata/layout pairing")
    return root, (25, 14), 36


def capture(proxy, *, approved_stage=None):
    """Return evidence from an existing exclusive session. Never boot/connect.

    Caller must separately approve the read experiment and assert this stage.
    Proxy protocol housekeeping changes checksum mode and exception counters;
    no device register, table, heap, cache, ADT or boot-policy writes are issued.
    """
    require(approved_stage == STAGE, "separate capture approval/stage required")
    iface = proxy.iface
    require(not iface.debug and not proxy.debug, "disable raw protocol debug logging")
    # Standard nop() advertises DISABLE_DATA_CSUMS on USB. Request no features
    # instead so REQ_MEMREAD probes the entire range under GUARD_RETURN.
    iface.cmd(iface.REQ_NOP, struct.pack("<Q", 0))
    negotiated = struct.unpack("<QQQ", iface.reply(iface.REQ_NOP))[0]
    require(negotiated == 0, "checksum-enabled transport required")
    iface.enabled_features = 0
    require(proxy.get_exc_count() == 0, "preexisting target exception")
    meta = fresh_metadata(proxy)
    before = [read_registers(proxy, s) for s in meta["streams"]]
    for stream, registers in zip(meta["streams"], before):
        layout(stream, registers)
    pages = [read_exact(iface, s["start"], s["end"] - s["start"]) for s in meta["streams"]]
    # Bracket two complete passes, not cached table walks. Does not prevent ABA
    # changes or supply a cache-coherency/quiescence guarantee.
    require(before == [read_registers(proxy, s) for s in meta["streams"]], "registers changed")
    require(pages == [read_exact(iface, s["start"], s["end"] - s["start"])
                      for s in meta["streams"]], "page tables changed")
    require(before == [read_registers(proxy, s) for s in meta["streams"]], "registers changed")
    require(meta == fresh_metadata(proxy), "bootargs/ADT changed")
    require(proxy.get_exc_count() == 0, "target exception during capture")
    for stream, registers, data in zip(meta["streams"], before, pages):
        stream.update(registers=registers, data_hex=data.hex(), sha256=digest(data))
    result = dict(schema="j514s-retained-dart-v1", captured_utc=datetime.now(timezone.utc).isoformat(),
                  stage_user_asserted=approved_stage, repeated_reads_equal=True,
                  hardware_acceptance=False, atomic_snapshot=False, cache_coherency_proven=False,
                  remote_loader_identity_verified=False, controller_sources_sha256=controller_sources(),
                  collector_sha256=digest(Path(__file__).read_bytes()), **meta)
    analyze(result)  # Reject malformed/out-of-region tables before publishing.
    return result


def walk(stream):
    # Reuse the pinned controller's bitfield definitions. No DART/RegMap instance.
    from m1n1.hw.dart8110 import PTE
    root, shifts, bits = layout(stream, stream["registers"])
    data = bytes.fromhex(stream["data_hex"])
    require(len(data) == stream["end"] - stream["start"] and digest(data) == stream["sha256"],
            "table data length/hash mismatch")
    leaves, visits = [], 0

    def visit(address, level, prefix, ancestors):
        nonlocal visits
        require(stream["start"] <= address <= stream["end"] - PAGE and address % PAGE == 0,
                "table pointer outside declared region")
        require(address not in ancestors, "page-table cycle")
        visits += 1
        require(visits <= MAX_VISITS, "table traversal budget exceeded")
        offset = address - stream["start"]
        for index, (value,) in enumerate(struct.iter_unpack("<Q", data[offset:offset + PAGE])):
            entry = PTE(value)
            if not entry.VALID:
                continue
            iova = prefix | (index << shifts[level])
            require(iova < 1 << bits, "valid entry outside VA width")
            pa = entry.OFFSET << 14
            if level + 1 < len(shifts):
                visit(pa, level + 1, iova, ancestors | {address})
            else:
                require(len(leaves) < MAX_LEAVES, "leaf traversal budget exceeded")
                leaves.append(dict(iova=iova, pa=pa, size=PAGE,
                                   flags=value & ~(((1 << 28) - 1) << 10)))

    visit(root, 0, 0, set())
    ranges = []
    for leaf in leaves:
        if (ranges and ranges[-1]["iova"] + ranges[-1]["size"] == leaf["iova"] and
                ranges[-1]["pa"] + ranges[-1]["size"] == leaf["pa"] and
                ranges[-1]["flags"] == leaf["flags"]):
            ranges[-1]["size"] += PAGE
        else:
            ranges.append(leaf.copy())
    return ranges, len(leaves), visits


def correlate(item, mappings):
    start, end = item["pa"], item["pa"] + item["size"]
    intervals, aliases = [], []
    starts = [m["iova"] for m in mappings]
    for mapping in mappings:
        lower, upper = max(start, mapping["pa"]), min(end, mapping["pa"] + mapping["size"])
        if lower < upper:
            intervals.append((lower, upper))
        if mapping["pa"] <= start < mapping["pa"] + mapping["size"]:
            candidate = mapping["iova"] + start - mapping["pa"]
            pos = start
            index = bisect_right(starts, candidate) - 1
            while index < len(mappings):
                other = mappings[index]
                delta = candidate + pos - start - other["iova"]
                if not 0 <= delta < other["size"] or other["pa"] + delta != pos:
                    break
                pos = min(end, pos + other["size"] - delta)
                if pos == end:
                    aliases.append(candidate)
                    break
                index += 1
    covered, previous = 0, start
    for lower, upper in sorted(intervals):
        covered += max(0, upper - max(previous, lower))
        previous = max(previous, upper)
    return dict(name=item["name"], address_coverage_bytes=covered,
                full_contiguous_address_aliases=sorted(set(aliases)))


def analyze(snapshot):
    for name in ("collector_sha256", "bootargs_sha256", "adt_sha256"):
        require(isinstance(snapshot.get(name), str) and
                re.fullmatch(r"[0-9a-f]{64}", snapshot[name]), "missing/invalid provenance hash")
    sources = snapshot.get("controller_sources_sha256")
    require(isinstance(sources, dict) and set(sources) ==
            {"adt.py", "tgtypes.py", "utils.py", "hw/dart8110.py", "proxy.py"} and
            all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
                for value in sources.values()), "missing/invalid controller source hashes")
    try:
        captured = datetime.fromisoformat(snapshot["captured_utc"])
    except (KeyError, TypeError, ValueError):
        raise ValueError("missing/invalid UTC acquisition timestamp") from None
    require(captured.tzinfo is not None and captured.utcoffset().total_seconds() == 0,
            "acquisition timestamp must be UTC")
    require(snapshot["schema"] == "j514s-retained-dart-v1" and
            snapshot["identity"] == dict(model="Mac15,6", chip_id=0x6030, board_id=4, firmware=FIRMWARE),
            "wrong snapshot identity/schema")
    require(snapshot["repeated_reads_equal"] is True and snapshot["atomic_snapshot"] is False and
            snapshot["hardware_acceptance"] is False and snapshot["cache_coherency_proven"] is False and
            snapshot["remote_loader_identity_verified"] is False and
            snapshot["stage_user_asserted"] == STAGE, "unsupported snapshot claims/stage")
    ram = snapshot["ram"]
    require(len(ram) == 2, "invalid RAM envelope")
    extent(ram[0], ram[1] - ram[0])
    require(len(snapshot["streams"]) == 3 and 0 < len(snapshot["extents"]) <= 193,
            "invalid snapshot record count")
    result = {}
    for index, (stream, spec) in enumerate(zip(snapshot["streams"], STREAMS)):
        name, _, _, sid, base = spec
        require((stream["name"], stream["sid"], stream["base"]) == (name, sid, base), "wrong stream")
        extent(stream["start"], stream["end"] - stream["start"], *ram)
        require(stream["start"] % PAGE == stream["end"] % PAGE == 0 and
                stream["end"] - stream["start"] <= MAX_REGION and stream["adt_root_marker"] == 2,
                "invalid table region")
        require(all(stream["end"] <= old["start"] or old["end"] <= stream["start"]
                    for old in snapshot["streams"][:index]), "overlapping stream table regions")
        require(set(stream["registers"]) == {"params0", "params4", "params8", "paramsc", "protect",
                                            "enabled", "tcr", "ttbr"} and
                all(type(value) is int and 0 <= value < 1 << 32 for value in stream["registers"].values()),
                "invalid captured register words")
        mappings, count, visits = walk(stream)
        for item in snapshot["extents"]:
            extent(item["pa"], item["size"], *ram)
        result[name] = dict(sid=sid, valid_leaf_entries=count, table_visits=visits, mappings=mappings,
                            extents=[correlate(e, mappings) for e in snapshot["extents"]])
    return dict(hardware_acceptance=False, complete_handoff_contract=False,
                interpretation="Address translations only. Raw flags retained; no access, ownership, "
                               "atomicity, cache-coherency or liveness proof.", streams=result)


def save_new(snapshot, path):
    """Publish complete JSON without replacing any existing artifact."""
    analyze(snapshot)
    data = (json.dumps(snapshot, sort_keys=True, indent=2) + "\n").encode()
    require(len(data) <= MAX_FILE, "snapshot file budget exceeded")
    path = Path(path)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".dart-snapshot-", delete=True) as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
        os.fchmod(output.fileno(), 0o400)
        os.link(output.name, path)  # Atomic, same filesystem, fails if path exists.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path, help="existing capture JSON; offline analysis only")
    args = parser.parse_args()
    with args.snapshot.open("rb") as source:
        data = source.read(MAX_FILE + 1)
    require(len(data) <= MAX_FILE, "snapshot file budget exceeded")
    print(json.dumps(analyze(json.loads(data)), sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
