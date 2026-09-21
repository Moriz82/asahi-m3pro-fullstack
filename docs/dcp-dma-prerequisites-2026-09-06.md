# DCP stream and Python T8110 mapping prerequisites

Development-only, offline checkpoint. No native display acceptance, installed
controller change or boot authorization. Patches 06/07 are not selected by any
canonical or development boot builder.

## Source and exact-target evidence

Base m1n1: `60e53e7078c5cb7efce32d64bf50829e9401e44f`. Disposable Python export
applies patches 01, 04, 05, 06 and 07, in that order. The generic ASC/T8110
changes do not require the DCP ABI patches, but all were tested together.

The previously verified 23J220 `DeviceTree.j514sap.decoded` binds
`/arm-io/dcp:iommu-parent` to `/arm-io/dart-dcp/mapper-dcp`, whose `reg` is **5**.
The DART compatibility is `dart,t8110`, with 16 KiB pages. The test verifies
the original ADT SHA-256 and the phandle relationship, not just a synthetic
stream number. This static template does not establish live TCR/TTBR state.

## Changes

- `06-dcp-stream-selection.patch`: `DCPClient` accepts an optional `stream`
  after the existing arguments, preserving default 0 and the display-DART
  argument. `StandardASC.iomap` invalidates `1 << self.stream`, matching its
  mapping stream instead of always invalidating stream 0. It preserves the
  existing DVA-offset encoding and physical/no-DART behavior.
- `07-t8110-mapping-validation.patch`: removes a reference to uninitialized
  `l1pte` when an existing four-level L0 entry is reused. Validates integer
  arguments, stream range, mode, alignment and representable address ranges
  before enabling a stream. The enabled-stream cache changes only after the
  register write returns successfully. An offset within valid physical page
  zero no longer becomes an unmapped result.

The virtual limits are the Python translator's existing 36/44-bit supported
widths; the physical limit follows its 28-bit PTE page number plus 14 page
bits. These are representation checks, not discovery or proof of the device's
actual address-width capability. Zero-length mappings remain no-ops.

## Verification

Evidence root: `out/isolated/dcp-source-audit-20260906/`.

- `tests/m1n1-dma-prerequisites-self-test.py`: 12 tests pass against actual
  patched classes, including 18 fresh/retained boundary-map combinations,
  repeated mappings, exact Apple metadata, no-DART behavior, mapping and
  invalidation failures, 26 malformed-range/type cases, five invalid
  mode/alignment cases, failed stream enable and physical-zero translation.
- Page-table checks walk flushed fake-memory bytes independently of the
  client's PTE constructor/cache; they also invalidate the software cache and
  exercise the actual translator. Table allocations start filled with junk,
  not zeros. Neighbor entries and unrelated enabled streams are preserved.
- Final unpatched baseline fails with 33 failed subcases and 10 errors,
  including the retained-L0 `UnboundLocalError` and unsupported `stream`
  argument. The initial fixture lacked lazy register backend methods; that
  fixture issue was corrected before the retained final baseline run.
- Python `-O` passes all 12 cases, including exact metadata. A407, D003,
  D411 and DMA prerequisite suites pass under V12.3/V13.5/V14.7; target-only
  cases are explicitly skipped on older profiles. Optional ADT tests run in
  the exact-input/optimized passes, not the metadata-free profile matrix.
- Fresh replay is byte-identical to the tested disposable client export.
  Independent bounded review found no material issue.
- Existing controller smoke test passes in the pinned Linux container: 218
  source parses, exact construct/pyserial versions, guarded imports, four
  target-access rejection controls, both parser-only launchers and local ARM
  assembly/disassembly. DMA tests also pass there (optional ADT case skipped).
  macOS lacked its configured cross-linker; the first bare Linux attempt
  lacked construct. The final run used a read-only isolated snapshot of the
  already installed pure-Python dependencies, without network or installation.
  Docker could not directly bind the Homebrew path, so the snapshot resides
  under the existing evidence root. These failed attempts are retained, not
  counted as passing tests.

Core commands, from the repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m1n1-dma-prerequisites-self-test.py \
  out/isolated/dcp-source-audit-20260906/m1n1-dma-replay/proxyclient \
  out/isolated/dcp-source-audit-20260906/inputs/DeviceTree.j514sap.decoded

PYTHONDONTWRITEBYTECODE=1 python3 -O -B tests/m1n1-dma-prerequisites-self-test.py \
  out/isolated/dcp-source-audit-20260906/m1n1-dma-replay/proxyclient \
  out/isolated/dcp-source-audit-20260906/inputs/DeviceTree.j514sap.decoded
```

Logs: `dma-python-{baseline-final,final,optimized}.log` and
`dma-regression-V*-*.log`. Patch/test/source hashes are in `dma-closure.json`.
No M0 or kernel rebuild was required for these Python-only changes.

Linux smoke evidence is `dma-controller-linux-final.log`. Executor image is
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
It ran `tests/m1n1-controller-offline-test.py CLIENT` followed by the DMA suite,
with read-only client/test/dependency mounts, network disabled and temporary
`/tmp`. The canonical source volume was not mounted. The dependency snapshot
is test evidence, not a new installed dependency or canonical cache.

## Remaining blockers, not solved by these patches

1. `DCPManager.allocate_buffer` and `map_physical` still bypass the ASC helper
   and hardcode stream 0. Do not replace them blindly: raw IOVA versus encoded
   DVA semantics and the Apple DART `vm-base` must first be reconciled.
2. `StandardASC` read/write/translation still masks to 36 bits. A genuine
   greater-than-36-bit IOVA is different from a tagged low IOVA; changing the
   stream alone does not resolve that distinction. The DART facade still
   allocates only 16 per-stream heaps despite T8110's 256 register slots.
3. T8110 allocation or table-write failure can still leave partially published
   state. This patch only prevents invalid requests and failed enable writes
   from recording success; it is **not** transactional mapping or rollback.
4. No cache/coherency, device-register mapping attributes, invalidation timeout,
   allocation cleanup, unmap or DMA-quiescence guarantee is added. A failed
   transport write can have reached hardware even when the client sees an error.
5. Python D411 DMA mode remains deliberately rejected. Linux DMA resource
   caching and quiesce-before-unmap, target DT/runtime reservations, and panel
   power sequencing still need evidence and implementation.

No live register/page-table reads, target commands, device initialization,
installed client/module/image, storage, firmware or boot-policy changes were
made. Offline fixtures are test tripwires, not an OS security sandbox.
