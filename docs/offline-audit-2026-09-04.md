# Offline code and evidence audit — 2026-09-04

Target: Mac15,6 / J514s / T6030. Branch: `topic/offline-test-audit`.
Starting commit: `546ffce`. Scope: project tooling, M1 startup/safety paths,
source contracts, and retained build artifacts. This is not an audit of every
line of the upstream kernel, firmware, or bootloader.

No native boot, hardware fault injection, host storage/firmware/boot-policy
change, installation, backup operation, or M0/Linux rebuild was performed.
The existing user-owned deletion of `HUMAN_DEVELOPMENT_PLAN.md` is untouched.
The second Mac is reported available; a DFU rehearsal and verified restore
remain separate requirements, not satisfied by its availability.

## Findings fixed

1. **Init could terminate before readiness.** `/run` was mounted over the log
   directory created immediately beforehand. An unmodified-init chroot test
   reproduced `cannot create /run/milestone1/session.log: Directory nonexistent`.
   Create logs after mounting `/run`; fail closed on mount failure, unreadable
   command line, forbidden storage parameters, and unknown test actions.
2. **Device rejection was swallowed.** `readonly var=$(validate ...)` returned
   the status of `readonly`, allowing later gates to run. Separate assignment
   from `readonly`, with an explicit failure exit in both native entrypoints.
3. **Published evidence referenced vanished staging paths.** Preflight and
   execution checksum lists used absolute temporary filenames. Production
   evidence writers now use relative names and are exercised after renaming.
4. **Real producer and hand-written fixtures disagreed.** Inner execution
   manifests omitted the tool; outer manifests duplicated keys. Tests now use
   the production record writer, then the real assembler and verifier.
5. **Preflight was not tied to the requested run.** Freeze versioned pointers;
   bind device, m1n1 pin, M0 run/manifest, Image, DTB, initramfs, readiness-script
   path and bytes. Require exact checksum closure, unique/exact manifest keys,
   successful producer/tee results, and freshness. Rehashed negative fixtures
   cover stale/future data, altered tools, extra/missing fields, and tampering.
6. **Assembler published before validating.** Validate the staged result first,
   then use the existing atomic no-replace publisher. Tests assert that a
   checksummed panic log and a dangling output symlink cannot publish a result.
7. **Old init images could remain usable after a source fix.** Require embedded
   init bytes to match the reviewed source. A self-consistent, rehashed stale
   image is rejected. The retained old image now fails the host verifier with
   an explicit rebuild-required message; it has not been overwritten.
8. **Syntax coverage was incomplete.** `bash -n file1 file2 ...` parses only
   `file1`. Parse every shell file individually, include `tests/`, config shell
   fragments, and the POSIX init. A miniature-project regression tests all
   locations and a malformed milestone predecessor chain.
9. **CI silently omitted meaningful tests.** Add a required isolated init
   runtime test and a required signed-repository/rollback job. Run the
   case-sensitive header archive fixture directly on Linux instead of requiring
   nested Docker. Report tier omissions and failed-test logs explicitly.

## Validation

Evidence lives in ignored `out/isolated/offline-audit-20260904/`; it is diagnostic
test output, never canonical M0 or native milestone evidence.

| Check | Result | Evidence |
| --- | --- | --- |
| Original 16-suite aggregate, macOS and Debian | Passed despite the discovered gaps | `baseline-static.log`, `baseline-linux-static.log` |
| Expanded 17-suite static aggregate, network-disabled/read-only Debian | Passed; 107 shell files plus config/init checked | `final-static.log` |
| M2–M7 source suites + U-Boot patch-binding suite (7) | Passed | `source-contracts-final.log` |
| Real signed-repository + signed-rollback suites (2) | Passed, pinned Arch / repo-add 7.1 | `arch-signed-suites.log` |
| Init startup, 13 scenarios with system POSIX shell | Passed | `m1-focused-final.log` |
| Same 13 scenarios with hash-pinned target AArch64 BusyBox | Passed | `init-pinned-busybox.log` |
| M1 producer/assembler, stale artifact, negative publication tests | Included in expanded aggregate | `final-static.log` |
| Retained M0 checksum entries (5,664) | All passed | `artifact-integrity.log` |
| Four real Linux package archive closures | Passed | `artifact-integrity.log` |
| m1n1, U-Boot, Linux DTB, bound boot payload verifiers | Passed | `artifact-integrity.log`, `bound-payload.log` |
| Workflow lint, actionlint 1.7.12; shell policy; diff whitespace | Passed locally | `actionlint.log`; aggregate |
| Full canonical M0 verifier | Blocked: original builder image missing | `m0-full-verifier.log` |
| Retained M1 initramfs host verifier | Expected rejection: reviewed init changed | `stale-initramfs-host.log` |

At the original September 4 checkpoint, the canonical verifier stopped at missing image
`sha256:175b095ef204602c43b99438fbc96c34895d19128fc38dca5b1e19f0e529964d`.
An unreviewed image substitution cannot establish canonical verification. The
subsequent, explicitly approved inspection migration is recorded below. No new
reproducibility handoff was created. GitHub Actions itself was not pushed or run;
the local equivalents and workflow syntax were checked.

There is no measured line/branch-coverage percentage. Fixture success does not
establish driver execution, hardware behavior, or a brick-free boot. M0–M9 native
gates remain blocked; known target diagnostics remain WIP debt.

All 26 shell test entrypoints were exercised across their appropriate tiers
(17 static + 7 source/artifact + 2 signing). The real-M0 handoff branch within
the integrity suite remains explicitly skipped because full canonical
verification is unavailable. A read-only review found an additional preflight
provenance gap; it was fixed and re-reviewed without a remaining material finding.

## Initramfs follow-up — 2026-09-05

Changes are limited to the existing initramfs builder, verifier, fixtures, and
documentation. No kernel rebuild, canonical evidence overwrite, or boot occurred.

- A rehashed concatenated gzip/CPIO image passed the old verifier: it stopped at
  the first trailer. Require exactly the producer's final 512-byte block padding
  and EOF, canonical trailer spelling, bounded member/name reads, and no embedded
  NUL names. Nine negative archive fixtures cover these cases.
- A rehashed archive with a non-executable `/init` also passed. Validate exact
  executable/directory/symlink modes, root ownership, unique M0-bound source epoch,
  and no hardlink metadata on payloads. Six additional metadata fixtures cover
  non-executable init, setuid BusyBox, UID, GID, mtime, and hardlink changes.
- `cpio --reproducible` plus `gzip -n` did not normalize file timestamps or
  ownership. The old pipeline produced different bytes from otherwise identical
  trees. The production packing helper now normalizes the private stage and
  records root ownership. Its self-test checks byte equality and actual newc
  metadata. The macOS test additionally caught umask-dependent symlink modes;
  these are normalized before the existing Docker packing fallback. A further
  cross-platform comparison exposed Darwin directory link counts in the bind
  mount. The fallback now copies only the private stage onto ephemeral Linux
  tmpfs before packing; the fixture checks link counts too. Host and Linux
  fixture archives now have the same SHA-256, recorded in both packing logs.
- Replace the shared temporary archive filename with a per-run `mktemp` file.
  Validate staged evidence before using the existing atomic no-replace publisher;
  canonical M0 verification remains mandatory before packing a real image.

Read-only review added seven more negative cases (22 archive/metadata mutations
total). The verifier now owns bounded single-member gzip decoding, CRC/trailer
validation, compressed/decompressed size limits, an 18-entry ceiling, and exact
directory link counts. An empty second gzip member cannot hide behind decompressed
EOF. The redundant unbounded `gzip -t` pass is removed. The packer resolves its
Docker image ID before running it and cleans only its own private staging paths
on failure. A helper failure test preserves existing evidence and `latest`; a
source-order assertion guards verify-before-publish-before-latest. Neither is
represented as a completed, full production initramfs build.

A final adversarial review reproduced inventory injection: a newline-containing
symlink target supplied the expected TSV line for a missing applet. Names now
reject control characters and each link target must be exactly `busybox` before
serialization. Five more fixtures bring the archive/metadata set to 27. The
decompression cap uses the reviewed init source (verified before parsing), not
the supplied init's size; evidence file hashing is streamed. These bound the
archive decoder, not every possible filesystem or resource-exhaustion scenario.

Reproducibility scope is the measured Mac fallback and the existing Linux test
image/filesystem. Direct Linux execution still depends on host cpio/gzip versions; byte
identity across arbitrary toolchains has not been established.

Evidence: `out/isolated/initramfs-archive-audit-20260905/`. The `*-before.log`
files preserve reproduced failures; these are deliberate failing regressions,
not successful native tests. `metadata-after.log` records the full Linux M1
suite with 13 chroot scenarios. `packing-host-final.log` and `m1-host-final.log`
record the macOS packing and M1 suites; chroot is explicitly unavailable on
macOS. The final parser cases are in `m1-linux-reviewed.log` and
`m1-host-reviewed.log`; final packing/cleanup checks are in
`packing-linux-reviewed.log` and `packing-host-reviewed.log`. Fixtures use
non-bootable stand-ins for ELF metadata, not hardware proof.
`inventory-injection-before.log` preserves the accepted bypass;
`m1-linux-final-review.log` and `m1-host-final-review.log` cover its fix and all
27 final mutations. Earlier logs are retained as dated intermediate evidence.
The final aggregate (`static-final-review.log`) passed all 17 suites and syntax/
shell checks for 108 shell files plus config/init. M0–M9 native gates stayed
closed. Bounded read-only re-review found no remaining material issue in the
changed initramfs scope. `test-source.SHA256SUMS` binds the final project test
inputs; `SHA256SUMS` covers the retained evidence snapshot. No canonical M1 image
was built or promoted during these checks.

Read-only prerequisite investigation: all 14 proposed archive-inspection tool
package versions in the existing immutable Arch base match the checksummed M0
`packages.txt`. Comparison is recorded in `arch-verification-tools.txt` and
`m0-recorded-verification-tools.txt`. This is not full M0 verification or a
reproduction claim. Separating that inspection executor from historical builder
provenance has been proposed for explicit approval; no acceptance policy changed.

## M2 log-gate follow-up — 2026-09-05

Pinned-source inspection found seven PMGR reset/power-state and DART command
timeout error messages omitted by the common fault patterns. The old M2 verifier
accepted a complete structured fixture containing all seven messages. Separately,
a simulated `grep` read/tool failure was treated as a clean log.

The existing evidence library and analyzer now share one matcher. Match, clean,
and scanner-error statuses remain distinct; scanner errors cannot produce a
clean report. Absolute-file guards now return explicitly on rejection, including
when called from Bash conditional contexts. No driver source, device-tree policy,
canonical artifact, or source pin changed.

Validation passed on macOS and Linux: all seven messages individually rejected
by the library and analyzer, benign neighboring messages accepted, scanner
failures rejected without publishing a report, invalid paths rejected, and the
full M2 bundle rejected. Per-file `bash -n`, ShellCheck at error severity, and the
final 17-suite static aggregate passed (108 shell files plus config/init).
Because the shared library also serves other verification tiers, all seven
source/artifact suites and both signed-repository/rollback suites were refreshed
and passed against the current code (`source-artifact-final.log`,
`signed-final.log`). They remain separate from the static aggregate.
Bounded read-only review found no material issue in the changed scope.

Evidence: `out/isolated/m2-log-audit-20260905/`. `m2-before.log` and
`scanner-error-before.log` are deliberate failing baseline reproductions.
`focused-linux.log` and `static-final.log` contain final Linux results; the
evidence README records the successful host command completion, whose output
was captured by the task rather than redirected to a log. `source-provenance.log`
records the pinned source commit and both driver file hashes. The new source
snapshot supersedes earlier snapshots for the current worktree; earlier evidence
is unchanged. These are synthetic logs, not Linux driver execution or native
power/DART fault coverage. All native gates remain closed.

## Approved M0 inspection follow-up — 2026-09-05

The user approved the version-matched read-only verification path while explicitly
forbidding boot. The shared runner now separates the recorded builder identity
from an immutable inspection executor. All 48 tool and observed shared-library
package versions match the checksum-bound full and package build inventories.
Those inventories and installed versions are checked again inside the same
read-only, network-disabled container before archive inspection. There is no
image override, fallback to the old image, source-volume mount, or build-policy
bypass. Existing artifact checks and rebuild comparisons are unchanged.

Focused static and actual-container tests cover malformed/short/extra/unsorted/
duplicate contracts, missing/changed/duplicate records, checksum failures,
symlinks, unsafe mount paths, wrong architecture, missing image, runtime version
mismatch, nonzero body propagation, read-only artifacts/root, case-sensitive
temporary storage, and its no-execution policy. The initial host run caught a
Bash 3.2 empty-array/nounset incompatibility; fixed by using an always-populated
mount array. Bounded critical review found no remaining material finding.

The first full `scripts/verify-milestone0.sh` invocation passed with the original
image absent. Pre/post artifact path/type/mode/size/mtime snapshots are identical.
Evidence is in `out/isolated/m0-inspection-20260905/`; final checkpoint results
and commands are recorded in its README. This is not a clean kernel rebuild or
native milestone completion, and no historical evidence was rewritten.

## Real M1 publication and preboot checkpoint — 2026-09-05

After canonical M0 verification passed, real M1 staging/verification uncovered
a Bash 3.2 collision between a caller's readonly `destination` and the shared
publisher's redundant local alias. Removing the aliases preserves the existing
atomic no-replace operation. Host/Linux regressions exercise readonly callers,
successful publication, and collision rejection without losing either tree.
The old M1 version remains intact. The corrected image now publishes, verifies,
and matches an isolated repeat byte-for-byte; its archive SHA-256 is
`cdfed2ea20e87583c217ab880442d4783a4e3312ab35975ede0ba5e3775f57eb`.

The latest aggregate passed 18 static suites and individually checked 110 shell
files plus config/init. All seven source/artifact suites, both signing suites,
and 13 pinned-BusyBox init scenarios passed. Detailed logs and exact commands
are in `out/isolated/m0-inspection-20260905/README.md`.
The previously skipped real-M0 handoff branch also passed in a unique isolated
test root: copied/published real evidence verifies and a rehashed altered
component map is rejected. Its test-only copies were cleaned up; no release
handoff or clean-rebuild acceptance was promoted.

A one-time read-only native-readiness report now completes instead of aborting
on an inaccessible Time Machine mount: **25 passed, 22 blocked**. No backup
operation was started/stopped and no monitoring was resumed. Recovery, storage,
upstream support, and the unvalidated controller/target split remain blockers.
See [the preboot checklist](preboot-readiness-2026-09-05.md). Neither artifact
publication nor the separate clean pinned client checkout satisfies native M1.

## Repeat without booting

Run from the project root. No kernel rebuild is needed for these checks.

```bash
docker build --pull=false -f build/Containerfile.static -t asahi-static-audit:20260904 .
docker run --rm --network none --read-only --tmpfs /tmp:rw,nosuid,exec,size=1g \
  -v "$PWD:/workspace:ro" -w /workspace -e M1_INIT_RUNTIME_REQUIRED=1 \
  asahi-static-audit:20260904 -lc './scripts/verify-all-software-tooling.sh --static'

docker run --rm --network none --read-only --tmpfs /tmp:rw,nosuid,exec,size=1g \
  -v "$PWD:/workspace:ro" -w /workspace --entrypoint /bin/bash \
  menci/archlinuxarm@sha256:55b83fc04a09f1e2e08644b4548b95c974ed1108fa8f0a34647af36a4b1c7f60 \
  -Eeuo pipefail -c 'tests/m8-signed-repo-self-test.sh; tests/m8-signed-rollback-bundle-self-test.sh'
```

The Arch command requires AArch64 Linux (Docker Desktop on this Mac qualifies).
It reuses the existing build base, without installing the Rust/kernel toolchain.
Debian's repo-add 6.0 lacks the production `--include-sigs` option; its temporary
dependency experiment was reverted, not worked around in production.

At this audit checkpoint, the isolated volume `asahi-offline-source-audit-20260904`
contained a 2.0 GiB clean source checkout at `/audit/linux`, reconstructed using the existing patch
and `git am --committer-date-is-author-date`. HEAD was verified exactly as
`d8082213fc5a3a64c8b9464a7d5c82d13b1ea115`, with no dirty or sparse source.
It is separate from the authoritative M0 build volume; no kernel objects exist
there. Retain it for source-only iteration, or recreate it from pinned inputs.
The subsequent [bootloader source tests](bootloader-source-tests-2026-09-05.md)
also use separately named m1n1/U-Boot checkouts in this volume; `/audit/linux`
remains unchanged.

```bash
docker run --rm --network none --read-only --tmpfs /tmp:rw,nosuid,exec,size=1g \
  -v "$PWD:/project:ro" -w /project \
  --mount type=volume,src=asahi-offline-source-audit-20260904,dst=/audit,readonly \
  asahi-static-audit:20260904 -Eeuo pipefail -c '
    evidence=$(cd out/milestone0/linux-full/latest && pwd -P)
    for test in tests/m2-source-contract-self-test.sh tests/m{3,4,5,6,7}-source-readiness-self-test.sh; do
      bash "$test" --source-dir /audit/linux --m0-evidence "$evidence"
    done
    bash tests/u-boot-patch-binding-self-test.sh --evidence /project/out/milestone0/u-boot/latest
  '

docker run --rm --network none --read-only --tmpfs /tmp:rw,nosuid,exec,size=256m \
  -v "$PWD:/workspace:ro" -w /workspace -e M1_INIT_RUNTIME_REQUIRED=1 \
  asahi-static-audit:20260904 -c \
  'python3 tests/m1-init-self-test.py --busybox out/milestone1/initramfs/latest/bin/busybox'
```

The second command verifies the BusyBox hash and exercises the **current** init
source; it does not execute the stale archived init or authorize that archive.

## Upstream refresh and safe next work

As checked on September 4, kernel.org lists mainline **7.3-rc1**, not a final 7.3
release. The [Asahi M3 matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
still lists T6030 GPU as TBA; DCP, display, USB data paths, and installer as WIP.
Core 7.3 enablement is not full M3 Pro support.

The official Linux `asahi` head remains pinned `77cb8f24…`; `asahi-wip` remains
`ca9a850f…`. [m1n1 advanced by two commits](https://github.com/AsahiLinux/m1n1/compare/60e53e7078c5cb7efce32d64bf50829e9401e44f...940439b9a407fbfc499bea933269219f3f62d4c7)
(display piodma alias and USB2 PHY constants). [U-Boot advanced beyond the existing candidate](https://github.com/AsahiLinux/u-boot/compare/dbd2154cb0d3a5552505cfcc00a8b5f8da737030...ec49c9d70e6ab003813d6f475fec62dc1c0f4bfe)
by four Apple NVMe changes. These were identified, not silently promoted.

The subsequent [bootloader source tests](bootloader-source-tests-2026-09-05.md)
reviewed those deltas and validated isolated candidates; canonical pins remain
unchanged. The approved September 5 follow-up verified M0 and rebuilt the corrected
initramfs as recorded above. A future native attempt still needs fresh readiness, verified
restore, actual DFU rehearsal, clean pinned m1n1, and explicit approval.

Changed production code is limited to initramfs startup/verification, M1 evidence
production and assembly, shared fault-log validation, static discovery/tests,
and CI. No SoC driver or firmware change was invented to replace missing
hardware evidence.
