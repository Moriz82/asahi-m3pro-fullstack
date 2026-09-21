# Retained T8110 table levels and lifecycle

Development-only m1n1 patch 12, following C patches 02/03/08/10/11 on
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. No builder selects it. No target
command, live register/page-table access, installed image, storage, firmware,
boot policy or boot changed. This is not native hardware acceptance.

## Format and implementation

The [author-submitted Linux four-level patch](https://lkml.iu.edu/2508.2/07822.html)
defines TCR bit 3 and hardware-reported input address width. The level count
includes the TTBR; four levels means three memory tables. The pinned Linux
allocator already supports this geometry. The inspected
[upstream m1n1 C source](https://raw.githubusercontent.com/AsahiLinux/m1n1/main/src/dart.c)
still assumes two memory tables. No duplicate Linux implementation was added.

Analysis-only IDA inspection of the existing kernelcache independently
confirms the mode-dependent starting level, page-number index shifts and
28-bit physical page-number extraction. The exact decoded J514s Apple tree
has 16 KiB DCP/display pages and no legacy `pt-region-*` or `l2-tt-*` properties.
Neither input establishes a future boot's TCR, TTBR or physical ownership.
Input hashes and bounded excerpts are in `levels-research.json`.

`src/dart.c`, `src/dart.h` and `src/dcp.c` in the disposable patch:

- Retained/locked T8110 initialization reads the existing mode. Four-level
  mode requires translation enabled, no bypass/remap, 16 KiB pages, 42-bit
  physical addresses and a reported virtual width in the representable
  37–47-bit range. Unsupported combinations fail before table allocation or
  register writes. Fresh contexts keep their old two-memory-table mode.
- Shared table helpers now supply translation, map, unmap and leaf release
  with the complete root index and optional extra table. Read-only queries
  never allocate. T8110 PTE physical extraction uses bits 37:10, matching
  the binary and Linux format, rather than treating reserved bits as PA.
- Physical search walks the same hierarchy; free-IOVA search observes valid
  PTEs, including physical page zero. Map/unmap/search bounds reject wrapping
  or unrepresentable ranges. Locked four-level ADT `vm-base` keeps its valid
  high bits instead of truncating them to 36 bits.
- Unmap and release no longer select a leaf from the wrong legacy TTBR.
  Release does not free retained leaves. Shutdown traverses table levels,
  not physical buffers, skips null intermediate pointers and out-of-aperture
  top entries, and invalidates after unlinking owned children before freeing.
  Newly allocated empty intermediate tables remain owned until shutdown.
- Four-level legacy preallocation returns a distinct unsupported-mode error.
  DCP setup propagates that error with cleanup. Existing legacy preallocation
  errors retain their prior continuation behavior; review caught and corrected
  an initial implementation that would have made all such errors fatal.

The existing heap-address ownership heuristic and void invalidation API are
retained. Successful fake invalidation is **not** proof of live quiescence,
timeout safety, shared-table alias safety or firmware/hardware ordering.

## Verification

- 457 actual-C retained-level/lifecycle cases pass under AArch64 Linux
  ASan/UBSan, leak detection and `-Wall -Wextra -Werror`. Tests execute the
  full DART source and exact loader continuity helper. Registers, allocation
  slots and physical table arrays are owned fakes, not target memory.
- Three original-code controls reproduce failed four-level translation,
  failed four-level physical search and wrong-root unmap. Each requires its
  intended failing assertion. Original source and final replay use the same
  fixture, not an independently rewritten model of the implementation.
- Coverage includes reported widths 37/42/47, table and address-space ends,
  holes/remaps, reserved PTE bits, null/poison intermediate slots, all retained
  keep/lock combinations, allocation-failure rollback, collisions, zero-page
  validity, malformed modes/ranges and retained-versus-owned cleanup. Width
  variants test representation; they do not assert actual T6030 capabilities.
- 8,225 existing cases pass: 4,059 loader continuity, 3,582 initialization and
  584 DART search/invalidation cases. The initialization fixture now expects
  the additional retained-T8110 TCR read, with prior expectations archived.
- DCP lifecycle/selector tests pass 138 cases on macOS, including both new
  unsupported-mode cleanup paths and preserved legacy fallback. Clock
  integration passes 46 real-libfdt plus 275 Linux callback cases on macOS.
- The full six-patch C sequence replays from the pin and matches all 510
  file/link entries, including five symlinks. Private Git files are excluded.
- Complete `dart.c`, `dcp.c` and `kboot.c` compile to freestanding AArch64
  objects with `-Werror` and no diagnostics. No linked bootloader, full kernel
  or M0 build. One bounded read-only review passes after the correction above.

Run on AArch64 Linux with read-only source/test mounts and temporary `/tmp`:

```bash
python3 -B /tests/m1n1-dart-levels-self-test.py /source
python3 -B /tests/m1n1-dart-levels-self-test.py /before --baseline
python3 -B /tests/m1n1-dcp-mapping-self-test.py /source
```

`/before` is the retained export before patch 12. Executor image:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Network is disabled; rootfs and inputs are read-only. No Linux source volume mounted.
Production checks use a writable temporary copy and existing `build-cfg` /
`invoke_cc` targets, as in the preceding mapping report.

Evidence: `out/isolated/dcp-source-audit-20260906/levels-closure.json`,
`levels-research.json`, `compile-levels/*final*` and
`levels-loader-{source,replay}`. Prior logs and before-edit fixture/doc snapshots
remain available. The closure records final hashes and historical bindings.

## Remaining integration work

This retires the C library's retained four-level traversal gap, not end-to-end
wide-address DCP support. `rtkit.c` still masks buffer addresses to 36 bits;
firmware address tags must be distinguished from genuine high IOVA bits.
The saved ADT is not authority to copy fixed runtime addresses. Required
T6030 region/stream membership, reservation policy, cache attributes, DMA
ownership/quiescence, alias/timeout behavior, reset/panel sequencing and live
display operation remain unproved. Physical-zero ambiguity remains in the
pointer-returning translation API, though free-space search now uses validity.
Next safe work: derive and test the firmware DVA encoding through its callers
before widening their masks or enabling any display/DART node.
