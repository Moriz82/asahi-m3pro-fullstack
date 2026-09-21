# Standalone dual-boot candidate: offline preparation only

For the later observed Linux-HV boot and separate restricted development guest,
see [the 2026-09-06 checkpoint](first-boot-development-2026-09-06.md). That guest
boot does not establish direct/native boot of the standalone candidate below.

The end goal is an independently bootable Linux installation alongside retained
macOS. This first implementation builds the standalone **RAM-only diagnostic
payload**, not an installer, persistent Arch root filesystem, or working desktop.
It adds no partition, firmware, startup-disk, or security-policy operation.

## What is built

`scripts/dualboot-candidate.py` reuses the existing canonical m1n1 and full Linux
artifacts and the verified M1 initramfs. It invokes their existing verifiers;
there is no skip-verification switch or kernel build. It freezes the selected
physical run paths and hashes before verification, rejects changes during
packaging, and atomically publishes a new read-only candidate under `out/isolated`.
Neither canonical M0 artifacts nor their `latest` pointers change.

The independently checked byte layout is:

```text
esp/m1n1/boot.bin = m1n1.bin + fixed boot arguments + J514s DTB
                   + existing initramfs.cpio.gz + deterministic Image.gz
```

This follows the [m1n1 stage-2/direct-Linux format](https://asahilinux.org/docs/sw/m1n1-user-guide/#configuring-to-boot-linux-directly).
It uses raw `m1n1.bin`, not the historical Mach-O candidate. The compressed kernel
has an explicit boundary, allowing m1n1 to preserve the stage-1 configuration.
The DTB is processed by m1n1 before Linux receives it. No second-stage boot manager
or hard-coded Linux partition number is needed for this RAM-only payload.

The archive remains the existing M1 init with its original log labels; the packager
does not reinterpret `controlled-tether-ready` as an observed native success.
It mounts only RAM/pseudo filesystems, provides no persistent root or interactive
desktop, triggers no panic/reboot, and waits after reporting readiness/failure.
It is deliberately not counted as M1's required tethered session evidence.

## Build and verify without booting

From the repository root, choose a new output name:

```sh
python3 scripts/dualboot-candidate.py build "$PWD/out/isolated/dualboot-candidate-001"
python3 scripts/dualboot-candidate.py verify "$PWD/out/isolated/dualboot-candidate-001"
scripts/test-dualboot-tools.sh
```

Inputs are the physical runs selected by `out/milestone0/{m1n1,linux-full}/latest`
and `out/milestone1/initramfs/latest`. Verification uses those recorded run IDs,
not potentially newer `latest` pointers. Keep the original evidence available.
The full Linux verifier uses the already-approved immutable inspection executor;
it does not recreate the deleted historical builder or rebuild a kernel.
Candidate checksums provide integrity, not a signature or independent authority.
Files are `0400`, directories `0500`; the owner can still change them. A private
workspace without concurrent same-user writers is assumed, as with other evidence
tools. Failed stages remain hidden under `out/isolated/.dualboot-*` for diagnosis.

Two identical builds must produce identical payload bytes in the same compression
environment. No cross-zlib-version reproducibility claim is made. Tests cover
source bindings, source mutation, unsafe paths, no-replace publication, exact
inventory, payload ordering, fixed arguments and bounded gzip integrity. Fixture
tests use fake source verifiers; real candidate builds run the actual verifiers.

## What still prevents deployment

- A separately provisioned, verified-compatible m1n1 stage-1 chainloader must
  load this file from the correct Linux EFI system partition. This tool neither
  creates that installation nor proves it exists. An external USB copy alone
  does not replace Apple's initial internal boot provisioning.
- macOS remains selected through Apple's startup options. This payload does not
  chainload macOS, alter the default OS, provide automatic macOS fallback, or
  make both systems independent of shared firmware/recovery failures.
- Existing backup/restore, recovery-host/DFU, identity, native readiness and
  explicit approval gates remain unchanged. A tether is unnecessary to load
  this self-contained kernel, but remains useful for observing/debugging it.
- Actual M3 Pro boot, display, input and return-to-macOS behavior are untested.
  The [current support matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
  still lists installer/main display as WIP and GPU as TBA (checked 2026-09-05).

The next native step requires an approved provisioning/reuse plan and actual
recovery proof. **Do not copy this candidate to a live ESP or boot it under the
current no-boot authorization.** M9 release gates remain blocked. Passing this
tool's verifier is software evidence only, not completed dual-boot support.

## Verified checkpoint: 2026-09-05

Real candidates `out/isolated/dualboot-20260905-standalone-01` and `-02` were
built from the existing canonical runs. All three actual source verifiers passed
for each build; a separate `verify` of candidate `-01` also passed. Both complete
`SHA256SUMS` files and both `esp/m1n1/boot.bin` files compare byte-identical.
Payload size: 18,082,288 bytes. SHA-256:
`e8f3a30c7489ef41445e2019fe4ae50a245285d52f5a9b853a0d3d8c66d1bdcb`.
Source verification logs, frozen run IDs/hashes, offsets and component hashes
are retained in each candidate's `checks/`, `manifest.json`, and `SHA256SUMS`.

`scripts/test-dualboot-tools.sh` passed all 20 tests on both macOS and the
existing read-only/no-network Linux static container. `bash -n`, ShellCheck
error severity, `scripts/test-static-runner.sh`, and `git diff --check` passed.
`scripts/test-common-tools.sh` passed with disposable explicit milestone/RE
roots. A bounded read-only implementation review reported no material findings.
Canonical `latest` pointers were unchanged. No native boot or installation ran.
