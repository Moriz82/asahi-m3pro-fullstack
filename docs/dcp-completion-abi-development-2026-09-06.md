# T6030 swap-completion callback contract

## Result

Linux development patch 16 and Python development patch 26 correct D589
swap-completion decoding for the exact J514s/T6030 23J220 firmware. The Python
callback previously had the correct total length but incorrect internal fields;
the Linux declaration also had the wrong length. The real Python manager now
handles parsed completion blobs without crashing. Older schemas remain intact.
No selected boot builder, display enablement, installed image or hardware changes.

IDA's firmware sender `0x13ead8` provides the following independent wire evidence:

| Field | Offset | Bytes |
| --- | ---: | ---: |
| Swap ID | 0 | 4 |
| First boolean | 4 | 1 |
| Optional inline completion data | 5 | 34 |
| Eight opaque 216-byte records | 39 | 1728 |
| Record count | 1767 | 4 |
| Second boolean | 1771 | 1 |
| Completion-data null flag | 1772 | 1 |
| Final padding | 1773 | 3 |

The sender copies two vectors and one halfword for the 34-byte value, advances
each opaque record by 216 bytes, stores the count at `0x6e7`, the second boolean
at `0x6eb`, and the null flag at `0x6ec`. It requests 1776 input bytes and zero
output. Record and boolean meanings beyond those accesses remain unknown.

The decoded firmware SHA-256 is
`fc54724dcdfcaa8c285c5171258dccd85d5c0713bdc111935d8c667d52107883`.
Saved sender/decompilation/disassembly evidence lives in
`completion-proof/ida-evidence.json`. This is static binary evidence, not an
observed live swap.

## Corrected behavior and boundaries

- Linux's existing versioned declaration now represents all fields and padding.
  Previous 12.3/13.3 structures remain unchanged. The real completion handler
  still updates the swap ID, triggers the existing page-flip path and retains
  its existing optional placeholder CRC behavior; this patch does not implement
  real CRC collection.
- V14.7 Linux rejects D589 unless its declared input/output sizes are 1776/0 and
  its outer message length is exactly 1788, before callback state, clearing,
  handler or ACK work. A review caught the initial omission of the last check.
- The outer-length rule is independently supported by the firmware packet
  builder `0x115b5c`: it sends input + output + 12 as the message length and
  tracks aligned allocation separately. Wrapper `0x1179f8` and dispatch
  `0x115784` connect that builder to D589. Evidence:
  `completion-proof/ida-transport-length.json`.
- Python applies the new schema only to exact `V14_7`. The formerly missing
  boolean is an optional final manager argument, preserving older callback
  signatures. Parsed `SwapInfoBlob` values are serialized for diagnostic
  hexdumps instead of incorrectly indexing a Construct container as bytes;
  direct byte input remains accepted.
- The Python manager checks declared/actual input length and zero output length
  for that target callback before changing manager state. This is not a complete
  Python callback-channel envelope/lifetime audit: the channel has already read
  and queued the message before invoking the manager. Error/reset policy there
  remains separate debt.

Production source changes are limited to `iomfb_template.h`, `iomfb.c`,
`ipc.py` and `manager.py` in disposable development exports. No firmware image
was patched, sent to hardware or executed.

## Verification

- Existing startup C fixture now also executes the actual completion handler
  and trampoline with recording DRM/time fakes. 33 cases each for 12.3/13.3 and
  69 for 14.7 pass: 135 total, including 36 new completion cases. Fields, both
  null states, swap-ID extrema, CRC on/off and input preservation are checked.
- Actual Linux transport fixture passes 3807 cases, including 64 new size,
  envelope, preservation and dispatch cases across four callback contexts.
  Malformed input/output sizes and short/trailing frames leave memory, channels,
  handler count and ACK count unchanged. Older 12.3/13.3 acceptance is retained.
- Both C fixtures pass ASan/UBSan on macOS/AArch64 Linux with
  `-Wall -Wextra -Werror -Wno-unused-parameter`; the exclusion is for extracted
  kernel callback signatures with intentionally unused parameters.
- Seven Python test methods pass with optimized Python for V12_3, V13_5, V14_7
  and a test-only hypothetical V14_8 on both hosts. Real callback decoding,
  null handling, complete manager invocation and exception nesting are covered.
  Strict malformed-state tests apply only to V14.7. V14_8 is preservation proof,
  not future-firmware support.
- The predecessor independently reproduces the Linux declaration mismatch,
  short and trailing frame acceptance, Python wrong fields/null decoding and
  the real manager's Construct-container `KeyError`.
- Startup Python, clock, bandwidth, register mapping, null flags and adjacent
  Python DCP suites pass. Recorded ADT and clock metadata are supplied to the
  applicable tests.
- Sixteen Linux and eight Python patches replay from their exact pins with
  strict whitespace checks. Final source/replay manifests match. Initial Python
  patch packaging dropped a final context-only line; its failed apply log is
  retained. The corrected final replay starts fresh from the pins.
- Full Apple DRM module links with `ARCH=arm64 W=1 KCFLAGS=-Werror`, no
  diagnostics. Module SHA-256:
  `e30a723f32b829f7231aa793257181a424003fa400aa3fdeb3ac44d1f1b767f3`.
  Bounded build held the authoritative volume lock; kernel source/output stayed
  read-only. No full Linux/M0 rebuild or canonical reproducibility promotion.
- Bounded read-only review was fixed and rechecked: no material finding.

From the repository root:

```sh
python3 -B tests/dcp-startup-abi-self-test.py \
  out/isolated/dcp-source-audit-20260906/completion-linux-final-replay/drivers/gpu/drm/apple
python3 -B tests/dcp-transport-self-test.py \
  out/isolated/dcp-source-audit-20260906/completion-linux-final-replay/drivers/gpu/drm/apple
PYTHONPATH=out/isolated/dcp-source-audit-20260906/dma-smoke-deps \
python3 -O -B tests/m1n1-dcp-completion-self-test.py \
  out/isolated/dcp-source-audit-20260906/completion-client-final-replay/proxyclient V14_7
```

Evidence: `out/isolated/dcp-source-audit-20260906/completion-proof/`;
hashes, exact commands, preserved predecessor bindings and final trees:
`completion-closure.json`. Final replay directories include `-final-replay`;
the earlier `completion-*-replay` directories are intermediate work, not proof
of the final independent replay. Previous sealed closures remain unchanged.

## Next safe work

A bounded survey of 121 firmware callback-sending functions is saved as
`completion-proof/callback-senders.json`. It exposes additional work:
D006 sends 60/56 bytes of frame-sync metadata while Linux currently returns
zeros; D576 sends 88/76 bytes and copies a 75-byte in/out value back, while the
Linux handler handles only the initial connection field. Those semantics need
host/firmware analysis before choosing what metadata to preserve or modify.
They are not fixed by this checkpoint, and their behavior is not inferred from
packet sizes alone.

Fresh retained region/SID membership, ordered display activation, real pixels,
DMA/cache behavior, USB/SSH, recovery and sustained native acceptance remain
unproven. The wider typed-callback and error/status audits are incomplete.
Continue offline investigation; refresh boot/observer/recovery gates and obtain
new approval before any native experiment. No target reads or boot occurred.
