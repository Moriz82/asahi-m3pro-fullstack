# Upstream loader fixes integrated with DCP development

## Outcome and scope

The combined development m1n1 loader now includes two upstream changes that
were already tested separately in the
[September 5 audit](bootloader-source-tests-2026-09-05.md):

- [PIODMA alias compatibility, a997f4e](https://github.com/AsahiLinux/m1n1/commit/a997f4eb552beb517fa44420f8b50457fb5cd7c7).
- [USB2 reset sequencing, 940439b](https://github.com/AsahiLinux/m1n1/commit/940439b9a407fbfc499bea933269219f3f62d4c7).

These are reused upstream fixes, not newly discovered hardware support. Their
downloaded patch bytes, authors and sign-offs are preserved as development
patches 23/24. The combined source still starts at pinned m1n1
`60e53e7078c5cb7efce32d64bf50829e9401e44f`; no pin is advanced. Apply the eighteen
native patches listed in the closure, ending with 23/24. The separate Python
DCP ABI patches are not silently folded into this loader source.

Linux development patch 14 changes only one alias property in
`arch/arm64/boot/dts/apple/t6030-display.dtsi`:
`disp0_piodma` becomes `disp0-piodma`. Its node label and referenced path stay
unchanged. The loader retains compatibility with old trees and deliberately
prefers the legacy alias when both are present, as upstream specifies.

No canonical/development boot builder selects these series. Nothing was
installed, flashed, enabled or booted. No disk, ESP, APFS, firmware or boot-policy
write occurred. No native read, target initialization or hardware experiment
occurred. The isolated loader build is not an M0 candidate or reproducibility
handoff; no kernel/M0 build was run.

## Current validation

| Check | Verified result |
| --- | --- |
| Actual `dt_set_display` and libfdt | 593 parameterized alias/dispatch cases on macOS and AArch64 Linux; ASan/UBSan, `-Wall -Wextra -Werror` |
| Old alias implementation | Independently fails the named canonical-alias assertion |
| Existing actual USB PHY fixture | 26 cases pass against combined source with UBSan; predecessor fails reset-event assertion |
| Adjacent loader ownership | 137 reserved-record, 43 DART-caller and 39 USB-lifecycle cases pass |
| Real J514s DT / loader clocks | Eight DT test methods; 46 libfdt handoff and 275 Linux callback checks pass, including FDT-readback data flow |
| Retained-DART capture preparation | All 15 optimized-Python tests pass with the combined controller export; fake proxy only |
| Fresh replay | Eighteen m1n1 patches and fourteen Linux patches apply from their exact pins; edited and replayed byte/link manifests match |
| Device-tree comparison | J514s decoded DTB differs only by alias spelling; J516s DTB is byte-identical |
| Full loader build | `m1n1.bin`, Mach-O, ELF and raw ELF link offline using the existing pinned executor |

These counts describe software cases and test methods, not independent defects,
hardware scenarios, coverage of the whole kernel or milestone acceptance.
macOS repeats are not additional unique cases.

The alias fixture extracts the actual complete dispatcher and mapping arrays.
It uses real libfdt with owned trees. Hardware operations and subordinate
reservation helpers are recorded stubs. It covers nine SoCs, four alias
combinations, both firmware branches, null/present display configuration and
reservation/VRAM error propagation. It does **not** prove subordinate missing-map
policy, native DART locking or MMIO. The real J514s tree exercises T6030's
current absence of a display-reservation branch: FDT bytes stay unchanged and
no reservation callback occurs. This is a missing integration gate, not proof
that T6030 needs no reservations.

All seven display hardware nodes and both clock providers remain disabled.
J514s DTC warnings decrease from ten to nine: only `alias_paths` is retired.
Seven baseline warnings and two development warnings remain; J516s keeps its
seven baseline warnings. No dt-schema pass is claimed.

The loader C build uses `EXTRA_CFLAGS=-Werror`. Rust retains the existing unused
`crate::println` import warning in `rust/src/usb4.rs`; that file is byte-identical
to patch 22 and the warning was recorded in earlier linked builds. Rust warnings
were not promoted to errors. No unrelated warning cleanup was added.

## Evidence and reproduction

All local evidence is under
`out/isolated/dcp-source-audit-20260906/`:

- `upstream-loader-source/` and `upstream-loader-replay/`: 510 byte/link entries,
  five symlinks; manifest SHA-256
  `5d21f55588e11112f9cf6426d0bfc82be59e0d88aeb33fe5c4c4e4ca7ea40fcf`.
- `upstream-linux-source/` and `upstream-linux-replay/`: selected Apple DT,
  Apple DRM and DT-binding paths, 1,417 byte/link entries, four symlinks;
  manifest SHA-256
  `38b9e1388686815dee6be16d2127935edf5a018836ee295048643efd01e845b0`.
- `upstream-proof/`: before/after DTBs, preprocessed/sorted trees, compiler
  diagnostics, focused logs and four linked loader artifacts.
- `upstream-closure.json`: exact commands, dependency/source/artifact hashes,
  source replay manifests, predecessor-evidence bindings and remaining gates.

The manifest algorithm hashes sorted `[relative path, kind, content SHA-256 or
symlink target]` records as compact ASCII JSON, excluding export `.git` data.
Fresh selected-path exports have no case-fold collisions. Each export has its
own Git root. DT preprocessing/compilation and the full loader build run on
Linux case-sensitive temporary storage, not in the canonical source worktrees.

The existing AArch64 executor is
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
It runs with no network, read-only root/source/dependencies and disposable
`/tmp`. No kernel/source-volume mount or concurrent Linux build is used.
The build reuses the recorded Cargo inputs with offline mode and `--locked`:

```sh
CARGO_HOME=/tmp/cargo CARGO_NET_OFFLINE=true \
M1N1_VERSION_TAG=60e53e7-dev-upstream-p24 SOURCE_DATE_EPOCH=1788197968 LC_ALL=C \
make -C /tmp/loader -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

The closure contains the complete container invocation and mounts. A focused
host alias check from the repository root is:

```sh
python3 -O -B tests/m1n1-display-alias-self-test.py \
  out/isolated/dcp-source-audit-20260906/upstream-loader-replay \
  out/isolated/dcp-source-audit-20260906/upstream-proof/after-j514s.dtb
```

Two setup failures remain visible instead of being discarded. First, applying
the DT patch inside an export without its own Git root silently skipped the
patch; all eight DT tests rejected that source. The failed attempt is retained
in `upstream-proof-unapplied-dt/`. The corrected private Git root and fresh replay
pass. Second, the old USB source did not call the new fixture's `clear32` hook,
so its first strict compilation rejected an unused test hook. Only that
predecessor control uses `-Wno-unused-function`; current-source checks retain
warnings-as-errors. The corrected old source then fails the intended assertion.

Bounded independent read-only review found no material issue. Historical
closures are not edited: changed documentation and test bytes have explicit
before-edit snapshot bindings in this closure.

## Remaining gates and next safe work

There is still no verified T6030 region/SID membership table or complete,
ordered display-reservation/activation handoff. Cached macOS addresses cannot
substitute for fresh pre-Linux mapping evidence. The
[guarded capture tool](retained-dart-snapshot-2026-09-06.md) prepares that later
experiment; it does not authorize a boot and rejects unsupported metadata.

Keep display nodes disabled and the series unselected until those contracts
are supported by evidence. Continue independent offline callback/transport
analysis where useful. Before any new boot, refresh loader/candidate integrity,
backup/recovery readiness and the Linux observer; obtain new boot approval.
Panel output, USB/SSH, DMA/cache behavior, suspend/resume and full native hardware
acceptance remain unproven. A successful build does not retire these gates.
