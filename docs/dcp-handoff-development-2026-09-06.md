# DCP handoff and DART development, 2026-09-06

## Result

Following the [A407 ABI correction](dcp-abi-development-2026-09-06.md), the
display-handoff trace exposed two real m1n1 DART defects. Three changed lines
fix them in an isolated source export. Source-backed tests, sanitizer runs,
patch replay and a freestanding object build pass. A separate follow-up below
also fixes allocation-failure ownership and partial register publication.
No builder selects these patches, and no installed boot file changed.

Files: `patches/m1n1-dcp-development/02-dart-handoff.patch`, its README,
`tests/m1n1-dart-self-test.c`, this report and the M3 milestone checkpoint.
Follow-up files: `patches/m1n1-dcp-development/03-dart-init-ownership.patch`
and `tests/m1n1-dart-init-self-test.c`, plus updates to the same documentation.
No canonical pin, source-volume checkout or Linux kernel output changed.

Evidence root: `out/isolated/dcp-source-audit-20260906/` (`AUDIT` below).

## Resource evidence without another boot

The static 23J220 Apple template has no populated runtime carveout map.
Current macOS does expose one through cached IODeviceTree properties. A
read-only, allowlisted capture recorded model Mac15,6, chip 0x6030, board 0x04,
macOS 26.7 / 25G227 and its distinct firmware-version labels. Only selected
display/register/mapper properties were retained, not raw registry output,
serial numbers, boot-policy material or authentication data.

`capture-host-display.py` produces `host-display-metadata.json`;
`analyze-host-display.py` checks that saved observation against the exact
previously decoded 23J220 ADT. All four files are research artifacts under
AUDIT, not new boot tooling.

Observed and checked:

- 24 static properties agree across the two firmware generations: DCP/DISP
  register ranges, compatibles, interrupts and clock/power gates; DART ranges,
  page size, VM base/size and stream IDs.
- Current phandles resolve by node name to DCP stream 5, display stream 0 and
  PIODMA stream 4. Numerical phandle IDs differ from the old template; they
  must not be copied between trees.
- Eight current DCP segment records parse using pinned `adt_segment_ranges`.
  Seven match the full physical address/size pairs of carveouts 49, 50, 57,
  94, 95, 14 and 157. The OS_LOG segment is not one of those seven captured
  carveouts; it remains explicit, not silently assigned a region ID.
- `/vram/reg` exactly matches region-id-14 in this same snapshot.

This is evidence about the **current macOS boot**, not runtime evidence from
the planned 23J220 Linux boot. It does not reveal the display DART's actual
IOVA-to-physical page-table entries. No live page-table memory or hardware
register was read. Never hard-code these runtime addresses into a boot image.

Snapshot SHA-256:
`0e03c89ee4cf7591324b2e1f0780b6acba48997ebc4f55fa6eec211721ee0eef`.
The analyzer records this digest and keeps target runtime/hardware acceptance
false in `host-display-analysis.json`.

## Defects and correction

1. `dart_t8110_tlb_invalidate()` writes the command at offset `0x80` but polls
   `DART_T8110_TLB_CMD_OP`, the `0x700` operation-field mask, as an offset.
   The correction polls `DART_T8110_TLB_CMD`, the register just written.
   Stream encoding, barrier, busy mask, timeout and warning policy are unchanged.
2. `dart_search()` uses `< 0x7ff` for both levels, omitting index 2047 from
   each 2048-entry table. It now derives the limit from `SZ_16K / sizeof(u64)`.
   Existing entry decoding, validity checks, TTBR iteration and return-address
   construction are unchanged.

The search is used by `kboot.c:dart_get_mapping()` for display
reserved-memory mappings and by `display.c:display_start_dcp()` for framebuffer
lookup. The invalidation path is shared by T8110 DART clients. Neither defect
is claimed as the observed cause of a prior boot failure. The retrieved
[upstream DART source](https://github.com/AsahiLinux/m1n1/blob/main/src/dart.c)
also contains these defects; this is not an upstream-submitted patch.

Input `src/dart.c` SHA-256 is identical in the host 60e53e7 checkout and the
clean source-volume local 940439b candidate:
`559bdff2173d54854c75ea1da3aa8470bae13bf34b3ed42412fbc34fec8d54ea`.
Patched source:
`3cb469685899aabe5b62d9c3bb36da9fefb517614b801ae4f714370151c8eb77`.
Patch:
`86924fb39494279d2e7f37f96b9ecd9ae1c68a327f39c158f0890b2ce664b398`.

## Exact validation

The harness includes the actual `dart.c`, not a rewritten search algorithm.
MMIO writes, polling and barriers are recorded test doubles. Page tables and
destination pages are process-owned aligned arrays. No `dart_init()` or device
initialization executes. Cases cover all three existing PTE formats and all
their TTBR slots, indices 0/1/2046/2047 at both levels, unchanged table contents,
unaligned nonmatches, invalid entries, absent tables, and poll success/timeout
for streams 0/4/5/255.

- Unmodified source: independent `poll`, `last-l1` and `last-l2` modes each
  abort at their intended assertion, exit 134. Logs: `dart-tests-before/`.
- Patched source: 584 cases pass with UBSan, and again with ASan plus UBSan.
  Logs: `dart-tests-after/{result,asan-result}.log`.
- Fresh patch replay in a private Git export byte-matches the tested source.
- The existing Makefile's `invoke_cc` target builds the production
  freestanding `dart.o`; ELF inspection confirms an AArch64 relocatable object,
  not a linked or bootable image. Logs/object: `dart-tests-after/`.
- Bounded independent review found no material issue in the three-line patch
  or regression coverage. This is not a complete DART audit or native signoff.

Commands below ran inside the existing network-disabled AArch64 Linux image
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
The existing source-volume lock was held shared/nonblocking, with sources and
repository mounted read-only. Outputs were isolated. No M0/Linux build ran.
`/repo` refers to the repository and `/workspace` to
`asahi-offline-source-audit-20260904`.

```bash
exec 9</workspace/.milestone0-build.lock
flock -sn 9
cd /tmp
gcc -O2 -g -no-pie -fno-pie -ffunction-sections -fdata-sections \
  -Wl,--gc-sections -fsanitize=address,undefined -fno-sanitize-recover=all \
  -I /workspace/m1n1-candidate/src \
  -DM1N1_DART_SOURCE='"/repo/out/isolated/dcp-source-audit-20260906/m1n1-dart-source/src/dart.c"' \
  /repo/tests/m1n1-dart-self-test.c -o dart-test
./dart-test
make -C /workspace/m1n1-candidate invoke_cc \
  CFILE=/repo/out/isolated/dcp-source-audit-20260906/m1n1-dart-source/src/dart.c \
  OBJFILE=/tmp/dart.o
```

The first sanitizer run used `-fsanitize=undefined` alone. Before-fix runs used
`/workspace/m1n1-candidate/src/dart.c` and the three named modes.
Object SHA-256:
`066c89412ac59977a712f230bab1b5af64feb0707d0776ec90a1f28e41f7d195`.

The whole-source host harness compiler reports an existing `free(dart->l1)`
nonheap-pointer warning in the unexecuted `dart_init()` allocation-error path,
before and after this patch. It was not suppressed or fixed here. The separate
freestanding compile emits no warning. The allocation-failure issue was
examined separately below; the original patch-02 logs and export are unchanged.

## Follow-up: initialization allocation transaction

The original `dart_init()` enables its stream before allocating missing root
tables and writes each TTBR immediately after allocating that table. Failure
then calls `free(dart->l1)` when unlocked. That pointer addresses an inline
array inside the DART object, not a heap allocation. Prior root allocations
leak, including when locked. Merely changing this to free every root would
also risk freeing retained tables and leaving published TTBRs pointing to
freed memory.

Patch 03 tracks only newly allocated roots with a four-bit mask. It prepares
and zeroes all missing roots before the first register write. If allocation
fails, it frees those new roots and the object, without touching retained
tables or any register. Success uses the existing stream-enable, new-TTBR,
conditional-TCR and invalidation write order. The retained-TTBR reads now
precede stream enablement. No type, PTE, shutdown or timeout policy changes.

Source-backed validation:

- Three baseline controls against the patch-02 source abort independently
  with exit 134: `invalid-free`, `leak`, and `partial-write`. They assert the
  invalid interior free, leaked allocation under lock, and changed register
  state when the first T8110 root allocation fails. Logs are under
  `dart-init-tests-before/`.
- The new harness passes 3,582 cases with ASan/UBSan and
  `-Wall -Wextra -Werror`. It covers all retained-root masks, every lock/keep
  combination, object allocation failure, every missing-root failure point,
  valid/invalid stream IDs, stream-bank boundaries and successful publication
  order across T8020, T6000 and T8110. Allocation slots are owned aligned
  arrays; fake frees detect retained, interior and duplicate frees. Register
  calls are recorded, never executed against hardware. The real object uses
  libc allocation. The harness does not exercise `dart_shutdown()`.
- The preceding actual-source search/invalidation harness passes all 584
  cases again with the same strict compiler and sanitizer options: 4,166
  cases total. Compiler logs are empty, with no suppressed warnings.
- The existing production `invoke_cc` target builds the patched freestanding
  object without warnings. Native `readelf -h` confirms AArch64 REL, no entry
  point/program headers. The initially attempted cross-prefixed readelf name
  was unavailable; native readelf completed the inspection. No linked image
  or full kernel/M0 build was produced.
- Fresh export of host pin 60e53e7, followed by patch 02 and patch 03, passes
  apply checks and byte-matches the tested source. Bounded read-only review
  found no material ownership or test defect; it is not native signoff.

Patched export: `m1n1-dart-init-source/src/dart.c`. Fresh replay:
`replay-dart-init/src/dart.c`. Test/object evidence: `dart-init-tests-after/`.
These are additional files under AUDIT, not replacements for patch-02 evidence.

Exact test/object commands inside the same immutable network-disabled image
and read-only mounts described above (`/evidence` is the new isolated output):

```bash
exec 9</workspace/.milestone0-build.lock
flock -sn 9
cd /tmp
for harness in m1n1-dart-init-self-test m1n1-dart-self-test; do
  gcc -O2 -g -Wall -Wextra -Werror -no-pie -fno-pie \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I /workspace/m1n1-candidate/src \
    -DM1N1_DART_SOURCE='"/repo/out/isolated/dcp-source-audit-20260906/m1n1-dart-init-source/src/dart.c"' \
    "/repo/tests/$harness.c" -o "$harness"
  "./$harness"
done
make -C /workspace/m1n1-candidate invoke_cc \
  CFILE=/repo/out/isolated/dcp-source-audit-20260906/m1n1-dart-init-source/src/dart.c \
  OBJFILE=/evidence/dart.o
readelf -h /evidence/dart.o
```

Baseline commands used the preceding `m1n1-dart-source/src/dart.c`, omitted
`-Werror`, and ran each of the three named failure controls. All logs were
saved separately; a baseline control is an expected failure, not a passing run.

SHA-256 digests:

- Patch 03: `a4bd59e1965304a1f68e2da0397b2b8033719e2b06644ac1a9af625299b54fb2`.
- Patched source: `95b1fc528096567e784b6f237fde3749eabc3aa0a035210f0d7076ad74aa3798`.
- Initialization harness: `34f7a566af103ac03710571adfe4c6a6e5dd5285872a2389fc316b2df291cb70`.
- Freestanding object: `71850c8ed2cb3bbe063a17915b960b0774c39d57331f5dc89b1b7b9840f05f78`.

This fixes the reproduced allocation failures, not the whole DART lifecycle.
Successful initialization still performs hardware-affecting writes. Whether
locked hardware accepts a missing TTBR, live timing, concurrent hardware
activity, shutdown ownership and invalid enum inputs are not established by
this test. Do not promote patch 03 as general DART safety or hardware support.

## Remaining enablement requirements

Do not add T6030 aliases and call the existing reservation path observation-only.
`dart_init(..., keep_pts=true)` still enables a stream, can allocate missing
tables and invalidates the TLB. The reservation path also enables DCP and
display DART nodes. It is a hardware-affecting path.

The Linux driver additionally requires correct provider-register order,
bandwidth scratch configuration, firmware compatibility and panel data.
The [subsequent exact-target analysis](dcp-bandwidth-development-2026-09-06.md)
resolves the scratch slot/offset/width and D003 reply layout offline. Other
mapping, target topology, runtime and panel requirements below remain open.
`apple,bw-scratch` is a deliberate probe gate protecting the simple framebuffer;
do not remove it to make a draft tree probe. The Python D411 manager signature
also lags its newer schema and needs actual DMA mapping semantics, not a dummy
zero output. These are next implementation gaps, not passing coverage.
The [later D411 work](dcp-register-development-2026-09-06.md) implements its
verified direct-register mode and restores dispatcher depth on exceptions;
DMA mapping and hardware lifetimes remain separate unresolved requirements.

Next safe steps: finish the target register/bandwidth and boot-time mapping
contracts, with a separate DART lifecycle review before hardware promotion. Keep current
macOS runtime addresses separate from the future boot's ADT. No new boot,
serial command, hardware enablement, partition/ESP, firmware or boot-policy
change occurred. All hardware and release milestones remain unproven.
