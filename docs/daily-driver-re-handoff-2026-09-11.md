# Daily-driver RE checkpoint — 2026-09-11

Ready on macOS; not yet copied to native Linux. Full daily-driver/GPU support
remains incomplete. The newer native Linux checkout and its pause remain
authoritative. No boot, native write, firmware execution or fan operation occurred.

Artifact directory:
`out/isolated/daily-driver-re-20260911/`

- `linux-daily-driver-re-20260911.tar.gz`: self-contained private handoff, about
  102 MiB compressed; 509 files listed in the internal SHA256SUMS.
- `linux-daily-driver-re-20260911/README.md`: usage and evidence boundaries.
- `GPU-CONTRACT.md`, `COOLING-CONTRACT.md`, `DAILY-DRIVER-MAP.md`,
  `LINUX-RESUME.md`: reviewed facts, remaining contracts, per-feature next steps.
- `agx-pte-contract.c`: host-only compiled arithmetic model, not driver code.
- `gpu-context-export/`, `iouat-export/`, `smc-host-export-v3/`: new decompiler
  exports; archive also contains the prior `binja-export-v2/` core evidence.

Archive SHA-256:
`448924783460c35adcc9d365df59c3f82d0ba8a595b09ba70d4d886a551b1e93`

## Verified scope

Four immutable, separately pinned manifests contain 102 distinct function
addresses / 112 function records / 336 HLIL, MLIL and assembly files.
15,468 instruction records match the pinned archived input (counts include
overlapping function exports). Decompiler/mnemonic correctness is not inferred
from byte provenance. Three compatible Binary Ninja databases are included.

Fifteen verifier regression tests pass, including coordinated manifest/IL edits,
truncation, wrong groups and unresolved explicit targets. The host C model
compiles with C11, strict warnings and UBSan; 16,384 option/root cases, 64 PA/VA
bit cases, high invalid bits and fixed boundary vectors pass. Independent
Daybreak review agrees with the limited PTE arithmetic and SMC packet/result
contracts. Gitleaks publication scan passes with no findings.

Fresh archive extraction independently passes all 509 checksums, the same 15
regression tests and the compiled UBSan model. No Linux runtime test was claimed.

New findings: IOUAT doMap reaches pmap_iommu_map; its bit-39 lock selection is
distinct from AGX's bit-42 root. Gated SMC writes now have a reviewed payload,
sequence-ID and matched raw reply path. The 0x82 host label is BadCommand; the
server reason, mode3/Ftst semantics and CPU thermal freshness/export remain open.

The upstream September 6 M3 announcement means supported peripherals should be
integrated/tested, not reimplemented. Full DCP and performant GPU acceleration
remain missing; sleep/HDMI depend on DCP. See the cited source matrix in the
packet, not a generic assumption that kernel 7.3 provides full-chip support.

## Changed work

New daily-driver staging/artifacts and this report; extended the prior
`gpu-re-handoff-20260910/{export-binja.py,verify-export.py,test-verify-export.py}`.
Existing dirty source changes were preserved, not staged/committed. No M0/Linux
build ran because this work cannot change kernel output. Investigation and
lean-build constraints kept work focused on the current RE frontier; no new
dependencies or hardware-control wrappers were added.

Next safe step: additive archive transfer, hash verification on Linux, then
offline work on the exact contracts in LINUX-RESUME. Do not overwrite the Linux
tree, resume hardware automation, raise CPU caps or run renderer stress tests.
