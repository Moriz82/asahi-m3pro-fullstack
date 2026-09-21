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
4. On the **target Mac**, produce readiness only after both recovery steps
   have actually been completed:

   ```sh
   scripts/milestone1-preflight.sh --target-readiness --dfu-rehearsed --sample-restore-verified
   ```

   Target mode requires Mac15,6/J514s and the reviewed readiness-script SHA256
   in `config/milestone1.env`, but no M0 artifacts or serial device. The existing
   full installation-readiness profile is unchanged. Failed reports are
   audit-only; they cannot authorize a controller preflight.
5. Independently retain the printed target identity SHA256 and readiness-bundle
   SHA256. Transfer the exact `readiness.log`, `manifest.txt`, and `SHA256SUMS`
   closure to the controller. Do not extract expected values from that copy.
   Identity hashes cover model, board, and platform UUID with domain separation;
   raw UUIDs are not retained.
6. On the **second Mac/controller**, with the artifacts/client/device above:

   ```sh
   scripts/milestone1-preflight.sh --controller-preflight \
     --target-readiness-dir /absolute/transferred-readiness \
     --expected-target-identity-sha256 "$EXPECTED_TARGET_ID" \
     --expected-target-bundle-sha256 "$EXPECTED_TARGET_BUNDLE"
   ```

   Both expected values are mandatory CLI inputs, without defaults or environment
   fallback. Controller mode never runs target readiness locally. It retains
   the verified target closure and binds its distinct local host identity,
   canonical serial path, tool hash, and artifact hashes. Both readiness and
   preflight must be no older than 900 seconds at execution, in that order.

Checksums establish integrity relative to independent anchors, not origin
authentication by themselves. Before real enrollment, the operator must choose
and validate how to carry anchors independently. An attacker who can replace
both evidence and that anchor channel defeats this scheme; resisting that
requires a separately designed signing key or authenticated channel. No real
enrollment or device access is needed to test the format offline.

Legacy format-1 combined-host preflights/sessions remain immutable but cannot
authorize format-2 execution or handoff. No automatic evidence upgrade exists.
The current authorization is **do not boot**; commands below document a future,
separately approved operator workflow.

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
device. It resolves and verifies the physical versioned M0/M1 run directories
before rendering the command, so later `latest` rotation cannot change the
reviewed inputs. The command is the pinned m1n1 proxyclient Linux tool with
`--compression none`, followed by `Image`, the J514s DTB, and the initramfs.

## Execute deliberately

Execution requires a fresh successful preflight, fresh verified M0/M1
artifacts, clean pinned m1n1 source, a present `M1N1DEVICE`, and both the
literal attestation and the flag below:

```sh
M1_EXECUTE_ATTESTATION=I_UNDERSTAND_CONTROLLED_TETHER \
  scripts/milestone1-execute.sh --execute \
    --expected-target-identity-sha256 "$EXPECTED_TARGET_ID" \
    --expected-target-bundle-sha256 "$EXPECTED_TARGET_BUNDLE"
```

The script captures host output and does not add a `root=` argument. It does
not run any disk, APFS, firmware, boot-policy, or startup-disk command.
Before invocation it resolves `latest` to immutable M0 and M1 run directories,
re-verifies that exact pair, and passes only those resolved paths to m1n1.
It rechecks local controller identity, device, clean pinned source, tool hash,
and artifacts. Each run retains the complete preflight/target evidence and
records the epoch used for its final freshness check.

## Aggregate a session

Execution produces `sessions/<run-id>/execution/`, with the enclosing run
manifest/checksum set alongside it. After the operator has collected 20
successful run directories and the five observation records under one
`sessions/` root, assemble them into one immutable session:

```sh
scripts/assemble-milestone1-session.sh sessions/ SESSION_OUTPUT \
  "$EXPECTED_TARGET_ID" /absolute/independently-retained-anchors.txt
scripts/verify-milestone1-session.sh SESSION_OUTPUT \
  "$EXPECTED_TARGET_ID" /absolute/independently-retained-anchors.txt
```

`sessions/` must contain exactly 20 non-symlink run directories. Each run must
contain `execution/manifest.txt`, `execution/SHA256SUMS`,
`execution/host.log`, and `execution/serial.log`, plus the enclosing
`manifest.txt`, `records.tsv`, and `SHA256SUMS` emitted by
`milestone1-execute.sh`. The sessions root must contain
`evidence-watchdog.txt`,
`evidence-panic.txt`, `evidence-reboot.txt`, `evidence-macos-return.txt`, and
`evidence-dfu.txt`.

Every execution also retains `execution/preflight/`, including the target
closure. The independent anchors file contains one lowercase 64-character
target-readiness bundle SHA256 per line, without duplicates. Retain it
separately; never generate it by scraping submitted sessions.

All 20 runs must share target, distinct controller, artifacts, tool, device,
and command. Readiness/preflight bundles and timestamps may vary per run.
The execution producer assigns a unique run ID, retained in both manifests.
Repeated execution IDs, copied runs, hidden/empty directories, and a record
pointing to another numbered run are rejected. The session checksum closure
includes every run's files, not just its top-level summary.
Historical freshness is checked against each **recorded execution-start epoch**,
not today's wall-clock. Current reviewed policy/script pins still apply.

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

M1 handoff creation and verification additionally require
`--expected-target-identity-sha256 HEX --target-readiness-anchors ABS`.
Those anchors stay external; copying them into a handoff does not establish
trust. All other milestone handoff interfaces remain unchanged.
Anchor file paths must be absolute with no symlink components; the verifier
opens each component without following links and reads the anchor file once.
These checks do not isolate evidence from another process running as the same
user; such a process can still rewrite both evidence and trusted anchor bytes.
