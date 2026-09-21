#!/usr/bin/env python3
"""Build/verify a restricted RAM-only development guest. Never installs or boots."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dualboot", PROJECT / "scripts/dualboot-candidate.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
require = base.require
CMDLINE = "earlycon loglevel=7 ignore_loglevel rdinit=/init panic=0"
NVME_NODE = "/soc/nvme@38dcc0000"
CORE_MODULES = (
    "kernel/drivers/pinctrl/pinctrl-apple-gpio.ko",
    "kernel/drivers/clk/clk-apple-nco.ko",
    "kernel/drivers/i2c/busses/i2c-pasemi-core.ko",
    "kernel/drivers/i2c/busses/i2c-pasemi-platform.ko",
    "kernel/drivers/spmi/spmi-apple-controller.ko",
    "kernel/drivers/pwm/pwm-apple.ko",
)
DART_MODULES = ("kernel/drivers/iommu/apple-dart.ko",)
GROUPS = {"core": CORE_MODULES, "dart": DART_MODULES}
MODULES = CORE_MODULES + DART_MODULES
MODULAR_GATES = ("CONFIG_NVME_CORE", "CONFIG_NVME_APPLE", "CONFIG_BLK_DEV_NVME",
                 "CONFIG_USB_DWC3_APPLE", "CONFIG_PCIE_APPLE", "CONFIG_APPLE_DART", "CONFIG_SPI_APPLE")
APPLETS = "base64 cat date dmesg grep head insmod ls mkdir mknod mount readlink sha256sum sh sleep stty timeout touch tr uname wc".split()


def development_kernel_root(project, path):
    """Only a published run of the reviewed framebuffer profile, never latest/staging."""
    path = base.real_path(Path(path), directory=True)
    require(len(path.parents) >= 3 and re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16}", path.name), "invalid development kernel run")
    output = path.parents[2]
    require(path.parent == output / "milestone0/linux-development-framebuffer" and
            output.parent == project / "out/isolated" and
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", output.name), "development kernel outside isolated run root")
    return path


def source_roots(project, runs=None, kernel=None):
    if runs is not None:
        require(isinstance(runs, dict) and set(runs) in (set(base.SOURCE_FILES), set(base.SOURCE_FILES) | {"development-kernel"}),
                "unexpected source roles")
        require(kernel is None, "verification cannot override recorded kernel")
    roots = base.source_roots(project, runs)
    if runs is not None and "development-kernel" in runs:
        record = runs["development-kernel"]
        require(isinstance(record, dict) and isinstance(record.get("output_root"), str) and
                re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", record["output_root"]) and
                isinstance(record.get("run_id"), str) and
                re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{16}", record["run_id"]), "invalid recorded development kernel")
        kernel = project / "out/isolated" / record["output_root"] / "milestone0/linux-development-framebuffer" / record["run_id"]
    if kernel is not None:
        roots["development-kernel"] = development_kernel_root(project, kernel)
    return roots


def snapshot(roots):
    result = base.snapshot({name: roots[name] for name in base.SOURCE_FILES})
    if "development-kernel" in roots:
        root = roots["development-kernel"]
        result["development-kernel"] = {"output_root": root.parents[2].name, "run_id": root.name,
            "files": {relative: {"sha256": base.digest(root / relative), "size": (root / relative).stat().st_size}
                      for relative in base.SOURCE_FILES["linux-full"]}}
    return result


def kernel_root(roots):
    return roots.get("development-kernel", roots["linux-full"])


def validate_sources(project, roots, logs=None):
    # BusyBox comes from the original verified M1 artifact, whose verifier must
    # keep its canonical Linux association. Do not relax that verifier's gates.
    base.validate_sources(project, {name: roots[name] for name in base.SOURCE_FILES}, logs)
    if "development-kernel" in roots:
        kernel = development_kernel_root(project, roots["development-kernel"])
        env = base.verifier_environment()
        env["MILESTONE0_OUTPUT_ROOT"] = str(kernel.parents[2])
        print("checking=development-kernel", flush=True)
        stream = (logs / "development-kernel.log").open("xb") if logs else tempfile.TemporaryFile()
        with stream:
            result = subprocess.run([str(project / "scripts/verify-linux-full.sh"), str(kernel), "--development-framebuffer"],
                                    env=env, stdout=stream, stderr=subprocess.STDOUT, check=False)
        require(result.returncode == 0, "source verifier failed: development-kernel" +
                ("; see " + str(logs / "development-kernel.log") if logs else ""))


def hash_bytes(data):
    return hashlib.sha256(data).hexdigest()


def configuration(data):
    return {line.split("=", 1)[0]: line.split("=", 1)[1]
            for line in data.decode().splitlines() if line.startswith("CONFIG_") and "=" in line}


def source_bytes(root, relative):
    """Bind every additional input to the already verified original inventory."""
    expected = []
    for line in (root / "SHA256SUMS").read_text().splitlines():
        fields = line.split("  ", 1)
        if len(fields) == 2 and fields[1].removeprefix("./") == relative:
            expected.append(fields[0])
    require(len(expected) == 1, "source input is not uniquely inventoried: " + relative)
    data = base.real_path(root / relative).read_bytes()
    require(hash_bytes(data) == expected[0], "source input checksum mismatch: " + relative)
    return data


def elf_notes(data):
    """Read the linked ARM64 kernel notes, not an external objcopy dependency."""
    require(len(data) >= 64 and data[:6] == b"\x7fELF\x02\x01" and data[18:20] == b"\xb7\x00", "invalid kernel ELF")
    offset = struct.unpack_from("<Q", data, 40)[0]
    stride, count, names_index = struct.unpack_from("<HHH", data, 58)
    require(stride == 64 and 0 < names_index < count <= 4096 and offset + count * stride <= len(data), "invalid kernel section table")
    def section(index):
        header = struct.unpack_from("<IIQQQQIIQQ", data, offset + index * stride)
        require(header[4] + header[5] <= len(data) and header[5] <= 1048576, "invalid kernel notes section bounds")
        return header, data[header[4]:header[4] + header[5]]
    _, names = section(names_index)
    matches = []
    for index in range(count):
        name_offset = struct.unpack_from("<I", data, offset + index * stride)[0]
        require(name_offset < len(names) and b"\0" in names[name_offset:], "invalid kernel section name")
        if names[name_offset:].split(b"\0", 1)[0] == b".notes":
            header, content = section(index)
            require(header[1] == 7 and header[2] & 2 and len(content) > 0, "invalid kernel notes")
            matches.append(content)
    require(len(matches) == 1, "kernel must contain one notes section")
    return matches[0]


def module_inputs(linux):
    release = source_bytes(linux, "kernelrelease").decode().strip()
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+\-]{0,100}", release), "invalid kernel release")
    cfg = configuration(source_bytes(linux, "config"))
    for key in MODULAR_GATES:
        require(cfg.get(key) == "m", key + " must remain modular in the reused kernel")
    base.real_path(linux / "modules/lib/modules" / release, directory=True)
    deps = {}
    for line in source_bytes(linux, "modules/lib/modules/" + release + "/modules.dep").decode().splitlines():
        name, rest = line.split(":", 1)
        require(name not in deps, "duplicate module dependency")
        deps[name] = rest.split()
    # Keep a fixed small dependency closure. Unexpected new dependencies require review.
    seen = set()
    files = {}
    for name in MODULES:
        require(name in deps and set(deps[name]) <= seen, "unapproved or out-of-order module dependency: " + name)
        data = source_bytes(linux, "modules/lib/modules/" + release + "/" + name)
        require(data[:4] == b"\x7fELF" and data[4:6] == b"\x02\x01" and data[18:20] == b"\xb7\x00", "module is not AArch64 ELF")
        match = re.search(rb"\x00vermagic=([^\x00]+)\x00", data)
        require(match and match[1].split()[0].decode() == release, "module vermagic mismatch")
        files["lib/modules/" + release + "/" + name] = data
        seen.add(name)
    softdeps = source_bytes(linux, "modules/lib/modules/" + release + "/modules.softdep").decode()
    names = {Path(x).stem.replace("-", "_") for x in MODULES}
    for line in softdeps.splitlines():
        words = line.split()
        require(not (len(words) > 1 and words[0] == "softdep" and words[1].replace("-", "_") in names), "selected module has unreviewed soft dependencies")
    return release, files


def root_files(project, roots):
    release, modules = module_inputs(kernel_root(roots))
    files = {"init": (project / "initramfs/development/init").read_bytes(),
             "bin/busybox": source_bytes(roots["initramfs"], "bin/busybox"),
             "etc/m3dev/kernelrelease": (release + "\n").encode(),
             "etc/m3dev/cmdline": (CMDLINE + "\n").encode()}
    files.update(modules)
    files["etc/m3dev/modules.order"] = ("\n".join(modules) + "\n").encode()
    for group, names in GROUPS.items():
        files["etc/m3dev/" + group + ".order"] = "".join("lib/modules/" + release + "/" + name + "\n" for name in names).encode()
    files["etc/m3dev/modules.sha256"] = "".join(hash_bytes(data) + "  " + name + "\n" for name, data in modules.items()).encode()
    files["etc/m3dev/kernel-notes.sha256"] = (hash_bytes(elf_notes(source_bytes(kernel_root(roots), "vmlinux"))) + "\n").encode()
    with tempfile.TemporaryDirectory(prefix="m3dev-binding-") as temporary:
        transformed = Path(temporary).resolve() / "target.dtb"
        disable_nvme(kernel_root(roots) / "dtbs/apple/t6030-j514s.dtb", transformed)
        binding = {"format": 1, "sources": snapshot(roots), "dtb_sha256": base.digest(transformed),
                   "bootargs": "chosen.bootargs=" + CMDLINE + "\n",
                   "rootfs": {name: hash_bytes(data) for name, data in files.items()}}
    files["etc/m3dev/console-binding"] = (hash_bytes(json.dumps(binding, sort_keys=True, separators=(",", ":")).encode()) + "\n").encode()
    return files


def archive(files, epoch):
    """Canonical newc: fixed metadata, sorted paths, only our regular files/links."""
    require(isinstance(epoch, int) and 0 <= epoch <= 0xffffffff, "invalid archive epoch")
    entries = {name: (0o100755 if name in ("init", "bin/busybox") else 0o100644, data)
               for name, data in files.items()}
    for directory in ("dev", "proc", "sys", "run"):
        entries[directory] = (0o040755, b"")
    for name in files:
        for parent in Path(name).parents:
            if str(parent) != ".": entries[str(parent)] = (0o040755, b"")
    for tool in APPLETS:
        entries["bin/" + tool] = (0o120777, b"busybox")
    raw = bytearray()
    for inode, name in enumerate([*sorted(entries), "TRAILER!!!"], 1):
        mode, data = entries.get(name, (0, b""))
        label = name.encode() + b"\x00"
        fields = (inode, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, epoch, len(data), 0, 0, 0, 0, len(label), 0)
        raw += b"070701" + b"".join(f"{value:08x}".encode() for value in fields) + label
        raw += b"\x00" * (-len(raw) % 4)
        raw += data
        raw += b"\x00" * (-len(raw) % 4)
    raw += b"\x00" * (-len(raw) % 512)
    packed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=packed, compresslevel=9, mtime=0) as stream:
        stream.write(raw)
    return packed.getvalue()


def dt_tools():
    # Explicit host-version pins; binary identities are frozen in each manifest.
    expected = {"darwin": "Version: DTC 1.7.2", "linux": "Version: DTC 1.6.1"}.get(sys.platform)
    require(expected, "unsupported device-tree tooling host")
    result = {}
    for name in ("fdtget", "fdtput"):
        found = shutil.which(name)
        require(found, "missing " + name)
        path = base.real_path(Path(found).resolve())
        version = subprocess.check_output([str(path), "-V"], text=True).strip()
        require(version == expected, "unapproved " + name + " version: " + version)
        result[name] = {"path": str(path), "version": version, "sha256": base.digest(path)}
    return result


def disable_nvme(source, target):
    tools = dt_tools()
    compatible = subprocess.check_output([tools["fdtget"]["path"], "-t", "s", str(source), NVME_NODE, "compatible"], text=True).strip()
    require(compatible == "apple,t6030-nvme-ans3 apple,t8103-nvme-ans2", "unexpected NVMe node")
    shutil.copyfile(source, target)
    subprocess.run([tools["fdtput"]["path"], "-t", "s", str(target), NVME_NODE, "status", "disabled"], check=True)
    require(subprocess.check_output([tools["fdtget"]["path"], "-t", "s", str(target), NVME_NODE, "status"], text=True).strip() == "disabled", "NVMe DT gate failed")
    require(dt_tools() == tools, "device-tree tool changed during transformation")


def epoch_of(roots):
    text = (kernel_root(roots) / "manifest.txt").read_text()
    epochs = re.findall(r"^source_date_epoch=(\d+)$", text, re.M)
    require(len(epochs) == 1, "missing or duplicate source epoch")
    return int(epochs[0])


def checksum_text(root):
    records = []
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "symlink in candidate")
        if path.is_dir(): continue
        base.real_path(path)
        require(path.stat().st_nlink == 1, "hardlink in candidate")
        if path.name == "SHA256SUMS" and path.parent == root: continue
        records.append(base.digest(path) + "  " + path.relative_to(root).as_posix() + "\n")
    return "".join(records)


def metadata(project, root, origins):
    return {"format": 4, "component": "restricted-development-ram-only-guest",
            "target": "Mac15,6/J514s/T6030", "hardware_acceptance": False,
            "boot_authorized": False, "canonical_m0": False, "persistent_root": False,
            "kernel_rebuilt": "development-kernel" in origins, "interface": "fixed-commands-not-shell",
            "kernel_profile": "framebuffer-v1" if "development-kernel" in origins else "original-verified-export",
            "module_loading": "inactive-until-matching-arm-and-probe-within-10-seconds",
            "nvme_policy": "modules-absent-and-device-tree-disabled",
            "raw_memory_policy": "no-device-nodes-no-arbitrary-command-execution-not-hostile-root-isolation",
            "sources": origins, "tool_sha256": {name: base.digest(project / name) for name in
                ("scripts/development-candidate.py", "scripts/dualboot-candidate.py", "scripts/lib/evidence.sh")},
            "init_sha256": base.digest(project / "initramfs/development/init"),
            "console_protocol": 2,
            "console_binding_sha256": (root / "rootfs/etc/m3dev/console-binding").read_text().strip(),
            "kernel_notes_sha256": (root / "rootfs/etc/m3dev/kernel-notes.sha256").read_text().strip(),
            "kernel_release": (root / "rootfs/etc/m3dev/kernelrelease").read_text().strip(),
            "module_manifest_sha256": base.digest(root / "rootfs/etc/m3dev/modules.sha256"),
            "dt_tools": dt_tools(), "module_groups": {name: list(paths) for name, paths in GROUPS.items()},
            "modules": list(MODULES), "payload_sha256": base.digest(root / "esp/m1n1/boot.bin")}


def verify_contents(project, root, roots, origins):
    require((root / "SHA256SUMS").read_text() == checksum_text(root), "candidate checksum mismatch")
    files = root_files(project, roots)
    expected = {"manifest.json", "SHA256SUMS", "esp/m1n1/boot.bin", *["rootfs/" + name for name in files],
                *["components/" + name for name in base.LAYOUT], *["checks/" + name + ".log" for name in roots]}
    actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
    require(actual == expected, "unexpected or missing candidate file")
    directories = {str(parent) for name in expected for parent in Path(name).parents if str(parent) != "."}
    require({p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_dir()} == directories,
            "unexpected or missing candidate directory")
    for name, data in files.items():
        require((root / "rootfs" / name).read_bytes() == data, "rootfs differs from reviewed source: " + name)
    require((root / "components/initramfs.cpio.gz").read_bytes() == archive(files, epoch_of(roots)), "initramfs bytes differ")
    require((root / "components/bootargs.txt").read_bytes() == ("chosen.bootargs=" + CMDLINE + "\n").encode(), "unapproved bootargs")
    require(base.digest(root / "components/m1n1.bin") == origins["m1n1"]["files"]["m1n1.bin"]["sha256"], "m1n1 mismatch")
    selected = "development-kernel" if "development-kernel" in origins else "linux-full"
    base.check_kernel(root / "components/Image.gz", origins[selected]["files"]["Image"])
    with tempfile.TemporaryDirectory(prefix="m3dev-dtb-") as temporary:
        dtb = Path(temporary) / "expected.dtb"
        disable_nvme(kernel_root(roots) / "dtbs/apple/t6030-j514s.dtb", dtb)
        require(dtb.read_bytes() == (root / "components/t6030-j514s.dtb").read_bytes(), "unapproved DT transformation")
    require((root / "esp/m1n1/boot.bin").read_bytes() == b"".join((root / "components" / name).read_bytes() for name in base.LAYOUT), "payload assembly mismatch")
    require(json.loads((root / "manifest.json").read_text(), object_pairs_hook=base.strict_object) == metadata(project, root, origins), "candidate metadata mismatch")


def build(project, destination, kernel=None):
    destination = base.output_path(project, destination)
    require(destination.name.startswith("dualboot-dev-"), "development output must start dualboot-dev-")
    roots = source_roots(project, kernel=kernel)
    origins = snapshot(roots)
    stage = Path(tempfile.mkdtemp(prefix=".m3dev-", dir=destination.parent))
    for name in ("rootfs", "components", "checks", "esp/m1n1"):
        (stage / name).mkdir(parents=True, exist_ok=True)
    validate_sources(project, roots, stage / "checks")
    require(snapshot(roots) == origins, "source changed during verification")
    files = root_files(project, roots)
    for name, data in files.items():
        path = stage / "rootfs" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (stage / "components/initramfs.cpio.gz").write_bytes(archive(files, epoch_of(roots)))
    (stage / "components/bootargs.txt").write_bytes(("chosen.bootargs=" + CMDLINE + "\n").encode())
    shutil.copyfile(roots["m1n1"] / "m1n1.bin", stage / "components/m1n1.bin")
    disable_nvme(kernel_root(roots) / "dtbs/apple/t6030-j514s.dtb", stage / "components/t6030-j514s.dtb")
    base.gzip_kernel(kernel_root(roots) / "Image", stage / "components/Image.gz")
    (stage / "esp/m1n1/boot.bin").write_bytes(b"".join((stage / "components" / name).read_bytes() for name in base.LAYOUT))
    (stage / "manifest.json").write_text(json.dumps(metadata(project, stage, origins), indent=2, sort_keys=True) + "\n")
    (stage / "SHA256SUMS").write_text(checksum_text(stage))
    verify_contents(project, stage, roots, origins)
    require(snapshot(roots) == origins, "source changed during packaging")
    for path in stage.rglob("*"):
        path.chmod(0o500 if path.is_dir() else 0o400)
    stage.chmod(0o500)
    subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c",
                    'set -Eeuo pipefail; source "$1"; evidence_atomic_publish_directory "$2" "$3"',
                    "dev-publish", str(project / "scripts/lib/evidence.sh"), str(stage), str(destination)],
                   check=True, env=base.verifier_environment())
    print("candidate=" + str(destination))


def verify(project, root):
    root = base.real_path(Path(root), directory=True)
    require(root.parent == project / "out/isolated" and root.name.startswith("dualboot-dev-"), "unexpected output location")
    manifest = json.loads((root / "manifest.json").read_text(), object_pairs_hook=base.strict_object)
    roots = source_roots(project, manifest["sources"])
    origins = snapshot(roots)
    require(origins == manifest["sources"], "source binding mismatch")
    validate_sources(project, roots)
    verify_contents(project, root, roots, origins)
    require(snapshot(roots) == origins, "source changed during verification")
    print("development_candidate_valid=true hardware_acceptance=false boot_authorized=false")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "verify"))
    parser.add_argument("output", type=Path)
    parser.add_argument("--kernel", type=Path, help="build only: published isolated linux-development-framebuffer run")
    args = parser.parse_args()
    try:
        if args.action == "build": build(PROJECT, args.output, args.kernel)
        else:
            require(args.kernel is None, "verify uses recorded source bindings; --kernel is build-only")
            verify(PROJECT, args.output)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        parser.exit(1, "error: " + str(exc) + "\n")
