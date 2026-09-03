# Milestone 1: controlled tethered boot

Milestone 1 validates one software-only tether path for the pinned M0 kernel,
J514s device tree, and a RAM-only initramfs. It is not a native installation,
storage change, boot-policy change, firmware operation, or hardware-support
claim.

## Preconditions

1. Complete and verify Milestone 0. The Linux `Image` and
   `dtbs/apple/t6030-j514s.dtb` must be from the same verified M0 build.
2. Set `M1N1DEVICE` explicitly to an existing canonical, non-symlink macOS
   character device under `/dev/cu.*` or `/dev/tty.*`. Disk devices, regular
   files, arbitrary character devices, and symlinked paths are rejected before
   any native command is started.
3. Set `M1_M1N1_SOURCE_DIR` to the checked-out pinned m1n1 tree. It must be
   clean and at `M1N1_COMMIT`.
4. Run the read-only native-readiness gate with both deliberate attestations:

   ```sh
   scripts/milestone1-preflight.sh --dfu-rehearsed --sample-restore-verified
   ```

   A successful result expires after 15 minutes and is saved only as session
   provenance. A blocked readiness result cannot be overridden by this repo.

## Build and inspect

```sh
scripts/build-milestone1-software.sh
scripts/verify-milestone1-initramfs.sh
scripts/milestone1-dry-run.sh
```

The software builder downloads the exact hash-pinned Debian snapshot
`busybox-static` package, extracts its static AArch64 BusyBox, records that
provenance, and rejects any different binary. The CPIO verifier requires the
exact RAM-only member set and requires every applet, including `/bin/sh`, to be
a symlink to the pinned BusyBox; extra executables and changed link targets are
rejected.

The dry run prints the exact command without opening the tether or touching the
device. The command is the pinned m1n1 proxyclient Linux tool with
`--compression none`, followed by `Image`, the J514s DTB, and the initramfs.

## Execute deliberately

Execution requires a fresh successful preflight, fresh verified M0/M1
artifacts, clean pinned m1n1 source, a present `M1N1DEVICE`, and both the
literal attestation and the flag below:

```sh
M1_EXECUTE_ATTESTATION=I_UNDERSTAND_CONTROLLED_TETHER \
  scripts/milestone1-execute.sh --execute
```

The script captures host output and does not add a `root=` argument. It does
not run any disk, APFS, firmware, boot-policy, or startup-disk command.
Before invocation it resolves `latest` to immutable M0 and M1 run directories,
re-verifies that exact pair, and passes only those resolved paths to m1n1.

## Aggregate a session

Execution produces `sessions/<run-id>/execution/`, with the enclosing run
manifest/checksum set alongside it. After the operator has collected 20
successful run directories and the five observation records under one
`sessions/` root, assemble them into one immutable session:

```sh
scripts/assemble-milestone1-session.sh sessions/ SESSION_OUTPUT
scripts/verify-milestone1-session.sh SESSION_OUTPUT
```

`sessions/` must contain exactly 20 non-symlink run directories. Each run must
contain `execution/manifest.txt`, `execution/SHA256SUMS`,
`execution/host.log`, and `execution/serial.log`, plus the enclosing
`manifest.txt`, `records.tsv`, and `SHA256SUMS` emitted by
`milestone1-execute.sh`. The sessions root must contain
`evidence-watchdog.txt`,
`evidence-panic.txt`, `evidence-reboot.txt`, `evidence-macos-return.txt`, and
`evidence-dfu.txt`.

The assembler rejects incomplete or duplicate inputs, path escapes and
symlinks, mismatched M0 run/hash provenance, command drift, failed pipes, and
unchecksummed serial evidence. It never overwrites an existing session.

## Exit evidence

Each controlled boot is a record in a session directory. The verifier refuses
hardware-exit approval unless there are exactly 20 successful records, serial
logs, and explicit evidence for watchdog, panic, reboot, return to macOS, and
DFU recovery. Any corruption, fault, panic, storage, or reset signature fails
the verifier. A prepared test is not evidence that the test occurred.

No hardware exit is claimed by this milestone. Hardware evidence must be
collected by the operator and reviewed separately.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
