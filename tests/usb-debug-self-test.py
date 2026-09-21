#!/usr/bin/env python3
"""Receiver tests: synthetic sysfs and PTYs only, never a real USB device."""
import contextlib
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import select
import stat
import subprocess
import sys
import tempfile
import termios
import threading
import time
import types
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receiver", PROJECT / "scripts/usb-debug-receiver.py")
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="usb-debug-test-")
        self.root = Path(self.temp.name).resolve()
        self.dev = self.root / "dev"
        self.dev.mkdir()
        self.device = self.dev / "ttyACM7"
        self.device.touch()
        self.usb = self.root / "usb/1-2"
        self.interface = self.usb / "1-2:1.2"
        self.interface.mkdir(parents=True)
        self.sysfs = self.root / "sys/class/tty"
        entry = self.sysfs / "ttyACM7"
        entry.mkdir(parents=True)
        (entry / "device").symlink_to(self.interface)
        (entry / "dev").write_text("166:7\n")
        (self.interface / "bInterfaceNumber").write_text("02\n")
        (self.usb / "idVendor").write_text("1209\n")
        (self.usb / "idProduct").write_text("316d\n")

    def tearDown(self):
        self.temp.cleanup()

    def identity(self, **override):
        original = Path.stat

        def fixture_stat(path, *args, **kwargs):
            if path == self.device:
                return types.SimpleNamespace(st_mode=override.get("mode", stat.S_IFCHR | 0o600),
                                             st_rdev=override.get("rdev", os.makedev(166, 7)))
            return original(path, *args, **kwargs)

        with mock.patch.object(Path, "stat", fixture_stat):
            return receiver.usb_identity(self.device, self.sysfs, self.dev)

    def test_secondary_identity(self):
        self.assertEqual(self.identity()["interface"], "02")

    def test_primary_refused(self):
        (self.interface / "bInterfaceNumber").write_text("00\n")
        with self.assertRaisesRegex(ValueError, "primary proxy"):
            self.identity()

    def test_wrong_vendor_product_interface(self):
        for file, value in ((self.usb / "idVendor", "05ac"), (self.usb / "idProduct", "1234"),
                            (self.interface / "bInterfaceNumber", "03")):
            original = file.read_text()
            file.write_text(value)
            with self.subTest(file=file.name), self.assertRaises(ValueError):
                self.identity()
            file.write_text(original)

    def test_regular_file_and_wrong_device_number_refused(self):
        for value in ({"mode": stat.S_IFREG | 0o600}, {"rdev": os.makedev(166, 9)}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.identity(**value)

    def test_symlink_to_wrong_device_class_refused(self):
        with self.assertRaisesRegex(ValueError, "ttyACM|under /dev"):
            receiver.usb_identity(Path("/dev/null"))

    def test_missing_sysfs_refused(self):
        (self.interface / "bInterfaceNumber").unlink()
        with self.assertRaises(OSError):
            self.identity()

    def test_wait_for_enumeration_without_opening(self):
        with mock.patch.object(receiver, "usb_identity", side_effect=[FileNotFoundError(), {"interface": "02"}]), \
             mock.patch.object(receiver.time, "sleep"), mock.patch.object(receiver.os, "open") as opening:
            self.assertEqual(receiver.wait_identity("/dev/m1n1-sec", 1), {"interface": "02"})
            opening.assert_not_called()

    def test_wait_does_not_hide_wrong_interface_or_timeout(self):
        with mock.patch.object(receiver, "usb_identity", side_effect=ValueError("primary proxy")):
            with self.assertRaisesRegex(ValueError, "primary proxy"):
                receiver.wait_identity("/dev/ttyACM0", 1)
        with mock.patch.object(receiver, "usb_identity", side_effect=FileNotFoundError()):
            with self.assertRaisesRegex(ValueError, "timed out"):
                receiver.wait_identity("/dev/m1n1-sec", 0)

    def test_output_never_overwritten(self):
        target = self.root / "session"
        receiver.new_session(target)
        (target / "keep").write_text("preserved")
        with self.assertRaisesRegex(ValueError, "existing"):
            receiver.new_session(target)
        self.assertEqual((target / "keep").read_text(), "preserved")
        self.assertEqual(target.stat().st_mode & 0o777, 0o700)

    def test_symlink_parent_and_existing_symlink_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.dev, target_is_directory=True)
        with self.assertRaises(ValueError):
            receiver.new_session(alias / "session")
        with self.assertRaises(ValueError):
            receiver.new_session(alias)

    def test_no_data_times_out_not_success(self):
        master, slave = pty.openpty()
        try:
            receiver.configure(slave)
            result = receiver.receive(slave, io.BytesIO(), io.StringIO(), .02, 100)
            self.assertEqual(result["bytes_received"], 0)
            self.assertEqual(result["stop_reason"], "duration-limit")
            self.assertFalse(result["hardware_acceptance"])
        finally:
            os.close(slave)
            os.close(master)

    def test_pty_byte_fidelity_control_escaping_and_no_echo(self):
        master, slave = pty.openpty()
        try:
            receiver.configure(slave)
            payload = b"M1 phase=initramfs-start\r\n\x1b[2J\x00\x03\xfftest\n"
            os.write(master, payload)  # Synthetic target writes; receiver never does.
            raw, records = io.BytesIO(), io.StringIO()
            result = receiver.receive(slave, raw, records, 1, len(payload))
            self.assertEqual(raw.getvalue(), payload)
            self.assertEqual(result["stop_reason"], "byte-limit")
            self.assertEqual(result["raw_sha256"], hashlib.sha256(payload).hexdigest())
            self.assertNotIn("\x1b", records.getvalue())
            self.assertNotIn("\r", records.getvalue())
            recovered = b"".join(json.loads(line)["text"].encode("latin-1") for line in records.getvalue().splitlines())
            self.assertEqual(recovered, payload)
            self.assertEqual(select.select([master], [], [], .02)[0], [])
        finally:
            os.close(slave)
            os.close(master)

    def test_capture_uses_readonly_fd_and_writes_complete_session(self):
        master, slave = pty.openpty()
        path = os.ttyname(slave)
        number = os.fstat(slave).st_rdev
        os.close(slave)
        target = self.root / "capture"
        identity = {"device": path, "device_number": number, "interface": "02"}
        payload = b"M1 diagnostic-end name=dmesg\n"
        failures = []

        def send_fixture():
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    file = target / "serial.jsonl"
                    if file.exists() and '"connected"' in file.read_text():
                        os.write(master, payload)
                        return
                    time.sleep(.01)
                failures.append("receiver never connected")
            except Exception as exc:
                failures.append(str(exc))

        producer = threading.Thread(target=send_fixture)
        producer.start()
        saved_umask = os.umask(0o077)
        try:
            original_open = receiver.os.open
            with mock.patch.object(receiver, "usb_identity", return_value=identity), \
                 mock.patch.object(receiver.os, "open", wraps=original_open) as opening, \
                 contextlib.redirect_stdout(io.StringIO()):
                status = receiver.capture(path, target, .5, 4096)
            self.assertEqual(status, 0)
            flags = opening.call_args.args[1]
            self.assertEqual(flags & os.O_ACCMODE, os.O_RDONLY)
            self.assertEqual((target / "serial.bin").read_bytes(), payload)
            summary = json.loads((target / "summary.json").read_text())
            self.assertEqual(summary["boot_success"], "not-assessed")
            self.assertFalse(summary["application_serial_writes"])
            self.assertEqual(len((target / "SHA256SUMS").read_text().splitlines()), 3)
            for name in ("serial.bin", "serial.jsonl", "summary.json", "SHA256SUMS"):
                self.assertEqual((target / name).stat().st_mode & 0o777, 0o600)
        finally:
            producer.join(4)
            os.close(master)
            os.umask(saved_umask)
        self.assertFalse(producer.is_alive())
        self.assertEqual(failures, [])

    def test_byte_limit_is_exact(self):
        master, slave = pty.openpty()
        try:
            receiver.configure(slave)
            os.write(master, b"x" * 100)
            raw = io.BytesIO()
            result = receiver.receive(slave, raw, io.StringIO(), 1, 17)
            self.assertEqual(result["bytes_received"], 17)
            self.assertEqual(raw.getvalue(), b"x" * 17)
        finally:
            os.close(slave)
            os.close(master)

    def test_disconnect_during_terminal_restore_preserves_evidence(self):
        for error in (errno.EIO, errno.ENODEV):
            with self.subTest(error=error):
                master, slave = pty.openpty()
                saved_umask = os.umask(0o077)
                target = self.root / ("restore-disconnected-" + str(error))
                identity = {"device": os.ttyname(slave), "device_number": os.fstat(slave).st_rdev,
                            "interface": "02", "vendor": "1209", "product": "316d", "usb_path": "fixture"}
                original = termios.tcgetattr(slave)
                summary = {"stop_reason": "disconnected", "bytes_received": 0,
                           "raw_sha256": hashlib.sha256(b"").hexdigest(),
                           "capture_continuity": "unproven", "hardware_acceptance": False}
                try:
                    with mock.patch.object(receiver, "usb_identity", return_value=identity), \
                         mock.patch.object(receiver, "configure", return_value=original), \
                         mock.patch.object(receiver, "receive", return_value=summary), \
                         mock.patch.object(receiver.termios, "tcsetattr", side_effect=termios.error(error, "disconnected")), \
                         mock.patch.object(receiver.os, "close", wraps=os.close) as closing, \
                         contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(receiver.capture(identity["device"], target, .01, 10), 2)
                        closing.assert_called_once()
                    records = [json.loads(line) for line in (target / "serial.jsonl").read_text().splitlines()]
                    self.assertEqual(records[-1]["event"], "stopped")
                    self.assertEqual(records[-1]["stop_reason"], "disconnected")
                    self.assertTrue(any(r["event"] == "cleanup-warning" for r in records))
                    for line in (target / "SHA256SUMS").read_text().splitlines():
                        digest, name = line.split("  ", 1)
                        self.assertEqual(hashlib.sha256((target / name).read_bytes()).hexdigest(), digest)
                finally:
                    os.close(slave)
                    os.close(master)
                    os.umask(saved_umask)

    def test_disconnect_reported(self):
        for error in (errno.EIO, errno.ENODEV):
            with mock.patch.object(receiver.select, "select", return_value=([10], [], [])), \
                 mock.patch.object(receiver.os, "read", side_effect=OSError(error, "disconnected")):
                result = receiver.receive(10, io.BytesIO(), io.StringIO(), 1, 100)
            self.assertEqual(result["stop_reason"], "disconnected")

    def test_unknown_read_error_not_hidden(self):
        with mock.patch.object(receiver.select, "select", return_value=([10], [], [])), \
             mock.patch.object(receiver.os, "read", side_effect=OSError(errno.EBADF, "bad fd")):
            with self.assertRaises(OSError):
                receiver.receive(10, io.BytesIO(), io.StringIO(), 1, 100)

    def test_interrupt_is_host_only(self):
        with mock.patch.object(receiver.select, "select", side_effect=KeyboardInterrupt):
            result = receiver.receive(10, io.BytesIO(), io.StringIO(), 1, 100)
        self.assertEqual(result["stop_reason"], "operator-interrupt")

    def test_capture_requires_ack_before_device_lookup(self):
        with mock.patch.object(receiver.sys, "platform", "linux"), \
             mock.patch.object(receiver.sys, "argv", ["receiver", "capture", "--device", "/dev/ttyACM7", "--output", str(self.root / "out")]), \
             mock.patch.object(receiver, "usb_identity") as identify, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(receiver.main(), 1)
            identify.assert_not_called()

    def test_list_never_opens_device(self):
        with mock.patch.object(receiver.sys, "platform", "linux"), \
             mock.patch.object(receiver.sys, "argv", ["receiver", "list"]), \
             mock.patch.object(receiver, "list_devices", return_value=[]), \
             mock.patch.object(receiver.os, "open") as opening, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(receiver.main(), 2)
            opening.assert_not_called()

    def test_cli_rejects_transmit_and_invalid_limits(self):
        script = str(PROJECT / "scripts/usb-debug-receiver.py")
        for arguments in (["send", "reboot"], ["capture", "--device", "/dev/ttyACM0", "--output", "/tmp/no",
                                               "--seconds", "0"]):
            result = subprocess.run([sys.executable, script, *arguments], capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
