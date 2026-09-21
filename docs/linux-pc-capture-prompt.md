# Linux PC agent: prepare now, capture only after user approval

Prepare a single pre-Linux m1n1 capture for the MacBook Pro Mac15,6 / J514s /
T6030. Work only on this Linux PC's capture kit, USB observer configuration,
and new private evidence directories. No recursive delegation. Never boot,
chainload, launch Linux, initialize hardware, repair storage, change firmware,
or use `m1n1.setup`, `ProxyUtils`, a DART constructor, an interactive proxy shell,
`chainload.py`, or `run_guest.py`. Stop on a failed gate; do not weaken it or retry.

## Prepare now — no USB device opens

Obtain `asahi-m3-capture-kit-20260906.tar.gz` from the Mac. The Mac agent supplies
its SHA-256 separately; verify before extracting into a new private directory.
The archive contains `asahi-m3-capture-kit/`. Enter that directory and run:

```sh
umask 077
CAPTURE_KIT=$(pwd -P)
sha256sum -c SHA256SUMS
mkdir -m 700 runtime sessions
tar -xzf runtime.tar.gz -C runtime
python3 -I -S -B -c 'import runpy; runpy.run_path("scripts/capture-retained-dart.py")["bind_runtime"](); print("bundled runtime verified; no device opened")'
PYTHONPATH="$CAPTURE_KIT/runtime" python3 -O -B tests/retained-dart-snapshot-self-test.py
python3 -O -B tests/capture-retained-dart-self-test.py
python3 -O -B tests/usb-debug-self-test.py
```

Do not replace/re-download dependencies: bundled construct 2.10.70 and pyserial
3.5 suffice. Runtime contains only needed m1n1 modules/data, not guest-launch
tools. Adapter verifies the complete runtime fingerprint before import.

Inspect existing udev rules and ModemManager configuration. If this kit's
`70-asahi-m3pro-debug.rules` is not already installed, install that exact rule
under `/etc/udev/rules.d/` and reload udev rules (do not trigger existing ports).
Preserve any differing prior rule; do not overwrite it without reviewing the
difference. This suppresses ModemManager probing these two m1n1 interfaces;
do not stop unrelated services or kill existing clients. If automatic serial
probing cannot be excluded, report the blocker before the Mac boots.

Report current PC hostname/IP, kit hash, test results, available disk space,
USB cable readiness and observer status. Missing m1n1 USB while macOS runs is
normal. **Wait for explicit user boot/capture approval. Do not open any tty yet.**

## After the user approves and manually selects M3 Dev

The Mac's EFI `m1n1/boot.bin` is loader-only, SHA-256
`097f1ae47b51e5580f401611977ce6d29c85cc9a15e6f6e28344af82a2e6b99e`.
Its source pin is `60e53e7078c5cb7efce32d64bf50829e9401e44f`.
No Linux kernel is appended. Confirm the Mac is paused in m1n1 proxy before
Linux; record its visible banner/photo. Do not open ports merely because they
enumerated: early opening can interrupt stage-1 payload loading. If the stage
or loader is unclear, stop and ask the Mac agent. Selected-file hash is not
remote loader attestation; record uncertainty honestly.

Use sysfs/`udevadm info` only to identify the real `/dev/ttyACM*` nodes:
VID `1209`, PID `316d`, interface **00 primary**, **02 secondary**, same physical
USB path. Do not guess tty numbering. `python3 -B scripts/usb-debug-receiver.py
list` lists validated secondary candidates without opening them. Require one
intended Mac, no competing readers, and no active guest/controller.

Set `PRIMARY`, `SECONDARY`, and `MAC_USB_PATH` to those freshly observed values.
The adapter must run under sudo to inspect other users' open descriptors. Do
not kill an owner to pass its check. Create one timestamp shared by both runs:

```sh
CAPTURE_RUN=$(date -u +%Y%m%dT%H%M%SZ)
python3 -I -S -B scripts/capture-retained-dart.py --device "$PRIMARY" --usb-path "$MAC_USB_PATH"
```

In a dedicated persistent terminal, start the secondary receiver FIRST:

```sh
sudo python3 -I -S -B scripts/usb-debug-receiver.py capture \
  --device "$SECONDARY" --output "$CAPTURE_KIT/sessions/serial-$CAPTURE_RUN" \
  --seconds 300 --wait-seconds 10 --acknowledge-proxy-entry
```

Confirm its `serial.jsonl` contains a `connected` event for `MAC_USB_PATH` and
the process is still running. Then, in another terminal, run exactly once:

```sh
sudo python3 -I -S -B scripts/capture-retained-dart.py \
  --device "$PRIMARY" --usb-path "$MAC_USB_PATH" \
  --output "$CAPTURE_KIT/sessions/dart-$CAPTURE_RUN" \
  --approve-pre-linux-capture
```

This has a 120-second total deadline. It negotiates checksums and checks/resets
exception counters; target access otherwise consists of bounded reads. Reads
can still fault. The adapter rejects mismatched target/firmware/layout and
changing data. Do not loosen guards, supply old addresses, reconnect, run an
interactive shell, or start Linux after either success or failure.

After it returns, stop the secondary receiver with Ctrl-C so it finalizes its
summary/hashes. Keep any error evidence. Analyze a successful capture offline:

```sh
sudo env PYTHONPATH="$CAPTURE_KIT/runtime" python3 -O -B scripts/retained-dart-snapshot.py \
  "$CAPTURE_KIT/sessions/dart-$CAPTURE_RUN/retained-dart.json"
```

Keep analysis output private. Verify both session `SHA256SUMS`, then archive
both complete session directories plus a small host/USB/banner record. Return
the archive privately to the Mac agent. Required data: `retained-dart.json`,
controller JSONL, session/result JSON, raw `serial.bin`, serial JSONL/summary,
and hashes. Do not paste raw tables, memory addresses, identifiers or credentials
into chat/shared notes. Give only status, capture path/hash and any gate failure.

**Stop at capture completion.** No automatic reboot, power action or Linux
continuation. User decides how to return to macOS after reviewing target state.
This captures mapping evidence, not a full-hardware-support acceptance test.
