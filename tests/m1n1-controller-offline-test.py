#!/usr/bin/env python3
"""Smoke-test a pinned proxyclient export on Linux without opening a target.

Python API guards catch accidental target access; these are test tripwires,
not an OS sandbox. Only --help is run from the two native launch tools.
"""

import argparse
import ast
import contextlib
import importlib
import importlib.abc
import importlib.metadata
import io
import os
from pathlib import Path
import runpy
import sys


def blocked(*args, **kwargs):
    raise RuntimeError("offline test forbids target access")


def audit(event, args):
    if event in {"socket.connect", "socket.bind", "socket.getaddrinfo"}:
        blocked()
    if event == "open" and isinstance(args[0], (str, bytes)):
        path = os.fsdecode(args[0])
        if path.startswith("/dev/") and path not in {
            "/dev/null", "/dev/urandom", "/dev/random"
        }:
            blocked()


class NoSetup(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if fullname == "m1n1.setup":
            blocked()
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("proxyclient", type=Path)
    args = parser.parse_args()
    root = args.proxyclient.resolve(strict=True)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(root))
    sys.meta_path.insert(0, NoSetup())
    sys.addaudithook(audit)

    paths = sorted(root.rglob("*.py"))
    if not paths or not (root / "m1n1/hv/__init__.py").is_file():
        raise RuntimeError("missing proxyclient sources")
    for path in paths:
        ast.parse(path.read_bytes(), filename=str(path))
    print(f"source_ast=PASS files={len(paths)}")

    for name, expected in (("construct", "2.10.70"), ("pyserial", "3.5")):
        actual = importlib.metadata.version(name)
        if actual != expected:
            raise RuntimeError(f"{name}: expected {expected}, found {actual}")
        print(f"dependency=PASS {name}=={actual}")
    import serial
    # proxy.Serial subclasses this class at import time. Keep its type intact
    # while making both construction and explicit opens fail before any I/O.
    serial.Serial.__new__ = staticmethod(blocked)
    serial.Serial.open = blocked
    serial.serial_for_url = blocked
    for name in ("m1n1.proxy", "m1n1.proxyutils", "m1n1.hv", "m1n1.hw.pmu"):
        importlib.import_module(name)
    importlib.import_module("m1n1.proxy").UartInterface = blocked
    print("controller_imports=PASS target_access_guarded=true")

    for action in (
        lambda: serial.Serial("/dev/asahi-offline-must-not-open"),
        lambda: importlib.import_module("m1n1.proxy").Serial(),
        lambda: importlib.import_module("m1n1.setup"),
        lambda: os.open("/dev/asahi-offline-must-not-open", os.O_RDONLY),
    ):
        try:
            action()
        except RuntimeError as exc:
            if str(exc) != "offline test forbids target access":
                raise
        else:
            raise RuntimeError("target-access tripwire failed")
    print("target_access_negative_controls=PASS cases=4")

    original_argv = sys.argv
    try:
        for name in ("chainload.py", "run_guest.py"):
            path = root / "tools" / name
            sys.argv = [str(path), "--help"]
            with contextlib.redirect_stdout(io.StringIO()) as output:
                try:
                    runpy.run_path(str(path), run_name="__main__")
                except SystemExit as exc:
                    if exc.code != 0:
                        raise
                else:
                    raise RuntimeError(f"{name} did not exit at argument parsing")
            if "usage:" not in output.getvalue():
                raise RuntimeError(f"{name} missing parser help")
            print(f"parser_only=PASS {name}")
    finally:
        sys.argv = original_argv
    if "m1n1.setup" in sys.modules:
        raise RuntimeError("hardware setup was imported")

    # Compile local bytes only. This does not instantiate a proxy or an HV.
    from m1n1.asm import ARMAsm
    code = ARMAsm("ret", 0x8000)
    if code.data != bytes.fromhex("c0035fd6") or code.start != 0x8000:
        raise RuntimeError("unexpected AArch64 assembly output")
    if not any("ret" in line for line in code.disassemble()):
        raise RuntimeError("AArch64 disassembly failed")
    print("arm_assembler=PASS ret=c0035fd6 start=0x8000")
    print("offline_controller=PASS native_execution=false hardware_acceptance=false")


if __name__ == "__main__":
    main()
