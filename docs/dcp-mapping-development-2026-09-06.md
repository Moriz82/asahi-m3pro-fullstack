# Retained DART mapping continuity

Development-only m1n1 patch 11, applied after C patches 02/03/08/10 on
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. No boot builder selects it.
No target commands, live registers/page tables, DART/device initialization,
installed files, storage, firmware, boot policy or boot changed.

## Corrected mechanics

`kboot.c::dart_get_mapping` previously checked only the first physical page
and final translated byte. Matching endpoints did not detect a missing or
remapped interior page. Empty or overflowing extents could also pass by
wrapping their last-byte arithmetic into an earlier valid mapping.

The existing helper now rejects null DART handles, zero/unaligned physical
bases, empty extents and physical/IOVA arithmetic overflow. It validates
every covered 16 KiB page against its expected physical page, retaining the
last-byte check for a partial final page. No new interface or allocation.

`dart.c::dart_translate_internal` now validates the entire IOVA root index
before indexing the root array. The previous two-bit mask discarded bits
38–63, allowing unsupported high addresses to alias a low root. Supported
existing layouts and addresses retain their behavior. This is not four-level
T8110 support and does not fix every mapping/unmapping API's address handling.

## Verification

- Five original-code controls reproduce an interior hole, remapped interior,
  accepted empty extent, overflowing extent and high-IOVA alias. Each must
  fail its intended assertion, not merely exit unsuccessfully.
- 4,059 cases run actual C DART search/translation plus the exact loader
  helper under AArch64 Linux ASan/UBSan with leak detection and `-Werror`.
  All pass on edited, incremental-replay and fresh-series exports.
- Cases cover all three existing C PTE formats and existing TTBR slots,
  partial pages, L1/root crossings, final-root boundaries, per-page holes and
  remaps, invalid physical extents, and unsupported high IOVA bits. Full
  table/handle snapshots must remain unchanged. The count is boundary-case
  coverage, not thousands of independent hardware scenarios.
- Existing actual-C DART suites pass another 584 and 3,582 cases. The nearby
  clock integration passes 46 real-libfdt cases plus 275 Linux callback cases
  on macOS against the new loader export. Kernel/ADT dependencies remain fakes.
- Both full production source files compile to AArch64 freestanding objects
  with `-Werror`, without diagnostics. No linked loader or kernel/M0 build.
- All five C patches replay from the pin. Edited, incremental and fresh
  exports match all 510 file/link entries, including five symlinks. Private
  `.git` administration is excluded. An initial nested-export replay skipped
  Git-format patches; a private `git init` corrected the invocation, and full
  byte/link comparison plus test execution verified the resulting replay.
- Bounded production review found no material issue. Final hashes and
  source-tree manifests are recorded in `mapping-closure.json`.

The mapping fixture uses process-owned aligned arrays. Physical values are
synthetic PTE data, not dereferenced target memory. Device initialization does
not execute; forbidden register-write/barrier/poll test doubles assert if
reached. ASan cannot establish target cache behavior, permissions, MMIO order
or consistency while firmware changes a live table.

## Reproduction and evidence

From the project root, export the pin into a new disposable directory and
initialize a private Git repository there before applying C patches
02/03/08/10/11 in that order. Preserve the canonical source and pinned inputs.
Inside the pinned AArch64 Linux development container:

```bash
python3 -B /tests/m1n1-dcp-mapping-self-test.py /source
# /before is the separately retained export immediately before patch 11:
python3 -B /tests/m1n1-dcp-mapping-self-test.py /before --baseline
```

Executor image:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Network disabled, root filesystem read-only, tests/source read-only bind
mounts, temporary compilation in `/tmp`. No Linux source volume was mounted.
The full source object checks used a writable temporary source copy:

```bash
make -s build-cfg
make -s invoke_cc CFILE=src/kboot.c OBJFILE=/evidence/kboot.o EXTRA_CFLAGS=-Werror
make -s invoke_cc CFILE=src/dart.c OBJFILE=/evidence/dart.o EXTRA_CFLAGS=-Werror
```

Evidence root: `out/isolated/dcp-source-audit-20260906/`.
`compile-mapping/` contains baseline, mapping, replay, adjacent-test and build
logs plus both objects. `mapping-loader-{source,replay,series-replay}` are the
matching exports. `mapping-research.json` records analysis-only IDA excerpts
bound to the existing host kernelcache and DCP firmware hashes. Earlier
closures remain unchanged; superseded documentation hashes are bound to
explicit before-edit snapshots in the new closure.

## Hardware-support gaps remain

IDA confirms the DCP firmware's 32 KiB stream-window spacing, corroborating
the previous transport patch. The host framebuffer carveout accessor resolves
an IOSurface memory-region object; it does **not** establish T6030 region-name
membership for DCP, display SID 0 and PIO-DMA SID 4. Existing T602x tables must
not be copied based only on matching cached region IDs.

No T6030 retained-region table or enablement branch was added. The existing
caller still treats a missing mapping as nonfatal and may omit its
`iommu-addresses` entry. Physical-address-zero ambiguity in the C API,
four-level T8110 traversal, PTE permissions/subpage constraints, alias choice,
live consistency, DMA coherency/lifetime, required-region failure policy and
ordered activation remain open. Reset, panel sequencing and native display
acceptance remain unproved. Cached macOS metadata is not a future boot's
address/rate source. Next safe work: establish the retained mapping/layout
contract offline before changing required-region policy or activation.
