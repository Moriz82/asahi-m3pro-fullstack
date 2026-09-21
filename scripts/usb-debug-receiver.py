#!/usr/bin/env python3
"""Linux m1n1 console: read-only capture or explicitly gated development commands."""

import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import secrets
import stat
import sys
import termios
import time
import tty


VID, PID, INTERFACE = "1209", "316d", "02"
APPROVED_GROUPS = {
    "core": ["kernel/drivers/pinctrl/pinctrl-apple-gpio.ko", "kernel/drivers/clk/clk-apple-nco.ko",
             "kernel/drivers/i2c/busses/i2c-pasemi-core.ko", "kernel/drivers/i2c/busses/i2c-pasemi-platform.ko",
             "kernel/drivers/spmi/spmi-apple-controller.ko", "kernel/drivers/pwm/pwm-apple.ko"],
    "dart": ["kernel/drivers/iommu/apple-dart.ko"],
}


def development_binding(path, expected_hash):
    """Read a transferred, host-verified manifest. Its hash is not a signature."""
    require(re.fullmatch(r"[0-9a-f]{64}", expected_hash), "invalid manifest hash")
    require(path.is_absolute() and path.resolve(strict=True) == path and path.is_file(), "manifest must be a canonical regular file")
    require(path.stat().st_size <= 65536, "manifest too large")
    with path.open("rb") as stream: data = stream.read(65537)
    require(len(data) <= 65536 and hashlib.sha256(data).hexdigest() == expected_hash, "manifest hash mismatch")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate manifest key")
            result[key] = value
        return result
    manifest = json.loads(data, object_pairs_hook=unique)
    require(isinstance(manifest, dict), "manifest must be an object")
    for key, value in {"format": 4, "component": "restricted-development-ram-only-guest",
                       "target": "Mac15,6/J514s/T6030", "interface": "fixed-commands-not-shell",
                       "console_protocol": 2, "module_groups": APPROVED_GROUPS,
                       "nvme_policy": "modules-absent-and-device-tree-disabled"}.items():
        require(type(manifest.get(key)) is type(value) and manifest[key] == value, "unapproved manifest " + key)
    for key in ("hardware_acceptance", "boot_authorized", "canonical_m0", "persistent_root"):
        require(manifest.get(key) is False, "unapproved manifest " + key)
    for key in ("init_sha256", "module_manifest_sha256", "payload_sha256", "console_binding_sha256", "kernel_notes_sha256"):
        require(isinstance(manifest.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", manifest[key]), "invalid " + key)
    require(isinstance(manifest.get("kernel_release"), str) and
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+\-]{0,100}", manifest["kernel_release"]), "invalid kernel release")
    return manifest


class DevelopmentConsole:
    """One owner, one request at a time, fresh challenge before every request.

    USB IDs/echoed hashes are not cryptographic device authentication. The caller
    must approve the physical session and supply a separately verified manifest.
    """
    def __init__(self, options, records):
        self.options, self.records = options, records
        self.manifest = options["manifest"]
        self.input_fd = options["input_fd"]
        self.phase, self.request = "waiting-ready", None
        self.pending, self.offset = b"", 0
        self.line, self.input_line = b"", b""
        self.dropping_line = self.dropping_input = self.in_record = False
        self.input_closed = False
        self.reply_record = None
        self.failure, self.stop_at = None, None
        self.deadline = time.monotonic() + 120
        self.nonce = None
        self.verified = False
        self.bytes_sent = self.input_bytes = 0
        self.probes_sent, self.completed = [], []
        self.module_started, self.module_status = [], []

    def note(self, kind, **fields):
        event(self.records, kind, **fields)
        print(json.dumps({"event": kind, **fields}, ensure_ascii=True), flush=True)

    def fail(self, reason):
        if self.failure: return
        self.failure, self.phase = reason, "failed"
        self.pending = b""
        self.stop_at = time.monotonic() + 3  # Capture a bounded failure tail; never reconnect/retry.
        self.note("development-failed", reason=reason, request=self.request, hardware_acceptance=False)

    def queue(self, command, after):
        require(not self.pending, "overlapping console transmission")
        self.pending, self.offset = (command + "\n").encode("ascii"), 0
        self.phase, self.after_write = "writing", after
        self.deadline = time.monotonic() + 2
        self.note("transmit-intent", command=command, application_serial_writes=True)

    def challenge(self):
        self.nonce = secrets.token_hex(16)
        self.queue("hello " + self.nonce, "waiting-hello")

    def write_ready(self, fd):
        if not self.pending or self.failure: return
        try: count = os.write(fd, self.pending[self.offset:])
        except BlockingIOError: return
        except OSError as exc:
            self.note("transmit-error", error_type=type(exc).__name__, message=str(exc), partial_bytes=self.offset)
            self.fail("serial-write-error"); return
        if count <= 0:
            self.fail("serial-write-zero"); return
        sent = self.pending[self.offset:self.offset+count]
        event(self.records, "transmit", byte_count=count, text=sent.decode("ascii"))
        self.bytes_sent += count
        self.offset += count
        if self.offset == len(self.pending):
            command = self.pending.decode("ascii").strip()
            self.pending, self.phase = b"", self.after_write
            self.deadline = time.monotonic() + (180 if self.phase == "waiting-reply" else 30)
            if command.startswith("probe-"): self.probes_sent.append(command)

    def tick(self):
        if self.phase not in ("idle", "failed", "quitting") and time.monotonic() >= self.deadline:
            self.fail("timeout-" + self.phase)

    def input(self, data):
        if not data:
            self.input_closed = True
            return  # Keep collecting after pipe EOF; quit is a host-only command.
        self.input_bytes += len(data)
        if self.input_bytes > 65536:
            self.fail("stdin-byte-limit"); return
        for byte in data:
            if byte == 10:
                command = self.input_line.rstrip(b"\r")
                if not self.dropping_input:
                    try: self.accept(command.decode("ascii"))
                    except UnicodeDecodeError: self.note("input-rejected", reason="ASCII fixed commands only")
                else: self.note("input-rejected", reason="oversized command")
                self.input_line, self.dropping_input = b"", False
            elif not self.dropping_input:
                if len(self.input_line) >= 32: self.input_line, self.dropping_input = b"", True
                else: self.input_line += bytes([byte])

    def accept(self, command):
        if command == "quit":
            self.pending, self.phase, self.stop_at = b"", "quitting", time.monotonic()
            self.note("host-quit", request_outcome="unproven" if self.request else "none")
            return
        if command not in ("help", "status", "snapshot", "fdt", "probe-core", "probe-dart"):
            self.note("input-rejected", reason="fixed commands only"); return
        if command.startswith("probe-"):
            group = command.removeprefix("probe-")
            if not self.options["allow_" + group] or command in self.probes_sent:
                self.note("input-rejected", reason="probe not permitted or already sent"); return
        if self.phase != "idle" or self.request:
            self.note("input-rejected", reason="busy or failed; commands are not queued"); return
        self.request = command
        if self.phase == "idle": self.challenge()

    def feed(self, data):
        # Protocol parsing is bounded and ignores diagnostic record bodies. The
        # surrounding receiver independently retains every original raw byte.
        for part in data.splitlines(keepends=True):
            self.line += part
            if len(self.line) > 1024:
                self.line, self.dropping_line = b"", True
            if part.endswith(b"\n"):
                if not self.dropping_line:
                    try: self.message(self.line.rstrip(b"\r\n").decode("ascii"))
                    except UnicodeDecodeError: pass
                self.line, self.dropping_line = b"", False

    def message(self, line):
        if self.failure or self.phase == "quitting": return
        if line.startswith("M3DEV record-begin "):
            self.in_record, self.reply_record = True, None
            if self.phase == "waiting-reply" and self.request == "fdt":
                match = re.fullmatch(r"M3DEV record-begin name=runtime-fdt status=0 bytes=([0-9]{1,7}) sha256=[0-9a-f]{64} encoding=base64 truncated=false", line)
                if match and 0 < int(match[1]) <= 1048576: self.reply_record = "runtime-fdt"
            return
        if line.startswith("M3DEV record-end "):
            self.in_record = False
            if self.phase == "waiting-reply" and self.request == "fdt" and self.reply_record == "runtime-fdt" and line == "M3DEV record-end name=runtime-fdt":
                self.complete("observed")
            self.reply_record = None
            return
        if self.in_record: return
        if line.startswith("M3DEV phase=blocked "):
            self.fail("guest-blocked"); return
        if self.phase == "waiting-ready" and (line == "M3DEV phase=development-ready hardware_acceptance=false" or
                                               re.fullmatch(r"M3DEV heartbeat sequence=\d+ uptime=[0-9.]+ core_attempted=(true|false) dart_attempted=(true|false)", line)):
            self.challenge(); return
        if self.phase == "waiting-hello":
            match = re.fullmatch(r"M3DEV hello protocol=2 nonce=([0-9a-f]{32}) init_sha256=([0-9a-f]{64}) modules_sha256=([0-9a-f]{64}) kernel_notes_sha256=([0-9a-f]{64}) bundle_sha256=([0-9a-f]{64}) kernel_release=([A-Za-z0-9._+\-]+)", line)
            if not match or match[1] != self.nonce: return
            if (match[2], match[3], match[4], match[5], match[6]) != (self.manifest["init_sha256"], self.manifest["module_manifest_sha256"],
                    self.manifest["kernel_notes_sha256"], self.manifest["console_binding_sha256"], self.manifest["kernel_release"]):
                self.fail("guest-identity-mismatch"); return
            self.verified = True
            self.note("development-ready", challenge="freshness-only-not-device-authentication", hardware_acceptance=False)
            if not self.request: self.phase = "idle"; return
            self.module_started, self.module_status = [], []
            if self.request.startswith("probe-"):
                self.queue("arm-" + self.request.removeprefix("probe-"), "waiting-arm")
            else: self.queue(self.request, "waiting-reply")
            return
        if self.phase == "waiting-arm":
            group = self.request.removeprefix("probe-")
            warning = "programs-hardware" if group == "core" else "resets-IOMMUs-may-disrupt-USB-debugging"
            if line == f"M3DEV {group}-armed next=probe-{group} expires_seconds=10 warning={warning}":
                self.queue(self.request, "waiting-reply")
            return
        if self.phase != "waiting-reply": return
        if line.startswith(("M3DEV probe-refused ", "M3DEV command-rejected ")):
            self.complete("refused"); return
        if ((self.request == "status" and re.fullmatch(r"M3DEV status uptime=[0-9]+(?:\.[0-9]+)? core_attempted=(true|false) dart_attempted=(true|false) hardware_acceptance=false", line)) or
            (self.request == "help" and line == "M3DEV commands=help,status,snapshot,fdt,arm-core,probe-core,arm-dart,probe-dart; no shell; probes program hardware") or
            (self.request == "snapshot" and line == "M3DEV snapshot-end label=operator hardware_acceptance=false")):
            self.complete("observed"); return
        if self.request.startswith("probe-"):
            group = self.request.removeprefix("probe-")
            paths = ["lib/modules/" + self.manifest["kernel_release"] + "/" + path for path in APPROVED_GROUPS[group]]
            begin = re.fullmatch(r"M3DEV module-probe-begin group=" + group + r" path=(\S+)", line)
            status = re.fullmatch(r"M3DEV module-probe path=(\S+) status=(\d+)", line)
            if begin:
                self.module_started.append(begin[1])
                if self.module_started != paths[:len(self.module_started)]: self.fail("unexpected-module-order")
            if status:
                if int(status[2]) > 255: self.fail("invalid-module-status"); return
                if len(self.module_started) != len(self.module_status)+1 or status[1] != self.module_started[-1]:
                    self.fail("unexpected-module-status"); return
                self.module_status.append(int(status[2]))
            if line == f"M3DEV snapshot-end label=after-{group} hardware_acceptance=false":
                if len(self.module_status) != len(self.module_started) or not self.module_status:
                    self.fail("incomplete-probe-records")
                elif all(value == 0 for value in self.module_status) and self.module_started == paths:
                    self.complete("observed-no-module-error")
                elif self.module_status[-1] != 0:
                    self.complete("observed-module-error")
                else: self.fail("incomplete-probe-records")

    def complete(self, result):
        self.completed.append({"command": self.request, "result": result})
        self.note("command-completed", command=self.request, result=result, hardware_acceptance=False)
        self.phase, self.request = "idle", None


def require(condition, message):
    if not condition:
        raise ValueError(message)


def usb_identity(device, sysfs=Path("/sys/class/tty"), dev_root=Path("/dev")):
    """Inspect sysfs only. USB identity is not proof of board identity or trust."""
    node = Path(device).resolve(strict=True)
    require(node.parent == dev_root, "device must resolve directly under /dev")
    require(re.fullmatch(r"ttyACM[0-9]+", node.name), "expected a Linux ttyACM device")
    info = node.stat()
    require(stat.S_ISCHR(info.st_mode), "serial node is not a character device")
    entry = sysfs / node.name
    require((entry / "dev").read_text().strip() == f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}", "sysfs/device number mismatch")
    interface = (entry / "device").resolve(strict=True)
    require((interface / "bInterfaceNumber").read_text().strip() == INTERFACE,
            "refusing primary proxy or unknown USB interface; secondary interface 02 required")
    usb = interface.parent
    require((usb / "idVendor").read_text().strip() == VID and (usb / "idProduct").read_text().strip() == PID,
            "USB device is not m1n1 1209:316d")
    return {"device": str(node), "usb_path": usb.name, "vendor": VID, "product": PID,
            "interface": INTERFACE, "device_number": info.st_rdev}


def list_devices():
    devices = []
    for entry in sorted(Path("/sys/class/tty").glob("ttyACM*")):
        try:
            devices.append(usb_identity(Path("/dev") / entry.name))
        except (OSError, ValueError):
            continue
    return devices


def wait_identity(device, seconds):
    deadline = time.monotonic() + seconds
    while True:
        try:
            return usb_identity(device)
        except FileNotFoundError:
            require(time.monotonic() < deadline, "timed out waiting for m1n1 secondary console")
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))


def new_session(path):
    require(path.is_absolute() and ".." not in path.parts, "output must be a new absolute path")
    require(path.parent.resolve(strict=True) == path.parent, "output parent must be canonical, without symlinks")
    require(path.parent.is_dir(), "output parent must exist")
    require(not os.path.lexists(path), "refusing existing session output")
    path.mkdir(mode=0o700)


def event(stream, kind, **fields):
    # ASCII JSON escapes control bytes, including terminal escapes and carriage returns.
    stream.write(json.dumps({"event": kind, "monotonic_ns": time.monotonic_ns(), **fields}, ensure_ascii=True) + "\n")
    stream.flush()


def receive(fd, raw, records, seconds, max_bytes, console=None):
    """Bounded byte capture. The default path never reads stdin or writes serial."""
    count = 0
    digest = hashlib.sha256()
    deadline = time.monotonic() + seconds
    reason = "duration-limit"
    try:
        while time.monotonic() < deadline:
            if console:
                console.tick()
                if console.stop_at is not None and time.monotonic() >= console.stop_at:
                    reason = console.failure or "host-quit"
                    break
            if count == max_bytes:
                reason = "byte-limit"
                break
            inputs = [fd]
            if console and not console.input_closed: inputs.append(console.input_fd)
            writes = [fd] if console and console.pending and not console.failure else []
            try:
                ready, writable, _ = select.select(inputs, writes, [], min(0.25, max(0, deadline - time.monotonic())))
            except OSError as exc:
                if console is None: raise
                console.note("select-error", message=str(exc))
                console.fail("serial-select-error")
                reason = "serial-select-error"
                break
            if fd in ready:
                try:
                    data = os.read(fd, min(16384, max_bytes - count))
                except BlockingIOError:
                    data = None
                except OSError as exc:
                    if exc.errno in (errno.EIO, errno.ENODEV): reason = "disconnected"; break
                    if console is None: raise
                    console.note("read-error", message=str(exc))
                    console.fail("serial-read-error")
                    reason = "serial-read-error"
                    break
                if data == b"": reason = "disconnected"; break
                if data:
                    raw.write(data)
                    raw.flush()
                    digest.update(data)
                    count += len(data)
                    # latin-1 maps every byte reversibly; raw remains authoritative.
                    event(records, "data", byte_count=len(data), text=data.decode("latin-1"))
                    if console: console.feed(data)
            if console and console.input_fd in ready:
                try: console.input(os.read(console.input_fd, 4096))
                except BlockingIOError: pass
                except OSError as exc:
                    console.note("stdin-error", message=str(exc))
                    console.fail("stdin-read-error")
            # Consume all old RX/input data before committing a queued write. A
            # response cannot be accepted until its complete request was written.
            if console and fd in writable: console.write_ready(fd)
    except KeyboardInterrupt:
        reason = "operator-interrupt"
    result = {"stop_reason": reason, "bytes_received": count, "raw_sha256": digest.hexdigest(),
              "capture_continuity": "unproven", "hardware_acceptance": False}
    if console:
        result["development"] = {"guest_binding_observed": console.verified, "failure": console.failure,
                                 "bytes_sent": console.bytes_sent, "completed_commands": console.completed,
                                 "unfinished_request": console.request, "probes_sent": console.probes_sent}
    return result


def configure(fd):
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    fcntl.ioctl(fd, termios.TIOCEXCL)
    original = termios.tcgetattr(fd)
    tty.setraw(fd, when=termios.TCSANOW)  # No echo, software flow control or input flush.
    settings = termios.tcgetattr(fd)
    settings[0] &= ~(termios.IXON | termios.IXOFF | getattr(termios, "IXANY", 0))
    settings[2] |= termios.CLOCAL | termios.CREAD
    settings[2] &= ~termios.HUPCL
    if hasattr(termios, "CRTSCTS"):
        settings[2] &= ~termios.CRTSCTS
    settings[4] = settings[5] = getattr(termios, "B500000", termios.B115200)
    termios.tcsetattr(fd, termios.TCSANOW, settings)
    return original


def capture(device, output, seconds, max_bytes, wait_seconds=300, development=None):
    if development: os.fstat(development["input_fd"])  # Fail before looking up/opening USB.
    identity = wait_identity(device, wait_seconds)
    new_session(output)
    os.umask(0o077)
    # Capture is O_RDONLY. Only the separately acknowledged development action
    # gets O_RDWR. Opening/configuring either can enter m1n1 proxy mode.
    fd = None
    original = None
    with (output / "serial.bin").open("xb") as raw, (output / "serial.jsonl").open("x", encoding="ascii") as records:
        event(records, "opening", **identity, may_enter_proxy=True, application_serial_writes_allowed=bool(development))
        try:
            access = os.O_RDWR if development else os.O_RDONLY
            fd = os.open(identity["device"], access | os.O_NOCTTY | os.O_NONBLOCK | os.O_NOFOLLOW)
            require(os.fstat(fd).st_rdev == identity["device_number"], "device changed while opening")
            require(usb_identity(identity["device"]) == identity, "USB identity changed while opening")
            if development:
                incoming = os.fstat(development["input_fd"])
                require(development["input_fd"] != fd and not (stat.S_ISCHR(incoming.st_mode) and incoming.st_rdev == identity["device_number"]),
                        "stdin must not be the serial device")
            original = configure(fd)
            event(records, "connected", **identity)
            if development:
                event(records, "development-binding", manifest=development["manifest"],
                      allow_core=development["allow_core"], allow_dart=development["allow_dart"],
                      binding_is_not_device_authentication=True)
                summary = receive(fd, raw, records, seconds, max_bytes, DevelopmentConsole(development, records))
            else:
                summary = receive(fd, raw, records, seconds, max_bytes)
        except BaseException as exc:
            event(records, "error", error_type=type(exc).__name__, message=str(exc), hardware_acceptance=False)
            raise
        finally:
            if fd is not None:
                if original is not None:
                    # Do not restore echo/IXOFF: queued target data could otherwise
                    # be echoed back to the target during close. No tcflush is used.
                    original[0] &= ~(termios.IXON | termios.IXOFF | getattr(termios, "IXANY", 0))
                    original[3] &= ~(termios.ECHO | termios.ECHONL)
                    original[2] &= ~termios.HUPCL
                    try:
                        termios.tcsetattr(fd, termios.TCSANOW, original)
                    except (OSError, termios.error) as exc:
                        # termios.error is not an OSError on every Python build.
                        # A vanished USB TTY must not discard already captured evidence.
                        event(records, "cleanup-warning", operation="restore-terminal",
                              error_type=type(exc).__name__, message=str(exc))
                os.close(fd)
        event(records, "stopped", **summary)
    writes_occurred = bool(summary.get("development", {}).get("bytes_sent", 0))
    (output / "summary.json").write_text(json.dumps({**summary, "identity": identity,
        "application_serial_writes": writes_occurred, "boot_success": "not-assessed"}, indent=2, sort_keys=True) + "\n")
    sums = []
    for name in ("serial.bin", "serial.jsonl", "summary.json"):
        digest = hashlib.sha256()
        with (output / name).open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        sums.append(digest.hexdigest() + "  " + name + "\n")
    (output / "SHA256SUMS").write_text("".join(sums))
    print(json.dumps(summary, sort_keys=True))
    info = summary.get("development")
    failed_development = info is not None and (not info["guest_binding_observed"] or info["failure"] or info["unfinished_request"] or
        any(item["result"] in ("refused", "observed-module-error") for item in info["completed_commands"]))
    return 2 if failed_development or summary["bytes_received"] == 0 or summary["stop_reason"] in ("disconnected", "byte-limit") else 0


def positive(value):
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("list", help="inspect Linux sysfs only; never opens serial devices")
    for action in ("capture", "develop"):
        reader = commands.add_parser(action, help="read-only capture" if action == "capture" else "explicit fixed-command session; never boots")
        reader.add_argument("--device", required=True)
        reader.add_argument("--output", required=True, type=Path)
        reader.add_argument("--seconds", type=positive, default=600)
        reader.add_argument("--wait-seconds", type=positive, default=300, help="wait for enumeration before opening; default 300")
        reader.add_argument("--max-bytes", type=positive, default=64 * 1024 * 1024)
        reader.add_argument("--acknowledge-proxy-entry", action="store_true", help="opening can change boot flow; not permission to boot")
        if action == "develop":
            reader.add_argument("--manifest", type=Path, required=True)
            reader.add_argument("--manifest-sha256", required=True)
            reader.add_argument("--acknowledge-target-commands", action="store_true")
            reader.add_argument("--allow-core-probe", action="store_true", help="permit stdin probe-core; programs hardware")
            reader.add_argument("--allow-dart-probe", action="store_true", help="permit stdin probe-dart; can disrupt USB debugging")
    args = parser.parse_args()
    try:
        require(sys.platform == "linux", "run this receiver on the Linux desktop")
        if args.action == "list":
            devices = list_devices()
            print(json.dumps({"secondary_consoles": devices, "device_opened": False}, indent=2))
            return 0 if devices else 2
        require(args.acknowledge_proxy_entry, "opening requires --acknowledge-proxy-entry")
        development = None
        if args.action == "develop":
            require(args.acknowledge_target_commands, "development mode requires --acknowledge-target-commands")
            development = {"manifest": development_binding(args.manifest, args.manifest_sha256), "input_fd": sys.stdin.fileno(),
                           "allow_core": args.allow_core_probe, "allow_dart": args.allow_dart_probe}
        return capture(args.device, args.output, args.seconds, args.max_bytes, args.wait_seconds, development)
    except (OSError, ValueError, termios.error) as exc:
        print("error: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
