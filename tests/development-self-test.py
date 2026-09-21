#!/usr/bin/env python3
"""Offline packaging checks; synthetic inputs, never devices or a kernel boot."""
import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("development", PROJECT / "scripts/development-candidate.py")
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class DevelopmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="m3dev-test-")
        self.project = Path(self.temporary.name).resolve()
        (self.project / "out/isolated").mkdir(parents=True)
        for name in ("scripts/development-candidate.py", "scripts/dualboot-candidate.py", "scripts/lib/evidence.sh", "initramfs/development/init"):
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, path)
        self.roots = {}
        self.release = "7.1.9.fixture"
        for kind, names in dev.base.SOURCE_FILES.items():
            parent = self.project / "out" / ("milestone1/initramfs" if kind == "initramfs" else "milestone0/" + kind)
            root = parent / "20260906-fixture"
            root.mkdir(parents=True)
            (parent / "latest").symlink_to(root.name)
            self.roots[kind] = root
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((kind + name).encode())
            (root / "manifest.txt").write_text("source_date_epoch=1787212057\n")
            verifier = "verify-milestone1-initramfs.sh" if kind == "initramfs" else "verify-" + kind + ".sh"
            path = self.project / "scripts" / verifier
            path.write_text('#!/bin/sh\ntest ! -e "$1/fail-verifier"\n')
            path.chmod(0o700)
        self.linux = self.roots["linux-full"]
        (self.linux / "kernelrelease").write_text(self.release + "\n")
        self.notes = b"\x04\0\0\0\x14\0\0\0\x03\0\0\0GNU\0" + b"N" * 20
        elf = bytearray(512); elf[:6] = b"\x7fELF\x02\x01"; elf[18:20] = b"\xb7\0"
        struct.pack_into("<Q", elf, 40, 64); struct.pack_into("<HHH", elf, 58, 64, 3, 1)
        names = b"\0.shstrtab\0.notes\0"
        struct.pack_into("<IIQQQQIIQQ", elf, 128, 1, 3, 0, 0, 256, len(names), 0, 0, 1, 0)
        struct.pack_into("<IIQQQQIIQQ", elf, 192, names.index(b".notes"), 7, 2, 0, 320, len(self.notes), 0, 0, 4, 0)
        elf[256:256+len(names)] = names; elf[320:320+len(self.notes)] = self.notes
        (self.linux / "vmlinux").write_bytes(elf)
        (self.linux / "config").write_text("".join(key + "=m\n" for key in dev.MODULAR_GATES))
        self.modules = self.linux / "modules/lib/modules" / self.release
        self.modules.mkdir(parents=True)
        for name in dev.MODULES:
            path = self.modules / name
            path.parent.mkdir(parents=True, exist_ok=True)
            elf = bytearray(64)
            elf[:6] = b"\x7fELF\x02\x01"
            elf[18:20] = b"\xb7\x00"
            path.write_bytes(elf + b"\x00vermagic=" + self.release.encode() + b" SMP\x00")
        (self.modules / "modules.dep").write_text("".join(x + ":\n" for x in dev.MODULES))
        (self.modules / "modules.softdep").write_text("# fixture\n")
        (self.roots["initramfs"] / "bin").mkdir()
        (self.roots["initramfs"] / "bin/busybox").write_bytes(b"fixture-static-busybox")
        self.rehash_sources()
        self.output = self.project / "out/isolated/dualboot-dev-fixture"
        self.patch_dtb = mock.patch.object(dev, "disable_nvme", side_effect=lambda src, dst: dst.write_bytes(src.read_bytes() + b"\x00disabled"))
        self.patch_dtb.start()

    def tearDown(self):
        self.patch_dtb.stop()
        for directory, dirs, files in os.walk(self.project):
            os.chmod(directory, 0o700)
            for name in files:
                path = Path(directory) / name
                if not path.is_symlink(): path.chmod(0o600)
        self.temporary.cleanup()

    def rehash_sources(self):
        for root in self.roots.values():
            (root / "SHA256SUMS").write_text(dev.checksum_text(root))

    def build(self, output=None, kernel=None):
        with contextlib.redirect_stdout(io.StringIO()): dev.build(self.project, output or self.output, kernel)

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()): dev.verify(self.project, self.output)

    def mutable(self, kernel=None):
        self.build(kernel=kernel)
        for p in self.output.rglob("*"): p.chmod(0o700 if p.is_dir() else 0o600)
        self.output.chmod(0o700)

    def rehash(self):
        (self.output / "SHA256SUMS").write_text(dev.checksum_text(self.output))

    def development_linux(self):
        root = self.project / "out/isolated/dev-kernel-fixture/milestone0/linux-development-framebuffer/20260906T000000Z-1-0123456789abcdef"
        shutil.copytree(self.linux, root)
        release = self.release + "-m3devfb1"
        modules = root / "modules/lib/modules" / release
        (root / "modules/lib/modules" / self.release).rename(modules)
        for path in modules.rglob("*.ko"):
            path.write_bytes(path.read_bytes().replace(self.release.encode(), release.encode()))
        (root / "kernelrelease").write_text(release + "\n")
        (root / "Image").write_bytes(b"different framebuffer Image fixture")
        data = bytearray((root / "vmlinux").read_bytes()); data[320+len(self.notes)-1] = ord("F")
        (root / "vmlinux").write_bytes(data)
        (root / "SHA256SUMS").write_text(dev.checksum_text(root))
        return root, release

    def test_development_kernel_roundtrip_and_separate_verifier_environment(self):
        kernel, release = self.development_linux()
        original = dev.base.snapshot(self.roots)
        with mock.patch.object(dev.subprocess, "run", wraps=subprocess.run) as calls:
            self.build(kernel=kernel); self.verify()
        commands = [call for call in calls.call_args_list if call.args[0][0].endswith("verify-linux-full.sh")]
        self.assertEqual(len(commands), 4)
        for call in commands:
            if len(call.args[0]) == 3:
                self.assertEqual(call.args[0][1:], [str(kernel), "--development-framebuffer"])
                self.assertEqual(call.kwargs["env"]["MILESTONE0_OUTPUT_ROOT"], str(kernel.parents[2]))
            else:
                self.assertEqual(call.args[0][1:], [str(self.linux)])
                self.assertNotIn("MILESTONE0_OUTPUT_ROOT", call.kwargs["env"])
        for call in calls.call_args_list:
            if call.args[0][0].endswith("verify-milestone1-initramfs.sh"):
                self.assertEqual(call.args[0][-1], str(self.linux))
        metadata = json.loads((self.output / "manifest.json").read_text())
        self.assertTrue(metadata["kernel_rebuilt"])
        self.assertEqual(metadata["kernel_profile"], "framebuffer-v1")
        self.assertEqual(metadata["sources"]["development-kernel"]["output_root"], "dev-kernel-fixture")
        self.assertEqual(metadata["kernel_release"], release)
        self.assertEqual(gzip.decompress((self.output / "components/Image.gz").read_bytes()), (kernel / "Image").read_bytes())
        self.assertNotEqual(metadata["kernel_notes_sha256"], dev.hash_bytes(self.notes))
        self.assertEqual(dev.base.snapshot(self.roots), original)
        self.assertTrue((self.output / "checks/development-kernel.log").is_file())
        other = self.output.with_name("dualboot-dev-repeat-framebuffer")
        self.build(other, kernel)
        self.assertEqual((other / "SHA256SUMS").read_bytes(), (self.output / "SHA256SUMS").read_bytes())

    def test_development_kernel_rejects_staging_latest_and_external_paths(self):
        kernel, _ = self.development_linux()
        latest = kernel.parent / "latest"; latest.symlink_to(kernel.name)
        stage = kernel.parent / ("." + kernel.name + ".tmp"); stage.mkdir()
        outside = self.project / kernel.name; outside.mkdir()
        for path in (latest, stage, self.linux, outside):
            with self.subTest(path=path), self.assertRaises(ValueError): self.build(kernel=path)
            self.assertFalse(self.output.exists())

    def test_development_kernel_verifier_failure_does_not_publish(self):
        kernel, _ = self.development_linux()
        (kernel / "fail-verifier").touch()
        with self.assertRaisesRegex(ValueError, "verifier failed: development-kernel"): self.build(kernel=kernel)
        self.assertFalse(self.output.exists())
        self.assertTrue(list((self.project / "out/isolated").glob(".m3dev-*")))  # Failed stages stay diagnostic-only.

    def test_selected_kernel_modular_gates_cannot_fall_back_to_original(self):
        kernel, _ = self.development_linux()
        for changed in dev.MODULAR_GATES:
            (kernel / "config").write_text("".join(key + ("=y\n" if key == changed else "=m\n") for key in dev.MODULAR_GATES))
            (kernel / "SHA256SUMS").write_text(dev.checksum_text(kernel))
            with self.subTest(setting=changed), self.assertRaisesRegex(ValueError, "must remain modular"):
                self.build(kernel=kernel)
            self.assertFalse(self.output.exists())

    def test_selected_kernel_mutation_after_verification_blocks_publication(self):
        kernel, release = self.development_linux()
        validate = dev.validate_sources
        for name in ("modules/lib/modules/" + release + "/" + dev.MODULES[0], "vmlinux", "dtbs/apple/t6030-j514s.dtb"):
            path = kernel / name; original = path.read_bytes()
            def mutate(project, roots, logs=None):
                validate(project, roots, logs)
                path.write_bytes(original + b"changed after verification")
            with self.subTest(name=name), mock.patch.object(dev, "validate_sources", side_effect=mutate):
                with self.assertRaises(ValueError): self.build(kernel=kernel)
            self.assertFalse(self.output.exists())
            path.write_bytes(original)

    def test_recorded_development_source_cannot_escape_or_be_overridden(self):
        kernel, _ = self.development_linux()
        self.mutable(kernel)
        path = self.output / "manifest.json"; original = path.read_bytes()
        for key, value in (("output_root", "../outside"), ("run_id", "../../outside"), ("run_id", "latest")):
            metadata = json.loads(original)
            metadata["sources"]["development-kernel"][key] = value
            path.write_text(json.dumps(metadata)); self.rehash()
            with self.assertRaisesRegex(ValueError, "invalid recorded development kernel"): self.verify()
        metadata = json.loads(original)
        with self.assertRaisesRegex(ValueError, "cannot override"):
            dev.source_roots(self.project, metadata["sources"], kernel=kernel)
        metadata["sources"]["unapproved-role"] = {}
        with self.assertRaisesRegex(ValueError, "unexpected source roles"):
            dev.source_roots(self.project, metadata["sources"])

    def test_roundtrip_and_repeat_payload(self):
        self.build(); self.verify()
        other = self.output.with_name("dualboot-dev-repeat")
        self.build(other)
        self.assertEqual((other / "esp/m1n1/boot.bin").read_bytes(), (self.output / "esp/m1n1/boot.bin").read_bytes())
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o500)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertFalse(manifest["hardware_acceptance"])
        self.assertFalse(manifest["boot_authorized"])
        self.assertEqual(manifest["format"], 4)
        self.assertEqual(manifest["kernel_notes_sha256"], dev.hash_bytes(self.notes))

    def test_kernel_notes_and_all_component_binding(self):
        self.assertEqual(dev.elf_notes((self.linux / "vmlinux").read_bytes()), self.notes)
        before = dev.root_files(self.project, self.roots)["etc/m3dev/console-binding"]
        for root, name in ((self.linux, "Image"), (self.linux, "dtbs/apple/t6030-j514s.dtb"),
                           (self.roots["m1n1"], "m1n1.bin"), (self.roots["initramfs"], "bin/busybox")):
            original = (root / name).read_bytes()
            (root / name).write_bytes(original + b"changed")
            self.rehash_sources()
            self.assertNotEqual(dev.root_files(self.project, self.roots)["etc/m3dev/console-binding"], before, name)
            (root / name).write_bytes(original); self.rehash_sources()
        for offset, value in ((4, 1), (18, 1), (60, 0), (196, 1), (200, 0)):
            data = bytearray((self.linux / "vmlinux").read_bytes()); data[offset] = value
            with self.assertRaises(ValueError): dev.elf_notes(data)
        with self.assertRaises(ValueError): dev.elf_notes(b"short")

    def test_cpio_metadata_inventory_and_no_device_nodes(self):
        packed = dev.archive(dev.root_files(self.project, self.roots), 1787212057)
        raw = gzip.decompress(packed); offset = 0; entries = {}
        while True:
            header = raw[offset:offset+110]
            self.assertEqual(header[:6], b"070701")
            numbers = [int(header[x:x+8], 16) for x in range(6, 110, 8)]
            _, mode, uid, gid, links, epoch, size, _, _, major, minor, namesize, checksum = numbers
            name = raw[offset+110:offset+110+namesize-1].decode()
            offset = (offset+110+namesize+3) & ~3
            data = raw[offset:offset+size]
            offset = (offset+size+3) & ~3
            if name == "TRAILER!!!": break
            self.assertNotIn(name, entries); entries[name] = data
            self.assertEqual((uid, gid, major, minor, checksum), (0,0,0,0,0))
            self.assertEqual(epoch, 1787212057)
            self.assertIn(mode & 0o170000, (0o040000,0o100000,0o120000))
            self.assertFalse(any(x in name for x in ("nvme", "modprobe", "efivar", "dev/mem", "drivers/spi/")))
        self.assertEqual(entries["init"], (PROJECT / "initramfs/development/init").read_bytes())
        self.assertEqual(entries["bin/sh"], b"busybox")
        if shutil.which("bsdtar"):
            result = subprocess.run(["bsdtar", "-tf", "-"], input=packed, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_existing_and_non_development_destination(self):
        self.output.mkdir()
        with self.assertRaises(ValueError): self.build()
        with self.assertRaises(ValueError): self.build(self.output.with_name("dualboot-canonical"))

    def test_rejects_builtin_storage_usb_pcie_and_dart(self):
        for changed in dev.MODULAR_GATES:
            (self.linux / "config").write_text("".join(key + ("=y\n" if key == changed else "=m\n") for key in dev.MODULAR_GATES))
            self.rehash_sources()
            with self.assertRaisesRegex(ValueError, "must remain modular"): self.build()

    def test_rejects_storage_dependency_cycle_and_wrong_order(self):
        for dependency in ("kernel/drivers/nvme/host/nvme-apple.ko", dev.MODULES[0], dev.MODULES[-1]):
            (self.modules / "modules.dep").write_text("".join(x + ":" + (" " + dependency if i==0 else "") + "\n" for i,x in enumerate(dev.MODULES)))
            self.rehash_sources()
            with self.assertRaisesRegex(ValueError, "dependency"): dev.module_inputs(self.linux)

    def test_rejects_softdep(self):
        (self.modules / "modules.softdep").write_text("softdep apple_dart pre: nvme_apple\n")
        self.rehash_sources()
        with self.assertRaisesRegex(ValueError, "soft dep|soft dep|soft dependencies"): self.build()

    def test_rejects_wrong_module_architecture_vermagic_and_hash(self):
        path = self.modules / dev.MODULES[0]
        original = path.read_bytes()
        for data, rehash in ((b"bad",True), (original.replace(self.release.encode(),b"wrong.version"),True), (original+b"changed",False)):
            path.write_bytes(data)
            if rehash: self.rehash_sources()
            with self.assertRaises(ValueError): dev.module_inputs(self.linux)

    def test_rehashed_payload_dtb_init_module_and_extra_file_tampering(self):
        self.mutable()
        names = ["esp/m1n1/boot.bin", "components/t6030-j514s.dtb", "rootfs/init",
                 "rootfs/lib/modules/"+self.release+"/"+dev.MODULES[0]]
        for name in names:
            path=self.output/name; original=path.read_bytes(); path.write_bytes(original+b"changed"); self.rehash()
            with self.assertRaises(ValueError): self.verify()
            path.write_bytes(original); self.rehash()
        (self.output/"rootfs/extra").write_text("not approved"); self.rehash()
        with self.assertRaisesRegex(ValueError,"unexpected"): self.verify()

    def test_source_verifier_failure(self):
        (self.linux / "fail-verifier").touch()
        with self.assertRaisesRegex(ValueError,"verifier failed"): self.build()
        self.assertFalse(self.output.exists())

    def test_real_dtb_transformation_changes_only_nvme_status(self):
        self.patch_dtb.stop()
        source = self.project / "source.dtb"
        target = self.project / "target.dtb"
        dts = b'''/dts-v1/; / { model = "fixture"; soc {
          nvme@38dcc0000 { compatible = "apple,t6030-nvme-ans3", "apple,t8103-nvme-ans2"; status = "okay"; };
          other { compatible = "fixture,untouched"; status = "okay"; };
        }; };'''
        subprocess.run(["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", str(source)], input=dts, check=True)
        original = source.read_bytes()
        dev.disable_nvme(source, target)
        self.assertEqual(source.read_bytes(), original)
        for node, value in ((dev.NVME_NODE, "disabled"), ("/soc/other", "okay")):
            self.assertEqual(subprocess.check_output(["fdtget", "-t", "s", str(target), node, "status"], text=True).strip(), value)
        subprocess.run(["fdtput", "-t", "s", str(source), dev.NVME_NODE, "compatible", "unexpected,chip"], check=True)
        with self.assertRaisesRegex(ValueError, "unexpected NVMe"): dev.disable_nvme(source, target)

    def test_additional_source_mutation_after_verification_fails(self):
        original = dev.base.validate_sources
        def mutate(project, roots, logs=None):
            original(project, roots, logs)
            (self.modules / dev.MODULES[0]).write_bytes(b"changed during verification")
        with mock.patch.object(dev.base, "validate_sources", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"): self.build()
        self.assertFalse(self.output.exists())

    def test_module_symlinks_and_duplicate_inventory_fail(self):
        path = self.modules / dev.MODULES[0]
        original = path.read_bytes()
        path.unlink(); path.symlink_to(self.modules / dev.MODULES[1])
        with self.assertRaisesRegex(ValueError, "symlink"): dev.module_inputs(self.linux)
        path.unlink(); path.write_bytes(original)
        inventory = self.linux / "SHA256SUMS"
        line = next(line for line in inventory.read_text().splitlines() if dev.MODULES[0] in line)
        inventory.write_text(inventory.read_text() + line + "\n")
        with self.assertRaisesRegex(ValueError, "uniquely inventoried"): dev.module_inputs(self.linux)

    def test_extra_directory_symlink_and_hardlink_fail(self):
        self.mutable()
        extra = self.output / "extra"
        extra.mkdir()
        with self.assertRaisesRegex(ValueError, "directory"): self.verify()
        extra.rmdir()
        extra.symlink_to(self.output / "manifest.json")
        with self.assertRaisesRegex(ValueError, "symlink"): self.verify()
        extra.unlink()
        os.link(self.output / "manifest.json", extra)
        with self.assertRaisesRegex(ValueError, "hardlink"): self.verify()

    def test_archive_epoch_is_bounded(self):
        for epoch in (-1, 0x100000000, "0"):
            with self.assertRaisesRegex(ValueError, "epoch"): dev.archive({}, epoch)

    def test_dt_tool_version_and_recorded_identity_are_enforced(self):
        original = subprocess.check_output
        def wrong_version(command, **kwargs):
            if command[-1] == "-V": return "Version: DTC unexpected\n"
            return original(command, **kwargs)
        with mock.patch.object(subprocess, "check_output", side_effect=wrong_version):
            with self.assertRaisesRegex(ValueError, "unapproved"): dev.dt_tools()
        self.mutable()
        actual = dev.dt_tools()
        actual["fdtget"]["sha256"] = "0" * 64
        with mock.patch.object(dev, "dt_tools", return_value=actual):
            with self.assertRaisesRegex(ValueError, "metadata mismatch"): self.verify()

    def test_dart_is_separate_and_spi_never_packaged(self):
        files = dev.root_files(self.project, self.roots)
        self.assertNotIn(b"apple-dart", files["etc/m3dev/core.order"])
        self.assertIn(b"apple-dart", files["etc/m3dev/dart.order"])
        self.assertFalse(any("drivers/spi/" in name for name in files))


if __name__ == "__main__": unittest.main()
