# T6030 DCP clock callback

Offline, development-only checkpoint. No boot builder selects this patch;
no installed client, image, module, DTB, storage or boot policy changed. No
target command, register/page-table access or new hardware observation ran.

## Implemented contract

`patches/m1n1-dcp-development/09-t6030-clock-metadata.patch` changes only
`DCPManager.sr_getClockFrequency` in the pinned m1n1 Python client. Apply after
01/04/05/06/07 to a disposable export of
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. Patch 05 provides exception-safe
callback-depth handling used by the regression tests. The C patches are
independent and are not required for this Python test.

For J514s/Mac15,6/T6030 on V14.7, D408 now honors its provider and clock-index
arguments instead of returning the legacy 533,333,328-Hz constant. It reads
the caller's ADT on each request, verifies the target nodes and clock IDs,
validates equal-length uint32 frequency/type arrays, and selects IDs 348/412
relative to the verified base 256. Type values must be 0 through 3. Unknown
providers, indices, firmware profiles, target identities and malformed
metadata reject before hardware dependencies.

An in-table zero remains zero. A declared clock outside the published table
also returns zero, matching the Apple lookup. The runtime table length is
not hard-coded to the observed 176 entries. Legacy chips keep their existing
callback behavior. The callback does not program clocks or initialize DCP.

The binary-backed lookup evidence is in
[the clock-provider report](dcp-config-clock-development-2026-09-06.md).
Recorded macOS build 25G227 metadata is used only as a test fixture; its
712,000,000/0-Hz pair is not embedded in the implementation. The exact 23J220
ADT template lacks the runtime type array and is correctly rejected. A test
overlays the recorded clock properties onto a parsed template to exercise the
real parser; this is explicitly not a genuine mixed-version boot. The caller
must supply the current boot's ADT. These tests do not prove that provenance.

## Verification

- Nine V14.7 tests pass against the real manager, D408 dispatcher and wire
  codec: 8-byte request/reply, both indices, changing values, valid zeros,
  table boundaries, 36 malformed metadata variants, invalid requests,
  callback-depth recovery, legacy replies and both optional Apple fixtures.
- The preceding constant-return implementation fails 60 assertions/subcases
  in the same suite. This is the expected negative control, not a successful
  baseline. The patched suite passes with optimized Python as well.
- V12.3 and V13.5 each pass three applicable tests and skip six target tests.
  Actual A407, D003, D411 and DMA prerequisite regressions pass another 32
  tests, giving 41 focused target/regression tests on macOS.
- The nine clock tests also pass in the existing AArch64 Linux container,
  network disabled, root/client/tests/dependencies read-only. No packages,
  controller files, kernel/M0 build or canonical source volume were involved.
- Clean source replay is byte-identical to the tested export. The first patch
  packaging check caught a trailing-context hunk count error; it was corrected
  before the successful replay. Bounded read-only review has no material finding.

From the repository root:

```bash
AUDIT="$PWD/out/isolated/dcp-source-audit-20260906"
CLIENT="$AUDIT/m1n1-clock-replay/proxyclient"
python3 -O -B tests/m1n1-dcp-clock-self-test.py "$CLIENT" \
  "$AUDIT/inputs/DeviceTree.j514sap.decoded" \
  "$AUDIT/config-clock-host-metadata.json"
python3 -O -B tests/m1n1-dcp-abi-self-test.py "$CLIENT"
for test in m1n1-dcp-bandwidth-self-test m1n1-dcp-register-self-test \
            m1n1-dma-prerequisites-self-test; do
  python3 -O -B "tests/$test.py" "$CLIENT" \
    "$AUDIT/inputs/DeviceTree.j514sap.decoded"
done
```

Evidence under that root: `clock-closure.json`, `clock-*.log`,
`m1n1-clock-source/` and `m1n1-clock-replay/`. The closure binds exact patch,
test, source, input and log hashes. Container image:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.

## Remaining work

Linux still has the single-clock, argument-ignoring D408 callback. It needs
an index-aware binding and fresh loader-published rates with correct resource
lifetime and zero-rate semantics. That path is not implemented by this patch.
Runtime reservations/IOVA handoff, reset/transport behavior, panel/eDP
sequencing, DMA coherency/quiescence and physical display acceptance remain
open. The development display nodes remain disabled; no native milestone is
promoted by these tests.
