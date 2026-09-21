# EPIC message ownership, matching and bounded parsing

Development-only m1n1 patch 16 follows C patches 02/03/08/10/11/12/13/14/15
on `60e53e7078c5cb7efce32d64bf50829e9401e44f`. Production changes are limited
to `src/afk.c` and `src/dcp/parser.c`. No canonical pin/source, installed image,
boot, firmware, storage or hardware changed. No builder selects this series.

## Changes

- High-level EPIC consumers copy the validated frame before acknowledging the
  ring, then free their own copy. Copy length comes from the saved ring peek,
  not a second untrusted length read. Header changes during copy fail closed.
  Notification callbacks may now safely encounter ring recycling or perform
  synchronous work without depending on an acknowledged payload.
- One decoder checks header sizes, versions, declared submessage length and
  inline bounds. Consumers use the declared length rather than trailing ring
  bytes. The pinned [Python protocol definitions](https://raw.githubusercontent.com/AsahiLinux/m1n1/60e53e7078c5cb7efce32d64bf50829e9401e44f/proxyclient/m1n1/fw/afk/epic.py)
  distinguish the version-2 EPIC header, version-4 subheader and optional
  command cookies. This C DCP path checks that layout; it does not claim
  support for the different version-2 AOP subheader.
- Standard notifications route through their own channel. A single checked
  reply allocation replaces the old pair of allocations; callback and send
  errors propagate. Replies require matching channel, subtype, category and
  submessage sequence. Four-byte status-only replies remain valid without
  requested output. Successful descriptor replies need their 28-byte fixed
  fields; optional cookies are not required.
- Command inputs and output lengths are checked before copying. Nonempty
  output must name the requested RX buffer, and cannot exceed caller or
  allocated capacity. A pending-command guard prevents nested/shared-buffer
  reuse. It clears only for a matched completed reply or an unpublished
  capacity failure. Uncertain completion keeps the buffers reserved.
- Background work and RBEP_RECV cannot consume a different pending command's
  RX stream. A new regression caught this missing ownership guard after the
  initial link. Standalone notification callbacks can still issue commands
  when no outer command owns the endpoint.
- Command deadlines are checked between work batches (one-second default).
  Each batch handles at most 16 mailbox messages and then completes the
  endpoint scan, preventing continuous traffic from starving a later endpoint.
  Interface discovery includes the first message in its 500 ms deadline and
  requires the exact expected service count. These are not hard real-time
  guarantees around callbacks, RTKit work or device operations.
- Announcements require bounded, terminated names; duplicate channels cannot
  inflate discovery. Owned property strings are freed on every outcome.
  Failed TX-buffer allocation attempts to release the newly allocated RX
  buffer; failed RTKit cleanup still retains its descriptor.
- The property parser checks bounds before pointer arithmetic, enforces
  allocation failure, rejects duplicate required keys, checks unknown-value
  skipping and publishes the unit only on success. Its tag now uses the real
  `PACKED` definition, not an undeclared `__packed` variable. Unknown nesting
  is limited to 32 levels; element counts and skipping remain input-bounded.

## Exact validation

4,313 actual-AFK/property-parser C checks pass under AArch64 Linux ASan/UBSan,
with assertions and leak detection. Coverage includes all header truncations,
cookie-optional descriptors, status-only replies, stale/wrong replies, output
bounds, immediate ring reuse, callback re-entry, cross-endpoint ownership,
allocation/send failures, partial discovery, 4,000 deterministic property
mutations, all valid-property prefixes, unaligned input and nesting limits.

Thirteen predecessor controls reproduce envelope, lifetime, notification
channel, reply channel/sequence/address, truncated skip, duplicate property,
OOM, unaligned tag, initial wait, continuous-traffic wait and nested-command
failures. The final ownership regression also failed on the initial patch-16
implementation before its two guards were added. Bounded review and focused
re-review found no material issue in the final delta.

```bash
python3 -B /tests/m1n1-epic-self-test.py /source
python3 -B /tests/m1n1-epic-self-test.py /baseline --baseline
python3 -B /tests/m1n1-afk-ring-self-test.py /source
python3 -B /tests/m1n1-iova-self-test.py /source
python3 -B /tests/m1n1-rtkit-buffer-self-test.py /source
python3 -B /tests/m1n1-dart-levels-self-test.py /source
python3 -B /tests/m1n1-dcp-mapping-self-test.py /source
```

147,356 neighboring checks pass: 130,257 AFK ring, 12,284 IOVA, 299 RTKit,
457 retained-level and 4,059 mapping checks. The harness compiles both complete
production C files without rewriting them; mailbox, time, allocation and DMA
boundaries are fake. Intentional multichar constants and existing transposed
calloc spelling are suppressed; the predecessor alone also needs its existing
signed-comparison warning suppressed. Other harness warnings remain errors.

Ten C patches replay from the pin to 510 identical file/link entries, including
five symlinks. Final source/replay tree SHA256:
`0c779ad1469c9dec661386a00f62199d4f9259c6c07ffd8c6b444f57f1864abb`.

## Full link and retained evidence

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-epic-p16 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

Executor: `sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Final source/tests/sealed dependencies are mounted read-only, with disposable
writable copies in `/tmp`; networking is disabled. Cargo.lock stays identical.
No Linux source volume or M0/kernel build. ELF, raw ELF, Mach-O and raw binary
link; relevant AFK/parser/RTKit/IOVA/display symbols are present with no named
undefined symbols. C uses `-Werror`. Rust retains its one existing unused
`crate::println` warning in `rust/src/usb4.rs`.

Evidence: `out/isolated/dcp-source-audit-20260906/epic-closure.json`,
`compile-epic/`, `epic-loader-{source,replay}` and existing `iova-cargo-input/`.
`compile-epic-pre-owner-review/` and `epic-loader-replay-pre-owner-review/`
precede the cross-endpoint guards and are not final evidence or install inputs.
No artifact was installed or promoted to canonical M0 evidence.

## Next boundary

Endpoint startup/shutdown and DCP/display callers still swallow failures or
free owners without proven DMA quiescence. Partial interface failure may
leave discovered service/client state; this patch does not establish a
quiescence-safe teardown transaction. A timeout does not cancel firmware DMA.
Those lifetime paths must be corrected before considering native integration.

Wire freshness, live cache/DMA ordering, target region/stream policy,
permissions, panel/reset sequencing and native acceptance remain unproved.
Snapshots assume firmware respects ownership until ACK. Passing a software
suite does not establish physical hardware support or guarantee one-boot debug.
