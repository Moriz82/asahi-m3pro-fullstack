# Retained display-DART capture preparation

## Result and limits

`scripts/retained-dart-snapshot.py` provides an offline analyzer and an
explicitly gated capture function for a future approved m1n1 proxy session.
No connection, boot, native read, device write or installed-image change was
performed for this work. No boot builder selects this tool automatically.

The missing display handoff evidence is the actual mapping membership of DCP
SID 5, display SID 0 and PIODMA SID 4 before Linux probes their DARTs. The
pinned Linux driver can replace mappings even on a locked DART. Cached macOS
physical addresses cannot fill this gap for a different boot. See
[the preceding handoff research](dcp-reserved-record-development-2026-09-06.md).

This capture prepares that experiment; it does not establish native/display
support, make a complete handoff contract, or authorize the experiment.

## Acquisition boundary

- Only an existing, exclusively owned proxy session is accepted. Importing the
  module and its CLI do not connect to a target. The CLI only analyzes JSON.
- The caller must separately approve the experiment, verify the running loader
  and assert `approved-exclusive-m1n1-before-linux`. This stage is an operator
  assertion, not remotely verified by the collector. Capture does not establish
  pristine iBoot state: m1n1 may already have changed hardware before this point.
- Protocol NOP negotiates checksums on. The usual controller NOP can disable
  checksums on USB; in the pinned target implementation this bypasses the
  guarded memory-read probe. Checksum negotiation and exception-counter
  read/reset are explicit proxy housekeeping. They are not DART/table writes.
- Fresh bootargs and ADT are read, with bounded lengths and a physical RAM
  envelope derived as in m1n1. Whole raw ADT, command line and identifiers are
  not exported. Raw parser error diagnostics are suppressed.
- Before any DART register read, require Mac15,6/J514sAP/T6030/board 4,
  `iBoot-10151.140.19.700.2` (the loader's V14.7 ABI classification), exact
  DART bases/sizes, mapper IDs and display mapper membership.
- Require nonoverlapping, aligned `pt-region-SID` start/end ranges, at most
  1 MiB per stream, within that boot's RAM envelope. Require matching
  `l2-tt-SID` metadata. Current support is deliberately limited to the observed
  legacy two-memory-table format, 16 KiB pages and 42-bit PA encoding.
  Four-level mode and unknown firmware/metadata formats fail before table reads.
- Read only fixed parameter/protection/enable/TCR/TTBR registers and the three
  declared page-table regions. Never dereference a leaf mapping's physical
  address. No DART constructor, map, invalidate, initialize, lock or shutdown;
  no `m1n1.setup`, `ProxyUtils`, heap setup, cache maintenance or target writes.
- Compare two complete table passes bracketed by register samples, then fresh
  bootargs/ADT again. Read faults, short reads or changes abort publication.
  Equality is not an atomicity, ABA, cache-coherency or quiescence guarantee.
  Even read-only hardware experiments can fault or disturb timing.
- Validate every traversed table pointer against its own declared region;
  reject cycles, unsupported layouts and traversal-budget exhaustion. Preserve
  raw table bytes and leaf flags. All aliases are retained, including physical
  extents split by flag changes. Correlation reports address coverage only,
  not permissions, ownership, DMA coherency or successful device access.
- Capture includes UTC time, collector/controller source hashes, ADT/bootargs
  hashes, raw registers and per-stream table hashes. Analyzer requires these
  fields. Structural validity and hashes are not source authentication or remote
  loader attestation. Preserve the independently verified loader/session record.
- `save_new` validates first and atomically links a completed private read-only
  JSON file without overwriting existing evidence. Raw table captures belong
  in local evidence, not the shared notes, public repositories or chat logs.

## Offline verification

`tests/retained-dart-snapshot-self-test.py` exercises the actual collector with
an allowlisted fake proxy and the pinned controller's real ADT/bootargs parser,
PTE definitions, translation walker and checksum reader. Serial construction,
setup/ProxyUtils imports, network connections and nontrivial `/dev` opens have
test tripwires. These Python tripwires are not an OS security sandbox.

Fifteen test methods pass on macOS and AArch64 Linux, including optimized
Python (`-O`, so production validation cannot depend on `assert`). Coverage:
all three bootargs layouts; exact read addresses/counts; approval before I/O;
wrong identity/firmware/topology; unsafe bounds; disabled or unsupported streams;
four-level refusal; read faults and changing tables/registers/ADT; escaped and
cyclic table links; budgets; alias/gap/flag-split correlation; checksum corruption;
missing provenance; false hardware claims; offline CLI; atomic no-clobber output.
These are parameterized software scenarios, not 15 hardware experiments.

From the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH=out/isolated/dcp-source-audit-20260906/reserved-record-loader-replay/proxyclient \
python3 -O -B tests/retained-dart-snapshot-self-test.py
```

Dependencies reuse construct 2.10.70 and pyserial 3.5. The existing AArch64
executor image is
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Linux runs without network, with a read-only root/source and temporary `/tmp`.
Its absent Python packages were supplied from the existing read-only
`dma-smoke-deps` export, not downloaded or installed. No kernel/M0 build needed.
Initial fixture/parser compatibility errors were corrected before final runs.
Independent review's missing-provenance finding is fixed and rechecked.

Exact commands, logs, source/dependency hashes and a clearly synthetic capture
are in `out/isolated/dcp-source-audit-20260906/retained-snapshot-proof/reviewed/`.
The preceding patch-22 closure and source tree remain unchanged.

## Future operator integration, not permission to boot

First refresh the independent boot/recovery, loader, target and observer gates.
Do not change startup disk, install an image or reboot to try this code without
new approval. Do not start a second proxy client while another owns the link.

At the approved pre-Linux pause, an existing exclusive controller with proxy
`p` can import the file with `runpy.run_path`, invoke
`capture(p, approved_stage="approved-exclusive-m1n1-before-linux")`, then invoke
`save_new(result, new_local_evidence_path)`. Import **this file**, not
`m1n1.setup`; the latter performs additional initialization and target writes.
Use the reviewed controller export and leave protocol debug logging disabled.
The checksum setting intentionally stays enabled after capture.

If any gate rejects the target/layout, stop that capture. Do not replace the
fresh values with cached macOS addresses, loosen checks or initialize a DART to
make it pass. Missing/unsupported metadata needs source analysis first.
No automatic Linux continuation or boot command is part of this tool.

Analyze a completed capture offline with the same pinned `PYTHONPATH`:

```sh
python3 -B scripts/retained-dart-snapshot.py /absolute/path/to/capture.json
```

The next development step is to use verified fresh mappings to distinguish
mandatory/optional regions and implement coherent, ordered loader handoff.
Actual framebuffer/panel behavior, USB/SSH, native boot, recovery and sustained
hardware operation remain separate unresolved gates.

## Exact-target iBoot research

The existing Apple OTA acquisition path retrieved only J514s 23J220 iBoot and
iBootData. BuildManifest target/identity agreement, ZIP CRC and manifest SHA-384
checks passed. The extracted payloads are not usable plaintext for IDA; no
mapping table was inferred from them. No decryption, signature verification or
firmware execution is claimed. Existing kernelcache/DCP IDA sessions remain
available for static analysis.

Evidence: `out/isolated/dcp-source-audit-20260906/target-iboot/acquisition.json`.
IM4P SHA-256: iBoot
`59b8a6112d3cb4c5cdbba79553d292d8c2874acb3f56b2e89375888458af5b18`;
iBootData `eb4ea4fec6833ccc2178f9dde20d5afc1431fc8882f70ba29fb1e6a8d71f7dc3`.
