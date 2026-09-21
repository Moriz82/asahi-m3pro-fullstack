#!/usr/bin/env python3
"""Exercise the actual development init with BusyBox, never booting a kernel.

Linux-root chroots contain ordinary files and FIFOs, no device nodes or host
mounts. All mount/mknod/insmod/stty calls are strict test doubles. The stty
double separates console input (FIFO) from its already-open output file.
Use a read-only, network-disabled container: chroot alone is not isolation.
"""
import argparse
import base64
import errno
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("development", PROJECT / "scripts/development-candidate.py")
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)
RELEASE = "7.1.9.asahi1+"


def write(root, name, data):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode() if isinstance(data, str) else data)


def script(root, name, body):
    path = root / "bin" / name
    path.unlink(missing_ok=True)  # Never write through an applet symlink.
    path.write_text("#!/bin/sh\nset -eu\n" + body)
    path.chmod(0o755)


def template(root, busybox):
    (root / "bin").mkdir(parents=True)
    shutil.copyfile(busybox, root / "bin/busybox")
    (root / "bin/busybox").chmod(0o755)
    for applet in dev.APPLETS:
        (root / "bin" / applet).symlink_to("busybox")
    shutil.copyfile(PROJECT / "initramfs/development/init", root / "init")
    (root / "init").chmod(0o755)
    for name in ("version", "meminfo", "stat", "interrupts", "mounts", "devices", "iomem", "fb", "consoles"):
        write(root, "proc/" + name, "fixture " + name + "; not hardware evidence\n")
    for name, data in {
        "proc/uptime": "0.00 0.00\n", "proc/modules": "", "proc/cmdline": dev.CMDLINE + "\n",
        "proc/config.gz": b"\x1f\x8b\x00fixture", "proc/sys/kernel/tainted": "0\n",
        "sys/firmware/devicetree/base/soc/nvme@38dcc0000/status": b"disabled\x00",
        "sys/firmware/fdt": b"\xd0\x0d\xfe\xed\x00fixture\xff",
        "sys/devices/system/cpu/online": "0-10\n", "sys/devices/system/cpu/possible": "0-10\n",
        "etc/m3dev/kernelrelease": RELEASE + "\n", "etc/m3dev/cmdline": dev.CMDLINE + "\n",
        "sys/kernel/notes": b"fixture kernel notes",
        "etc/m3dev/kernel-notes.sha256": dev.hash_bytes(b"fixture kernel notes") + "\n",
        "etc/m3dev/console-binding": "b" * 64 + "\n",
    }.items():
        write(root, name, data)
    modules = {"lib/modules/" + RELEASE + "/" + name: b"fixture module " + name.encode() for name in dev.MODULES}
    for name, data in modules.items(): write(root, name, data)
    write(root, "etc/m3dev/modules.order", "\n".join(modules) + "\n")
    for group, names in dev.GROUPS.items():
        write(root, "etc/m3dev/" + group + ".order", "".join("lib/modules/" + RELEASE + "/" + name + "\n" for name in names))
    write(root, "etc/m3dev/modules.sha256", "".join(dev.hash_bytes(data) + "  " + name + "\n" for name, data in modules.items()))
    script(root, "uname", '[ "$*" = -r ]; printf "%s\\n" "${FIXTURE_RELEASE}"\n')
    script(root, "mount", '''
printf '%s\\n' "$*" >>/mount-calls
case "$*" in
  '-t tmpfs -o nosuid,noexec,size=1m tmpfs /dev'|\
  '-t proc -o nosuid,nodev,noexec proc /proc'|\
  '-t sysfs -o ro,nosuid,nodev,noexec sysfs /sys'|\
  '-t tmpfs -o nosuid,nodev,noexec,size=16m tmpfs /run') ;;
  *) exit 91 ;;
esac
for target; do :; done
[ "${FAIL_MOUNT:-}" != "$target" ]
''')
    script(root, "mknod", '''
printf '%s\\n' "$*" >>/mknod-calls
case "$*" in '-m 600 /dev/console c 5 1'|'-m 600 /dev/tty c 5 0'|'-m 666 /dev/null c 1 3') ;; *) exit 91 ;; esac
[ "${FAIL_NODE:-}" != "$3" ]
: >"$3"
''')
    script(root, "stty", '''
[ "$*" = '-F /dev/console -echo -icanon -ixon -ixoff min 1 time 0' ]
[ "${FAIL_STTY:-}" != 1 ]
/bin/busybox mv /dev/console /console-output
/bin/busybox mkfifo /dev/console
''')
    script(root, "sleep", '''
step=0
if [ -f /sleep-step ]; then read -r step </sleep-step; fi
step=$((step + 1)); printf '%s\\n' "$step" >/sleep-step
case "$step" in
  1) printf '15.01 0.00\\n' >/proc/uptime ;;
  2) printf '60.01 0.00\\n' >/proc/uptime ;;
  *) exit 73 ;;
esac
''')
    script(root, "dmesg", '''
case "${DMESG_MODE:-}" in
  failed) exit 37 ;;
  oversized|hanging) exec cat /proc/dmesg-fixture ;;
  *) printf 'fixture dmesg; not hardware evidence\\n' ;;
esac
''')
    script(root, "insmod", '''
[ "$#" = 1 ]
grep -Fx "${1#/}" /etc/m3dev/modules.order >/dev/null
grep -F "path=${1#/}" /console-output >/dev/null
printf '%s\\n' "$1" >>/insmod-calls
case "${INSMOD_MODE:-}" in
  failed) exit 37 ;;
  oversized) exec cat /proc/insmod-fixture ;;
  hanging) exec cat /proc/insmod-fixture ;;
  storage) mkdir -p /sys/class/block; touch /sys/class/block/nvme0n1 ;;
esac
printf 'fixture insmod; no module loaded\\n'
''')


def records(log):
    pattern = rb"^M3DEV record-begin name=(\S+) status=(\d+) bytes=(\d+) sha256=([0-9a-f]{64}) encoding=(text|base64) truncated=(true|false)\n"
    result = []
    for match in re.finditer(pattern, log, re.M):
        name, status, length, checksum, encoding, truncated = match.groups()
        end = log.index(b"\nM3DEV record-end name=" + name + b"\n", match.end())
        data = log[match.end():end]
        if encoding == b"base64": data = base64.b64decode(data, validate=False)
        assert len(data) == int(length), (name, length, len(data))
        assert hashlib.sha256(data).hexdigest().encode() == checksum, name
        result.append((name, int(status), len(data), truncated == b"true"))
    return result


def run_case(root, commands, env, expired=False):
    process = subprocess.Popen([shutil.which("chroot"), str(root), "/init"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                               "FIXTURE_RELEASE": RELEASE, **env})
    try:
        deadline = time.monotonic() + 15
        while process.poll() is None and time.monotonic() < deadline:
            console = root / "dev/console"
            if console.exists() and console.is_fifo():
                try: descriptor = os.open(console, os.O_WRONLY | os.O_NONBLOCK)
                except OSError as exc:
                    if exc.errno != errno.ENXIO: raise
                else:
                    try:
                        if expired:
                            os.write(descriptor, b"arm-core\n")
                            armed_deadline = time.monotonic() + 3
                            while b"M3DEV core-armed" not in (root / "console-output").read_bytes():
                                assert time.monotonic() < armed_deadline, "arm was not observed"
                                time.sleep(0.005)
                            write(root, "proc/uptime-next", "11.00 0.00\n")
                            os.replace(root / "proc/uptime-next", root / "proc/uptime")
                        assert os.write(descriptor, commands) == len(commands)
                    finally: os.close(descriptor)
                    break
            time.sleep(0.005)
        output, _ = process.communicate(timeout=20)
        if process.returncode != 73:
            details = {str(p.relative_to(root)): (oct(p.lstat().st_mode), p.lstat().st_uid)
                       for p in (root / "dev").glob("*")}
            calls = {name: (root / name).read_text() for name in ("mknod-calls", "mount-calls") if (root / name).exists()}
            raise AssertionError((root.name, process.returncode, output, details, calls))
    finally:
        if process.poll() is None:
            process.kill(); process.wait()
    console_log = root / ("console-output" if (root / "console-output").exists() else "dev/console")
    log = output + (console_log.read_bytes() if console_log.exists() and console_log.is_file() else b"")
    assert not any(p.is_char_device() or p.is_block_device() for p in root.rglob("*"))
    assert not (root / "injected").exists()
    return log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--busybox", type=Path, help="exercise the SHA256-pinned AArch64 target binary")
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() != 0:
        if os.environ.get("M1_INIT_RUNTIME_REQUIRED") == "1":
            raise RuntimeError("development runtime tests require Linux root/chroot")
        print("SKIP development-init-runtime: requires Linux chroot; mandatory in static CI")
        return
    busybox = args.busybox or Path(shutil.which("busybox") or "/missing-busybox")
    if args.busybox:
        pinned = re.search(r"^M1_BUSYBOX_SHA256=([0-9a-f]{64})$", (PROJECT / "config/milestone1.env").read_text(), re.M)[1]
        assert dev.hash_bytes(busybox.read_bytes()) == pinned, "BusyBox target hash mismatch"
    applets = subprocess.check_output([str(busybox), "--list"], text=True).splitlines()
    assert set(dev.APPLETS) <= set(applets), "missing required BusyBox applet"
    cases = ["normal", "commands-lf", "commands-crlf", "unarmed", "injection", "empty", "oversized", "multibyte",
             "hello", "hello-short", "hello-uppercase", "hello-control", "hello-nonhex", "hello-oversized", "arm-hello",
             "wrong-running-kernel", "missing-kernel-notes", "hello-storage",
             "dart-only", "wrong-group", "arm-expired", "arm-status", "arm-help", "arm-snapshot", "arm-fdt",
             "wrong-kernel", "wrong-cmdline", "missing-cmdline", "missing-release", "missing-expected-cmdline",
             "nvme-enabled", "missing-nvme-status", "block-visible", "mem-visible", "mtd-visible", "spi-loaded", "storage-loaded", "missing-modules",
             "dev-mount", "proc-mount", "sys-mount", "run-mount", "console-node", "tty-node", "null-node", "console-mode",
             "module-hash", "module-failed", "module-oversized", "module-hanging", "module-storage", "reprobe",
             "record-missing", "record-timeout", "record-truncated", "fdt-truncated", "drivers-truncated",
             "framebuffer-present", "framebuffer-truncated", "framebuffer-timeout",
             "dmesg-failed", "dmesg-oversized", "dmesg-hanging"]
    with tempfile.TemporaryDirectory(prefix="m3dev-init-test-") as temporary:
        source = Path(temporary) / "template"
        template(source, busybox)
        for case in cases:
            root = Path(temporary) / case
            shutil.copytree(source, root, symlinks=True)
            env = {}; commands = b""; blocked = None; modules = 0
            if case in ("commands-lf", "commands-crlf", "reprobe"):
                commands = b"help\nstatus\nsnapshot\nfdt\narm-core\nprobe-core\nstatus\n"
                modules = len(dev.CORE_MODULES)
                if case == "commands-crlf": commands = commands.replace(b"\n", b"\r\n")
                if case == "reprobe": commands += b"arm-core\nprobe-core\n"
            elif case == "unarmed": commands = b"probe-core\n"
            elif case == "dart-only": commands = b"arm-dart\nprobe-dart\n"; modules = 1
            elif case == "wrong-group": commands = b"arm-core\nprobe-dart\nprobe-core\n"
            elif case in ("wrong-running-kernel", "missing-kernel-notes", "hello-storage"):
                commands = b"hello " + b"a" * 32 + b"\narm-core\nprobe-core\n"
                if case == "wrong-running-kernel":
                    write(root, "sys/kernel/notes", b"same-release different kernel"); blocked = "running-kernel-notes-mismatch"
                elif case == "missing-kernel-notes":
                    (root / "sys/kernel/notes").unlink(); blocked = "kernel-notes-unavailable"
                else:
                    # Appears only after the initial storage guard, just before hello.
                    script(root, "stty", (root / "bin/stty").read_text().split("set -eu\n", 1)[1] +
                           "mkdir -p /sys/class/mtd; touch /sys/class/mtd/mtd0\n")
                    blocked = "storage-visible"
            elif case == "arm-expired": commands = b"probe-core\n"
            elif case == "arm-hello": commands = b"arm-core\nhello " + b"a" * 32 + b"\nprobe-core\n"
            elif case.startswith("arm-"): commands = b"arm-core\n" + case.removeprefix("arm-").encode() + b"\nprobe-core\n"
            elif case.startswith("hello"):
                nonce = {"hello": b"a" * 32, "hello-short": b"a" * 31, "hello-uppercase": b"A" * 32,
                         "hello-control": b"a" * 31 + b"\x1b", "hello-nonhex": b"g" * 32,
                         "hello-oversized": b"a" * 81}[case]
                commands = b"hello " + nonce + b"\nstatus\n"
            elif case in ("injection", "empty", "oversized", "multibyte"):
                bad = {"injection": b"$(touch /injected); sh", "empty": b"", "oversized": b"x" * 128,
                       "multibyte": "🧪".encode() * 32}[case]
                commands = b"arm-core\n" + bad + b"\nprobe-core\nstatus\n"
            elif case == "wrong-kernel": env["FIXTURE_RELEASE"] = "wrong"; blocked = "kernel-release"
            elif case == "wrong-cmdline": write(root, "proc/cmdline", dev.CMDLINE + " root=/dev/nvme0n1\n"); blocked = "command-line"
            elif case.startswith("missing-"):
                name, blocked = {"missing-cmdline": ("proc/cmdline", "missing-cmdline"),
                                 "missing-release": ("etc/m3dev/kernelrelease", "missing-kernel-release"),
                                 "missing-expected-cmdline": ("etc/m3dev/cmdline", "missing-expected-command-line"),
                                 "missing-nvme-status": ("sys/firmware/devicetree/base/soc/nvme@38dcc0000/status", "nvme-status-unavailable"),
                                 "missing-modules": ("proc/modules", "storage-visible")}[case]
                (root / name).unlink()
            elif case == "nvme-enabled": write(root, "sys/firmware/devicetree/base/soc/nvme@38dcc0000/status", b"okay\x00"); blocked = "nvme-not-disabled"
            elif case == "block-visible": write(root, "sys/class/block/nvme0n1", ""); blocked = "storage-visible"
            elif case == "mem-visible": write(root, "dev/mem", ""); blocked = "storage-visible"
            elif case == "mtd-visible": write(root, "sys/class/mtd/mtd0", ""); blocked = "storage-visible"
            elif case == "spi-loaded": write(root, "proc/modules", "spi_apple 4096 0 - Live\n"); blocked = "storage-visible"
            elif case == "storage-loaded": write(root, "proc/modules", "nvme_apple 4096 0 - Live\n"); blocked = "storage-visible"
            elif case.endswith("-mount"): env["FAIL_MOUNT"] = "/" + case.split("-")[0]; blocked = "sysfs-mount" if case == "sys-mount" else case
            elif case.endswith("-node"): env["FAIL_NODE"] = "/dev/" + case.split("-")[0]; blocked = case
            elif case == "console-mode": env["FAIL_STTY"] = "1"; blocked = "console-mode"
            elif case.startswith("module-"):
                commands = b"arm-core\nprobe-core\n"; modules = 1
                env["INSMOD_MODE"] = case.removeprefix("module-")
                if case == "module-hash": write(root, "lib/modules/" + RELEASE + "/" + dev.MODULES[0], b"changed"); blocked = "module-hashes"; modules = 0
                if case == "module-storage": blocked = "storage-visible"
                if case == "module-oversized": write(root, "proc/insmod-fixture", b"M" * 140000)
                if case == "module-hanging": os.mkfifo(root / "proc/insmod-fixture")
            elif case == "record-missing": (root / "proc/version").unlink()
            elif case == "record-timeout": (root / "proc/version").unlink(); os.mkfifo(root / "proc/version")
            elif case == "record-truncated": write(root, "proc/version", b"V" * 70000)
            elif case == "fdt-truncated": write(root, "sys/firmware/fdt", b"F" * 1048578)
            elif case == "drivers-truncated":
                for n in range(130): (root / "sys/bus/platform/devices" / str(n)).mkdir(parents=True)
            elif case.startswith("framebuffer-"):
                for name, value in {"name": "simpledrmdrmfb\n", "virtual_size": "3024,1964\n",
                                    "bits_per_pixel": "32\n", "stride": "12096\n"}.items():
                    write(root, "sys/class/graphics/fb0/" + name, value)
                if case == "framebuffer-truncated": write(root, "sys/class/graphics/fb0/name", b"F" * 257)
                if case == "framebuffer-timeout":
                    (root / "sys/class/graphics/fb0/stride").unlink()
                    os.mkfifo(root / "sys/class/graphics/fb0/stride")
            elif case.startswith("dmesg-"):
                env["DMESG_MODE"] = case.removeprefix("dmesg-")
                if case == "dmesg-oversized": write(root, "proc/dmesg-fixture", b"D" * 140000)
                if case == "dmesg-hanging": os.mkfifo(root / "proc/dmesg-fixture")
            log = run_case(root, commands, env, expired=case == "arm-expired")
            attempted = (root / "insmod-calls").read_text().splitlines() if (root / "insmod-calls").exists() else []
            expected_modules = dev.DART_MODULES if case == "dart-only" else dev.MODULES[:modules]
            assert attempted == ["/lib/modules/" + RELEASE + "/" + name for name in expected_modules], (case, attempted)
            for module in attempted:
                begin = b"M3DEV module-probe-begin group=" + (b"dart" if case == "dart-only" else b"core") + b" path=" + module[1:].encode()
                end = b"M3DEV module-probe path=" + module[1:].encode()
                assert log.index(begin) < log.index(end), (case, module)
            if blocked:
                assert ("phase=blocked reason=" + blocked).encode() in log, (case, log[-3000:])
                if not case.startswith("module-") and case not in ("wrong-running-kernel", "missing-kernel-notes", "hello-storage"):
                    assert b"phase=development-ready" not in log, case
            else:
                assert b"phase=development-ready hardware_acceptance=false" in log, (case, log[-3000:])
                for label in (b"early", b"scheduled-15s", b"scheduled-60s"):
                    assert b"snapshot-end label=" + label in log, (case, label)
                assert log.count(b"M3DEV heartbeat ") in ((3, 4) if case == "arm-expired" else (3,)), case
            captured = records(log)
            if case == "record-timeout": assert any(n == b"version" and s != 0 for n,s,_,_ in captured)
            if case == "record-truncated": assert (b"version", 0, 65536, True) in captured
            if case == "fdt-truncated": assert (b"runtime-fdt", 0, 1048576, True) in captured
            if case == "drivers-truncated": assert b"inventory-truncated limit=128" in log
            if case.startswith("framebuffer-"):
                assert (b"fb0-virtual_size", 0, 10, False) in captured
                assert (b"fb0-bits_per_pixel", 0, 3, False) in captured
                if case == "framebuffer-truncated": assert (b"fb0-name", 0, 256, True) in captured
                else: assert (b"fb0-name", 0, len(b"simpledrmdrmfb\n"), False) in captured
                if case == "framebuffer-timeout": assert any(n == b"fb0-stride" and s != 0 for n,s,_,_ in captured)
                else: assert (b"fb0-stride", 0, 6, False) in captured
            elif case == "normal":
                for name in (b"name", b"virtual_size", b"bits_per_pixel", b"stride"):
                    assert b"M3DEV record name=fb0-" + name + b" status=unavailable\n" in log
            if case in ("dmesg-oversized", "module-oversized"):
                path = root / ("run/m3dev/dmesg.tmp" if case.startswith("dmesg") else "run/m3dev/insmod.txt")
                assert path.stat().st_size == 66048, (case, path.stat().st_size)
            if case in ("dmesg-hanging", "dmesg-failed"):
                assert re.search(rb"dmesg-producer status=(37|137|143|124) ", log), case
            if case in ("module-hanging", "module-failed", "module-oversized"): assert b"probe-stopped reason=module-error" in log
            if case in ("empty", "injection", "oversized", "multibyte", "unarmed", "wrong-group") or case.startswith("arm-"):
                assert b"probe-refused reason=requires-current-arm-core" in log
            if case == "reprobe": assert b"probe-refused reason=already-attempted" in log
            if case in ("hello", "arm-hello"):
                expected = (b"M3DEV hello protocol=2 nonce=" + b"a" * 32 + b" init_sha256=" +
                            dev.hash_bytes((root / "init").read_bytes()).encode() + b" modules_sha256=" +
                            dev.hash_bytes((root / "etc/m3dev/modules.sha256").read_bytes()).encode() +
                            b" kernel_notes_sha256=" + dev.hash_bytes(b"fixture kernel notes").encode() +
                            b" bundle_sha256=" + b"b" * 64 + b" kernel_release=" + RELEASE.encode() + b"\n")
                assert log.count(expected) == 1, (case, log[-3000:])
            elif case.startswith("hello-"):
                assert b"M3DEV hello protocol=" not in log, case
                if case != "hello-storage": assert b"M3DEV command-rejected reason=" in log, case
            print("PASS development-init-runtime " + case, flush=True)
    print(f"development_init_runtime_cases={len(cases)} target_busybox={bool(args.busybox)}")


if __name__ == "__main__": main()
