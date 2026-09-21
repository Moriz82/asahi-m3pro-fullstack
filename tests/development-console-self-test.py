#!/usr/bin/env python3
"""Restricted console regressions. Pure protocol and PTYs; never real USB."""
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
import tempfile
import threading
import time
import unittest
from unittest import mock

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receiver", PROJECT / "scripts/usb-debug-receiver.py")
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


def manifest():
    return {"format": 4, "component": "restricted-development-ram-only-guest", "target": "Mac15,6/J514s/T6030",
            "interface": "fixed-commands-not-shell", "console_protocol": 2, "module_groups": receiver.APPROVED_GROUPS,
            "nvme_policy": "modules-absent-and-device-tree-disabled", "hardware_acceptance": False,
            "boot_authorized": False, "canonical_m0": False, "persistent_root": False,
            "init_sha256": "1" * 64, "module_manifest_sha256": "2" * 64,
            "payload_sha256": "3" * 64, "kernel_release": "7.1.9.asahi1+",
            "kernel_notes_sha256": "4" * 64, "console_binding_sha256": "5" * 64}


def hello(nonce, binding=None):
    binding = binding or manifest()
    return (f'M3DEV hello protocol=2 nonce={nonce} init_sha256={binding["init_sha256"]} '
            f'modules_sha256={binding["module_manifest_sha256"]} kernel_notes_sha256={binding["kernel_notes_sha256"]} '
            f'bundle_sha256={binding["console_binding_sha256"]} kernel_release={binding["kernel_release"]}\n').encode()


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="m3dev-console-")
        self.root = Path(self.temporary.name).resolve()
        self.records = io.StringIO()
        self.stdout = contextlib.redirect_stdout(io.StringIO()); self.stdout.__enter__()
        self.options = {"manifest": manifest(), "input_fd": 0, "allow_core": False, "allow_dart": False}
        self.console = receiver.DevelopmentConsole(self.options, self.records)

    def tearDown(self):
        self.stdout.__exit__(None, None, None)
        self.temporary.cleanup()

    def write(self):
        data = self.console.pending
        with mock.patch.object(receiver.os, "write", return_value=len(data)) as sending:
            self.console.write_ready(987)
        self.assertEqual(sending.call_args.args, (987, data))
        return data

    def ready(self):
        self.console.feed(b"M3DEV phase=development-ready hardware_acceptance=false\n")
        nonce = self.console.nonce
        self.assertEqual(self.write(), b"hello " + nonce.encode() + b"\n")
        self.console.feed(hello(nonce))
        self.assertEqual(self.console.phase, "idle")
        self.assertTrue(self.console.verified)

    def request(self, command):
        self.console.input(command.encode() + b"\n")
        nonce = self.console.nonce
        self.assertEqual(self.write(), b"hello " + nonce.encode() + b"\n")
        self.console.feed(hello(nonce))

    def binding(self, value):
        path = self.root / "manifest.json"
        data = json.dumps(value).encode() if not isinstance(value, bytes) else value
        path.write_bytes(data)
        return receiver.development_binding(path, hashlib.sha256(data).hexdigest())

    def test_manifest_hash_shape_duplicates_and_storage_policy(self):
        self.assertEqual(self.binding(manifest()), manifest())
        for key, value in (("format", 2), ("format", True), ("target", "other"), ("boot_authorized", True),
                           ("persistent_root", True), ("module_groups", {}), ("kernel_release", "bad\nname"),
                           ("init_sha256", "short"), ("console_protocol", True)):
            with self.subTest(key=key, value=value):
                data = manifest(); data[key] = value
                with self.assertRaises(ValueError): self.binding(data)
        with self.assertRaisesRegex(ValueError, "duplicate"): self.binding(b'{"format":3,"format":3}')
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            receiver.development_binding(self.root / "manifest.json", "0" * 64)

    def test_manifest_oversize_and_symlink_rejected(self):
        path = self.root / "big"; path.write_bytes(b"X" * 65537)
        with self.assertRaisesRegex(ValueError, "too large"): receiver.development_binding(path, "0" * 64)
        link = self.root / "link"; link.symlink_to(path)
        with self.assertRaisesRegex(ValueError, "canonical"): receiver.development_binding(link, "0" * 64)

    def test_host_group_allowlist_matches_candidate_builder(self):
        spec = importlib.util.spec_from_file_location("candidate", PROJECT / "scripts/development-candidate.py")
        candidate = importlib.util.module_from_spec(spec); spec.loader.exec_module(candidate)
        self.assertEqual(receiver.APPROVED_GROUPS, {key: list(value) for key,value in candidate.GROUPS.items()})

    def test_no_command_before_ready_and_no_old_hello_replay(self):
        self.console.accept("status")
        self.console.feed(hello("a" * 32))
        self.assertEqual(self.console.pending, b"")
        self.assertIsNone(self.console.request)
        self.console.feed(b"M3DEV phase=development-ready hardware_acceptance=false\n")
        nonce = self.console.nonce
        self.console.feed(hello(nonce))  # Response before complete transmission is not accepted.
        self.assertFalse(self.console.verified)
        self.write()
        self.console.feed(hello("b" * 32))
        self.assertEqual(self.console.phase, "waiting-hello")
        self.console.feed(hello(nonce))
        self.assertEqual(self.console.phase, "idle")

    def test_chunk_boundaries_record_bodies_control_bytes_and_limits(self):
        self.console.feed(b"X" * 2000 + b"M3DEV phase=development-ready hardware_acceptance=false\n")
        self.assertEqual(self.console.pending, b"")
        self.console.feed(b"M3DEV record-begin name=fixture\nM3DEV phase=development-ready hardware_acceptance=false\nM3DEV record-end name=fixture\n")
        self.assertEqual(self.console.pending, b"")
        data = b"\xff\x1b[2J\nM3DEV phase=development-ready hardware_acceptance=false\r\n"
        for byte in data: self.console.feed(bytes([byte]))
        self.write()
        for byte in hello(self.console.nonce): self.console.feed(bytes([byte]))
        self.assertTrue(self.console.verified)
        self.assertLessEqual(len(self.console.line), 1024)

    def test_wrong_guest_identity_disables_all_writes(self):
        self.console.feed(b"M3DEV phase=development-ready hardware_acceptance=false\n")
        self.write()
        other = manifest(); other["init_sha256"] = "f" * 64
        self.console.feed(hello(self.console.nonce, other))
        self.assertEqual(self.console.failure, "guest-identity-mismatch")
        self.console.accept("status")
        with mock.patch.object(receiver.os, "write") as sending: self.console.write_ready(987)
        sending.assert_not_called()

    def test_each_request_gets_a_fresh_challenge(self):
        self.ready(); original = self.console.nonce
        self.request("status")
        self.assertNotEqual(self.console.nonce, original)
        self.assertEqual(self.write(), b"status\n")
        self.console.feed(b"M3DEV status uptime=5.00 core_attempted=false dart_attempted=false hardware_acceptance=false\n")
        self.assertEqual(self.console.completed, [{"command":"status", "result":"observed"}])

    def test_exact_status_help_and_correlated_fdt(self):
        self.ready(); self.request("status"); self.write()
        for line in (b"M3DEV status uptime=\n", b"M3DEV status uptime=0 injected=true\n"):
            self.console.feed(line); self.assertEqual(self.console.completed, [])
        self.console.phase, self.console.request = "waiting-reply", "help"
        self.console.feed(b"M3DEV commands=reboot\n")
        self.assertEqual(self.console.completed, [])
        self.console.phase, self.console.request = "waiting-reply", "fdt"
        self.console.feed(b"M3DEV record-end name=runtime-fdt\n")
        self.assertEqual(self.console.completed, [])
        begin = b"M3DEV record-begin name=runtime-fdt status=0 bytes=4 sha256=" + b"a" * 64 + b" encoding=base64 truncated=false\n"
        for bad in (begin.replace(b"status=0", b"status=1"), begin.replace(b"truncated=false", b"truncated=true")):
            self.console.feed(bad + b"M3DEV record-end name=runtime-fdt\n")
            self.assertEqual(self.console.completed, [])
        self.console.feed(begin + b"M3DEV record-end name=other\nM3DEV record-end name=runtime-fdt\n")
        self.assertEqual(self.console.completed, [])
        self.console.feed(begin + b"AAAAAA==\nM3DEV record-end name=runtime-fdt\n")
        self.assertEqual(self.console.completed, [{"command":"fdt", "result":"observed"}])

    def test_wrong_kernel_or_bundle_never_arms(self):
        for key in ("kernel_notes_sha256", "console_binding_sha256"):
            control = receiver.DevelopmentConsole({**self.options, "allow_core": True}, io.StringIO())
            control.phase, control.request, control.nonce = "waiting-hello", "probe-core", "a" * 32
            wrong = manifest(); wrong[key] = "f" * 64
            control.feed(hello(control.nonce, wrong))
            self.assertEqual(control.failure, "guest-identity-mismatch")
            self.assertEqual(control.pending, b"")

    def test_partial_arm_and_probe_writes_stay_ambiguous_on_disconnect(self):
        for command in ("arm-core", "probe-core"):
            control = receiver.DevelopmentConsole(self.options, io.StringIO())
            control.request = "probe-core"
            control.queue(command, "waiting-arm" if command == "arm-core" else "waiting-reply")
            with mock.patch.object(receiver.os, "write", side_effect=[4, OSError(errno.EIO, "disconnected")]) as sending:
                control.write_ready(987); control.write_ready(987)
            self.assertEqual(sending.call_args.args[1], (command + "\n").encode()[4:])
            self.assertEqual(control.failure, "serial-write-error")
            self.assertEqual(control.completed, [])
            self.assertEqual(control.request, "probe-core")
            self.assertEqual(control.probes_sent, [])

    def test_command_allowlist_no_shell_and_busy_requests_not_queued(self):
        self.ready()
        for command in (b"reboot\n", b"arm-core\n", b"probe-dart\n", b"probe-core\n", b"$(touch /tmp/no)\n", b"status;sh\n", b"status\x00\n", b"\xff\n", b"X" * 100 + b"\n"):
            self.console.input(command)
            self.assertEqual(self.console.pending, b"")
        self.console.input(b"status\n")
        pending = self.console.pending
        self.console.input(b"snapshot\n")
        self.assertEqual(self.console.pending, pending)
        self.assertEqual(self.console.request, "status")

    def test_partial_writes_eagain_and_error_never_resend_prefix(self):
        self.console.feed(b"M3DEV phase=development-ready hardware_acceptance=false\n")
        pending = self.console.pending
        with mock.patch.object(receiver.os, "write", side_effect=[3, BlockingIOError(), OSError(errno.EIO, "gone")]) as sending:
            self.console.write_ready(987); self.console.write_ready(987); self.console.write_ready(987)
        self.assertEqual(sending.call_args_list[1].args[1], pending[3:])
        self.assertEqual(sending.call_args_list[2].args[1], pending[3:])
        self.assertEqual(self.console.bytes_sent, 3)
        self.assertEqual(self.console.failure, "serial-write-error")
        self.assertEqual(self.console.pending, b"")

    def test_timeout_and_guest_blocked_fail_closed(self):
        self.console.deadline = 0
        self.console.tick()
        self.assertEqual(self.console.failure, "timeout-waiting-ready")
        other = receiver.DevelopmentConsole(self.options, io.StringIO())
        other.feed(b"M3DEV phase=blocked reason=storage-visible hardware_acceptance=false\n")
        self.assertEqual(other.failure, "guest-blocked")

    def test_probe_requires_own_permission_fresh_hello_arm_and_exact_order(self):
        self.options["allow_core"] = True
        self.ready(); self.request("probe-core")
        self.assertEqual(self.write(), b"arm-core\n")
        self.console.feed(b"M3DEV dart-armed next=probe-dart expires_seconds=10 warning=resets-IOMMUs-may-disrupt-USB-debugging\n")
        self.assertEqual(self.console.pending, b"")
        self.console.feed(b"M3DEV core-armed next=probe-core expires_seconds=10 warning=programs-hardware\n")
        self.assertEqual(self.write(), b"probe-core\n")
        for module in receiver.APPROVED_GROUPS["core"]:
            path = "lib/modules/7.1.9.asahi1+/" + module
            self.console.feed(f"M3DEV module-probe-begin group=core path={path}\nM3DEV module-probe path={path} status=0\n".encode())
        self.console.feed(b"M3DEV snapshot-end label=after-core hardware_acceptance=false\n")
        self.assertEqual(self.console.completed[-1]["result"], "observed-no-module-error")
        self.assertEqual(self.console.probes_sent, ["probe-core"])
        self.console.accept("probe-core"); self.console.accept("probe-dart")
        self.assertEqual(self.console.pending, b"")

    def test_unexpected_module_or_missing_completion_is_not_success(self):
        for data in (b"M3DEV module-probe-begin group=core path=lib/modules/wrong/nvme.ko\n",
                     b"M3DEV snapshot-end label=after-core hardware_acceptance=false\n"):
            control = receiver.DevelopmentConsole(self.options, io.StringIO())
            control.phase, control.request = "waiting-reply", "probe-core"
            control.feed(data)
            self.assertTrue(control.failure)
            self.assertEqual(control.completed, [])

    def test_module_error_recorded_not_called_success(self):
        self.console.phase, self.console.request = "waiting-reply", "probe-dart"
        path = "lib/modules/7.1.9.asahi1+/" + receiver.APPROVED_GROUPS["dart"][0]
        self.console.feed(f"M3DEV module-probe-begin group=dart path={path}\nM3DEV module-probe path={path} status=37\nM3DEV snapshot-end label=after-dart hardware_acceptance=false\n".encode())
        self.assertEqual(self.console.completed[-1]["result"], "observed-module-error")

    def test_stdin_eof_keeps_capture_and_quit_never_transmits(self):
        self.ready(); self.console.input(b"")
        self.assertTrue(self.console.input_closed)
        self.assertIsNone(self.console.stop_at)
        self.console.input(b"quit\n")
        self.assertEqual(self.console.phase, "quitting")
        self.assertEqual(self.console.pending, b"")

    def test_cli_needs_both_acknowledgments_before_usb_lookup(self):
        path = self.root / "manifest.json"; path.write_text(json.dumps(manifest()))
        args = ["receiver", "develop", "--device", "/dev/ttyACM7", "--output", str(self.root / "out"),
                "--manifest", str(path), "--manifest-sha256", hashlib.sha256(path.read_bytes()).hexdigest()]
        for acknowledgments in ([], ["--acknowledge-proxy-entry"], ["--acknowledge-target-commands"]):
            with mock.patch.object(receiver.sys, "platform", "linux"), mock.patch.object(receiver.sys, "argv", args + acknowledgments), \
                 mock.patch.object(receiver, "usb_identity") as identify, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(receiver.main(), 1)
                identify.assert_not_called()

    def test_real_pty_duplex_capture_with_fresh_identity_and_status(self):
        master, slave = pty.openpty()
        path, number = os.ttyname(slave), os.fstat(slave).st_rdev
        os.close(slave)
        input_read, input_write = os.pipe()
        target = self.root / "capture"
        options = {**self.options, "input_fd": input_read}
        identity = {"device": path, "device_number": number, "interface": "02"}
        failures, received, transmitted = [], [], []
        def peer():
            buffered = b""
            def wait_event(name):
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    log = target / "serial.jsonl"
                    if log.exists() and '"event": "' + name + '"' in log.read_text(): return
                    time.sleep(.005)
                raise AssertionError("missing event " + name)
            def read_line():
                nonlocal buffered
                deadline = time.monotonic() + 4
                while b"\n" not in buffered:
                    if time.monotonic() > deadline: raise AssertionError("peer timed out")
                    if select.select([master], [], [], .05)[0]: buffered += os.read(master, 4096)
                line, buffered = buffered.split(b"\n", 1)
                transmitted.append(line + b"\n")
                return line.decode()
            def send(data):
                received.append(data); os.write(master, data)
            try:
                wait_event("connected")
                send(b"M3DEV phase=development-ready hardware_acceptance=false\n")
                first = read_line(); self.assertTrue(first.startswith("hello "))
                send(hello(first.split()[1])); wait_event("development-ready")
                os.write(input_write, b"status\n")
                second = read_line(); self.assertTrue(second.startswith("hello ")); self.assertNotEqual(first, second)
                send(hello(second.split()[1]))
                self.assertEqual(read_line(), "status")
                send(b"M3DEV status uptime=8.00 core_attempted=false dart_attempted=false hardware_acceptance=false\n")
                wait_event("command-completed"); os.write(input_write, b"quit\n")
            except BaseException as exc: failures.append(repr(exc))
        producer = threading.Thread(target=peer); producer.start()
        saved_umask = os.umask(0o077)
        try:
            original_open = receiver.os.open
            with mock.patch.object(receiver, "usb_identity", return_value=identity), mock.patch.object(receiver.os, "open", wraps=original_open) as opening:
                self.assertEqual(receiver.capture(path, target, 6, 65536, development=options), 0)
                self.assertEqual(opening.call_args.args[1] & os.O_ACCMODE, os.O_RDWR)
            producer.join(5)
            self.assertFalse(producer.is_alive()); self.assertEqual(failures, [])
            self.assertEqual((target / "serial.bin").read_bytes(), b"".join(received))
            summary = json.loads((target / "summary.json").read_text())
            self.assertTrue(summary["application_serial_writes"])
            self.assertFalse(summary["hardware_acceptance"])
            self.assertEqual(summary["development"]["bytes_sent"], len(b"".join(transmitted)))
            self.assertEqual(summary["development"]["completed_commands"], [{"command":"status", "result":"observed"}])
            events = [json.loads(line) for line in (target / "serial.jsonl").read_text().splitlines()]
            self.assertEqual(b"".join(row["text"].encode("ascii") for row in events if row["event"] == "transmit"), b"".join(transmitted))
            for line in (target / "SHA256SUMS").read_text().splitlines():
                digest, name = line.split("  ", 1)
                self.assertEqual(hashlib.sha256((target / name).read_bytes()).hexdigest(), digest)
        finally:
            producer.join(5)
            for fd in (master, input_read, input_write): os.close(fd)
            os.umask(saved_umask)


if __name__ == "__main__": unittest.main()
