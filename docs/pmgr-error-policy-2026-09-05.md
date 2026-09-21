# PMGR preliminary-fault policy: caller-aware correction

Checked 2026-09-05. Target remains Mac15,6 / J514s / T6030. No boot, hardware
access, kernel patch/build, source-pin change, or canonical promotion occurred.

## Decision

Do not patch `apple_pmgr_ps_set()` to return its preliminary force-reset/disable
error just because the earlier isolated assertion demanded that result. That
assertion selected an error policy without tracing the generic power-domain
callers. It is removed and replaced by caller-aware regression controls.

The observed log-and-continue behavior is real, but calling it a proven bug was
not justified. Historical logs/manifests remain unchanged; this note supersedes
their `known_gap` interpretation. This does not prove all fault recovery safe.

## Why callback semantics matter

Pinned Linux: `d8082213fc5a3a64c8b9464a7d5c82d13b1ea115` (M0 post-patch), based
on Asahi `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`. A live `git ls-remote`
returned that same upstream branch head, so there was no newer branch fix to
import. The [upstream PMGR implementation](https://github.com/AsahiLinux/linux/blob/77cb8f24c2381a8abb7272d7bbdec548d6426a8a/drivers/pmdomain/apple/pmgr-pwrstate.c#L56)
logs the preliminary fault, still performs the final transition, and returns
the final poll status.

The [generic power-domain core](https://github.com/AsahiLinux/linux/blob/77cb8f24c2381a8abb7272d7bbdec548d6426a8a/drivers/pmdomain/core.c#L904)
interprets a failing power-off callback as domain still ON. Its runtime and
system-suspend callers can still finish suspend; resume can skip power-on when
the recorded domain status is ON. Source locations inspected:

- PMGR writes/polls and final return: `pmgr-pwrstate.c:56–126`; callback binding
  at `:266–267`.
- Core callback/error handling: `core.c:904–931`, `:1049–1056`, `:1472–1486`.
- Suspend acceptance: `core.c:1306–1311`, `:1610–1615`; resume fast paths:
  `:1079–1080`, `:1516–1517`.

| Policy after preliminary fault | Final observation | Logical consequence |
| --- | --- | --- |
| Continue, return final success | Requested OFF state observed | Core can record OFF and later request ON |
| Continue, then return earlier error | Requested OFF state observed | Core retains ON and can skip required power-on |
| Abort immediately | Final transition never attempted | Earlier write has already changed auto-PM/disable/reset; no verified rollback |
| Continue, return final failure | Requested state not established | Error remains visible; no false successful transition |

These are source-contract conclusions, not real-hardware observations. Any
future alternative must establish coherent state/rollback, preserve atomic-safe
execution (`GENPD_FLAG_IRQ_SAFE`), and be validated on hardware that uses the
properties. Do not add speculative recovery register writes to satisfy a test.

The force properties were proposed for special ISP power-domain handling in
the [camera/ISP patch series](https://lists.infradead.org/pipermail/linux-arm-kernel/2025-February/1002642.html).
The local two-commit shallow checkout already contains them at its boundary;
`git log -S` there cannot establish the true introduction commit. No history
was fetched or attribution invented.

## Stronger target applicability check

The retained compiled and installed J514s DTBs both pass their M0 manifest
checksums: `3a1e59f79d842138724361ce9ad57d386a4f3dff42b061c1f0ed23001d554d14`.
DTC 1.6.1 decompilation exposes 160 PMGR nodes, zero `apple,force-disable` and
`apple,force-reset` properties, and four `apple,externally-clocked` properties.
This covers the compiled include graph, not only `t6030-pmgr.dtsi`; runtime m1n1
fixups/overlays remain unexamined. It is not hardware-support proof.

The first positive-control query looked for the generic compatibility string,
found zero domains, and failed closed. The corrected query recognizes the
actual T6030/T8103 compatibility list. Both outputs and unfiltered DTC warnings
are retained; this was decompilation, not a new `dtbs_check` acceptance run.

## Executed regression proof

The existing C harness now checks three force combinations × two preliminary
failures (timeout/EIO) × three final outcomes (success/timeout/EIO). These 18
cases require the authoritative final return, two writes and follow-through,
correct register payloads, logs, and timeout-versus-EIO polling behavior.

All 85 PMGR + 195 DART cases pass optimized ASan/UBSan and separate gcov runs.
Six compiled mutants are rejected at their intended assertions, including
propagating an earlier errno after final success and aborting prematurely.
`apple_pmgr_ps_set()` now reaches 100% gcov blocks in this selected-function
model. All 11 runner-test groups pass on Linux/AArch64 and macOS, and the
complete host M2 suite passes. All 47 source-run artifact checksums pass.

A bounded critical read-only review found no material defects in the three
changed test files. The reviewer did not run tests. Generic core semantics were
source-reviewed, not executed by the C harness. Regmap write failures, actual
partial hardware state, real concurrency and all earlier coverage exclusions
remain untested. No kernel build or full static-suite rerun was needed for this focused
test correction; the earlier 18-suite static checkpoint is retained separately.

Evidence and exact commands: `out/isolated/pmgr-timeout-review-20260905/README.md`.
Native gates remain unchanged; see [preboot readiness](preboot-readiness-2026-09-05.md).
