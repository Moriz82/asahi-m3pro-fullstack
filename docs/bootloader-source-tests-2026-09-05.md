# Offline bootloader candidate tests — 2026-09-05 UTC

Target remains Mac15,6 / J514s / T6030. This extends the
[offline tooling audit](offline-audit-2026-09-04.md) with execution of actual
upstream C functions. No boot, installation, Apple firmware execution, host
storage access, or native acceptance was attempted. Canonical pins are unchanged.

Changes: `tests/bootloader-source-self-test.sh`,
`tests/m1n1-usb-phy-self-test.c`, `tests/u-boot-apple-nvme-self-test.c`,
`scripts/verify-all-software-tooling.sh`, `README.md`, this report, and
`docs/offline-audit-2026-09-04.md`. Earlier audit edits remain documented in the
linked audit; the user-owned plan deletion is untouched.

## Inputs and scope

- m1n1: `940439b9a407fbfc499bea933269219f3f62d4c7`, artwork
  `80d14f8b6f485b310e305a84b4b806361518ddd1`. Exactly two commits after the pin:
  [display alias fallback](https://github.com/AsahiLinux/m1n1/commit/a997f4eb552beb517fa44420f8b50457fb5cd7c7)
  and [USB PHY reset sequence](https://github.com/AsahiLinux/m1n1/commit/940439b9a407fbfc499bea933269219f3f62d4c7).
  The alias change affects existing SoC branches; it does **not** add a T6030
  display-carveout branch. The USB change clears reset bits separately, preserving
  other control bits. These tests do not establish hardware timing correctness.
- U-Boot: `ec49c9d70e6ab003813d6f475fec62dc1c0f4bfe`, four commits after the
  existing `dbd2154c…` candidate. [The delta](https://github.com/AsahiLinux/u-boot/compare/dbd2154cb0d3a5552505cfcc00a8b5f8da737030...ec49c9d70e6ab003813d6f475fec62dc1c0f4bfe)
  changes only `drivers/nvme/nvme_apple.c`: conditional DMA flags, zero TCB opcode,
  admin-PRP alignment guards, and removal of the obsolete PRP-null-check register
  access. The last change addresses a firmware compatibility fault reported
  upstream; applicability to this exact Mac is an inference, not native proof.
- Builder: existing `build/Containerfile`, Debian snapshot `20260824T000000Z`,
  Rust `1.93.1`, GCC `12.2.0`. Local Docker image ID:
  `sha256:19a43a73e0415bde04bb0c1730db7e16ada85c01350be84183cfa7efaf496ccc`.
  The tag is `asahi-m3pro-milestone0:bookworm-rust-1.93.1`; recheck its ID before
  reuse. This is not the missing original canonical Arch builder image.

Sources and objects live on the case-sensitive isolated volume
`asahi-offline-source-audit-20260904`, alongside the unchanged `/audit/linux`:
`/audit/m1n1-candidate`, `/audit/m1n1-cargo`, `/audit/u-boot-candidate`, and
`/audit/u-boot-build`. No kernel build ran. Builds take the exclusive
`.milestone0-build.lock`; source tests take its shared side and refuse a busy
builder. Network access was used for source/dependency preparation only.

## Executed coverage

| Actual production function | Tested behavior | Measured coverage |
| --- | --- | --- |
| m1n1 `usb_drd_get_regs` | Both missing paths; all three register lookup failures; successful lookup order | 20/20 executable lines, 100% basic blocks |
| m1n1 `usb_phy_bringup` | Eight slots, unrelated-bit preservation, two invalid indices, all three power failures, ordered writes/clears | 24/24 executable lines, 100% basic blocks |
| U-Boot `apple_nvme_submit_cmd` | Admin/I/O queues, 4/16 KiB pages, first/intermediate/last slots, opcodes, lengths, no-data/data PRPs, alignment rejection | 19/19 executable lines, 100% basic blocks |
| U-Boot `apple_nvme_complete_cmd` | Descriptor clearing, neighboring bytes preserved, invalidation register, queue wrap | 12/12 executable lines, 100% basic blocks |

The USB test has 26 scenarios. The NVMe matrix has 972 successful
submit/completion combinations and six separate-process expected alignment
rejections. Counts describe a bounded matrix, not independent hardware tests.
Optimized builds pass UBSan. Separate unoptimized gcov builds measure coverage;
U-Boot coverage links static libc because its hidden allocator declarations
conflict with dynamically linked libgcov. No production header was changed.

Regression controls compile the same tests against historical source:

- m1n1 `60e53e7…`: rejected at the combined reset sequence.
- U-Boot `dbd2154c…`: rejected for incorrect no-data TCB flags.
- U-Boot `01e7f95a…`: rejected for nonzero TCB opcode.
- U-Boot `6bfd8a4f…`: normal matrix passes; missing alignment rejection fails.

Expected failures must have both the expected exit status and diagnostic.
The test doubles replace only ADT/power responses and panic handling. Real
AArch64 register helpers operate on process-owned arrays; no `/dev` device is
opened. Test files include production C directly, not a copied implementation.

The obsolete register's removal is supported by source review and the complete
U-Boot build, **not** an executed controller-probe test. Neither suite tests
enumeration, DMA/IOMMU behavior, cache coherency, real PHY timing, asynchronous
firmware, suspend/resume, DCP, GPU, or recovery. There is no whole-driver or
whole-platform coverage percentage.

## Repeat the source-specific tier

The clean pinned checkouts need the historical commits used above. The runner
generates its own `apple_m1_defconfig` and prepared headers directly from the
pinned U-Boot source in disposable `/tmp` storage. Externally supplied generated
headers are not accepted; a three-symbol mismatched-build fixture tests that
rejection. The command prepares headers and compiles test executables, not a
bootable loader. This closes a source/config binding gap found during review.

```bash
docker run --rm --network none --read-only \
  --tmpfs /tmp:exec,size=128m --cap-drop ALL --security-opt no-new-privileges \
  --mount type=volume,src=asahi-offline-source-audit-20260904,dst=/audit,readonly \
  --mount "type=bind,src=$PWD,dst=/project,readonly" \
  sha256:19a43a73e0415bde04bb0c1730db7e16ada85c01350be84183cfa7efaf496ccc \
  bash /project/tests/bootloader-source-self-test.sh \
  /audit/m1n1-candidate /audit/u-boot-candidate
```

This is a separate tier, explicitly reported as not run by the source-free
static aggregate. CI does not currently fetch/build these candidate inputs or
execute this tier. The shell entrypoint itself receives syntax/ShellCheck checks.

## Evidence and remaining gates

Initial retained output: `out/isolated/m1n1-upstream-20260905/`. The directory
name predates the U-Boot extension; it contains both candidates. This snapshot
is preserved unchanged, including its earlier test-source hashes. The reviewed
runner's final evidence is separate: `out/isolated/bootloader-source-binding-20260905/`.
Key records:

- Final `source-suite-verified.log`: regenerated source-bound configuration,
  mismatched external-build rejection, sanitizer tests, four regression controls,
  and all four function coverage checks. `source-suite-final.log` also records
  rejection while the source-volume lock is held exclusively.
- Initial `usb-phy-coverage.log`, `apple-nvme-coverage-static.log`: detailed gcov
  line/branch reports. The final suite log is authoritative for the reviewed runner.
- Final `final-static.log`: all 17 static suites passed again; 108 shell files
  plus config/init checked. The source-specific tier is explicitly omitted here.
- Initial `candidate-build-{1,2}.log`, `build-{1,2}/`: two clean m1n1 builds, using the
  same locked inputs and source epoch. All four ELF/Mach-O/raw artifacts match.
- Initial `uboot-candidate-build-{1,2}.log`, `u-boot-build-{1,2}/`: isolated U-Boot build
  records and artifacts; two clean builds produce identical ELF/raw binaries
  and configuration. Apple NVMe configuration and T6030/ATC strings checked.
- Final `test-source.SHA256SUMS`: exact three reviewed test sources; verify from
  the project root. Each directory has its own recursive `SHA256SUMS` closure.

A bounded read-only review found the external-generated-header provenance gap.
The runner now creates those headers itself; re-review found no remaining
material issue in the bounded files. This is not a whole-bootloader audit.

These are development artifacts, not outputs accepted by the canonical M0
verifier. No signed-tag trust claim is made for the post-tag U-Boot commit; the
existing candidate tag's expired-key limitation remains unchanged. No firmware
binary was imported into IDA/Binary Ninja or marked reviewed. Available public
source and direct execution were sufficient for these bounded questions.

Native safety gates still require fresh readiness, verified restore, a real DFU
rehearsal, clean pinned boot artifacts, and explicit approval. The current audit
also retains the missing-canonical-builder and stale-initramfs blockers. Do not
replace those gates with this test output or describe either candidate as safe
to boot on the user's Mac.
