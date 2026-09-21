#!/usr/bin/env python3
"""Run the unmodified M1 init in a disposable Linux chroot, never a kernel boot.

Only ordinary files exist in /dev. One /proc fixture is a FIFO to test timeout.
mount/dmesg/sleep are test doubles; the
mount double models /run hiding pre-existing files, and sleep terminates init.
No device nodes or host mounts are placed inside the root. CI additionally
uses a read-only, network-disabled container; chroot alone is not a sandbox.
"""
import os
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def copy_binary(root, path):
    destination = root / path.lstrip("/")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, destination)
    destination.chmod(0o755)
    dependencies = subprocess.run(["ldd", path], check=True, capture_output=True, text=True)
    for library in re.findall(r"(/[\w/+.\-]+)", dependencies.stdout):
        target = root / library.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(library, target)
        target.chmod(0o755)


def script(root, name, contents):
    target = root / "bin" / name
    target.write_text("#!/bin/sh\nset -eu\n" + contents)
    target.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--busybox", type=Path, help="also exercise the pinned target BusyBox, on native AArch64 Linux")
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() != 0:
        if os.environ.get("M1_INIT_RUNTIME_REQUIRED") == "1":
            raise RuntimeError("M1 init runtime test requires Linux root with chroot capability")
        print("SKIP m1-init-runtime: requires Linux chroot; mandatory in static CI")
        return
    chroot = shutil.which("chroot")
    if not chroot:
        raise RuntimeError("missing chroot")
    source = Path(__file__).resolve().parents[1] / "initramfs/milestone1/init"
    if args.busybox:
        config = (source.parents[2] / "config/milestone1.env").read_text()
        pinned = re.search(r"^M1_BUSYBOX_SHA256=([0-9a-f]{64})$", config, re.MULTILINE).group(1)
        if hashlib.sha256(args.busybox.read_bytes()).hexdigest() != pinned:
            raise ValueError("BusyBox does not match the pinned target binary")
    cases = [
        ("normal", "", "", "none", None),
        ("root", "root=/dev/nvme0n1", "", "none", "forbidden-root-parameter"),
        ("nvme", "foo=nvme", "", "none", "forbidden-persistent-storage-parameter"),
        ("apfs", "foo=APFS", "", "none", "forbidden-persistent-storage-parameter"),
        ("missing-cmdline", None, "", "none", "missing-command-line"),
        ("run-mount", "", "/run", "none", "mount_failed"),
        ("proc-mount", "", "/proc", "none", "mount_failed"),
        ("sys-mount", "", "/sys", "none", "mount_failed"),
        ("dev-mount", "", "/dev", "none", "mount_failed"),
        ("unknown-action", "", "", "unknown", "unknown-test-action"),
        ("watchdog", "", "", "prepare-watchdog", None),
        ("panic", "", "", "prepare-panic", None),
        ("reboot", "", "", "prepare-reboot", None),
        ("diagnostic-missing", "", "", "none", None),
        ("diagnostic-timeout", "", "", "none", None),
        ("diagnostic-truncated", "", "", "none", None),
        ("dmesg-failure", "", "", "none", None),
        ("dmesg-oversized", "", "", "none", None),
        ("dmesg-hanging", "", "", "none", None),
    ]
    with tempfile.TemporaryDirectory(prefix="m1-init-runtime-") as temporary:
        template = Path(temporary) / "template"
        for directory in ("bin", "dev", "proc", "sys", "run"):
            (template / directory).mkdir(parents=True)
        applets = ("sh", "mkdir", "touch", "date", "uname", "cat", "mv", "head", "timeout")
        if args.busybox:
            shutil.copyfile(args.busybox, template / "bin/busybox")
            (template / "bin/busybox").chmod(0o755)
            for binary in applets:
                (template / "bin" / binary).symlink_to("busybox")
        else:
            for binary in applets:
                copy_binary(template, "/bin/" + binary)
        shutil.copyfile(source, template / "init")
        (template / "init").chmod(0o755)
        (template / "dev/console").touch()
        script(template, "mount", '''
printf '%s\\n' "$*" >>/mount-calls
[ "$1" = -t ]
case "$2:$3:$4" in
    tmpfs:tmpfs:/run|proc:proc:/proc|sysfs:sysfs:/sys|devtmpfs:devtmpfs:/dev) ;;
    *) exit 91 ;;
esac
[ "${FAIL_MOUNT:-}" != "$4" ] || exit 1
if [ "$4" = /run ]; then mv /run /hidden-run; mkdir /run; fi
''')
        script(template, "dmesg", "printf 'fixture dmesg; not hardware evidence\\n'\n"
               'case "${DMESG_MODE:-}" in\n'
               'dmesg-failure) exit 1 ;;\n'
               'dmesg-oversized) exec head -c 70000 /proc/dmesg-fixture ;;\n'
               'dmesg-hanging) exec cat /proc/dmesg-fixture ;;\n'
               'esac\n')
        script(template, "sleep", "exit 73\n")
        for name, cmdline, failed_mount, action, blocked_marker in cases:
            root = Path(temporary) / name
            shutil.copytree(template, root)
            for proc in ("version", "meminfo", "uptime", "stat", "interrupts", "modules", "mounts", "devices", "iomem"):
                (root / "proc" / proc).write_text("fixture " + proc + "\n")
            cpu = root / "sys/devices/system/cpu"
            cpu.mkdir(parents=True)
            (cpu / "online").write_text("0-10\n")
            (cpu / "possible").write_text("0-10\n")
            if name == "diagnostic-missing":
                (root / "proc/uptime").unlink()
            elif name == "diagnostic-timeout":
                (root / "proc/uptime").unlink()
                os.mkfifo(root / "proc/uptime")
            elif name == "diagnostic-truncated":
                (root / "proc/version").write_text("X" * 70000)
            elif name == "dmesg-oversized":
                (root / "proc/dmesg-fixture").write_text("Z" * 70000)
            elif name == "dmesg-hanging":
                os.mkfifo(root / "proc/dmesg-fixture")
            if cmdline is not None:
                (root / "proc/cmdline").write_text(cmdline + "\n")
            result = subprocess.run(
                [chroot, str(root), "/init"], timeout=10, capture_output=True, text=True,
                env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "FAIL_MOUNT": failed_mount,
                     "M1_TEST_ACTION": action, "DMESG_MODE": name},
            )
            assert result.returncode == 73, (name, result.returncode, result.stderr)
            log = (root / "run/milestone1/session.log").read_text()
            assert "phase=initramfs-start storage_policy=ram-only" in log, name
            assert len((root / "mount-calls").read_text().splitlines()) == 4, name
            if blocked_marker:
                assert blocked_marker in log and "phase=safe-halt" in log, (name, log)
                assert "phase=controlled-tether-ready" not in log, (name, log)
                assert "phase=diagnostics-start" not in log, name
            else:
                assert "phase=controlled-tether-ready" in log, (name, log)
                assert "phase=safe-halt" not in log, (name, log)
                assert "phase=diagnostics-end hardware_acceptance=false" in log, name
                assert "diagnostic-begin name=cpu-online status=0" in log, name
                assert "diagnostic-begin name=dmesg status=0" in log, name
                if name == "diagnostic-missing":
                    assert "diagnostic name=uptime status=unavailable" in log, name
                elif name == "diagnostic-timeout":
                    assert re.search(r"diagnostic-begin name=uptime status=(124|137|143) ", log), log
                elif name == "diagnostic-truncated":
                    assert "X" * 65536 in log and "X" * 65537 not in log, name
                elif name == "dmesg-failure":
                    assert "diagnostic name=dmesg-command status=1" in log, name
                elif name == "dmesg-oversized":
                    assert (root / "run/milestone1/dmesg-start.log").stat().st_size == 65536, name
                    assert "Z" * 65000 in log and "Z" * 65536 not in log, name
                elif name == "dmesg-hanging":
                    assert re.search(r"diagnostic name=dmesg-command status=(124|137|143) ", log), log
                assert (root / "run/milestone1/dmesg-start.log").stat().st_size <= 65536, name
                if action != "none":
                    assert "operator must trigger externally" in log, (name, log)
            print(f"PASS m1-init-runtime {name}")


if __name__ == "__main__":
    main()
