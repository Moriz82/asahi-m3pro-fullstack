#!/usr/bin/env python3
"""Mutation tests for M1 provenance; fixtures only, no host/device operations."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
project, fixture, identity, digest, controller_id, device, tool_sha, binding, completed = sys.argv[1:]
spec = importlib.util.spec_from_file_location("provenance", Path(project) / "scripts/lib/milestone1-provenance.py")
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
config = (Path(project) / "config/milestone1.env").read_text()
for attr, key in (("MODEL", "M1_TARGET_MODEL"), ("BOARD", "M1_TARGET_BOARD"),
                  ("SCRIPT_SHA", "M1_READINESS_SCRIPT_SHA256"), ("TARGET_AGE", "M1_TARGET_READINESS_MAX_AGE_SECONDS"),
                  ("CONTROLLER_AGE", "M1_PREFLIGHT_MAX_AGE_SECONDS")):
    setattr(p, attr, re.search(r"^" + key + r"=(.+)$", config, re.M)[1])
baseline = p.tree(fixture)
target_files = p.sub(baseline, "target-readiness/")


def rehash(files):
    files = dict(files)
    files["SHA256SUMS"] = "".join(f"{p.sha(data)}  {name}\n" for name, data in sorted(files.items())
                                    if name != "SHA256SUMS").encode()
    return files


def change(files, key, value):
    files = dict(files)
    values = p.fields(files["manifest.txt"].decode())
    if value is None:
        values.pop(key)
    else:
        values[key] = value
    files["manifest.txt"] = "".join(f"{k}={v}\n" for k, v in values.items()).encode()
    return rehash(files)


def verify(files, reference=completed, **overrides):
    args = dict(identity=identity, digest=digest, controller_id=controller_id,
                device=device, tool_sha=tool_sha, binding=binding, reference=reference)
    args.update(overrides)
    return p.controller(files, **args)


def make_execution():
    values = p.fields(baseline["manifest.txt"].decode())
    keys = dict(p.artifact(binding), format="2", status="completed", compression="none", storage_policy="ram-only",
                producer_exit="0", tee_exit="0", pipe_status="0,0", exit="0", tool="/tmp/linux.py", device=device,
                command="fixture --compression none Image dtb initramfs", m1n1_tool_sha256=tool_sha,
                execution_id="fixture-1", execution_started_epoch=str(int(completed) + 1), controller_preflight_completed_epoch=completed,
                controller_preflight_bundle_sha256=p.bundle(baseline, "controller-preflight"))
    for key in p.ROLE_KEYS:
        if key not in keys:
            keys[key] = values[key]
    files = {"preflight/" + name: data for name, data in baseline.items()}
    files.update({"manifest.txt": "".join(f"{k}={v}\n" for k, v in keys.items()).encode(),
                  "host.log": b"fixture only\n", "serial.log": b"fixture only\n"})
    return rehash(files)


class ProvenanceTests(unittest.TestCase):
    def test_historical_freshness_boundaries(self):
        # Current wall-clock is irrelevant to a previously valid execution.
        for delta in (0, 1, 899, 900):
            with self.subTest(delta=delta):
                verify(baseline, str(int(completed) + delta))
        for delta in (-1, 901, 999999):
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                verify(baseline, str(int(completed) + delta))
        with self.assertRaises(ValueError):
            verify(change(baseline, "completed_epoch", str(int(completed) - 1)))

    def test_target_semantics_even_with_rehashed_anchor(self):
        mutations = dict(format="1", kind="controller-preflight", status="blocked", target_model="Mac15,7",
                         target_board="J516s", target_identity_sha256=controller_id, readiness_max_age_seconds="901",
                         dfu_rehearsed="false", sample_restore_verified="false", producer_exit="7", tee_exit="8",
                         pipe_status="0,8", readiness_script_sha256="f" * 64, readiness_sha256="f" * 64,
                         completed_epoch=str(int(completed) - 901), extra="untrusted")
        for key, value in mutations.items():
            candidate = change(target_files, key, value)
            with self.subTest(key=key), self.assertRaises(ValueError):
                p.target(candidate, identity, p.bundle(candidate, "target-readiness"), completed)
        for key in p.fields(target_files["manifest.txt"].decode()):
            candidate = change(target_files, key, None)
            with self.subTest(missing=key), self.assertRaises(ValueError):
                p.target(candidate, identity, p.bundle(candidate, "target-readiness"), completed)

    def test_independent_digest_not_just_self_checksums(self):
        candidate = dict(target_files, **{"readiness.log": b"substituted complete log\n"})
        candidate = change(candidate, "readiness_sha256", p.sha(candidate["readiness.log"]))
        # All internal checksums and semantic fields match; external anchor does not.
        p.target(candidate, identity, p.bundle(candidate, "target-readiness"), completed)
        with self.assertRaisesRegex(ValueError, "independent anchor"):
            p.target(candidate, identity, digest, completed)
        for bad in ("", "0" * 63, "G" * 64):
            with self.subTest(anchor=bad), self.assertRaises(ValueError):
                p.target(target_files, identity, bad, completed)

    def test_controller_mutations(self):
        mutations = dict(format="1", kind="target-readiness", status="failed", preflight_max_age_seconds="901",
                         target_model="Mac15,7", target_board="J516s", target_identity_sha256=controller_id,
                         controller_identity_sha256=identity, target_readiness_bundle_sha256="f" * 64,
                         target_readiness_completed_epoch=str(int(completed) - 1), target_readiness_max_age_seconds="901",
                         device="/dev/cu.changed", m1n1_tool_sha256="f" * 64, image_sha256="f" * 64,
                         completed_epoch=str(int(completed) + 1), extra="untrusted")
        for key, value in mutations.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify(change(baseline, key, value))
        for key in p.fields(baseline["manifest.txt"].decode()):
            with self.subTest(missing=key), self.assertRaises(ValueError):
                verify(change(baseline, key, None))
        for key, value in dict(controller_id=identity, identity="", digest="", device="/dev/disk0",
                               tool_sha="f" * 64, binding=binding + "\nextra=bad").items():
            with self.subTest(external=key), self.assertRaises(ValueError):
                verify(baseline, **{key: value})

    def test_exact_closure(self):
        candidates = []
        for name in baseline:
            candidate = dict(baseline)
            del candidate[name]
            candidates.append(candidate)
        candidates.append(rehash(dict(baseline, extra=b"unexpected")))
        for sums in (b"", baseline["SHA256SUMS"][:-1], baseline["SHA256SUMS"] * 2,
                     b"0" * 64 + b"  /tmp/escape\n", b"0" * 64 + b"  ../escape\n"):
            candidates.append(dict(baseline, SHA256SUMS=sums))
        candidates.append(dict(baseline, **{"manifest.txt": baseline["manifest.txt"] + b"device=duplicate\n"}))
        candidates[-1] = rehash(candidates[-1])
        for index, candidate in enumerate(candidates):
            with self.subTest(index=index), self.assertRaises(ValueError):
                verify(candidate)

    def test_execution_chain(self):
        original = make_execution()
        p.execution(original, identity, {digest})
        for key, value in dict(format="1", execution_started_epoch=str(int(completed) + 901),
                               controller_preflight_completed_epoch=str(int(completed) - 1),
                               target_readiness_completed_epoch=str(int(completed) - 1),
                               controller_preflight_bundle_sha256="f" * 64, target_readiness_bundle_sha256="f" * 64,
                               controller_identity_sha256=identity, target_identity_sha256=controller_id,
                               m1n1_tool_sha256="f" * 64, producer_exit="7", tee_exit="8", status="failed",
                               pipe_status="7,0", exit="1", storage_policy="disk", extra="untrusted").items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                p.execution(change(original, key, value), identity, {digest})
        with self.assertRaises(ValueError):
            p.execution(original, identity, set())
        # Complete inner rehashes cannot replace the independently kept target anchor.
        forged_target = dict(target_files, **{"readiness.log": b"forged target\n"})
        forged_target = change(forged_target, "readiness_sha256", p.sha(forged_target["readiness.log"]))
        forged_digest = p.bundle(forged_target, "target-readiness")
        forged_preflight = dict(baseline)
        forged_preflight.update({"target-readiness/" + k: v for k, v in forged_target.items()})
        forged_preflight = change(forged_preflight, "target_readiness_bundle_sha256", forged_digest)
        forged = dict(original)
        forged.update({"preflight/" + k: v for k, v in forged_preflight.items()})
        forged = change(forged, "target_readiness_bundle_sha256", forged_digest)
        forged = change(forged, "controller_preflight_bundle_sha256", p.bundle(forged_preflight, "controller-preflight"))
        p.execution(forged, identity, {forged_digest})
        with self.assertRaisesRegex(ValueError, "independently anchored"):
            p.execution(forged, identity, {digest})

    def test_filesystem_and_anchor_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "link").symlink_to(Path(fixture) / "manifest.txt")
            with self.assertRaises(ValueError):
                p.tree(root)
            with self.assertRaises((ValueError, OSError)):
                p.anchors(root / "link")
            (root / "real-anchors").mkdir()
            (root / "alias").symlink_to(root / "real-anchors", target_is_directory=True)
            (root / "real-anchors/anchors").write_text(digest + "\n")
            with self.assertRaises(OSError):
                p.anchors(root / "alias/anchors")
            with self.assertRaises(ValueError):
                p.tree("relative")
            for text in ("", digest + "\n" + digest + "\n", "not-a-digest\n"):
                (root / "anchors").write_text(text)
                with self.assertRaises(ValueError):
                    p.anchors(root / "anchors")

    def test_host_inventory_is_hashed_and_role_independent(self):
        record = {"model": p.MODEL.encode() + b"\0", "target-type": p.BOARD,
                  "IOPlatformUUID": "01234567-89AB-CDEF-0123-456789ABCDEF"}
        outputs = []
        with patch.object(p.sys, "platform", "darwin"), patch.object(p.subprocess, "check_output", return_value=plistlib.dumps([record])):
            for role in ("target", "controller"):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    p.main(["host-identity", role])
                outputs.append(output.getvalue().strip())
        self.assertEqual(outputs[0], outputs[1])
        self.assertRegex(outputs[0], r"^[0-9a-f]{64}$")
        self.assertNotIn(record["IOPlatformUUID"], outputs[0])
        record["model"] = b"Mac15,7\0"
        with patch.object(p.sys, "platform", "darwin"), patch.object(p.subprocess, "check_output", return_value=plistlib.dumps([record])):
            with self.assertRaisesRegex(ValueError, "wrong target"):
                p.main(["host-identity", "target"])


unittest.main(argv=[sys.argv[0]], verbosity=2)
