# AFK ring transport and buffer negotiation

Development-only m1n1 patch 15 follows C patches 02/03/08/10/11/12/13/14 on
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. Production delta: `src/afk.c`.
No canonical source/pin, installed image, boot, storage, firmware or hardware
changed. No builder selects these development patches.

## Corrected transport boundary

- GETBUF validates the entire rounded allocation against the 48-bit wire
  address field. Tag/requested-window publication occurs only after the reply
  is sent. Pre-publication failures attempt cleanup; failed cleanup leaves the
  descriptor owned and reachable. `asc_send` returns false before writing
  either mailbox word, so this cleanup does not revoke a published address.
- Ring initialization checks the negotiated window rather than allocator
  padding. Invalid offsets, sizes, initial positions, duplicate initialization
  and overlapping RX/TX windows fail before publishing ring state.
- Ring geometry follows the pinned [Python AFK implementation](https://raw.githubusercontent.com/AsahiLinux/m1n1/60e53e7078c5cb7efce32d64bf50829e9401e44f/proxyclient/m1n1/fw/afk/rbep.py):
  three header blocks precede the payload window. The C path derives and
  validates power-of-two block sizes of at least 64 bytes, with at least two
  payload blocks. Mailbox offsets still use fixed 64-byte units. Tests cover
  64- and 128-byte blocks, not an observed M3 firmware block size. Other
  geometries fail closed rather than using unchecked alignment arithmetic.
- Shared positions are volatile, aligned and inside the cached window.
  RX includes the 16-byte queue header in wrap/length checks and requires the
  complete aligned frame to have been committed by the producer. Wrapped
  frames require matching tail/head headers. Malformed input faults the ring.
- RX does not advance the consumer during peek. ACK uses a saved validated
  cursor, never a reread of mutable message length. Missing/duplicate ACK or
  an unexpectedly changed consumer position faults the ring without advancing.
- TX validates lengths/pointers, preserves the empty/full distinction and
  wrap-header convention, and leaves memory unchanged on capacity failure.
  If mailbox send fails after producer-position publication, the ring faults;
  blind retries cannot silently append a duplicate command.
- Work skips uninitialized ring pointers, surfaces ring faults and rejects
  START_ACK before a successful start request and both ring initializations.

This reuses the existing transport and pinned dependencies. No new wrapper,
allocator, dependency, live DART operation or Linux/M0 build was introduced.

## Exact validation

The actual complete `afk.c` compiles into the AArch64 Linux harness with fake
RTKit allocation/mailbox boundaries. 130,257 checks pass with assertions,
ASan, UBSan and leak detection. Coverage includes exhaustive payload lengths
and position pairs against an independent block-occupancy model, 30,000
queued TX-to-RX iterations, non-power-of-two payload capacities, 48-bit span
edges, negotiation failures, allocation cleanup failure, geometry, malformed
headers, uncommitted frames and saved ACK cursors.

Nine controls fail on the preceding source for the intended assertions:
window bounds, address truncation, header-sized wrap, uncommitted payload,
invalid position, mutable ACK length, duplicate initialization, 128-byte
header blocks and post-publication TX retries. A bounded read-only review
found no material issue in the delta; that is not a full AFK lifecycle audit.
12,284 IOVA, 299 RTKit, 457 retained-level and 4,059 mapping regressions pass.

```bash
python3 -B /tests/m1n1-afk-ring-self-test.py /source
python3 -B /tests/m1n1-afk-ring-self-test.py /baseline --baseline
python3 -B /tests/m1n1-iova-self-test.py /source
python3 -B /tests/m1n1-rtkit-buffer-self-test.py /source
python3 -B /tests/m1n1-dart-levels-self-test.py /source
python3 -B /tests/m1n1-dcp-mapping-self-test.py /source
```

The harness suppresses intentional multichar constants and GCC's existing
unrelated transposed-calloc spelling warning. All other warnings remain
errors. The full freestanding production C build uses `EXTRA_CFLAGS=-Werror`.
No source is rewritten for the harness. `/baseline` is the patch-14 replay.

Nine patches replay from the pin to 510 identical file/link entries, including
five symlinks. Source/replay tree digest:
`a35812c50cdeaf2b422195c8fb7becba09df8fee3b824259842b61665e50a18d`.

## Full offline link and evidence

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-afk-p15 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

Executor: `sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Networking is disabled; source, tests and sealed `iova-cargo-input` are mounted
read-only and copied into disposable `/tmp` storage. Cargo.lock remains
byte-identical. No Linux source-volume mount or concurrent kernel build.
ELF, raw ELF, Mach-O and raw binary link successfully. AFK/RTKit/IOVA/display
symbols are present; there are no named undefined symbols. Rust retains its
one existing unused `crate::println` warning in `rust/src/usb4.rs`.

Post-link inspection initially used unavailable `llvm-nm`; installed GNU
`nm`/`readelf` completed symbol/ELF verification without rebuilding. The build
itself had already completed successfully. This is recorded, not a hidden
build retry or a dependency installation.

Evidence: `out/isolated/dcp-source-audit-20260906/afk-closure.json`,
`compile-afk/`, `afk-loader-{source,replay}` and the preceding sealed dependency
input. Historical evidence retains explicit before-edit documentation bindings.
These linked images are not installed or promoted to canonical M0 evidence.

## Remaining work

EPIC parsers still need independent envelope/submessage bounds, allocation
checks, response matching and ownership-safe notification processing. In
particular, the existing command path acknowledges a notification before
using its ring-backed payload; saved ACK cursors do not fix that lifetime.
Endpoint startup/shutdown can swallow errors, wait indefinitely and free
owners despite failed shutdown. Error propagation must be fixed through
AFK, DCP wrappers and display, with DMA quiescence—not merely a local free.

Firmware-owned payloads are not immutable snapshots. This patch assumes the
producer respects ring ownership until ACK; it does not establish concurrent
host use or live cache/DMA ordering. Fresh target region/stream policy,
permissions, panel/reset sequencing and native acceptance remain unproved.
No software-only suite guarantees one-boot debugging or full hardware support.
