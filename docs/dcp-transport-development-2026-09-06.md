# DCP transport bounds and nested-call ownership

Development-only Linux patch 13, after patches 01–12 on
`77cb8f24c2381a8abb7272d7bbdec548d6426a8a`. No boot builder selects this series.
No installed files, target commands, live registers/page tables, DART setup,
storage, firmware, boot policy or boot changed. Hardware acceptance is false.

## Changed mechanics

`iomfb.c`, `iomfb.h` and `dcp-internal.h` in the isolated patch:

- Validate callback context, 64-byte-aligned offset, 32 KiB channel extent,
  complete header, input/output extents and nonoverlapping RX stack extent
  before output clearing, handler dispatch or stack mutation. Header lengths
  are copied locally once. Invalid uint32 lengths cannot wrap the checks.
- Reject stack overflow, underflow, absent shared memory and ACK/frame-kind
  mismatches before changing channel state. Depth eight is valid and full:
  it can be popped but not pushed. Invalid states above eight are rejected.
- Mark RX callback versus TX command frames explicitly. Nested callback-
  context commands share CMD's TX window; their start follows occupied TX
  extents in both channels, not an unrelated callback RX extent. Normal and
  out-of-band windows remain separate.
- Incoming ACKs use the saved top-command output pointer and cookie, clearing
  those slots before invoking completion. Zero-length/zero-offset ACKs remain
  valid; returned headers and ACK envelope addresses do not select a response
  pointer. Deferred completions and reentrant commands retain their state.

Protocol basis is the pinned m1n1 implementation, not guessed window spacing:
`proxyclient/m1n1/fw/dcp/dcpep.py` defines all six 0x8000-byte windows and completes
ACKs without reading an ACK payload address. Existing Linux context-to-window
mapping is retained; unsolicited callbacks on CMD/OOBCMD are rejected.
Neither client is native proof of every firmware behavior.

## Verification

- 3,743 cases execute the actual C transport, packet declarations and channel
  structure under ASan/UBSan on macOS and network-disabled AArch64 Linux.
  Kernel logging/mailbox transmission and callback bodies are explicit fakes.
  Most cases exercise boundary values and invalid uint8 depths; the count is
  not equivalent to independent hardware scenarios or complete coverage.
- Every rejected-envelope/push case compares the full fake shared-memory
  buffer and channel state with its pre-call snapshot, and checks no message
  or handler was emitted. Valid cases cover all four callback contexts,
  both TX windows, exact window-end payloads, all eight stack levels,
  nested/interleaved RX/TX frames, zero-envelope ACKs, output-header corruption,
  deferred completions with and without an original command, and reentrancy.
- Five independently executed baseline controls reproduce the original empty-
  ACK underflow, full-stack callback overflow, short declared payload write,
  nested TX overwrite and returned-header-derived output-pointer defects.
  Controls require a failing assertion or sanitizer diagnostic, not merely
  nonzero exit. These are original-code failures, not invented mutations.
- Existing clock tests pass 275 cases on both hosts. The real-libfdt loader
  integration still passes 46 cases and feeds resulting rates into those
  clock tests on macOS. Existing bandwidth, register-map and null-flag tests
  pass. The clock test fixture was extended only for the dispatcher’s new
  channel fields/helper; the separate transport fixture uses actual structs.
- All 13 patches apply from the pinned partial export and match the edited
  and incremental-replay exports byte-for-byte, including symlink targets.
  Private Git administrative files are excluded from the comparison.
- The complete Apple DRM module compiles and links with W=1 and no diagnostics
  against the retained AArch64 framebuffer kernel. The source volume and its
  kernel output were read-only; its authoritative lock was held exclusively.
  Module output used tmpfs. No full kernel/M0 build or canonical promotion ran.
- Bounded read-only production-source review found no material issue.

An initial fixture incorrectly treated depth eight as invalid for ACKs; its
expectation was corrected before accepted results. An added test block was
initially placed in a baseline-only branch and moved into the normal run;
the final case count and logs include it. An initial replay command used the
wrong working directory and failed before applying anything; the accepted
replays use explicit paths. These are not production negative controls.

Reproduce from the repository root:

```bash
AUDIT="$PWD/out/isolated/dcp-source-audit-20260906"
DRIVER="$AUDIT/transport-linux-replay/drivers/gpu/drm/apple"
python3 -B tests/dcp-transport-self-test.py "$DRIVER"
python3 -B tests/dcp-transport-self-test.py \
  "$AUDIT/clock-linux-replay/drivers/gpu/drm/apple" --baseline
python3 -B tests/dcp-clock-self-test.py "$DRIVER"
```

Evidence: `transport-closure.json`, `transport-final.log`,
`transport-baseline.log`, `transport-series-test.log`,
`transport-clock-integration.log`, `transport-regression-*.log`, and
`compile-transport/` beneath AUDIT. Module SHA-256:
`e495ed5fe0cd69605e4665346248f4b597284816a08168f9d297d81b3e12a1b0`.
Pinned container:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.

Prior clock-handoff evidence remains unchanged. Its earlier README, series,
clock test and clock C fixture are retained as `transport-*-before.*` snapshots;
the new closure records explicit historical source bindings. Do not compare
an older closure’s hash against a newer working revision of the same path.

## Remaining boundary

This does **not** validate every callback's typed ABI sizes. A structurally
valid packet can still be smaller than a handler expects. D408’s existing
specific size check remains, but the general TODO is not retired. Rejected
messages are dropped with diagnostics: no resynchronization, timeout ownership,
pending-call error callback or reset policy is implemented. `dcp_push` remains
void, so callers cannot yet receive a synchronous rejection error. Duplicate
or out-of-order ACKs across independent channels, hostile concurrent DMA,
CPU/RTKit synchronization and coherency are not proven by these single-thread
fixtures. Unknown firmware behavior remains a compatibility risk.

The parallel source-location investigation found that current loader runtime
addresses already come from fresh `/chosen/carveout-memory-map` and `/vram/reg`.
The missing target input is the verified T6030 region-name set and each
region’s DCP/display-SID0/PIO-DMA-SID4 membership, not hardcoded addresses.
`clock-loader-replay/src/kboot.c` has no T6030 region table or display branch.
Live `dart_search`/`dart_translate` currently derive retained IOVAs and check
mapping continuity; their initialization is a hardware boundary, not an
offline operation. Missing mappings can currently be omitted nonfatally.
Required-region fail-closed policy, ordered provider/node activation, panel/
eDP sequencing, PMGR/reset behavior and DMA lifetime still need development.
Cached macOS metadata is not a later boot's address or mapping evidence.
