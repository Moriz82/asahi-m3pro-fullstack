# IOVA domain correctness and RTKit integration

Development-only m1n1 patch 14 follows C patches 02/03/08/10/11/12/13 on
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. Changed production files:
`src/iova.c`, `src/iova.h`, and the framebuffer allocation guard in
`src/display.c`. No canonical source/pin, installed image, hardware, boot,
storage or firmware changed. No builder selects the development patches.

## Fix and caller contract

The [inspected upstream allocator](https://raw.githubusercontent.com/AsahiLinux/m1n1/main/src/iova.c)
also contains the pinned code's absolute-limit size calculation, unreachable
exact-reservation branch and incomplete free-list insertion. No existing
replacement was found or new allocator dependency introduced.

- Domain bounds are exclusive, with the existing 32 MiB base alignment and
  a page-aligned limit. Size is now `limit - first_usable_address`, not an
  absolute address. Zero-based domains exclude page zero; empty/reversed/
  malformed domains fail before allocation.
- Reservations cover every page intersecting the original byte range,
  including an unaligned start. Exact-block/tail reservations work, removing
  a head preserves its successor, and split allocation failure is atomic.
- Allocation rejects zero/wrapping sizes. Free validates domain/alignment/
  overlap before mutation and handles head, middle, tail and both-neighbor
  coalescing. The existing fatal policy for invalid frees or metadata OOM is
  retained; this is not a new recoverable allocation API.
- Shutdown's table-release walk cannot wrap through address zero near the
  end of the numeric address space. That test is a bounds check, not a claim
  that hardware accepts 64-bit IOVAs.
- Review found that framebuffer exhaustion passed zero to `display_map_fb`,
  whose zero means search-anywhere rather than allocation failure. The caller
  now rejects exhaustion before physical allocation, memset or DART mapping.
  This prevents mapping/freeing an address the IOVA allocator never owned.

The free list does not track allocation identities. Callers still own the
responsibility for releasing only their allocated/reserved page ranges.
Single-threaded ownership, live DMA quiescence and existing map-failure
cleanup are not established by these changes.

## Exact validation

Final replay passes 12,284 actual-C/model/integration checks under AArch64
Linux ASan/UBSan and leak detection. This includes 12,000 deterministic
operations compared against a page-use oracle across six address profiles,
all 255 nonzero RTKit buffer request sizes, exhaustion, non-LIFO release,
tagged high addresses, mapping/mailbox failure rollback and allocator OOM.
The harness compiles complete `iova.c` and `rtkit.c`, plus the exact display
allocation prefix; memory, DART and mailbox boundaries are fake.

Seven original-fault controls reproduce high-domain over-allocation, rejected
exact reservation, tail-free panic, zero-address allocation, missed unaligned
reservation coverage, shutdown wrap and the display exhaustion sentinel bug.
299 RTKit, 457 retained-level and 4,059 retained-mapping checks also pass.
One bounded review identified the display regression; re-review passes after
its correction and exhausted/fragmented/success-path tests.

```bash
python3 -B /tests/m1n1-iova-self-test.py /source
python3 -B /tests/m1n1-iova-self-test.py /baseline --baseline
python3 -B /tests/m1n1-rtkit-buffer-self-test.py /source
python3 -B /tests/m1n1-dart-levels-self-test.py /source
python3 -B /tests/m1n1-dcp-mapping-self-test.py /source
```

`/source` is the eight-patch replay; `/baseline` precedes patch 14. Replay
matches all 510 file/link entries, including five symlinks. Final tree digest:
`ee6a29f804526b09da7c518e9df1e26167871b915b8262be856de355682cf5e5`.
Python syntax, patch whitespace, secret scans and prior evidence hashes pass.

## Full development link

Complete ELF, raw ELF, Mach-O and raw binary builds pass from the final replay,
with the updated allocator/RTKit/display functions present in linked symbols.
The complete IOVA/RTKit/AFK/DCP/display objects are retained as well.

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-iova-p14 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

Executor: `sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Final build has networking disabled, read-only source/test/dependency mounts,
and disposable writable copies in `/tmp`. No Linux source volume, M0 build
or kernel build is involved. C compilation is strict; Rust retains one existing
unused `crate::println` import warning in `rust/src/usb4.rs`. It is not hidden
or represented as a warning-free Rust build.

An initial attempt proved the offline image lacked pinned `fatfs`. A separate
fetch used `cargo fetch --locked` for the existing lockfile, without upgrades;
the resulting approximately 40 MiB dependency input is sealed outside canonical
evidence. The final build copied it into temporary storage and ran offline.
Cargo.lock remained byte-identical. Earlier failed/pre-display-guard builds are
not final evidence; only `compile-iova/final/` contains the corrected full link.

Evidence: `out/isolated/dcp-source-audit-20260906/iova-closure.json`,
`compile-iova/final/`, `iova-loader-{source,replay}` and `iova-cargo-input/`.
The closure binds files, source/dependency trees and preceding documentation
snapshots. This image is not installed, selected by a boot builder or promoted
to canonical M0 evidence.

## Next integration boundary

Actual allocator-to-RTKit software flow is now exercised. AFK's 48-bit reply
envelope, ring/window validation, endpoint failure recovery, parsed log bounds,
fresh target region/stream policy, cache attributes, DMA quiescence and panel
sequencing remain open. The display guard does not fix every existing mapping/
mode-change failure path. No simulated test or successful link proves live
firmware negotiation, native display operation or full hardware support.
