# Failure-aware DCP lifecycle and boot handoff

Development-only m1n1 patch 18 follows C patches 02/03/08/10/11/12/13/14/15/16/17
on `60e53e7078c5cb7efce32d64bf50829e9401e44f`. No builder selects this series.
No installed image, boot, firmware, storage or hardware changed. This is a
software-ownership prerequisite, not proof of physical quiescence.

## Changes

- AFK rejects invalid/occupied endpoint IDs and failed startup. Startup and
  shutdown check one-second software deadlines between nonblocking polls.
  Shutdown requires an ACK after successful request publication, not simply
  `started == false`; unsolicited ACKs are rejected. A retry waits on the same
  published request rather than sending it again.
- Stopping endpoints ignore other mailbox types and cannot restart or process
  rings. Failure retains the registered owner and every unreleased buffer.
  Endpoint/parent cleanup stops at the first failure. Active-frame leases cover
  startup, command, discovery, callbacks and shutdown, so a callback on another
  endpoint cannot free an owner still used by its caller's C frame.
- All four DCP clients publish their ownership before service discovery. Failed
  teardown retains both client and endpoint; successful cleanup clears the
  owner's slot. Constructors reject duplicate or stopping owners.
- DCP tracks the active owner, including failed initialization. Client and AFK
  shutdown must succeed before a checked RTKit sleep/quiesce; RTKit buffer
  cleanup must succeed before dropping its owner. Failed resets latch failure.
  An early DART owner without RTKit is retained because this path cannot prove
  quiescence. Successful RTKit power transition is remembered across buffer-free
  retries. Successful teardown also frees the previously leaked ASC owner.
- `rtkit_free()` now returns a boolean and retains its object/name when any
  owned-buffer cleanup fails. Already released buffers remain idempotent;
  callers still owe an independently established quiescent device.
- Display returns cleanup errors. Main remains in the existing proxy before
  NVMe/exception/USB/MMU teardown when display cleanup fails or a retry clears
  the next-stage entry. HV initialization propagates display failure before
  further setup; primary/secondary HV start require successful initialization.
  Proxy replies expose the display/HV initialization results.

No timeout is a hard real-time bound around every handler or hardware call.
Retained owners are deliberate quarantine, not permission to force-free them.
An independent safe reset/recovery path is required where retry is refused.

## Validation

191 new checks pass on AArch64 Linux with ASan/UBSan, leak detection,
assertions and warnings-as-errors:

- AFK: 126, compiling complete actual AFK/parser C against fake RTKit/time.
  Includes all endpoint slots, invalid IDs, OOM, start/stop failures, late and
  unsolicited ACKs, buffer cleanup, parent retention and callback re-entry.
  Three cases dispatch an actual EPIC notification on endpoint B while A is
  starting, discovering services or shutting down; attempted teardown retains
  A's slot/buffer until its live frame returns, then cleanup succeeds.
- DCP owner: 17; display: 10; RTKit free: 3; main handoff loop: 3.
  Complete production functions/loop are extracted without rewriting their
  bodies and compiled against fake dependencies. HV/proxy ordering and latch
  guards are source-contract checks, not runtime HV execution.
- Four actual endpoint-client constructor/destructor pairs: 8 checks each.

23 predecessor controls reproduce the earlier defects, including two unbounded
AFK waits. Focused review's missing cross-endpoint coverage was added; re-review
found no material issue. No hardware, MMIO, DMA or live serial endpoint is used.

```bash
for suite in afk-lifecycle dcp-lifecycle dcp-client; do
  python3 /tests/m1n1-$suite-self-test.py /baseline --baseline
  python3 /tests/m1n1-$suite-self-test.py /source
done
for suite in rtkit-power epic afk-ring iova rtkit-buffer dart-levels dcp-mapping; do
  python3 /tests/m1n1-$suite-self-test.py /source
done
```

152,227 neighboring checks pass: RTKit power 420; EPIC 4,313; AFK rings 130,257;
IOVA 12,284; RTKit buffers 299; retained levels 457; mappings 4,059; DCP config
138. The last suite runs on macOS with existing pinned-input evidence:

```bash
python3 -O -B tests/m1n1-dcp-config-self-test.py \
  out/isolated/dcp-source-audit-20260906/lifecycle-loader-source \
  out/isolated/dcp-source-audit-20260906/m1n1-dma-replay/proxyclient \
  out/isolated/dcp-source-audit-20260906/inputs/DeviceTree.j514sap.decoded
```

The config fixture now models truthful cleanup results and intentional retained
early-init failures. It also passes all 138 cases on the patch-17 predecessor.
Before-edit fixture/runner snapshots preserve prior evidence bindings.

Twelve C patches replay from the pin to 510 identical file/link entries,
including five symlinks. Source/replay tree SHA256:
`550e045ff087dc6d27d09099103e4beb021c0afb33847976fecbf1cbb8da9b97`.
All 191 new checks also pass on that fresh replay.

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-lifecycle-p18 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

The complete ELF, raw ELF, Mach-O and raw binary link offline with unchanged
Cargo.lock and no named undefined symbols. Production C uses `-Werror`; the
existing unused `crate::println` Rust warning remains. Executor:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Source/tests/sealed dependencies are read-only mounts, with disposable build
copies in `/tmp`, networking disabled, and no M0/Linux source-volume mount or
kernel rebuild. No new dependency or cache was added.

Evidence: `out/isolated/dcp-source-audit-20260906/lifecycle-closure.json`,
`compile-lifecycle/`, `lifecycle-loader-{source,replay}` and the existing
`iova-cargo-input/`. Preview logs are excluded from final build evidence.

## Remaining work before integration

NVMe/SMC still ignore RTKit power/free failures. Their partial initialization,
reset and top-level handoff callers need failure-aware retention. IOVA/DART
cleanup and TLB invalidation still have void/error-swallowing paths; this patch
does not make them transactional. The DCP singleton assumes the existing
single-caller bootloader model, not concurrent multicore synchronization.

Shutdown ACKs and power counters are observed protocol progress, not proof of
correlated transactions, DMA stop or cache ordering. The prior empty-mailbox-
to-publication ACK race remains. CPU stop still lacks physical completion
proof. Live region/stream ownership, panel sequencing and native acceptance
remain open. Failure may deliberately block handoff indefinitely; no automatic
reset, reboot or memory reclamation is used to bypass that state.

The existing archive establishes one Linux guest boot under m1n1 HV, not direct
Linux or full hardware support. Its SHA256 still matches the independently
reviewed archive recorded in `first-boot-development-2026-09-06.md`. Before a
new boot: finish relevant ownership/driver work, select one specific test
objective and exact image, recheck recovery/partition/capture evidence, then
pause for explicit user approval. No patch count or host test count grants
native acceptance.
