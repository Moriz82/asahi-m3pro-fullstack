# Preboot checkpoint: no-go

Target: Mac15,6 / J514s / T6030. Checked 2026-09-05 UTC.
Authority: complete non-boot development and checks; **do not boot**.
No native installation, partition/APFS mutation, firmware/boot-policy operation,
DFU transition, or backup operation was performed. Backup monitoring was not
restarted. The one-time readiness check was read-only.

## Software prepared

- The retained canonical M0 artifacts pass `scripts/verify-milestone0.sh` using
  the explicitly approved, immutable, version-matched inspection executor.
  Historical builder provenance and clean-rebuild requirements are unchanged.
- The corrected real M1 initramfs builds and passes
  `scripts/verify-milestone1-initramfs.sh`. An isolated second build has identical
  archive bytes: `cdfed2ea20e87583c217ab880442d4783a4e3312ab35975ede0ba5e3775f57eb`.
  The previous versioned image remains intact; `latest` now selects the verified
  new image. This is an artifact publication, not M1 hardware acceptance.
- Real publication exposed a Bash 3.2 readonly-variable collision in the shared
  atomic publisher. Removing redundant local aliases fixes it without changing
  atomic no-replace behavior. Regression tests prove destination preservation.
- A separate clean m1n1 client checkout at `60e53e7078c5cb7efce32d64bf50829e9401e44f`
  is retained in `out/isolated/m0-inspection-20260905/m1n1-client`. The existing
  `src/m1n1` edits/deletions are untouched. Both pinned Python dependencies match;
  218 proxyclient Python files parse, and `linux.py --help` exits before hardware
  setup. No serial connection or hardware setup module was invoked.
- Current pinned BusyBox passes all 13 isolated init scenarios. They use ordinary
  fixture files and mocked mount/dmesg/sleep operations, not real devices.
- Follow-up M1 audit fixes scanner errors that could appear clean and separates
  target readiness from controller preflight. Format-2 evidence retains both
  host identities, tool/device/artifact bindings, execution-time freshness,
  independent target anchors, and unique execution IDs through aggregation and
  handoff. Session checksums cover every run. M9 consumers now require and
  forward those same external M1 anchors; no readiness gate was weakened.
- A further M2 source-behavior tier compiles 12 verbatim pinned PMGR/DART
  functions with real polling macros and simulated kernel services. It passes
  280 behavior cases under ASan/UBSan and rejects six deliberate regressions.
  Caller review corrected the earlier PMGR "timeout gap" interpretation: final
  transition status must remain authoritative to avoid a genpd state mismatch.
  No kernel error-policy patch is justified by the reproduction alone. This is
  selected-function software coverage, not driver/hardware acceptance. Scope,
  exclusions, and known debt: [M2 executable tier](milestones/02-core-power.md#executable-driver-source-tier).

Exact commands, tier results, source hashes, and failure reproductions are in
`out/isolated/m0-inspection-20260905/README.md`; the follow-up role-split audit is
`out/isolated/m1-gates-20260905/README.md`. Earlier audit evidence remains
unchanged. No fresh clean Linux rebuild or release handoff is claimed.
M2 source runs and their exact invocation are retained separately in
`out/isolated/m2-driver-source-20260905/README.md`.
The caller-aware correction and expanded source test are documented in
[PMGR error-policy review](pmgr-error-policy-2026-09-05.md), with new evidence in
`out/isolated/pmgr-timeout-review-20260905/`.

## Firmware metadata cross-check

A further read-only IORegistry capture on this Mac (macOS 26.7 / 25G227)
compares existing firmware metadata with the checksummed, compiled J514s DTB.
It does not read hardware registers or invoke the m1n1 proxy/setup module.
The pinned m1n1 decoder translates all 75 captured memory regions (71 PMGR,
one AIC, three SMC) exactly to their independent IORegistry resolved addresses.
All 160 Linux PMGR addresses match the corresponding firmware descriptor fields;
11 malformed-input/mutation controls pass. This is address consistency only.

The comparison also records **unresolved policy differences**. Twelve DCS entries
are marked virtual/no-PS in firmware but exposed as always-on Linux domains.
There are 22 parent-list and 13 always-on/critical-flag differences in total;
19 nonvirtual firmware entries are absent from the Linux PMGR domain list.
Virtual intermediate parents and Linux's explicit PCIe-PHY always-on policy
explain some structural differences, but do not prove runtime safety or justify
blindly copying firmware parent links into Linux. No DT or driver patch was made.

AIC's core region matches exactly and its event window is contained within it.
The SMC core window is contained within its firmware region; the Linux SMC SRAM
window at `0x36de00000` (1 MiB) is not independently described by the captured SMC
properties. This is missing corroboration, **not evidence of an incorrect address**.
Before native acceptance, resolve these policy/mapping questions through suitable
source provenance and, when separately authorized, observed runtime behavior.

Reproducible analysis, retained metadata, all domain comparisons, negative controls,
source excerpts, and checksums: `out/isolated/m2-firmware-map-20260905/README.md`.
No kernel build, canonical artifact promotion, storage change, or backup check.

Source-history follow-up identifies the origin of those questions. Upstream
commit [`9d1725ac`](https://github.com/AsahiLinux/linux/commit/9d1725acb7f02eabe00f2141d3f0902be0e6beb5)
introduced the same SMC SRAM base/size. The current PMGR file is byte-identical
to the original [`fbedb15c`](https://github.com/AsahiLinux/linux/commit/fbedb15cdf4bed2d389c83fb35a7d6fa95209e23)
after removing four later audio `apple,externally-clocked` additions. Thus the
DCS/parent/always-on policies are inherited upstream, not project regressions.
The initial PCIe-PHY comment explicitly retains power because macOS does not
turn it off. This establishes source provenance, not independent physical-map
or runtime safety proof. These remain M2 review/trace questions, **not newly
invented M1 execution gates** or grounds for speculative changes. Exact source
bytes, origin commits, and comparisons: `out/isolated/smc-map-provenance-20260905/`.

## Read-only native gate

`asahi-arch-hyprland-lab/scripts/check-native-readiness.sh` exited **2**:
**25 passed, 22 blocked**, at 2026-09-05T06:15:06Z. FileVault, SIP, target identity,
and default macOS boot target passed. The report previously aborted on an
unavailable backup mount; a focused fix now records BLOCK and continues, with
failure/empty/success regression tests. It does not mount or repair backups.

| Remaining prerequisite | Observed state / required evidence |
| --- | --- |
| Recoverable backup | At the 06:15 UTC checkpoint, the configured network destination's reported completed backup path was unavailable locally and older than 24 hours; a backup was running then. Current status is unknown because backup checking was canceled and was not restarted. None of those observations proves recoverability or data loss. With renewed approval, make a completed backup accessible, verify encryption-key access independently, restore a sample, and compare bytes. Do not interrupt or resize during an active backup. |
| Selected installation profile | Requires an external physical SSD backup; none was connected. A verified network backup can be useful recovery evidence, but does not satisfy this existing profile. Any alternative must be deliberately designed and reviewed, not silently accepted. |
| Space / shrinkability | 158 GiB free versus this profile's 192 GiB (128 GiB Linux plus 64 GiB macOS headroom): approximately 34 GiB short. An APFS update snapshot limits shrinkage. Do not forcibly delete it or resize storage to pass this check. |
| Recovery controller | User reports a second Mac; model, macOS version, cable, correct DFU port, power/internet, and actual Finder detection have not been demonstrated here. |
| Two-Mac M1 workflow | The software role split and evidence chain are implemented and fixture-tested. Real controller inventory, target enrollment, independent anchor capture/transfer, and physical serial/target correspondence remain unverified. |
| Hardware/support acceptance | Native M1 and later milestone observations remain absent; known target diagnostics remain WIP debt. Do not relabel static fixtures, checksums, or candidate builds as support. |

`scripts/milestone1-preflight.sh` now has separate target and controller modes.
Mandatory independently retained target identity/bundle hashes have no defaults;
the controller never derives trusted expected values from an imported bundle.
Both 900-second freshness windows are checked at execution. Fixture tests do
not demonstrate the physical topology. Choose and validate an independent
anchor-transfer channel before enrollment; checksums alone do not authenticate
origin. Do not use invented attestations or fake serial devices. The separate
clean source checkout solves only source hygiene.

Space and full desktop support are installation-profile requirements, not
universal requirements for experimental RAM-only bring-up. Current M1 preflight
nevertheless invokes that same installation gate. A separate experimental
profile would need deliberate design/review; it must retain recovery proof,
target/controller binding and explicit execution approval. No gate was weakened
in this preparation pass.

A bounded critical review distinguishes **initial provisioning** from **reuse**.
Calling the kernel/rootfs RAM-only does not eliminate the initial APFS boot
environment, installed boot-chain components, vendor firmware or boot-policy
setup. No compatible installed environment has been proven on this target.
A later reuse-only profile could omit installation-specific space/shrink and
desktop/package checks, but only after independently binding the installed
boot environment, target identity, component versions/hashes, and the provenance
of its prior provisioning approval. Current format-2 readiness evidence does
not contain that installed-state proof or a profile identity. Adding a boolean
or merely rehashing a supplied report would not establish either fact.

No narrower profile was implemented or selected. A future design must bind its
profile and installed-state proof through target, controller, execution and
session validation; reject unknown/missing/rehashed substituted profiles; and
retain all original backup/restore, DFU, freshness and execution-approval gates.
Initial provisioning remains a separate, explicitly reviewed and authorized
physical workflow, not an exception obtained by calling it RAM-only. Review
record: `out/isolated/smc-map-provenance-20260905/m1-gate-scope-review.txt`.

## Upstream support is not a boot-safety certificate

The current [Asahi M3 feature matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
lists some M3 Pro enablement against `linux-asahi (7.3)`, including device tree
and keyboard backlight. It still lists GPU as TBA, and DCP, main display,
brightness, USB data paths, and installer as WIP. The inspected production
upstream installer marks J514s expert-only; the current ALARM installer does not
expose it. A 7.3 label does not establish a fully working laptop or safe dual boot.

## What the operator needs next

1. Identify the second Mac and its macOS version; arrange a direct USB-C cable
   that supports charging and data. Apple's current recovery instructions need
   macOS 14 or later on the second Mac, internet, power, and enough free space
   (Apple says 32 GB should suffice). Do not use a Thunderbolt 3 cable for DFU.
2. Finish and independently validate recoverable backup access and a matching
   sample restore. Keep the encryption secret outside the target Mac; never put
   it in project evidence or chat handoffs. Resolve the selected backup-profile
   requirement before any installation proposal.
3. Validate a concrete controller/target M1 plan: target-readiness provenance,
   reviewed artifacts on the controller, clean pinned client, actual serial
   identity, and fresh fail-closed preflight. No execution is authorized here.
4. DFU detection rehearsal is a later, separately approved physical step: it
   requires changing the target's power/boot state, so it was not done under
   the present no-boot instruction. Apple distinguishes non-erasing **Revive**
   from erasing **Restore**; neither was attempted.
5. Before a release-quality M0 handoff/major promotion, perform the required
   clean reproducibility rebuild and byte-level closure comparison. Before any
   boot attempt, obtain fresh readiness and explicit approval. Ordinary daily
   tooling edits do not require a kernel rebuild.

Recovery source: [Apple: revive or restore Mac firmware](https://support.apple.com/en-us/108900).
These checks reduce avoidable risk; they cannot establish a brick-free boot or
replace native driver, storage, thermal, display, GPU, or recovery validation.
