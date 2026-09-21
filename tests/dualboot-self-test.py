#!/usr/bin/env python3
"""Packaging tests use fake source verifiers, never native hardware or real builds."""

import contextlib
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("dualboot", PROJECT / "scripts/dualboot-candidate.py")
dualboot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dualboot)


class DualBootTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dualboot-test-")
        self.project = Path(self.temporary.name).resolve()
        (self.project / "out/isolated").mkdir(parents=True)
        (self.project / "scripts/lib").mkdir(parents=True)
        for relative in ("scripts/dualboot-candidate.py", "scripts/lib/evidence.sh"):
            shutil.copyfile(PROJECT / relative, self.project / relative)
        self.roots = {}
        for name, members in dualboot.SOURCE_FILES.items():
            parent = self.project / "out" / ("milestone1/initramfs" if name == "initramfs" else "milestone0/" + name)
            root = parent / "20260905-fixture"
            root.mkdir(parents=True)
            self.roots[name] = root
            (parent / "latest").symlink_to(root.name)
            for member in members:
                path = root / member
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((name + "/" + member + "\n").encode() * 64)
            verifier = "verify-milestone1-initramfs.sh" if name == "initramfs" else "verify-" + name + ".sh"
            script = self.project / "scripts" / verifier
            script.write_text('#!/bin/bash\nset -eu\n[[ -d "$1" ]]\n'
                              'if [[ -e "$1/fail-verification" ]]; then exit 1; fi\n'
                              'printf "fixture_source_verifier=passed\\n"\n')
            script.chmod(0o700)
        self.destination = self.project / "out/isolated/dualboot-test"

    def tearDown(self):
        for current, dirs, files in os.walk(self.project):
            os.chmod(current, 0o700)
            for name in files:
                path = Path(current) / name
                if not path.is_symlink():
                    path.chmod(0o600)
        self.temporary.cleanup()

    def build(self, destination=None):
        with contextlib.redirect_stdout(io.StringIO()):
            dualboot.build(self.project, str(destination or self.destination))
        return destination or self.destination

    def mutable(self):
        self.build()
        for current, dirs, files in os.walk(self.destination):
            os.chmod(current, 0o700)
            for name in files:
                (Path(current) / name).chmod(0o600)

    def rehash(self):
        (self.destination / "SHA256SUMS").write_text(dualboot.checksums(self.destination))

    def reject(self, text):
        with self.assertRaisesRegex((ValueError, OSError), text), contextlib.redirect_stdout(io.StringIO()):
            dualboot.verify(self.project, self.destination)

    def test_real_cli_roundtrip_and_readonly_publication(self):
        cli = [sys.executable, str(self.project / "scripts/dualboot-candidate.py")]
        result = subprocess.run(cli + ["build", str(self.destination)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(cli + ["verify", str(self.destination)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hardware_acceptance=false", result.stdout)
        self.assertIn("installation_authorized=false", result.stdout)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o500)
        for relative in dualboot.FILES:
            self.assertEqual((self.destination / relative).stat().st_mode & 0o777, 0o400)
        with gzip.open(self.destination / "components/Image.gz", "rb") as stream:
            self.assertEqual(stream.read(), (self.roots["linux-full"] / "Image").read_bytes())
        expected = b"".join((self.destination / "components" / name).read_bytes() for name in dualboot.LAYOUT)
        self.assertEqual(expected, (self.destination / "esp/m1n1/boot.bin").read_bytes())

    def test_second_build_byte_identical(self):
        self.build()
        second = self.build(self.project / "out/isolated/dualboot-repeat")
        for relative in dualboot.FILES:
            self.assertEqual((self.destination / relative).read_bytes(), (second / relative).read_bytes(), relative)

    def test_refuses_existing_and_external_destinations_before_verifiers(self):
        self.destination.mkdir()
        sentinel = self.destination / "keep"
        sentinel.write_text("preserved")
        with mock.patch.object(dualboot, "validate_sources") as verifier:
            for path in (self.destination, self.project, self.project / "out/dualboot-test",
                         self.project / "out/isolated/unprefixed", self.project / "out/isolated/../dualboot-test"):
                with self.subTest(path=str(path)), self.assertRaises(ValueError):
                    dualboot.build(self.project, str(path))
            verifier.assert_not_called()
        self.assertEqual(sentinel.read_text(), "preserved")

    def test_refuses_symlinked_output_parent(self):
        (self.project / "out/isolated").rmdir()
        (self.project / "out/isolated").symlink_to(self.project / "scripts", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.build()

    def test_refuses_escaping_latest(self):
        latest = self.roots["m1n1"].parent / "latest"
        latest.unlink()
        latest.symlink_to(self.roots["linux-full"], target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "outside run root"):
            self.build()
        self.assertFalse(self.destination.exists())

    def test_refuses_symlinked_input_file(self):
        source = self.roots["m1n1"] / "m1n1.bin"
        source.unlink()
        source.symlink_to(self.roots["linux-full"] / "Image")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.build()

    def test_each_source_verifier_failure_prevents_publication(self):
        for name, root in self.roots.items():
            with self.subTest(source=name):
                flag = root / "fail-verification"
                flag.touch()
                with self.assertRaisesRegex(ValueError, "source verifier failed"):
                    self.build()
                flag.unlink()
                self.assertFalse(self.destination.exists())

    def test_source_mutation_during_verification_rejected(self):
        original = dualboot.validate_sources

        def mutate(*args):
            original(*args)
            (self.roots["linux-full"] / "Image").write_bytes(b"changed")

        with mock.patch.object(dualboot, "validate_sources", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "source changed"):
                self.build()
        self.assertFalse(self.destination.exists())

    def test_destination_race_never_overwrites(self):
        original = dualboot.validate_sources

        def claim(*args):
            original(*args)
            self.destination.mkdir()
            (self.destination / "keep").write_text("preserved")

        with mock.patch.object(dualboot, "validate_sources", side_effect=claim):
            with self.assertRaises(subprocess.CalledProcessError):
                self.build()
        self.assertEqual((self.destination / "keep").read_text(), "preserved")
        self.assertEqual({path.name for path in self.destination.iterdir()}, {"keep"})

    def test_rehashed_payload_tamper_rejected(self):
        self.mutable()
        with (self.destination / "esp/m1n1/boot.bin").open("ab") as stream:
            stream.write(b"extra")
        self.rehash()
        self.reject("trailing payload")

    def test_reordered_payload_rejected(self):
        self.mutable()
        (self.destination / "esp/m1n1/boot.bin").write_bytes(b"".join(
            (self.destination / "components" / name).read_bytes() for name in reversed(dualboot.LAYOUT)))
        self.rehash()
        self.reject("order mismatch")

    def test_rehashed_bootargs_even_with_updated_layout_rejected(self):
        self.mutable()
        (self.destination / "components/bootargs.txt").write_bytes(b"chosen.bootargs=root=/dev/nvme0n1p4 rw\n")
        origins = dualboot.snapshot(self.roots)
        (self.destination / "manifest.json").write_text(json.dumps(
            dualboot.metadata(self.project, self.destination, origins), indent=2, sort_keys=True) + "\n")
        self.rehash()
        self.reject("unapproved kernel")

    def test_manifest_false_cannot_be_replaced_by_zero(self):
        self.mutable()
        manifest = self.destination / "manifest.json"
        manifest.write_text(manifest.read_text().replace('"installation_authorized": false', '"installation_authorized": 0'))
        self.rehash()
        self.reject("manifest/layout")

    def test_duplicate_manifest_keys_rejected(self):
        self.mutable()
        manifest = self.destination / "manifest.json"
        manifest.write_text(manifest.read_text().replace('{\n', '{\n  "format": 1,\n', 1))
        self.rehash()
        self.reject("duplicate manifest")

    def test_source_substitution_rejected(self):
        self.mutable()
        (self.roots["linux-full"] / "Image").write_bytes(b"different source")
        self.reject("manifest/layout/source")

    def test_candidate_symlink_and_extra_file_rejected(self):
        self.mutable()
        extra = self.destination / "unexpected"
        extra.touch()
        self.reject("inventory mismatch")
        extra.unlink()
        extra.symlink_to(self.roots["m1n1"] / "m1n1.bin")
        self.reject("symlink")

    def test_hardlinked_candidate_rejected(self):
        self.mutable()
        path = self.destination / "components/m1n1.bin"
        path.unlink()
        os.link(self.roots["m1n1"] / "m1n1.bin", path)
        self.reject("hardlinked")

    def test_gzip_truncation_extra_member_size_and_content(self):
        source = self.roots["linux-full"] / "Image"
        path = self.project / "kernel.gz"
        dualboot.gzip_kernel(source, path)
        data = path.read_bytes()
        expected = {"size": source.stat().st_size, "sha256": dualboot.digest(source)}
        dualboot.check_kernel(path, expected)
        for broken in (data[:-1], data + data, data + b"trailing", data[:-8] + b"\0" * 8):
            path.write_bytes(broken)
            with self.subTest(length=len(broken)), self.assertRaises((ValueError, dualboot.zlib.error)):
                dualboot.check_kernel(path, expected)
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "exceeds"):
            dualboot.check_kernel(path, {**expected, "size": 1})
        with self.assertRaisesRegex(ValueError, "differs"):
            dualboot.check_kernel(path, {**expected, "sha256": "0" * 64})

    def test_environment_cannot_rebind_sources_or_inject_shell_startup(self):
        with mock.patch.dict(os.environ, {"MILESTONE0_OUTPUT_ROOT": "/bad", "MILESTONE1_OUTPUT_ROOT": "/bad",
                                          "M1_READINESS_SCRIPT": "/bad", "BASH_ENV": "/bad", "ENV": "/bad"}):
            env = dualboot.verifier_environment()
        for key in ("MILESTONE0_OUTPUT_ROOT", "MILESTONE1_OUTPUT_ROOT", "M1_READINESS_SCRIPT", "BASH_ENV", "ENV"):
            self.assertNotIn(key, env)

    def test_cli_has_no_install_or_execute_mode(self):
        for action in ("install", "execute", "boot"):
            result = subprocess.run([sys.executable, str(PROJECT / "scripts/dualboot-candidate.py"), action, "/dev/disk0"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
