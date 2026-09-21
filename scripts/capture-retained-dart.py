#!/usr/bin/env python3
"""Linux-only, single-session adapter for retained-dart-snapshot.py. Never boots.

Without --approve-pre-linux-capture, inspect sysfs only (no serial open).
Approval asserts a fresh, exclusively owned m1n1 pause before Linux; it is not
remote attestation. Target reads can fault. No automatic retry or continuation.
"""
import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import stat
import sys
import termios

STAGE = 'approved-exclusive-m1n1-before-linux'
RUNTIME_DIGEST = '91fb7bc3ab8dafc161681ac6cb215ed4aa857acf476d2fd786e1f1c613ca9c05'


def require(value, message):
    if not value:
        raise ValueError(message)


def identity(device, usb_path, *, sysfs=Path('/sys/class/tty'), dev_root=Path('/dev')):
    node = Path(device)
    require(node.parent == dev_root and re.fullmatch(r'ttyACM[0-9]+', node.name)
            and not node.is_symlink(), 'use the real /dev/ttyACM node')
    info = node.stat()
    require(stat.S_ISCHR(info.st_mode), 'not a character device')
    entry = sysfs / node.name
    interface = (entry / 'device').resolve(strict=True)
    usb = interface.parent
    require((usb / 'idVendor').read_text().strip() == '1209' and
            (usb / 'idProduct').read_text().strip() == '316d' and
            (interface / 'bInterfaceNumber').read_text().strip() == '00' and
            usb.name == usb_path, 'primary USB identity/path mismatch')
    require((entry / 'dev').read_text().strip() ==
            f'{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}', 'device number mismatch')
    return dict(device=str(node), usb_path=usb.name, interface='00',
                device_number=info.st_rdev)


class EscapedLog:
    def __init__(self, stream):
        self.stream, self.count = stream, 0

    def write(self, text):
        self.count += len(text.encode('utf-8', errors='replace'))
        require(self.count <= 2 << 20, 'controller log limit reached')
        self.stream.write(json.dumps(dict(text=text), ensure_ascii=True) + '\n')
        self.stream.flush()
        return len(text)

    def flush(self):
        self.stream.flush()


def deadline(signum, frame):
    raise TimeoutError('capture deadline reached; no retry')


def bind_runtime(root=None):
    require(sys.flags.isolated and sys.flags.no_site, 'launch with python3 -I -S -B')
    require(not any(n == 'm1n1' or n.startswith('m1n1.') or n == 'serial' or
                    n.startswith('serial.') or n == 'construct' or n.startswith('construct.')
                    for n in sys.modules), 'controller/dependencies already imported')
    root = root or Path(__file__).resolve().parents[1] / 'runtime'
    require(root.is_dir() and root == root.resolve(), 'missing/noncanonical bundled runtime')
    fingerprint = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'runtime symlink rejected')
        if path.is_file():
            fingerprint.update(path.relative_to(root).as_posix().encode() + b'\0' +
                               hashlib.sha256(path.read_bytes()).digest())
        else:
            require(path.is_dir(), 'unexpected runtime entry')
    require(fingerprint.hexdigest() == RUNTIME_DIGEST, 'bundled runtime fingerprint mismatch')
    sys.path.insert(0, str(root))


def require_no_owner(device_number, owned_fd=None, proc=Path('/proc')):
    # Must run as root to see other users' descriptors. Reject inaccessible proc
    # entries rather than claim exclusivity. This is not isolation from hostile root.
    require(os.geteuid() == 0, 'capture requires sudo for complete /proc owner checks')
    for process in proc.iterdir():
        if not process.name.isdigit():
            continue
        try:
            for fd in (process / 'fd').iterdir():
                if int(process.name) == os.getpid() and owned_fd == int(fd.name):
                    continue
                try:
                    info = fd.stat()
                except (FileNotFoundError, ProcessLookupError):
                    continue
                require(not (stat.S_ISCHR(info.st_mode) and info.st_rdev == device_number),
                        f'primary port already open by PID {process.name}; stop, do not kill it')
        except (FileNotFoundError, ProcessLookupError):
            continue


def collect(device, usb_path, expected, output, *, approved_stage=None):
    require(approved_stage == STAGE, 'explicit pre-Linux capture approval required')
    require_no_owner(expected['device_number'])
    bind_runtime()
    # Import only the low-level proxy, never setup, ProxyUtils, HV or a DART.
    from m1n1.proxy import Serial, UartInterface, M1N1Proxy
    snap = runpy.run_path(str(Path(__file__).with_name('retained-dart-snapshot.py')))
    require(identity(device, usb_path) == expected, 'identity changed before open')
    # Pinned Serial intentionally preserves pending RX bytes. No reconnect path.
    with Serial(device, baudrate=115200, timeout=3, write_timeout=3, exclusive=True) as port:
        fcntl.ioctl(port.fileno(), termios.TIOCEXCL)
        require_no_owner(expected['device_number'], owned_fd=port.fileno())
        require(os.fstat(port.fileno()).st_rdev == expected['device_number'] and
                identity(device, usb_path) == expected, 'identity changed during open')
        iface = UartInterface(port, debug=False)
        iface.tty_enable = True  # escaped controller.jsonl owns primary text
        result = snap['capture'](M1N1Proxy(iface, debug=False), approved_stage=approved_stage)
        snap['save_new'](result, output / 'retained-dart.json')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--usb-path', required=True, help='fresh observed sysfs USB path, e.g. 1-1')
    parser.add_argument('--output', type=Path, help='new absolute private session directory')
    parser.add_argument('--approve-pre-linux-capture', action='store_true')
    args = parser.parse_args(argv)
    require(sys.platform.startswith('linux'), 'live adapter requires Linux')
    expected = identity(args.device, args.usb_path)
    if not args.approve_pre_linux_capture:
        print(json.dumps(dict(identity=expected, device_opened=False, target_executed=False)))
        return 0
    output = args.output
    require(output is not None and output.is_absolute() and output == output.resolve()
            and not output.exists(), 'output must be a new absolute canonical directory')
    os.umask(0o077)
    output.mkdir(mode=0o700)
    record = dict(started_utc=datetime.now(timezone.utc).isoformat(), identity=expected,
                  stage_user_asserted='approved-exclusive-m1n1-before-linux',
                  remote_loader_identity_verified=False, hardware_acceptance=False,
                  script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    with (output / 'session.json').open('x') as stream:
        json.dump(record, stream, indent=2)
    for key in list(os.environ):
        if key.startswith('M1N1'):
            del os.environ[key]
    old_handler = signal.signal(signal.SIGALRM, deadline)
    status, code = 'failed', 1
    try:
        with (output / 'controller.jsonl').open('x', encoding='ascii') as stream:
            logger = EscapedLog(stream)
            with contextlib.redirect_stdout(logger), contextlib.redirect_stderr(logger):
                signal.alarm(120)
                try:
                    collect(args.device, args.usb_path, expected, output, approved_stage=STAGE)
                    status, code = 'captured', 0
                except BaseException as exc:
                    # Private escaped diagnostics; do not print target data to terminal.
                    record['error'] = dict(type=type(exc).__name__, message=str(exc)[:4096])
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
    record.update(status=status, finished_utc=datetime.now(timezone.utc).isoformat())
    with (output / 'result.json').open('x') as stream:
        json.dump(record, stream, indent=2)
    with (output / 'SHA256SUMS').open('x') as stream:
        for path in sorted(output.iterdir()):
            if path.name != 'SHA256SUMS':
                stream.write(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n')
    print(json.dumps(dict(status=status, evidence=str(output), boot_started=False)))
    return code


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(json.dumps(dict(error=type(exc).__name__, message=str(exc))), file=sys.stderr)
        raise SystemExit(1)
