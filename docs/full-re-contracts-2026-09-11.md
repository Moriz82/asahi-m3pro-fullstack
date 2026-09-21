# Full-RE request: reviewed contract supplement

The earlier 102-function packet was a checkpoint, not all required reverse
engineering. This supplement closes specific implementation contracts and
records what still blocks a complete daily-driver driver stack. Newer native
Linux source remains authoritative. No boot, native write, kernel build/install,
fan/key/register operation or firmware execution occurred.

## Deliverable on macOS

`out/isolated/full-re-20260911/re-contracts-20260911-v2.tar.gz`

122,672,927 bytes; SHA-256
`df9c9bd7fe44df128f0863815544099a272a5a003d1d76c78c4505cecc5da8be`.
242 checksummed files, 12 pinned export groups, 30,602 instruction records
(overlapping/group-repeat records counted). Four isolated Binary Ninja databases,
PMP/DCP inputs, IDA/Binary Ninja exports, reviewed contracts and executable
host-only fixtures. Kernel input is reused from the earlier packet, not duplicated.
Start with the packet README. This archive has not been transferred or installed.

## Concrete findings

- GPU: prefix allocation owners, CPU/GPU output relationships, rounding, failure
  residuals, teardown and stale-VA hazard are traced. Ring record and publication
  order are specified. The encoder's shared lock does not prove single-producer
  serialization. Firmware-alive is set before InitData submission.
- DCP: A472 is traced through the exact constructed receiver to its concrete
  power action. That action returns zero even when logging hardware failures.
  Brightness scale, timestamp and userspace-notification callbacks are distinct
  from physical backlight control.
- Cooling: exact PMP payload recovered from the saved Apple OTA and manifest
  verified. Metadata/copy gates are specified, but validity is not freshness.
  Compiled ApplePMPThermal remains conditional: target endpoint publication,
  fan ownership and a safe supported host sample/control API are unproved.

## Validation and review

Exact commands (run from project root):

```sh
python3 -B out/isolated/full-re-20260911/test-contracts.py
python3 -B out/isolated/full-re-20260911/test-evidence.py \
  out/isolated/dcp-source-audit-20260906/target-kernelcache/kernelcache.macho
python3 -B out/isolated/gpu-re-handoff-20260910/test-verify-export.py \
  out/isolated/dcp-source-audit-20260906/target-kernelcache/kernelcache.macho
```

12 model tests + 5 evidence tests + 15 earlier verifier regression tests pass.
The models include all 65,536 ring-index pairs and 17,408 PMP metadata/tag cases,
DCP status/A472 vectors and checked allocation alignment/overflow behavior.
All 16 new/affected Python files parse successfully. Four IDA call-analysis
failures remain explicit; complete Binary Ninja fallback exports cover all four.
Scoped Daybreak reviews checked GPU, DCP and cooling claims; identified wording
and signedness/indirection errors were corrected before packaging.

The first candidate's fresh-extraction test exposed a fixture-permission bug:
negative tests copied immutable files with their read-only modes. V2 copies
only disposable fixtures with writable new files, preserving evidence modes.
Use V2; the unversioned first candidate is rejected for portable test execution.
V2 fresh extraction at `/tmp/m3-re-v2-check.zZ3VcA` passes all 242 hashes,
all 12 host-model tests and all five evidence tests with read-only evidence.

The private staging text/source scan found zero Gitleaks findings; three large
BNDBs were skipped by its 20-MB file limit. This is a scoped scan, not a claim
that a scanner proved all binary content free of sensitive data. No auth stores,
license patch kits or raw conversations were selected for this packet.

## Changed files and boundaries

- Added `out/isolated/full-re-20260911/`: five subsystem contracts/README,
  models/tests, acquisition/export/symbol-resolution scripts and private artifacts.
- Extended `out/isolated/gpu-re-handoff-20260910/export-binja.py` to accept an
  explicit pinned firmware input; kernel default and immutable earlier archive
  remain unchanged.
- Extended its `verify-export.py` with independent new group/input pins, IDA
  format support and explicit known-analysis-failure accounting. Older checks pass.
- Added this tracked-location report. Existing unrelated dirty files preserved;
  no staging/commit or changes to the native Linux checkout.

Still open: remaining GPU InitData/firmware consumer and command/completion
layouts, recovery/coherency; calibrated fresh cooling samples and actual fan
server/ownership; complete DCP startup/sleep/VRR/hotplug coverage and target
runtime effects. Static tests cannot prove rendering, cooling, panel behavior
or a one-boot debugging outcome.

Next safe step: additive transfer, checksum/offline test verification on Linux,
then narrow implementation against these contracts in the newer native tree.
Keep runtime acceptance separate and preserve the current cooling policy/caps.
Do not call this full-RE completion or automatically resume hardware experiments.
