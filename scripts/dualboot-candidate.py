#!/usr/bin/env python3
"""Build/verify an offline, RAM-only standalone stage-2 candidate. Never install."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zlib


PROJECT = Path(__file__).resolve().parent.parent
BOOTARGS = b"chosen.bootargs=earlycon loglevel=7 ignore_loglevel rdinit=/init panic=0\n"
LAYOUT = ("m1n1.bin", "bootargs.txt", "t6030-j514s.dtb", "initramfs.cpio.gz", "Image.gz")
SOURCE_FILES = {
    "m1n1": ("manifest.txt", "SHA256SUMS", "m1n1.bin"),
    "linux-full": ("manifest.txt", "SHA256SUMS", "Image", "dtbs/apple/t6030-j514s.dtb"),
    "initramfs": ("manifest.txt", "SHA256SUMS", "milestone1-initramfs.cpio.gz"),
}
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
FILES = {"manifest.json", "SHA256SUMS", "esp/m1n1/boot.bin"}
FILES.update("components/" + name for name in LAYOUT)
FILES.update("checks/" + name + ".log" for name in SOURCE_FILES)
DIRECTORIES = {"components", "checks", "esp", "esp/m1n1"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def real_path(path, directory=False):
    """Reject symlink ancestors, special files and lexical path escapes."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "absolute non-escaping path required")
    require(path.resolve() == path, "symlink or noncanonical path: " + str(path))
    mode = path.lstat().st_mode
    require(stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode), "wrong file type: " + str(path))
    return path


def digest(path):
    real_path(path)
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def source_roots(project, runs=None):
    roots = {}
    for name in SOURCE_FILES:
        parent = project / "out" / ("milestone1/initramfs" if name == "initramfs" else "milestone0/" + name)
        real_path(parent, directory=True)
        if runs is None:
            path = (parent / "latest").resolve(strict=True)
        else:
            run = runs[name]["run_id"]
            require(isinstance(run, str) and RUN_ID.fullmatch(run) and run != "latest", "invalid source run ID")
            path = parent / run
        require(path.parent == parent and RUN_ID.fullmatch(path.name) and path.name != "latest", "source outside run root")
        roots[name] = real_path(path, directory=True)
    return roots


def snapshot(roots):
    return {name: {"run_id": root.name, "files": {
        relative: {"sha256": digest(root / relative), "size": (root / relative).stat().st_size}
        for relative in SOURCE_FILES[name]
    }} for name, root in roots.items()}


def verifier_environment():
    # Do not let caller output-root overrides rebind the canonical source evidence.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("MILESTONE0_", "MILESTONE1_", "M1_", "M0_", "UBOOT_"))
           and key not in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def validate_sources(project, roots, logs=None):
    commands = {
        "m1n1": ["verify-m1n1.sh", str(roots["m1n1"])],
        "linux-full": ["verify-linux-full.sh", str(roots["linux-full"])],
        "initramfs": ["verify-milestone1-initramfs.sh", str(roots["initramfs"]), str(roots["linux-full"])],
    }
    for name, arguments in commands.items():
        print("checking=" + name, flush=True)
        stream = (logs / (name + ".log")).open("xb") if logs else tempfile.TemporaryFile()
        with stream:
            result = subprocess.run([str(project / "scripts" / arguments[0]), *arguments[1:]],
                                    env=verifier_environment(), stdout=stream, stderr=subprocess.STDOUT, check=False)
        require(result.returncode == 0, "source verifier failed: " + name +
                ("; see " + str(logs / (name + ".log")) if logs else "; rerun its existing verifier for diagnostics"))


def output_path(project, value):
    path = Path(value)
    parent = real_path(project / "out/isolated", directory=True)
    require(path.is_absolute() and path.parent == parent, "output must be a direct child of project out/isolated")
    require(re.fullmatch(r"dualboot-[A-Za-z0-9][A-Za-z0-9._-]{0,80}", path.name), "output name must start with dualboot-")
    require(not os.path.lexists(path), "refusing existing output")
    return path


def gzip_kernel(source, destination):
    with source.open("rb") as incoming, destination.open("xb") as outgoing:
        with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=outgoing, mtime=0) as packed:
            shutil.copyfileobj(incoming, packed, 1024 * 1024)


def check_kernel(packed, expected):
    # One bounded gzip member only, including CRC/truncation/trailing-data checks.
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    result = hashlib.sha256()
    count = 0
    with packed.open("rb") as stream:
        require(stream.read(10) == b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff", "noncanonical kernel gzip header")
        stream.seek(0)
        for block in iter(lambda: stream.read(64 * 1024), b""):
            raw = decoder.decompress(block, expected["size"] - count + 1)
            count += len(raw)
            require(count <= expected["size"] and not decoder.unconsumed_tail, "kernel gzip exceeds source size")
            require(not decoder.unused_data, "extra member or trailing kernel gzip data")
            result.update(raw)
    require(decoder.eof and count == expected["size"] and result.hexdigest() == expected["sha256"], "kernel differs from verified Image")


def metadata(project, root, origins):
    offset = 0
    layout = []
    for name in LAYOUT:
        file = root / "components" / name
        size = file.stat().st_size
        layout.append({"file": name, "offset": offset, "size": size, "sha256": digest(file)})
        offset += size
    return {"format": 1, "component": "standalone-ram-only-stage2", "target": "Mac15,6/J514s/T6030",
            "hardware_acceptance": False, "installation_authorized": False, "canonical_m0": False,
            "persistent_root": False, "macos_selection": "Apple startup options, not this payload",
            "stage1": "separately provisioned and verified compatible chainloader required",
            "payload": "esp/m1n1/boot.bin", "layout": layout, "sources": origins,
            "tool_sha256": digest(project / "scripts/dualboot-candidate.py")}


def checksums(root):
    return "".join(digest(root / name) + "  " + name + "\n" for name in sorted(FILES - {"SHA256SUMS"}))


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate manifest key")
        result[key] = value
    return result


def inspect_tree(root):
    real_path(root, directory=True)
    files, directories = set(), set()
    for current, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            require(not path.is_symlink(), "symlink in candidate")
            if stat.S_ISDIR(mode):
                directories.add(relative)
            else:
                require(stat.S_ISREG(mode) and path.stat().st_nlink == 1, "nonregular or hardlinked candidate member")
                files.add(relative)
    require(files == FILES and directories == DIRECTORIES, "candidate inventory mismatch")


def verify_contents(project, root, origins):
    inspect_tree(root)
    require((root / "SHA256SUMS").read_text() == checksums(root), "candidate checksums mismatch")
    manifest = json.loads((root / "manifest.json").read_text(), object_pairs_hook=strict_object)
    expected_manifest = json.dumps(metadata(project, root, origins), indent=2, sort_keys=True) + "\n"
    require((root / "manifest.json").read_text() == expected_manifest, "candidate manifest/layout/source mismatch")
    require((root / "components/bootargs.txt").read_bytes() == BOOTARGS, "unapproved kernel arguments")
    for member, origin, original in (("m1n1.bin", "m1n1", "m1n1.bin"),
                                     ("t6030-j514s.dtb", "linux-full", "dtbs/apple/t6030-j514s.dtb"),
                                     ("initramfs.cpio.gz", "initramfs", "milestone1-initramfs.cpio.gz")):
        file = root / "components" / member
        require({"sha256": digest(file), "size": file.stat().st_size} == origins[origin]["files"][original], "component differs from source: " + member)
    check_kernel(root / "components/Image.gz", origins["linux-full"]["files"]["Image"])
    with (root / "esp/m1n1/boot.bin").open("rb") as payload:
        for name in LAYOUT:
            with (root / "components" / name).open("rb") as component:
                for block in iter(lambda: component.read(1024 * 1024), b""):
                    require(payload.read(len(block)) == block, "payload concatenation/order mismatch")
        require(not payload.read(1), "trailing payload bytes")
    return manifest


def build(project, destination):
    destination = output_path(project, destination)
    roots = source_roots(project)
    origins = snapshot(roots)
    stage = Path(tempfile.mkdtemp(prefix=".dualboot-", dir=destination.parent))
    # Keep failed private stages for diagnostics; never replace a prior candidate.
    for directory in sorted(DIRECTORIES):
        (stage / directory).mkdir(mode=0o700)
    validate_sources(project, roots, stage / "checks")
    require(snapshot(roots) == origins, "source changed during verification")
    for member, origin, original in (("m1n1.bin", "m1n1", "m1n1.bin"),
                                     ("t6030-j514s.dtb", "linux-full", "dtbs/apple/t6030-j514s.dtb"),
                                     ("initramfs.cpio.gz", "initramfs", "milestone1-initramfs.cpio.gz")):
        shutil.copyfile(roots[origin] / original, stage / "components" / member)
    (stage / "components/bootargs.txt").write_bytes(BOOTARGS)
    gzip_kernel(roots["linux-full"] / "Image", stage / "components/Image.gz")
    with (stage / "esp/m1n1/boot.bin").open("xb") as payload:
        for name in LAYOUT:
            with (stage / "components" / name).open("rb") as source:
                shutil.copyfileobj(source, payload, 1024 * 1024)
    (stage / "manifest.json").write_text(json.dumps(metadata(project, stage, origins), indent=2, sort_keys=True) + "\n")
    (stage / "SHA256SUMS").write_text(checksums(stage))
    verify_contents(project, stage, origins)
    require(snapshot(roots) == origins, "source changed during packaging")
    for file in FILES:
        (stage / file).chmod(0o400)
    for directory in sorted(DIRECTORIES, reverse=True):
        (stage / directory).chmod(0o500)
    stage.chmod(0o500)
    subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c",
                    'set -Eeuo pipefail; source "$1"; evidence_atomic_publish_directory "$2" "$3"',
                    "dualboot-publish", str(project / "scripts/lib/evidence.sh"), str(stage), str(destination)],
                   check=True, env=verifier_environment())
    print("candidate=" + str(destination))


def verify(project, root):
    inspect_tree(root)
    manifest = json.loads((root / "manifest.json").read_text(), object_pairs_hook=strict_object)
    roots = source_roots(project, manifest["sources"])
    origins = snapshot(roots)
    verify_contents(project, root, origins)
    validate_sources(project, roots)
    require(snapshot(roots) == origins, "source changed during verification")
    verify_contents(project, root, origins)
    print("candidate=verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "verify"))
    parser.add_argument("path", help="new out/isolated/dualboot-NAME output, or existing candidate to verify")
    args = parser.parse_args()
    try:
        if args.action == "build":
            build(PROJECT, args.path)
        else:
            verify(PROJECT, Path(args.path))
    except (ValueError, OSError, KeyError, TypeError, zlib.error, subprocess.CalledProcessError) as exc:
        print("error: " + str(exc), file=sys.stderr)
        return 1
    print("hardware_acceptance=false\ninstallation_authorized=false\ncanonical_m0=false")
    return 0


if __name__ == "__main__":
    sys.exit(main())
