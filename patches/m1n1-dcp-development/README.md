# Development-only DCP client and handoff corrections

None of these patches is selected by a canonical or development boot builder. Apply
only to a disposable source export. No native display acceptance is implied.

## 01: Python A407 schema

`01-a407-layout.patch` targets m1n1
`60e53e7078c5cb7efce32d64bf50829e9401e44f`, Python proxyclient only.
Apply to a disposable export, not the canonical source or sealed client bundle.
No bootloader binary, pin, installed image, receiver or boot candidate changes.

The V14.7 A407 schema now describes six secondary surfaces, relies on existing
automatic pointer-null fields and includes both output pointers. The request
stays 7000 bytes; its aligned response is 12 bytes with status at offset 5.
The old source incorrectly read status at offset 1 in an eight-byte reply.

Run from the project root against the patched export:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m1n1-dcp-abi-self-test.py /absolute/export/proxyclient
```

The test uses an in-process fake transport. It never sends a DCP command.
Old V12.3/V13.5 schemas remain unchanged. V14.7 callers using the previous
experimental keyword layout must migrate to the corrected pointer arguments;
do not deploy this as an unnoticed replacement for an existing controller.

Evidence and limitations: `docs/dcp-abi-development-2026-09-06.md`.

## 02: C DART handoff

`02-dart-handoff.patch` fixes three lines in `src/dart.c`: the T8110 TLB
completion poll uses the command register, and both retained-mapping search
loops include all 2048 entries in a 16 KiB table. This source file is identical
at `60e53e7078c5cb7efce32d64bf50829e9401e44f` and local post-patch candidate
`940439b9a407fbfc499bea933269219f3f62d4c7`. The latter was initially tested
as a separate local candidate; its upstream provenance is now verified in the
patch-23/24 integration report below. This patch affects generic DART code,
not just DCP.

The actual C source passes 584 offline cases under UBSan and ASan/UBSan;
baseline polls and both final-table-entry controls fail as expected. The
production freestanding object also compiles. This is not a linked bootloader,
native timing, live IOVA observation or boot approval. The `dart_init`
allocation-error cleanup defect is addressed separately in patch 03 below.

Commands, source hashes and evidence: `docs/dcp-handoff-development-2026-09-06.md`.

## 03: DART initialization ownership

Apply `03-dart-init-ownership.patch` after patch 02. It allocates and zeroes
all missing root tables before enabling streams or publishing TTBRs. On
allocation failure it frees only newly allocated roots and the DART object,
not retained tables or the object's inline pointer array. No register writes
occur on those failures. Successful register-write order remains unchanged;
retained TTBR reads now happen before stream enablement.

`tests/m1n1-dart-init-self-test.c` includes the actual patched source with
owned allocation slots and recorded MMIO. All 3,582 cases pass with ASan/UBSan
and `-Wall -Wextra -Werror`; the preceding 584 DART cases also pass. Three
independent baseline controls reproduce the interior free, allocation leak,
and partial register write. Replay and freestanding object compilation pass.

This does not make `keep_pts` read-only, change shutdown or TLB timeout policy,
or prove locked-register writes are accepted by hardware. Exact commands,
digests and limitations are in the same handoff development report.

## 04: T6030 bandwidth metadata and D003 layout

`04-t6030-bandwidth.patch` targets the same pinned Python client. It may be
applied independently of the C patches and alongside patch 01. Exact 23J220
host-driver and ADT evidence resolves display scratch slot 5, offset 0x988,
length 8. The new T6030 branch derives its address from caller-supplied ADT
metadata with fail-closed target/table/resource checks; it performs no hardware
access. D003's V14.7 layout is 56-byte configuration plus four-byte status.
Other firmware profiles retain the original layout; no future support inferred.

`tests/m1n1-dcp-bandwidth-self-test.py CLIENT [DECODED_ADT]` tests the actual
callback and wire encoding, exact optional Apple input, 47 malformed contracts,
legacy replies and a test-only future-version rejection. Replay, legacy RPC
layout comparison and the existing A407 regression pass. No builder, installed
client, boot image or target hardware was changed. Evidence, commands and
remaining D411/DART/DT gaps: `docs/dcp-bandwidth-development-2026-09-06.md`.

## 05: T6030 direct-register D411 callback

Apply `05-t6030-direct-registers.patch` alongside patches 01/04 in a disposable
client export. Exact host/firmware evidence shows the bandwidth path requests
direct physical registers, not DMA. This patch accepts the three-output
callback for J514s/T6030/V14.7/PROV/0x100, validates metadata and returns PA in
both address fields. It rejects DMA/unverified modes without hardware access.
It also restores callback depth in `finally` after parser/handler exceptions.

`tests/m1n1-dcp-register-self-test.py CLIENT [DECODED_ADT]` passes seven tests,
including actual wire callbacks, exact Apple resources, malformed inputs and
dispatcher recovery. Legacy checks, optimized Python and clean replay pass.
This is not a complete DMA mapper or ready-to-run DCP controller. Evidence and
the corresponding Linux correction: `docs/dcp-register-development-2026-09-06.md`.

## 06/07: DCP stream and Python T8110 prerequisites

`06-dcp-stream-selection.patch` preserves the DCP constructor's defaults while
allowing an explicit stream and invalidating that same stream after mapping.
`07-t8110-mapping-validation.patch` repairs retained four-level table traversal,
rejects invalid mapping arguments before stream enable, avoids recording a
failed enable as success, and preserves physical address zero in translations.
Both target the pinned Python client; neither modifies the C DART patches.

Apply to a disposable export alongside 01/04/05. Run
`tests/m1n1-dma-prerequisites-self-test.py CLIENT [DECODED_ADT]`. Twelve actual-code
tests, optimized Python, legacy profiles and clean replay pass. These patches
are prerequisites, not a complete DCP DMA implementation: raw manager mappings,
wide IOVA encoding, allocation/flush recovery, cache attributes and safe teardown
remain open. No builder or installed client consumes them. Evidence and commands:
`docs/dcp-dma-prerequisites-2026-09-06.md`.

## 08: J514s configuration and reset routing

`08-j514s-display-config.patch` adds the exact-target internal display config
and makes `dcp_init` honor its PMGR name/die for internal as well as external
paths. Invalid names/null inputs fail before hardware dependencies; the
external V13.5 gate remains. Two duplicate J473 initializers are removed
without changing their shared values. It applies independently of 01–07 to
the same base. No builder consumes it.

`tests/m1n1-dcp-config-self-test.py SOURCE CLIENT DECODED_ADT` runs the actual
C selector and complete init/shutdown functions with fake dependencies.
130 sanitizer cases, four original-fault controls, optimized Python, Linux
execution, clean replay and both production freestanding objects pass.
Hardware reset, loader reservations, DCP transport and DMA lifetime remain
unproved. Clock-provider research now establishes runtime-table lookup, not
a fixed clock value. Report: `docs/dcp-config-clock-development-2026-09-06.md`.

## 09: T6030 metadata-driven clock callback

Apply `09-t6030-clock-metadata.patch` after the Python patches 01/04/05/06/07
to the same pinned disposable export. J514s/T6030/V14.7 D408 now validates
provider/index and ADT clock tables, selects the requested clock, and preserves
valid zero/out-of-table replies. Legacy behavior is unchanged. No saved-host
frequency constants, hardware programming or builder integration are added.

`tests/m1n1-dcp-clock-self-test.py CLIENT [DECODED_ADT [CLOCK_METADATA_JSON]]`
passes nine target tests on macOS and Linux; the old constant fails 60 checks.
Optimized/legacy profiles, 32 neighboring tests, byte-identical replay and
bounded review pass. Fresh-boot provenance, Linux/loader clock binding, runtime
reservations and physical display/DMA acceptance remain open. Report:
`docs/dcp-clock-metadata-development-2026-09-06.md`.

## 10: J514s loader clock publication

`10-j514s-clock-handoff.patch` adds a metadata-only `kboot.c` helper paired
with Linux development patch 12. It validates the current boot's display
provider, raw ADT tables and both FDT clock references/placeholders before
in-place rate publication. Missing/invalid input changes no FDT bytes; valid
zeros remain valid. Older trees without DCP are unchanged. Clock providers
and hardware stay disabled, and no runtime mapping or native support is implied.

46 real-libfdt sanitizer cases and the 275-case Linux callback suite pass on
macOS and Linux, including actual FDT-readback-to-callback data flow. Replay,
the production kboot object and full DRM module pass. No builder consumes
these patches. Report: `docs/dcp-clock-handoff-development-2026-09-06.md`.

## 11: Retained mapping continuity and IOVA bounds

`11-retained-mapping-continuity.patch` rejects empty/wrapping/invalid physical
extents, checks every retained mapping page instead of only its endpoints,
and prevents unsupported high IOVA bits from aliasing a low C DART root.
Apply after C patches 02/03/08/10 in a disposable, independently initialized
Git export. No builder selects it; no T6030 region table or hardware activation.

4,059 actual-C ASan/UBSan cases, five original-fault controls, 4,166 existing
DART cases, nearby clock integration, full C-series replay and both production
object builds pass. The fixture owns its synthetic page tables; it does not
access live mappings. Four-level T8110, permissions, missing-map failure policy,
target region/stream membership and native acceptance remain open. Report:
`docs/dcp-mapping-development-2026-09-06.md`.

## 12: Retained T8110 levels and coherent table operations

`12-t8110-retained-levels.patch` follows the C sequence 02/03/08/10/11. It
preserves the existing T8110 translation level, validates four-level geometry,
and uses shared hierarchy helpers for reads, mapping, unmap and table cleanup.
It corrects the T8110 PA mask and wrong-root legacy unmap/release. Fresh
contexts retain their previous mode. Unsupported four-level legacy
preallocation has a distinct fatal result; older fallback behavior remains.

457 new actual-C sanitizer cases, three original failures, 8,225 DART/mapping
regressions, 138 DCP lifecycle cases, 321 clock cases, full C-series replay and
three production objects pass. Fixtures own the registers/tables; no hardware
ran. Live ownership/alias/timeout behavior, higher-level 36-bit RTKit DVA
masks and target region/panel integration remain open. No builder selects
this patch. Report: `docs/dcp-retained-levels-development-2026-09-06.md`.

## 13: RTKit wide addresses and explicit buffer ownership

`13-rtkit-buffer-addresses.patch` follows the C sequence 02/03/08/10/11/12.
It removes unconditional 36-bit DART truncation, checks reversible ASC tags,
validates borrowed spans page-by-page and rejects 42-bit reply overflow.
Rounded allocation, explicit ownership, atomic descriptor publication and
idempotent cleanup fix the adjacent buffer-lifetime defects. SART cleanup
failure retains memory; borrowed buffers are never freed as heap allocations.

299 actual-C sanitizer cases, four original failures, 4,516 DART/mapping
regressions, seven-patch replay and RTKit/AFK/DCP production objects pass.
IOVA allocator bounds, AFK wire/recovery details, parsers and live DMA remain
open. No builder selects it and no hardware ran. Report:
`docs/dcp-rtkit-buffers-development-2026-09-06.md`.

## 14: IOVA domain bounds and allocator integration

`14-iova-domain-bounds.patch` follows C patches 02/03/08/10/11/12/13. It
corrects high-base domain capacity, page-zero exclusion, reservation rounding/
exact removal, free-list insertion/coalescing and shutdown wrap. The display
caller now rejects IOVA exhaustion before physical allocation or DART search.

12,284 actual-C/model/RTKit/display checks, seven original failures, 4,815
regressions and full eight-patch replay pass. Complete m1n1 ELF/Mach-O/raw
images link offline with locked dependencies; one existing Rust unused-import
warning remains. No builder or installed artifact changes. AFK protocol,
live DMA/region ownership and panel/native acceptance remain open. Report:
`docs/dcp-iova-development-2026-09-06.md`.

## 15: AFK ring and buffer negotiation bounds

`15-afk-ring-bounds.patch` follows C patches 02/03/08/10/11/12/13/14. It
checks 48-bit buffer replies and negotiated ring windows, derives bounded
header geometry, validates shared positions and complete committed frames,
saves ACK cursors and faults TX after post-publication mailbox failure.
130,257 actual-C sanitizer checks, nine original-fault controls, 17,099
regressions, nine-patch replay and complete offline m1n1 links pass. The
existing Rust unused-import warning remains. No new dependency or builder
selection. EPIC parsers, notification payload ownership and quiescence-aware
endpoint/DCP teardown remain open; this is not live firmware or hardware
acceptance. See `docs/dcp-afk-rings-development-2026-09-06.md`.

## 16: EPIC message ownership and parsing

`16-epic-message-ownership.patch` follows C patches 02/03/08/10/11/12/13/14/15.
It copies validated frames before ACK, checks message/property bounds, matches
command replies, prevents uncertain/nested buffer reuse and protects pending
RX streams from background consumers. Discovery and command deadlines include
bounded work batches; partial discovery cannot report success. 4,313 new
sanitizer checks, thirteen predecessor controls, 147,356 regressions, ten-patch
replay and complete offline links pass. Final review passes; one existing Rust
warning remains. No new dependency, builder selection or installed artifact.
Endpoint/DCP/display teardown still needs quiescence-safe failure propagation.
See `docs/dcp-epic-development-2026-09-06.md`.

## 17: RTKit power acknowledgements and bounded receive work

`17-rtkit-power-acknowledgements.patch` follows C patches
02/03/08/10/11/12/13/14/15/16. It fixes the sleep boolean/result bug, bounds
receive batches and ACK waits, requires newly observed power-state progress,
drains stale queued ACKs around transitions and latches uncertain completion.
420 actual-C sanitizer checks, nine predecessor controls, the reviewed
message-16/17 regression, 151,669 neighboring checks, eleven-patch replay and
complete offline links pass. The existing Rust warning remains. This is not
quiescence-safe teardown: AFK/DCP/display, NVMe and SMC callers still need
failure-aware ownership/handoff handling. No hardware, builder selection or
installed artifact changes. See `docs/dcp-rtkit-power-development-2026-09-06.md`.

## 18: Failure-aware DCP lifecycle and handoff

`18-dcp-lifecycle-ownership.patch` follows C patches
02/03/08/10/11/12/13/14/15/16/17. It bounds AFK startup/shutdown, retains failed
owners, protects live frames from callback teardown, and propagates cleanup
failure through endpoint clients, DCP, display and boot/HV handoff. RTKit free
now reports failed buffer cleanup without losing its owner. Uncertain states
remain quarantined, not force-freed or reset automatically.

191 new sanitizer checks, 23 predecessor controls, 152,227 neighboring checks,
twelve-patch replay and complete offline links pass. Cross-endpoint callback
coverage and focused re-review pass. One existing Rust warning remains. No
builder selects it or installed artifact changes. NVMe/SMC cleanup, DART
invalidation/release failure, live DMA/panel behavior and native acceptance
remain open. See `docs/dcp-lifecycle-development-2026-09-06.md`.

## 19: NVMe/SMC ownership and caller DMA lifetime

`19-storage-lifecycle-owned-dma.patch` follows loader patches
02/03/08/10/11/12/13/14/15/16/17/18. It retains failed NVMe/SMC owners, checks
shutdown/reset results, protects active frames and blocks normal handoff on
failure. NVMe reads use an owned 4 KiB staging buffer; uncertain commands cannot
DMA into released caller memory. Rust cache publication and C/Python callers
now propagate failure. This patch includes auxiliary Rust/Python changes.

79 new scenarios, 19 predecessor controls, 152,418 existing neighboring checks,
thirteen-patch replay and complete offline links pass. Review's main-entry
ordering regression was reproduced, fixed and re-reviewed. One existing Rust
warning remains. No builder or installed image changes. SART/DART release,
physical reset/DMA completion, target integration and native acceptance remain
open. See `docs/storage-lifecycle-development-2026-09-06.md`.

## 20: SART grant ownership and bounds

`20-sart-grant-ownership.patch` follows loader patches
02/03/08/10/11/12/13/14/15/16/17/18/19. It rejects truncated/empty/overlapping
owned grants, preserves full flags, clears only owned slots, disables access
before changing extents, and retains failed cleanup through NVMe. Metadata
length/alignment checks preserve the version-0 fallback.

253 new scenarios, nine defect controls, 370 neighboring cases, fourteen-patch
replay and complete offline links pass. Read-only review found no material issue.
Setters still report software argument validity, not hardware completion; no
post-publication failure contract or DMA-quiescence proof is added. DART and its
RTKit/display/USB callers still need coordinated invalidation/release handling.
No builder, installed artifact or hardware changed. See
`docs/sart-ownership-development-2026-09-06.md`.

## 21: Checked DART invalidation and retained DMA ownership

Apply `21-dart-lifecycle-retained-dma.patch` after patch 20. DART uses explicit
table ownership and sticky fault quarantine; RTKit distinguishes ordinary map
failure from uncertain publication. Checked cleanup extends through IOVA,
DCP/display, USB, kboot and handoff/proxy callers. USB retains failed constructors
and active callback frames, and clears VUART aliases before free. Python DART
initialization wire arguments and SEP failed-result handling are corrected.

The additions pass 132 focused cases, 42 predecessor defect controls and affected
existing regression suites. Fifteen-patch replay and complete offline links pass.
Read-only review findings were fixed and rechecked. This does not prove native
invalidation, DMA quiescence, locked-register acceptance, display output or
recovery. No builder selects this patch and nothing is installed. Contracts,
validation commands and remaining gates:
`docs/dart-lifecycle-development-2026-09-06.md`.

## 22: Complete reserved-memory records and checked failures

Apply `22-reserved-memory-records.patch` after patch 21. One libfdt append
publishes the complete phandle/address/size record. Display and ASC reservation
helpers now propagate node-creation/property errors instead of stale success.
Other multi-node transaction and optional-mapping policies are unchanged.

137 focused checks, three predecessor controls, 4,880 adjacent checks, strict
sixteen-patch replay and production AArch64 object compilation pass. No full
loader/kernel rebuild or installed changes. Target research confirms locked
DART attachment can replace unrepresented boot mappings; it does not establish
T6030 region membership or authorize activation. See
`docs/dcp-reserved-record-development-2026-09-06.md`.

## 23/24: Upstream alias compatibility and USB2 reset sequence

Apply `23-upstream-piodma-alias.patch` then `24-upstream-usb2phy-reset.patch`
after patch 22. These are byte-identical upstream patches from commits
`a997f4eb552beb517fa44420f8b50457fb5cd7c7` and
`940439b9a407fbfc499bea933269219f3f62d4c7`, with authorship retained. They were
tested separately on September 5 but were missing from the combined DCP loader.
The loader accepts both PIODMA aliases, preferring the legacy spelling when
present, and clears the two USB2 reset bits separately. Linux development
patch 14 emits the canonical `disp0-piodma` alias; the node label is unchanged.

593 real-libfdt alias/dispatch cases, the existing 26 USB PHY cases, adjacent
ownership/clock/DT tests, eighteen-patch replay and full offline loader links
pass. The old source fails both independent regression controls. All display
nodes remain disabled; T6030 still has no display-reservation branch. One
existing Rust warning and two development DT warnings above baseline remain.
No builder, pin, installed artifact or hardware changed. Commands and proof:
`docs/upstream-loader-integration-2026-09-06.md`.

## 25: Exact-target startup wire schemas

`25-startup-wire-layouts.patch` follows Python patches 01/04/05/06/07/09 in
a disposable proxyclient export. It does not change the native loader or
consume C patches 23/24. Exact V14.7 A406 now takes an in/out swap ID and a
by-value opaque 64-bit client handle. A472 now includes three boolean inputs,
placing its output-pointer null flag at byte 11. Older and hypothetical later
profiles retain their prior schemas; no future firmware support is inferred.

Seven test methods per supported test profile pass on macOS/Linux, including
real serialization and output-reference updates; two predecessor layouts fail.
Three hypothetical-future preservation tests also pass. Actual firmware is
not executed. Existing experimental scripts remain unvalidated and must not
be treated as target-ready. The generic serializer still rejects null in/out
pointers before transport; no shared serializer change is hidden here.
Caller migration, firmware offsets and evidence:
`docs/dcp-startup-abi-development-2026-09-06.md`.

## 26: Exact-target swap-completion decoding

`26-swap-completion-wire-layout.patch` follows Python patches
01/04/05/06/07/09/25. D589 retains 1776 total bytes but corrects the 34-byte
completion data, eight-record blob, count, additional boolean and null offset.
Exact V14_7 only; older and hypothetical later schemas remain unchanged.
The actual manager now handles Construct blobs and validates declared/actual
target input length and zero output before manager state changes. Generic
channel envelope/error policy is not claimed fixed.

Seven test methods across four profiles pass on macOS/Linux, with explicit
V14_8 preservation rather than support. Three predecessor decoding/manager
faults reproduce, adjacent suites and eight-patch replay pass. No native loader
or boot selection changes. See `docs/dcp-completion-abi-development-2026-09-06.md`.

## 27: Frame-sync and hotplug metadata

`27-display-metadata-callbacks.patch` follows Python patches
01/04/05/06/07/09/25/26. Exact V14_7 D006 is 60/56 bytes; D576 is 88/76.
The manager mirrors received frame properties locally, acknowledges flags,
preserves hotplug metadata, and rejects wrong target lengths. Target null
records serialize as zero-filled replies. Non-target extra hotplug arguments
remain rejected; old schemas and generic serializer behavior are retained.
No brightness notifications, tiling policy, native loader or boot change.
Tests and evidence: `docs/dcp-metadata-development-2026-09-06.md`.
