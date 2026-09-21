# SART grant ownership and failure-aware cleanup

Development-only m1n1 patch 20 follows loader patches
02/03/08/10/11/12/13/14/15/16/17/18/19 on
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. It changes only `src/sart.c`,
`src/sart.h` and the NVMe cleanup caller. No builder selects this series;
no boot, installed image, storage, firmware or live hardware changed.

## Corrected defects

All four existing SART layouts use a 32-bit physical page register shifted by
12 bits. The API now rejects empty, misaligned, unencodable or overflowing
extents before writes, including addresses that previously truncated to another
physical page. Each layout retains its existing size-field limit. Physical
zero remains representable; representability is not proof of valid target RAM.

The owner records exactly which slots it published. Cleanup/removal no longer
clear unowned slots, including entries populated after initialization. Duplicate
or overlapping owned grants are rejected before publication: removing one
otherwise could leave another granting access to the same released buffer.
Version 3/4 flags stay 32-bit, so opaque upper bits cannot make a populated
firmware entry appear empty. Version metadata requires exactly four bytes and
uses an alignment-safe copy; the existing version-0 compatibility fallback stays.

Setters write disabled configuration before changing physical address/size and
publish enabled configuration last. This fixes the previous removal sequence,
which first redirected an enabled grant toward physical zero. It establishes
software register-write order, not hardware acceptance or physical DMA stop.

`sart_free()` now returns a boolean and clears only successfully released
ownership bits. A failure retains the object and remaining slots, rejects new
grants and permits cleanup retry without repeating completed slots. NVMe checks
that result, retaining queues, read staging and ASC after RTKit was already
freed. Retry does not reuse the freed RTKit owner or repeat power/reset phases.

## Verification

253 new offline scenarios pass: 252 actual SART/RTKit cases plus one NVMe
caller-failure case. The SART fixture compiles complete production SART and
RTKit sources with owned fake registers. It exercises all four layouts,
every slot, all 24 upper flag bits on version 3/4, bounds, overlap, metadata,
write order, exhaustion and cleanup failure at each of 16 positions. Actual
RTKit map/unmap tests verify unchanged output on rejection and retained grants
on release failure.

Eight patch-19 controls reproduce the original SART defects. A ninth compiles
the predecessor NVMe body against the new result contract and proves that
ignoring SART failure loses ownership. This is an explicit compatibility
control, not an unchanged-predecessor ABI test. Failure callbacks are injected
before writes; no physical SART write failure has been observed.

370 existing neighboring cases pass: NVMe/SMC 51, storage callers/cache 20,
RTKit buffers 299. Including the additions, the final replay runs 623 cases.
The revised storage fixture also passes all 51 cases against patch 19. C uses
AArch64 Linux ASan/UBSan, leak detection, assertions and `-Werror`; the existing
multichar literal exception remains. Rust/Python caller checks remain actual
source tests. Read-only review found no material issue.

```bash
python3 /tests/m1n1-sart-self-test.py /baseline --baseline
python3 /tests/m1n1-storage-lifecycle-self-test.py /baseline
for suite in sart storage-lifecycle storage-integration rtkit-buffer; do
  python3 /tests/m1n1-$suite-self-test.py /source
done
```

`/baseline` is the sealed patch-19 replay; `/source` is the fresh patch-20 replay.
Fourteen patches produce 510 identical source/link entries, including five
symlinks. Source/replay tree SHA256:
`c838242e7cc4064013af3e03c48bf8d5f3bacf62aec78b67143319e66a46887e`.
Replay normalizes inherited basename/full-path patch entries and compares
manifests in the same path order; the initial harness checks failed and were
corrected before accepting any replay or build result. Historical closures
remain unchanged.

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-sart-p20 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

Complete ELF/raw ELF/Mach-O/raw binary links pass with unchanged Cargo.lock.
Production C uses `-Werror`; the existing Rust `usb4.rs` unused-import warning
remains. Executor:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Network/rootfs writes are disabled; read-only source/tests/sealed dependencies
are copied into disposable `/tmp`. No kernel/M0 build, source-volume mount,
dependency download or new cache. Evidence:
`out/isolated/dcp-source-audit-20260906/sart-closure.json`, `compile-sart/`,
`sart-loader-{source,replay}`. The closure selects final logs/artifacts only.

## Still required

Current setters report argument validity, not register-readback or hardware
completion. Do not add a post-publication false result without changing the
caller ownership contract: RTKit may free a buffer after a rejected map.
Removing a grant still requires independently established device quiescence.
No cache/DMA acceptance, physical reset completion or transaction guarantee
follows from fake registers. Concurrent firmware replacement of an owned slot
is not detected; the existing single-caller ownership assumption remains.

DART invalidation failures still propagate only as log messages, including map,
unmap and page-table cleanup. Fixing them requires coordinated RTKit, IOVA,
display, USB and handoff callers, especially partial-map rollback where a caller
must not release backing memory after uncertain invalidation. That is the next
safe work, followed by exact-target region/stream/panel integration. The prior
archive proves one Linux guest under m1n1 HV, not direct-native/full hardware
support. Before another boot, refresh exact candidate, recovery, partition and
capture checks and pause for user approval.
