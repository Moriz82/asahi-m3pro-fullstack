#!/usr/bin/env python3
import gzip
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("archboot", Path(__file__).resolve().parents[1] / "scripts/package-arch-boot.py")
boot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boot)


class Packaging(unittest.TestCase):
    def setUp(self):
        self.kernel = b"\0" * 56 + b"ARM\x64" + b"kernel-data"
        self.dtb = b"\xd0\x0d\xfe\xed" + struct.pack(">I", 40) + b"\0" * 32

    def test_layout_and_initrd_length(self):
        parts = boot.components(b"loader", self.dtb, b"070701early-cpio\x1f\x8bbody", self.kernel)
        self.assertEqual(list(parts), ["m1n1.bin", "bootargs.txt", "t6030-j514s.dtb", "initramfs.m1n1", "Image.gz"])
        wrapped = parts["initramfs.m1n1"]
        self.assertEqual(wrapped[:14], b"m1n1_initramfs")
        self.assertEqual(struct.unpack("<I", wrapped[14:18])[0], len(wrapped) - 18)
        self.assertEqual(gzip.decompress(parts["Image.gz"]), self.kernel)

    def test_invalid_kernel(self):
        with self.assertRaises(ValueError):
            boot.components(b"loader", self.dtb, b"initrd", b"bad")

    def test_invalid_dtb(self):
        for dtb in (b"", self.dtb + b"extra", b"bad" + self.dtb[3:]):
            with self.assertRaises(ValueError):
                boot.components(b"loader", dtb, b"initrd", self.kernel)

    def test_missing_initramfs(self):
        with self.assertRaises(ValueError):
            boot.components(b"loader", self.dtb, b"", self.kernel)

    def test_deterministic_components(self):
        self.assertEqual(boot.components(b"loader", self.dtb, b"initrd", self.kernel),
                         boot.components(b"loader", self.dtb, b"initrd", self.kernel))

    def test_streaming_checksum(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "root.img"
            path.write_bytes(b"test root image")
            original = boot.file_digest(path)
            self.assertEqual(original, boot.digest(b"test root image"))
            path.write_bytes(b"changed image")
            self.assertNotEqual(original, boot.file_digest(path))


if __name__ == "__main__":
    unittest.main()
