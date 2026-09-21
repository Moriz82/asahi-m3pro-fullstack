#!/usr/bin/env python3
"""Package a staged Arch root's direct-m1n1 boot payload; never install or boot."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
LOADER = PROJECT / "out/milestone0/m1n1/20260903T140652Z-1-dc7ae74559143fae/m1n1.bin"
LOADER_SHA = "097f1ae47b51e5580f401611977ce6d29c85cc9a15e6f6e28344af82a2e6b99e"
ROOT_UUID = "72d1456d-516d-41e1-a29d-398001cc4cef"
ARGS = ("chosen.bootargs=earlycon console=tty0 console=ttySAC0,115200n8 "
        f"root=UUID={ROOT_UUID} rootfstype=ext4 rw rootwait panic=0 "
        "clk_ignore_unused pd_ignore_unused firmware_class.path=/usr/lib/firmware/vendor "
        "systemd.unit=multi-user.target\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024**2), b""):
            checksum.update(block)
    return checksum.hexdigest()


def components(loader, dtb, initramfs, kernel):
    if not kernel[56:60] == b"ARM\x64":
        raise ValueError("not an ARM64 Linux Image")
    if len(dtb) < 40 or dtb[:4] != b"\xd0\x0d\xfe\xed" or struct.unpack(">I", dtb[4:8])[0] != len(dtb):
        raise ValueError("invalid DTB length/header")
    if not initramfs or len(initramfs) >= 2**32:
        raise ValueError("invalid initramfs size")
    packed = io.BytesIO()
    with gzip.GzipFile(filename="", fileobj=packed, mode="wb", mtime=0) as stream:
        stream.write(kernel)
    if gzip.decompress(packed.getvalue()) != kernel:
        raise ValueError("kernel gzip round-trip failed")
    # m1n1's explicit initramfs wrapper preserves mixed early-cpio/compressed data.
    wrapped = b"m1n1_initramfs" + struct.pack("<I", len(initramfs)) + initramfs
    return {"m1n1.bin": loader, "bootargs.txt": ARGS, "t6030-j514s.dtb": dtb,
            "initramfs.m1n1": wrapped, "Image.gz": packed.getvalue()}


def build(source, output):
    isolated = (PROJECT / "out/isolated").resolve()
    source, output = source.resolve(strict=True), output.absolute()
    if not source.is_relative_to(isolated) or output.parent.resolve() != isolated:
        raise ValueError("use an existing isolated root and a new isolated output directory")
    if output.exists() or output.is_symlink():
        raise ValueError("output already exists")
    root_image = source / "root.img"
    root_anchor = source / "root.img.sha256"
    if root_image.is_symlink() or not root_image.is_file() or root_image.stat().st_size != 107239964672:
        raise ValueError("missing or invalid root image identity")
    image_sha = file_digest(root_image)
    if root_anchor.exists():
        match = re.fullmatch(r"([0-9a-f]{64})  root\.img\n", root_anchor.read_text())
        if not match or image_sha != match.group(1):
            raise ValueError("root image checksum mismatch")
    else:
        # One full source read establishes identity; native readback verifies it
        # independently. Never trust an unverified caller-provided digest.
        with root_anchor.open("x") as stream:
            stream.write(f"{image_sha}  root.img\n")
        root_anchor.chmod(0o400)
    checks = {}
    for line in (source / "SHA256SUMS").read_text().splitlines():
        sha, name = line.split("  ", 1)
        if name in checks:
            raise ValueError("duplicate checksum name")
        checks[name] = sha
    inputs = {}
    for name in ("Image", "t6030-j514s.dtb", "initramfs-linux-asahi.img"):
        path = source / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 256 * 1024**2:
            raise ValueError("unsafe or oversized source: " + name)
        inputs[name] = path.read_bytes()
        if digest(inputs[name]) != checks.get(name):
            raise ValueError("source checksum mismatch: " + name)
    compat = subprocess.check_output(["fdtget", "-t", "s", str(source / "t6030-j514s.dtb"), "/", "compatible"], text=True).split()
    if "apple,j514s" not in compat or "apple,t6030" not in compat:
        raise ValueError("wrong target DTB")
    loader = LOADER.read_bytes()
    if digest(loader) != LOADER_SHA:
        raise ValueError("known-working loader checksum mismatch")
    parts = components(loader, inputs["t6030-j514s.dtb"], inputs["initramfs-linux-asahi.img"], inputs["Image"])
    stage = Path(tempfile.mkdtemp(prefix=".arch-boot-", dir=isolated))
    layout, offset = [], 0
    for name, data in parts.items():
        (stage / name).write_bytes(data)
        layout.append({"name": name, "offset": offset, "size": len(data), "sha256": digest(data)})
        offset += len(data)
    payload = b"".join(parts.values())
    (stage / "boot-arch-dev.bin").write_bytes(payload)
    if (stage / "boot-arch-dev.bin").read_bytes() != payload:
        raise ValueError("payload readback failed")
    manifest = {"format": 1, "root_uuid": ROOT_UUID, "root_source": str(source),
                "root_image_sha256": image_sha, "root_image_bytes": root_image.stat().st_size,
                "root_checksums_sha256": digest((source / "SHA256SUMS").read_bytes()),
                "layout": layout, "payload_sha256": digest(payload), "boot_ready": False,
                "installed": False, "hardware_acceptance": False,
                "missing": ["operator boot approval", "native root/console/network validation"]}
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (stage / "SHA256SUMS").write_text("".join(f"{digest(p.read_bytes())}  {p.name}\n" for p in sorted(stage.iterdir())))
    for path in stage.iterdir():
        path.chmod(0o400)
    subprocess.run(["bash", "-c", 'source "$1"; evidence_atomic_publish_directory "$2" "$3"',
                    "publish", str(PROJECT / "scripts/lib/evidence.sh"), str(stage), str(output)], check=True)
    print(f"packaged={output}; boot_ready=false; installed=false")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.source, args.output)
