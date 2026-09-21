#!/usr/bin/env python3
"""Adapter tests, no real devices or target I/O. Collector has its own suite."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('adapter', ROOT / 'scripts/capture-retained-dart.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
ARGS = ['--device', '/dev/ttyACM0', '--usb-path', '1-1']
IDENTITY = dict(device='/dev/ttyACM0', usb_path='1-1', interface='00', device_number=123)


class Tests(unittest.TestCase):
    def invoke(self, args, collect):
        with patch.object(sys, 'platform', 'linux'), patch.object(adapter, 'identity', return_value=IDENTITY), \
                patch.object(adapter, 'collect', collect), contextlib.redirect_stdout(io.StringIO()):
            return adapter.main(args)

    def test_unapproved_inspection_never_collects(self):
        collect = Mock(side_effect=AssertionError('serial must not open'))
        self.assertEqual(self.invoke(ARGS, collect), 0)
        collect.assert_not_called()

    def test_private_success_and_no_clobber(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary).resolve() / 'session'
            collect = Mock()
            args = ARGS + ['--approve-pre-linux-capture', '--output', str(output)]
            self.assertEqual(self.invoke(args, collect), 0)
            self.assertEqual(collect.call_count, 1)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            result = json.loads((output / 'result.json').read_text())
            self.assertEqual(result['status'], 'captured')
            self.assertFalse(result['hardware_acceptance'])
            self.assertFalse(result['remote_loader_identity_verified'])
            with self.assertRaises(ValueError):
                self.invoke(args, collect)
            self.assertEqual(collect.call_count, 1)
            for path in output.iterdir():
                self.assertEqual(path.stat().st_mode & 0o077, 0)

    def test_fault_and_interrupt_no_retry(self):
        for fault in (TimeoutError('bounded'), KeyboardInterrupt(), ValueError('\x1b[31m')):
            with self.subTest(fault=type(fault).__name__), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary).resolve() / 'session'
                collect = Mock(side_effect=fault)
                self.assertEqual(self.invoke(ARGS + ['--approve-pre-linux-capture', '--output', str(output)], collect), 1)
                self.assertEqual(collect.call_count, 1)
                self.assertEqual(json.loads((output / 'result.json').read_text())['status'], 'failed')
                self.assertNotIn('\x1b', (output / 'result.json').read_text())
                self.assertFalse((output / 'retained-dart.json').exists())

    def test_identity_rejects_wrong_interface_path_and_major(self):
        values = {'idVendor': '1209', 'idProduct': '316d', 'bInterfaceNumber': '00', 'dev': '0:123'}
        def read(path, *args, **kwargs):
            return values[path.name]
        with patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=stat.S_IFCHR, st_rdev=123)), \
                patch.object(Path, 'is_symlink', return_value=False), \
                patch.object(Path, 'resolve', return_value=Path('/sys/usb/1-1/1-1:1.0')), \
                patch.object(Path, 'read_text', read):
            self.assertEqual(adapter.identity('/dev/ttyACM0', '1-1'), IDENTITY)
            for key, value in [('idVendor', '0000'), ('idProduct', '0000'), ('bInterfaceNumber', '02'), ('dev', '0:124')]:
                old = values[key]
                values[key] = value
                with self.assertRaises(ValueError):
                    adapter.identity('/dev/ttyACM0', '1-1')
                values[key] = old
            for device, usb in [('/dev/ttyACM0', '2-1'), ('/tmp/ttyACM0', '1-1'), ('/dev/ttyUSB0', '1-1')]:
                with self.assertRaises(ValueError):
                    adapter.identity(device, usb)

    def test_sole_session_closes_on_fault_and_has_no_continuation(self):
        for fault in (None, ValueError('read fault')):
            port = Mock()
            port.__enter__ = Mock(return_value=port)
            port.__exit__ = Mock(return_value=False)
            port.fileno.return_value = 456
            iface = SimpleNamespace(tty_enable=False)
            proxy = object()
            fake = SimpleNamespace(Serial=Mock(return_value=port), UartInterface=Mock(return_value=iface),
                                   M1N1Proxy=Mock(return_value=proxy))
            capture, save = Mock(return_value={'fixture': True}, side_effect=fault), Mock()
            with patch.dict(sys.modules, {'m1n1.proxy': fake}), \
                    patch.object(adapter, 'bind_runtime'), \
                    patch.object(adapter, 'require_no_owner') as owners, \
                    patch.object(adapter, 'identity', return_value=IDENTITY), \
                    patch.object(adapter.fcntl, 'ioctl') as ioctl, \
                    patch.object(os, 'fstat', return_value=SimpleNamespace(st_rdev=123)), \
                    patch.object(adapter.runpy, 'run_path', return_value={'capture': capture, 'save_new': save, 'STAGE': 'approved'}):
                if fault:
                    with self.assertRaises(ValueError):
                        adapter.collect('/dev/ttyACM0', '1-1', IDENTITY, Path('/tmp/session'), approved_stage=adapter.STAGE)
                    save.assert_not_called()
                else:
                    adapter.collect('/dev/ttyACM0', '1-1', IDENTITY, Path('/tmp/session'), approved_stage=adapter.STAGE)
                    save.assert_called_once()
                fake.Serial.assert_called_once_with('/dev/ttyACM0', baudrate=115200, timeout=3,
                                                    write_timeout=3, exclusive=True)
                ioctl.assert_called_once_with(456, adapter.termios.TIOCEXCL)
                capture.assert_called_once_with(proxy, approved_stage=adapter.STAGE)
                self.assertEqual(owners.call_count, 2)
                port.__exit__.assert_called_once()

    def test_direct_call_without_approval_stops_before_import_or_open(self):
        with patch.object(adapter, 'bind_runtime') as bind, patch.object(adapter, 'require_no_owner') as owners:
            with self.assertRaises(ValueError):
                adapter.collect('/dev/ttyACM0', '1-1', IDENTITY, Path('/tmp/session'))
            bind.assert_not_called()
            owners.assert_not_called()

    def test_runtime_mismatch_prevents_import(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(sys, 'flags', SimpleNamespace(isolated=True, no_site=True)):
            original = list(sys.path)
            with self.assertRaisesRegex(ValueError, 'fingerprint mismatch'):
                adapter.bind_runtime(Path(temporary).resolve())
            self.assertEqual(sys.path, original)

    @unittest.skipUnless(sys.platform.startswith('linux') and os.geteuid() == 0, 'Linux /proc root test')
    def test_preexisting_uncooperative_pty_owner_rejected(self):
        import pty
        master, slave = pty.openpty()
        try:
            number = os.fstat(slave).st_rdev
            with self.assertRaisesRegex(ValueError, 'already open'):
                adapter.require_no_owner(number)
            adapter.require_no_owner(number, owned_fd=slave)
            with patch.object(adapter, 'bind_runtime') as bind:
                with self.assertRaisesRegex(ValueError, 'already open'):
                    adapter.collect('/dev/ttyACM0', '1-1', dict(device_number=number), Path('/tmp/session'),
                                    approved_stage=adapter.STAGE)
                bind.assert_not_called()
        finally:
            os.close(slave)
            os.close(master)

    def test_escaped_log_and_limit(self):
        stream = io.StringIO()
        logger = adapter.EscapedLog(stream)
        logger.write('\x1b[31m target')
        self.assertNotIn('\x1b', stream.getvalue())
        logger.count = 2 << 20
        with self.assertRaises(ValueError):
            logger.write('x')


if __name__ == '__main__':
    unittest.main()
