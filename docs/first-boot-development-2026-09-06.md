# First observed Linux-HV boot and restricted development guest

This document retains the initial checkpoint below. Its format-2 candidates
`-04`/`-05` are historical, not compatible with the newer protocol-2 receiver.
See the subsequent console/framebuffer checkpoint for the current development
state; no development artifact here grants another boot or hardware probe.

## What the supplied evidence establishes

Reviewed `~/Downloads/out.zip` read-only on 2026-09-06 UTC. Archive SHA-256:
`3522da62e30614d22a3ed0b507c403ecf0de6f54242fd438ec60ddd3884ee08b`.
All ZIP CRCs and all 258 root-manifest entries passed independent verification.
No archive script was executed. Extracted evidence is retained under
`out/isolated/boot-evidence-review-20260906.AnGd7D/`.

The primary serial JSONL reconstructs exactly 73,108 raw bytes, SHA-256
`11877b9725d160ec417e1e8440179da956cefe63109156fd50fb9af8fc690161`.
It shows Linux `7.1.9.asahi1+` on the M3 Pro target, 11 activated processors,
all 12 bounded diagnostic sections completing with status zero, and
`phase=controlled-tether-ready action=none`. The Linux console is `ttySAC0`.
Only RAM/pseudo-filesystem mounts appear in the captured diagnostic inventory.
There are 48 `sync_state` pending lines plus a deferred PWM LED probe; these are
unresolved dependency observations, not successful peripheral tests.

This establishes **one Linux guest boot under m1n1's hypervisor**, not direct
Linux/native-M1 acceptance, a persistent root, full hardware support, a working
desktop, recovery proof, or long-duration stability. The later zero-byte
120-second observation does not prove continued liveness. Receiver cleanup
failed with `termios.error`; an earlier controller read also drained 3,244 bytes
without preserving them. Do not claim a gapless capture or reuse historical
controller process IDs as current state.

The exact original Linux export is still present and passes
`scripts/verify-linux-full.sh`:
`out/milestone0/linux-full/20260903T140724Z-90923-697e6696b7bffbef`.
Its Image SHA-256 is
`39a4c4be87119c408082500fc3becb09b6c64429330b6db501ea61bbbf175b24`.
The original module tree, symbols, configuration and DTBs survive. The old
Linux object-cache volume does not; future kernel changes require a new
isolated build, with the source-volume lock respected.

## Development added without another hardware run

`scripts/development-candidate.py` builds and verifies a **separate** restricted
RAM-only diagnostic guest. It reuses the original verified kernel, m1n1,
BusyBox and exact-version modules. The canonical M1 init, existing standalone
candidate tool, canonical artifacts and `latest` pointers are not modified by
this builder. Nothing is installed into the live ESP.

The development init provides:

- Early, elapsed-at-least-15-second and elapsed-at-least-60-second snapshots,
  plus five-second heartbeats when the collector is not busy.
- Bounded, checksummed records of kernel state and cached driver bindings;
  binary runtime FDT and kernel configuration are base64 encoded.
- Fixed commands only: `help`, `status`, `snapshot`, `fdt`, `arm-core`,
  `probe-core`, `arm-dart`, `probe-dart`. LF and CRLF are accepted; unknown/empty/oversized commands
  disarm probes. There is no shell, arbitrary path, eval, reboot, stress or
  raw-memory command. Any command other than the immediately matching probe
  disarms a request; the arm expires after 10 seconds.
- Six inactive core modules in reviewed dependency order: Apple GPIO, NCO clock,
  PASEMI I2C core/platform, SPMI controller and PWM. Only `arm-core` immediately
  followed by `probe-core` permits a single attempt. DART is a separate seventh
  module, requiring `arm-dart` / `probe-dart`, because resetting IOMMUs can disrupt
  USB debugging. SPI is deliberately absent: it can bind the enabled NVRAM flash
  while this kernel has built-in SPI-NOR/MTD drivers. Exact module hashes are
  checked before loading. A marker precedes every load, so a hang still has
  attribution; errors stop the remaining modules in that group.
- No NVMe modules, block nodes, devtmpfs, module autoload helper, debugfs or
  efivarfs mount. `/dev` contains only console, tty and null; sysfs is read-only.
  The NVMe DT node is disabled and checked again in the runtime tree.
  NVMe, Apple DWC3/PCIe, DART and Apple SPI must all be modular in the source
  config; unapproved built-in drivers are rejected. Physical block/MTD devices,
  raw-memory nodes or loaded storage/SPI modules cause
  the collector to stop progressing, including after individual module probes.

**Loading drivers programs hardware.** A timeout does not guarantee that a
driver stuck in uninterruptible kernel code can be stopped. This is a restricted
collector, not isolation against hostile root: the reused kernel still has raw
memory, block, USB storage, kexec and other capabilities compiled in. A future
unrestricted shell requires a separately designed and validated kernel profile.

Packaging checks the exact module architecture, vermagic, checksummed source
inventory and dependency closure; rejects unreviewed soft dependencies; uses a
deterministic CPIO and compression format; and reconstructs the permitted DT
edit and full payload during verification. Files, directories, metadata and
dependency-tool hashes must match. Publication is atomic/no-replace, with
read-only output modes. Checksums are integrity evidence, not signatures or
protection from a malicious same-user process. Repeatability is scoped to the
same tooling/compression environment. Failed stages remain for diagnosis.
Device-tree tools have explicit host-version pins: macOS DTC 1.7.2, Linux DTC
1.6.1. Resolved executable paths, versions and binary hashes are bound in format-2
metadata and checked around transformation. A candidate is not portable to a
different verification tool environment without a separately reviewed rebuild.

The USB receiver now catches both `OSError` and `termios.error` when restoring
a disconnected terminal. It records a cleanup warning and preserves the serial
data, stopped summary and checksum manifest. Disconnect still returns a failure
status; the fix does not reinterpret it as a successful boot.

The m1n1 source routes both transmit and receive bytes through its secondary
CDC virtual UART (`src/m1n1/src/hv_vuart.c`, `usb.c` and
`proxyclient/m1n1/hv/__init__.py`). This is source-level transport evidence, not
an observed guest-input test. The existing receiver deliberately opens that
interface read-only and exclusively. It **cannot send the new commands**.
Interactive use requires a separately reviewed bidirectional client with sole
ownership of that interface; do not attach a second reader/writer to an active
exclusive capture. The timed automatic diagnostics work without command input.

## Offline commands and validation

These commands only package or inspect files; they never boot or install:

```sh
scripts/test-development-tools.sh
python3 -B scripts/development-candidate.py build "$PWD/out/isolated/dualboot-dev-<new-id>"
python3 -B scripts/development-candidate.py verify "$PWD/out/isolated/dualboot-dev-<new-id>"
```

`scripts/test-development-tools.sh` runs ShellCheck, packaging regressions and
the actual init in a disposable Linux chroot. macOS reports the runtime test as
skipped; static CI requires it through `M1_INIT_RUNTIME_REQUIRED=1`. The static
job now has x86 and ARM runners; the ARM path verifies the exact target BusyBox
hash, not only a same-version x86 binary. This CI configuration has been tested
locally on ARM, not observed running on GitHub in this turn. The static
image now includes pinned BusyBox and device-tree tools for these tests.
Runtime tests use ordinary files/FIFOs and strict command doubles, never host
devices, real mounts or `insmod`. Run in a read-only, network-disabled container;
chroot alone is not a sandbox. The explicit side-effect command paths also avoid
BusyBox's built-in applet optimization bypassing the command doubles.

Verified this turn:

- 16 packaging tests on macOS, including actual DT transformation, source
  mutation, module metadata, dependencies, archive metadata and rehashed tampering.
- 50 actual-init runtime scenarios with the SHA-pinned target AArch64 BusyBox.
  Record hashes/lengths are independently checked; time advances are simulated.
  The tests prove collector logic, not actual 60-second hardware stability.
- Full Linux static aggregate: 21 suites; 113 shell files plus configuration/init
  syntax checks. Native milestone gates remain blocked. The M0 real end-to-end
  fixture is explicitly skipped, and source-contract, signed-repository and
  bootloader/driver build suites are outside this static aggregate.
- USB receiver regression suite: 21 tests on macOS and Linux, including the
  reproduced EIO/ENODEV cleanup failures.

Logs are under `out/isolated/boot-evidence-review-20260906.AnGd7D/`; the full
static per-suite logs are in its `static-aggregate-02/` directory. These are
development evidence, not canonical M0 or native acceptance evidence.

The earlier candidates `-01`, `-02` and `-03` are superseded prototypes that
still contained the SPI/batched-DART hazards found during review. **Do not use
them on hardware.** They have been moved, without changing their contents, to
`out/isolated/retired-NOT-FOR-BOOT-20260906.Esi8YC/`. The relocation is reversible;
they are retained only for diagnostic history. Candidate `-04` and later
incorporate the corrected groups, guards and tool provenance.

Corrected candidates `out/isolated/dualboot-dev-20260906-04` and `-05` pass their
real source gates and internal candidate checks. Their payloads and complete
`SHA256SUMS` files compare byte-identical. Payload: 18,241,273 bytes, SHA-256
`5d3af1d3bf2a018aacd8896b19906f484887417505eacc210a32c53745408401`.
A separate `verify` of `-04` also passed at that source revision. Those artifacts
are retained unchanged, but are superseded for interactive use. The bounded follow-up review found no remaining
high-severity implementation blocker in this slice. The final static rerun
passed all 21 suites, including 16 packaging and 50 hash-pinned target-runtime
cases. This is not physical-use approval or a hardware-support claim.

Exact final checks, run from the repository root (all exited zero):

```sh
bash scripts/test-development-tools.sh
bash scripts/test-usb-debug-tools.sh
python3 -B scripts/development-candidate.py verify "$PWD/out/isolated/dualboot-dev-20260906-04"
cmp out/isolated/dualboot-dev-20260906-04/esp/m1n1/boot.bin out/isolated/dualboot-dev-20260906-05/esp/m1n1/boot.bin
cmp out/isolated/dualboot-dev-20260906-04/SHA256SUMS out/isolated/dualboot-dev-20260906-05/SHA256SUMS
git diff --check
```

The target-runtime and aggregate commands ran inside `asahi-static-audit:20260906`,
built from the pinned `build/Containerfile.static`, with `--network none`,
`--read-only`, `--cap-drop MKNOD`, an executable disposable `/tmp` tmpfs and the
repository mounted read-only at `/workspace`. Commands inside that container:

```sh
PYTHONDONTWRITEBYTECODE=1 M1_INIT_RUNTIME_REQUIRED=1 \
  python3 tests/development-init-self-test.py --busybox out/milestone1/initramfs/latest/bin/busybox
PYTHONDONTWRITEBYTECODE=1 M1_INIT_RUNTIME_REQUIRED=1 TEST_OUTPUT_ROOT=/tmp/m3dev-static \
  ./scripts/verify-all-software-tooling.sh --static
```

Curated report/handoff files passed Gitleaks. Shared-context integrity verification
passed without running the full chat-history importer. Quarantined prototype
checksum inventories still pass; their contents were not changed or deleted.

Changed files for this slice: `initramfs/development/init`,
`scripts/development-candidate.py`, `scripts/test-development-tools.sh`,
`tests/development-self-test.py`, `tests/development-init-self-test.py`,
the terminal-cleanup fix in `scripts/usb-debug-receiver.py` and its test in
`tests/usb-debug-self-test.py`, `build/Containerfile.static`, the static-runner
matrix in `.github/workflows/static.yml`, this report, and links in `README.md`
and `docs/dualboot-candidate.md`. All unrelated pre-existing edits remain intact.

## Remaining path to a desktop

The original pinned kernel export has `CONFIG_DRM_SIMPLEDRM`, `CONFIG_SYSFB_SIMPLEFB` and
`CONFIG_FB_SIMPLE` disabled. Its Asahi GPU OF table in
`src/linux/drivers/gpu/drm/asahi/driver.rs` includes T8103/T8112/T600x/T602x,
not T6030. Adding a compatible string would not implement the missing GPU
hardware/firmware interface. Asahi's
[M3 support matrix](https://asahilinux.org/docs/platform/feature-support/m3/),
checked 2026-09-06, still lists the M3 Pro main display as WIP and GPU as TBA;
individual `linux-asahi (7.3)` entries are not full-laptop support.

At the initial checkpoint, the next progression was to finish a reviewed bidirectional host command channel;
then separately approve a controlled Linux-HV diagnostic session with fresh
recovery/transport checks. Capture an idle baseline before optional core probes,
compare driver bindings/errors afterward, and preserve the full raw stream.
No module probe has run on hardware in this turn. Further offline graphics
development should start with a separately validated framebuffer-capable kernel
profile, not a silent kernel pin change or an unsupported GPU probe.

No new reboot, Recovery entry, storage operation, startup-policy change or
live-payload replacement occurred during this development work. The original
successful diagnostic image remains available.

## Subsequent checkpoint: protocol 2 and isolated framebuffer build

2026-09-06 06:25 UTC: the restricted console is now bidirectional only through
the explicit `develop` action. Ordinary `capture` remains read-only. See
[the updated operator procedure](usb-debug-linux.md#restricted-development-console--no-new-boot-authorized).
No live serial port was opened by this development work.

Before every command, a fresh nonce exchange checks the actual init/module
manifest, kernel release, running kernel notes and a component-binding digest.
The digest covers source hashes, the transformed DTB, bootargs and all rootfs
inputs. It is not live firmware attestation. Kernel notes are measured from
`/sys/kernel/notes`, whose bytes match the linked `.notes` section on this pinned
ARM64 kernel. The original Image and vmlinux contain the same 84-byte section:
SHA-256 `2c365833132b8cb067ccf2613b2501978774f28cfe355c542ceb6aa4e88ed7eb`.
A different same-release kernel now fails before arming. Raw USB identity and
the handshake still cannot authenticate a hostile device or replace independent
launch-payload checks.

The receiver journals exact TX fragments alongside raw RX, never resends an
accepted prefix, does not reconnect, and keeps incomplete requests unproven.
Core/DART require separate permissions; arm acknowledgments and module ordering
are checked. Status/help responses are exact, and FDT completion needs a matching
begin/end pair. Diagnostics also include `/proc/fb` and `/proc/consoles` for the
future framebuffer session. No arbitrary shell or storage command was added.

At that checkpoint, **format-4** candidates:

- `out/isolated/dualboot-dev-20260906-06` and `-07`: all actual source verifiers
  passed; candidate06 separately verified; full payload and `SHA256SUMS` compare
  byte-identical. These still reuse the original kernel, without simpledrm.
- Payload: 18,241,699 bytes, SHA-256
  `6ed0316b1a4fb3c4cf775ec13e59490efaeb4b86e8a5fb75976737b1c7c1022e`.
- Candidate06 manifest SHA-256:
  `cae2902cebef3e237ca2abc62c3745321832b68d27731d1baf0656b399c57f83`.
- Candidate06 complete checksum-file SHA-256:
  `7b1801e10cd18c19cfe6d3ab18703d91d44d19af7a8cb3e36752e0477a99fd20`.

Final focused validation passed on macOS and the isolated ARM Linux container:
17 packaging tests, 60 actual-init cases with the SHA-pinned BusyBox, 21 legacy
receiver plus 19 bidirectional tests, and the Linux-full contract suite including
canonical/development argument separation. The real PTY tests simulate a serial
peer; they do not exercise Apple USB hardware. Final Bash syntax, error-severity
ShellCheck, init ShellCheck and the original Linux export verifier passed.
The full static aggregate was not rerun for this narrower slice. Focused log:
`out/isolated/boot-evidence-review-20260906.AnGd7D/development-console-linux-final.log`.
The independent read-only review's kernel-mixup and canonical-dependency findings
were fixed before packaging/building; hardware and unrestricted-shell limits remain.

The separate `--development-framebuffer` build/verify mode keeps canonical M0
defaults and validation, but uses a pinned additional fragment, distinct
`.asahi1-m3devfb1` localversion, object/output directory and manifest component.
It requires a validated isolated output root; canonical verification rejects
development markers. Canonical builds do not mount or depend on development-only
files. The pinned Arch toolchain image was rebuilt successfully. Real Kconfig
resolution and `rustavailable` passed against the clean pinned Linux source;
the delta is limited to localversion, simpledrm/sysfb helper, built-in DRM client
helpers and the now-invisible disabled FB_SIMPLE setting. Configuration SHA-256:
`cc5514f07c3556e7802293e90d4d777861061c716064aaf6cc7c2df8fba73ade`.

At the 06:25 UTC checkpoint one full isolated kernel build had started, **not
finished**. It subsequently completed; see the verified result below.

```sh
MILESTONE0_OUTPUT_ROOT="$PWD/out/isolated/dev-framebuffer-20260906" \
SOURCE_VOLUME_OVERRIDE=asahi-offline-source-audit-20260904 \
./scripts/build-linux-full.sh --development-framebuffer
```

Run `20260906T062500Z-11553-a4526ae87ceeb9bb`; progress log
`out/isolated/dev-framebuffer-20260906/build-driver.log`. Source-volume lock is
authoritative. Its new object directory is `/workspace/build/linux-development-framebuffer`;
the existing audit checkout is retained. The host input mirror was copied from
the local pinned Git objects, not the case-colliding APFS working files. Do not
launch another M0/Linux build, resume a partial stage as canonical evidence, or
run unrelated static workloads while this build owns the volume. A published,
verified kernel and a separately updated candidate source binding are still
needed before this profile can be packaged for a proposed hardware session.

Changed in this subsequent slice: `scripts/usb-debug-receiver.py`,
`initramfs/development/init`, `scripts/development-candidate.py`,
`tests/development-console-self-test.py`, `tests/development-init-self-test.py`,
`tests/development-self-test.py`, `scripts/test-usb-debug-tools.sh`,
`scripts/build-linux-full.sh`, `scripts/verify-linux-full.sh`,
`scripts/test-linux-full-tools.sh`, `scripts/lib/linux-development-profile.sh`,
`config/linux-development-framebuffer.config`, this report and USB procedure.
No canonical artifact, live payload, disk layout or boot policy was changed.

This is framebuffer enablement, not GPU acceleration or a hardened general shell.
Native display behavior, scanout preservation, hardware probes, sustained
stability and other laptop subsystems remain unvalidated. Keep the milestone
goal open; continue with build verification and isolated candidate integration,
then obtain separate approval before any new boot or hardware probe.

### Framebuffer integration and source review

The candidate builder now has an explicit build-only `--kernel` input for one
published isolated framebuffer run. It preserves the original M1/BusyBox source
association, runs a separate development-kernel verifier, and binds the selected
Image, DTB, release, notes and exact module inventory. Staging directories,
`latest` links, external paths and verification-time source overrides are
rejected. Packaging/runtime regressions and real candidate verification have now
passed, as recorded below.
Candidates06/07 remain historical source checkpoints, not claims of successful
verification with subsequently changed packaging code or init bytes.

The bounded source review traced the existing HV wrapper through inner m1n1
`payload.c` into `kboot_prepare_dt()`: `kboot.c:180` populates the firmware
framebuffer template and enables it; `fb.c:500` shuts down m1n1's console/shadow
buffer without clearing the firmware scanout. Linux's `drivers/of/platform.c:581`
registers the resulting `simple-framebuffer`, and
`drivers/gpu/drm/sysfb/simpledrm.c:837` registers DRM and its default client.
Keep the existing no-`console=` command line: VT initially registers as a printk
console, DT stdout-path subsequently selects serial0, and fbcon takes over VT.
Adding a guessed UART baud or replacing DT console selection is unnecessary.

The already verified archive also corroborates this path: its primary
`evidence/serial-boot/serial.bin` reports a pre-initialized 3024x1964 display,
notch cropping to 3024x1890, a populated FDT framebuffer, the reserved-memory
setup skip, and both `tty0` and `ttySAC0` enabled. Linux used the dummy VT console
because that original kernel lacked simpledrm. No separate runtime DTB dump was
found in the supplied archive; its `components/t6030-j514s.dtb` is the input
template, not the loader-mutated runtime tree. These serial observations do not
establish visible pixels, framebuffer-driver binding or display stability.

Snapshots now also read four fixed, bounded fb0 attributes: `name`, `virtual_size`,
`bits_per_pixel`, and `stride`. The pinned `fbsysfs.c` show handlers only return
cached `fb_info` fields; no modeset, framebuffer node or raw memory access is
added. Missing values stay unavailable, and truncated/timed-out reads retain
their status. The expected simpledrm fbdev name is `simpledrmdrmfb`. Its stride is
the fbdev shmem shadow-buffer pitch, **not necessarily the firmware DT stride**;
do not reject a correct registration because those pitches differ.

Residual: m1n1 `kboot.c:1965` has no T6030 `dt_set_display()` branch and skips its
display reserved-memory setup after locking DART. This does not itself remove
the inherited simple-framebuffer mapping, but it leaves physical scanout survival
unproven. Future acceptance needs runtime FDT properties, registered fb0 state,
uninterrupted UART capture and operator-observed pixels. None alone establishes
GPU acceleration, DCP modesetting or complete display hardware support.

## Verified framebuffer candidate checkpoint

2026-09-06 UTC: the isolated full build completed successfully and published
`out/isolated/dev-framebuffer-20260906/milestone0/linux-development-framebuffer/20260906T062500Z-11553-a4526ae87ceeb9bb`.
The build verifier and a separate verification of the published run both pass.
No M0/Linux build remains running from this work. Warm objects remain in the
source volume for later authorized incremental development; do not delete that
cache or treat this isolated export as canonical M0.

- Kernel release: `7.1.9.asahi1-m3devfb1+`.
- Image SHA-256: `6e9fb71221601e1099d9385e9a8aa06dbe452858e412a3b5fa5858380f682465`.
- Config SHA-256: `cc5514f07c3556e7802293e90d4d777861061c716064aaf6cc7c2df8fba73ade`.
- The 84-byte linked notes occur exactly once in the Image, at offset 35525744;
  notes SHA-256: `8db79fec5dd9e1572084b66e82bd0b62b8ab9b190c8104c45de32b6e42f7db36`.
- All unfiltered binding/DTB checks, module/header exports, inventory/byte checks
  and pinned toolchain inspection pass. The exact target baseline remains 309
  diagnostic lines / 113 fingerprints, SHA-256
  `32f5d0fc9cd3da7eb13d96e9176545e6b228ec1980db32c9a9906d53df1cc18c`.
  Those diagnostics remain known WIP debt, not hardware support.

Candidates `out/isolated/dualboot-dev-20260906-08` and `-09` both pass their real
source gates. Candidate08 passes a separate `verify`; their complete payloads
and `SHA256SUMS` files compare byte-identical. They select the new framebuffer
kernel while retaining the original verified m1n1/M1/BusyBox source association.
The receiver accepts Candidate08's actual manifest in an offline binding check;
no serial device was opened.

- Payload: 18,254,005 bytes; SHA-256
  `20eb9675b17f518b9fbdbc9ba0deaea27cc515f501ef04aedb1d9e318e07983e`.
- Candidate08 manifest SHA-256:
  `8849575f53916beff3a6e377564b25294adc2f1ac69ad3f45c78f8174196dc34`.
- Candidate08 complete checksum-file SHA-256:
  `8ca106055637a5e6875e36d8ac0cec1280a95edb6fc73b72b973ca20c06a5205`.
- Format4 / protocol2 / `kernel_profile=framebuffer-v1`, `kernel_rebuilt=true`.
  `canonical_m0`, `hardware_acceptance`, `boot_authorized`, `persistent_root`
  remain false. The existing successful image and canonical artifacts are unchanged.

Focused validation passed: **23 packaging cases, 63 actual-init cases with the
SHA-pinned target ARM BusyBox, and 40 transport cases** (21 receiver + 19
bidirectional/PTY). Packaging and transport passed on macOS and Linux; macOS
correctly skips the Linux-root runtime test. The new init cases cover cached fb0
presence, truncation and timeouts; the ordinary fixture checks explicit absence.
Selected-kernel regressions cover separate verifier environments, forbidden paths,
verifier failure, modular storage gates, post-verification source mutation,
recorded-source overrides and repeat packaging. ShellCheck and `git diff --check`
pass. The full static aggregate was not repeated for this focused slice.
Final bounded read-only review found no material issue.

Exact main commands (all completed with status zero):

```sh
bash scripts/test-development-tools.sh
bash scripts/test-usb-debug-tools.sh
MILESTONE0_OUTPUT_ROOT="$PWD/out/isolated/dev-framebuffer-20260906" \
  ./scripts/verify-linux-full.sh "$PWD/out/isolated/dev-framebuffer-20260906/milestone0/linux-development-framebuffer/20260906T062500Z-11553-a4526ae87ceeb9bb" --development-framebuffer
python3 -B scripts/development-candidate.py build "$PWD/out/isolated/dualboot-dev-20260906-08" \
  --kernel "$PWD/out/isolated/dev-framebuffer-20260906/milestone0/linux-development-framebuffer/20260906T062500Z-11553-a4526ae87ceeb9bb"
python3 -B scripts/development-candidate.py build "$PWD/out/isolated/dualboot-dev-20260906-09" \
  --kernel "$PWD/out/isolated/dev-framebuffer-20260906/milestone0/linux-development-framebuffer/20260906T062500Z-11553-a4526ae87ceeb9bb"
python3 -B scripts/development-candidate.py verify "$PWD/out/isolated/dualboot-dev-20260906-08"
cmp out/isolated/dualboot-dev-20260906-08/esp/m1n1/boot.bin out/isolated/dualboot-dev-20260906-09/esp/m1n1/boot.bin
cmp out/isolated/dualboot-dev-20260906-08/SHA256SUMS out/isolated/dualboot-dev-20260906-09/SHA256SUMS
git diff --check
```

The Linux focused tests used image `2b1c51b229e8`, `--network none`, `--read-only`,
`--cap-drop MKNOD`, disposable executable `/tmp` tmpfs, read-only repository mount,
and `M1_INIT_RUNTIME_REQUIRED=1`. That image already has `/bin/bash` as entrypoint;
pass `--noprofile --norc -c` directly after its ID, not an extra `bash`. The initial
duplicated-entrypoint invocation exited126 before running tests; the corrected
invocation passed. No source or dependency change was needed.

Logs in `out/isolated/boot-evidence-review-20260906.AnGd7D/`:
`framebuffer-integration-macos-01.log`, `framebuffer-integration-linux-02.log`,
`framebuffer-kernel-verification-01.log`, `framebuffer-candidates-08-09.log`, and
`framebuffer-receiver-binding-01.log`. The build's complete progress/diagnostic log
is `out/isolated/dev-framebuffer-20260906/build-driver.log`.

Changed in this integration slice: `scripts/development-candidate.py`,
`tests/development-self-test.py`, `initramfs/development/init`,
`tests/development-init-self-test.py`, `docs/usb-debug-linux.md`, and this report.
Lean-build/Ponytail kept this within the existing builder, collector and verifier;
no new wrapper, dependency, generic kernel override, guessed console setting or
canonical-M0 relaxation was added.

No new boot, live command exchange, module probe, ESP replacement, storage or
boot-policy action occurred. GPU acceleration, DCP modesetting, visible panel
refresh, sustained stability, persistent Linux root and full hardware acceptance
remain open. Next physical step requires fresh recovery/transport preflight and
explicit approval of the exact candidate and planned actions; observe an idle
framebuffer/UART baseline before any separately authorized core/DART probe.

Curated code/docs/handoff/index/project files pass Gitleaks. Local shared-context
integrity verification passes with 7,324 files and no problems. No full history
import was run because this task contains earlier credentials; no secrets were
copied and cross-device synchronization is not asserted.
