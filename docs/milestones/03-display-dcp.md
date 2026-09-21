# Milestone 3: internal display and DCP

The collector validates supplied display-mode declarations, clean kernel and
DCP logs, at least 100 structured successful brightness records, and at least
50 structured successful suspend/resume records. Bare `pass` strings are not
accepted as records. All bundles remain `software-plan-only` with
`hardware_acceptance=false`.

Human-only future gates include DCP initialization, framebuffer handoff,
modesetting, eDP and panel sequencing, backlight and variable refresh, lid and
hotplug behavior, blank/unblank, compositor restart, low-battery resume,
black-screen recovery, two-person review, and native panel evidence at every
advertised mode.

## Pinned source state

The pinned post-patch Linux source tree contains the Apple DRM/DCP driver, and
the M0 configuration builds `CONFIG_DRM_APPLE=m`. The J514s/T6030 device-tree
closure does not contain a DCP device, DCP mailbox/DART, display subsystem,
panel, or backlight node; it exposes only the loader-populated simple
framebuffer. Older Apple SoCs having DCP nodes does not make that driver usable
on T6030. No target DCP implementation is inferred or duplicated here.

`scripts/check-m3-source-readiness.sh` binds this check to the M2 source
contract and checks the target DCP node, mailbox, DART, and display-subsystem
requirements. With the current pin it exits 2 and reports
`gate=blocked-target-dcp-topology`. Run it in the same read-only pinned Arch
container used by the M2 source-contract check.

The structured-evidence validator requires positive numeric width, height, and
refresh values for unique display-mode tuples, brightness percentages in
`0..100`, and nonnegative numeric resume times. These checks only prevent
malformed supplied records. They do not turn a software-plan bundle into
runtime or hardware evidence. M3 stays blocked until reviewed target source and
native panel evidence exist.

## Development checkpoint (2026-09-06)

[Offline DCP ABI work](../dcp-abi-development-2026-09-06.md) adds an isolated
upstream 14.7 backport, binary-backed six-surface A407 corrections for the
kernel and Python client, and focused compile/fake-transport regression tests.
The configured Apple DRM module compiles; no boot builder selects these patches.
Target DT topology, runtime carveouts and hardware acceptance remain missing.
This does not retire the pinned-source gate above or establish panel support.

[Display-handoff follow-up](../dcp-handoff-development-2026-09-06.md) captures
allowlisted current-macOS metadata and fixes two generic m1n1 DART defects in
an isolated patch. All 584 source-backed cases pass under sanitizers. Current
macOS addresses are not future-boot inputs; target register/bandwidth and IOVA
contracts and native behavior remain unresolved. A separate initialization
patch now fixes allocation-failure ownership and defers register publication
until all missing roots are ready. Another 3,582 source-backed sanitizer cases
pass, with replay and freestanding object proof. No builder consumes this
patch; locked-register acceptance and broader DART lifecycle remain untested.

[Target bandwidth follow-up](../dcp-bandwidth-development-2026-09-06.md) now
resolves scratch slot 5/offset 0x988/length 8 from the exact 23J220 host driver
and Apple tree. A development-only Python callback and D003 status-layout fix
pass real-code offline tests, 47 malformed-contract checks, clean replay and
legacy-layout comparison. This supersedes the specific unknown scratch
contract above, not D411 DMA, PMP runtime readiness, target topology, panel or
native acceptance gaps. No boot builder consumes the new patch.

[D411 register-mode work](../dcp-register-development-2026-09-06.md) implements
the verified metadata-only direct-register callback, fixes Linux's address-mode
selection and false-success DMA-error reply, and restores Python callback
depth after exceptions. Seven Python tests, six C sanitizer executables,
fresh replay and a W=1 full DRM-module build pass. This does not resolve DMA
mapping ownership/quiescence, target topology or native panel operation.

[Python DMA prerequisites](../dcp-dma-prerequisites-2026-09-06.md) now correct
explicit DCP stream/invalidation routing and retained T8110 page-table traversal,
with pre-write argument checks and physical-zero translation. Twelve offline
tests, optimized/legacy-profile regressions and replay pass. These unselected
development patches do not resolve DMA lifetime, cache attributes or full
target address encoding, and do not retire any native acceptance gate.

[Linux bandwidth and disabled topology](../dcp-display-topology-2026-09-06.md)
now implement the verified V14.7 scratch width/status and safe resource bounds.
A J514s-only fragment supplies exact-ADT DCP/mailbox/DART/display wiring with
all active nodes disabled. Six sanitizer executables, eight DT tests, five
rejected DT mutants, clean replay and another full W=1 module build pass;
J516s is byte-identical. This supersedes the development topology absence
above, not the unchanged pinned-source gate. Mandatory clock, runtime loader
mappings, panel sequencing and DMA lifetime still block enablement. Three
additional DT compiler warnings remain debt; no dt-schema/native pass.

[Bootloader configuration and clock contract](../dcp-config-clock-development-2026-09-06.md)
now add exact J514s selection and correct internal-DCP reset name/die routing
in an unselected m1n1 patch. 130 sanitizer cases, four original-fault controls,
replay and production object builds pass. IDA resolves the clock table's base
and D408's provider/index arguments; fresh boot metadata is still required.
This supersedes the specific selector/default-name gap, not physical reset,
runtime reservations, DMA or native display acceptance.

[Metadata-driven Python clocks](../dcp-clock-metadata-development-2026-09-06.md)
now replace the T6030 constant reply with verified provider/index lookup from
caller-supplied ADT, preserving valid zeros and rejecting malformed metadata.
Nine target tests on macOS/Linux, 32 adjacent regressions, negative controls,
legacy profiles, replay and review pass. This supersedes only the Python
clock-callback gap. Linux/loader binding and fresh-boot provenance remain
unproved; no builder selects the patch and display nodes stay disabled.

[Linux/loader clock handoff](../dcp-clock-handoff-development-2026-09-06.md)
now supplies paired development patches: two disabled fixed-clock providers,
fresh ADT-to-FDT rate publication, and index-aware Linux D408 handling with
platform-lifetime clock ownership. Packet-size guards and alignment-safe
shared reply copies accompany the new consumer. 321 sanitizer cases pass on
macOS/Linux, including FDT readback into the callback fixture; DT regressions,
source replay and production object/module compilation pass. This supersedes
the unimplemented clock binding/publication gap, not provider activation,
live freshness, runtime mappings, panel or DMA/hardware acceptance.

[DCP transport hardening](../dcp-transport-development-2026-09-06.md) bounds
callback envelopes/stacks, separates RX/TX frames, prevents nested commands
from overwriting shared TX windows, and completes ACKs from saved output
pointers. 3,743 actual-C sanitizer cases and five original-fault controls pass
on macOS/Linux; clock/adjacent regressions, full-series replay and W=1 module
compilation pass. Per-handler schemas, malformed-message recovery, concurrency
and physical transport remain unproved. No builder or hardware is enabled.

[Retained mapping continuity](../dcp-mapping-development-2026-09-06.md) now
checks every covered page, rejects invalid/wrapping extents, and prevents
unsupported high IOVAs from aliasing low roots in the existing C DART walker.
4,059 new sanitizer cases, five original-fault controls, 4,166 existing DART
cases, clock integration, full C-series replay and two production objects pass.
Target region/stream membership, four-level traversal, required-region policy,
live consistency and physical DMA/display operation remain unproved. No
T6030 retained-region table, installed image or hardware enablement was added.

[Retained T8110 hierarchy](../dcp-retained-levels-development-2026-09-06.md)
now preserves four-level mode and supplies bounded translation/search/map/
unmap/cleanup through the existing C library. Fresh contexts and legacy
preallocation fallback retain their behavior. 457 new sanitizer cases,
8,225 DART/mapping regressions, DCP/clock integration, six-patch C replay and
three production objects pass. This supersedes the C traversal gap above,
not higher-level wide-DVA encoding, target region policy, DMA/panel or native
acceptance. Display/DART nodes remain disabled; no installed artifacts change.

[RTKit buffer prerequisites](../dcp-rtkit-buffers-development-2026-09-06.md)
now preserve real high IOVA bits, validate explicit tag encoding and borrowed
page continuity, and track allocation ownership. 299 new sanitizer cases,
four original failures, 4,516 DART/mapping regressions, full C replay and
RTKit/AFK/DCP objects pass. This supersedes RTKit's unconditional 36-bit mask
gap, not end-to-end DMA support. Allocator bounds, AFK protocol/recovery,
live quiescence, region policy and panel/native acceptance remain open.
No builder, installed artifact or hardware activation changed.

[IOVA domain integration](../dcp-iova-development-2026-09-06.md) now bounds
the real allocator at high bases, handles reservations and arbitrary release
order, and rejects framebuffer IOVA exhaustion before mapping. 12,284 new
checks include actual allocator/RTKit flow; seven original controls, 4,815
regressions, full C replay and complete offline m1n1 links pass. The linked
image is development-only, with one existing Rust warning. This supersedes
allocator-domain correctness gaps above, not AFK recovery, live DMA, panel
or native acceptance. No canonical/installed image or hardware changed.

[AFK ring transport](../dcp-afk-rings-development-2026-09-06.md) now bounds
48-bit buffer replies and negotiated windows, checks ring geometry/positions
and committed frames, saves ACK cursors, and faults ambiguous TX publication.
130,257 new sanitizer checks, nine original-fault controls, 17,099 neighboring
regressions, nine-patch replay and complete offline m1n1 links pass. This
supersedes the ring/wire-bound gaps above, not EPIC parser/payload lifetime,
shutdown recovery, live DMA or native acceptance. Header block sizes are
tested formats, not freshly observed target metadata. No installed image or
hardware changed; the existing Rust warning remains visible.

[EPIC message ownership](../dcp-epic-development-2026-09-06.md) now copies
frames before ACK, validates message/property bounds, matches replies, prevents
uncertain buffer reuse and protects pending endpoint RX ownership. Discovery
and command waits include bounded work batches. 4,313 new checks, thirteen
predecessor controls, 147,356 neighboring regressions, ten-patch replay and
complete offline links pass. This supersedes the parser/payload-lifetime gaps
above, not quiescence-safe endpoint/DCP/display teardown or native acceptance.
No installed image or hardware changed; one existing Rust warning remains.

[RTKit power acknowledgements](../dcp-rtkit-power-development-2026-09-06.md)
now fix the sleep boolean bug, bound receive/ACK work, require new observed
ACK progress, drain stale queued messages and prevent uncertain retries.
420 new checks, nine predecessor controls, a reproduced review-found stale-ACK
case, 151,669 regressions, eleven-patch replay and complete offline links pass.
This supersedes only the RTKit power-handshake defects, not failure-aware
AFK/DCP/display/NVMe/SMC cleanup or native quiescence. No installed image or
hardware changed; the existing Rust warning remains visible.

[DCP lifecycle ownership](../dcp-lifecycle-development-2026-09-06.md) now
propagates failed AFK/client/RTKit cleanup through DCP/display and blocks unsafe
boot/HV handoff. Active-frame leases prevent cross-endpoint callback teardown;
failed or uncertain owners remain reachable instead of being freed. 191 new
sanitizer checks, 23 predecessor controls, 152,227 neighboring checks,
twelve-patch replay and complete offline links pass. This supersedes those
DCP caller-lifetime gaps, not NVMe/SMC retention, DART invalidation/cleanup
failure handling, physical quiescence, panel behavior or native acceptance.
No installed artifact or hardware changed; the existing Rust warning remains.

[NVMe/SMC ownership](../storage-lifecycle-development-2026-09-06.md) now retains
failed storage/SMC owners, checks cleanup/reset results, isolates uncertain read
DMA from caller buffers and gates normal main/HV handoff. Rust cache and
C/Python callers propagate failure. 79 new scenarios, 19 predecessor controls,
152,418 existing neighboring checks, thirteen-patch replay and complete offline
links pass. Review's payloadless-proxy regression is fixed and re-reviewed.
This supersedes the identified NVMe/SMC lifetime gaps, not SART/DART release,
physical reset/quiescence, target panel integration or native acceptance.
No builder, installed image or hardware changed; one existing Rust warning remains.

[SART grant ownership](../sart-ownership-development-2026-09-06.md) now rejects
unencodable/overlapping owned ranges, preserves full flags, clears only owned
slots and orders access revocation before address changes. NVMe retains failed
cleanup. 253 new scenarios, nine controls, 370 neighboring cases, fourteen-patch
replay and offline links pass. This is software grant ownership, not readback,
physical DMA stop or native acceptance. DART and its RTKit/display/USB callers
remain the next coordinated failure-propagation boundary. No installed changes.

[Checked DART/USB ownership](../dart-lifecycle-development-2026-09-06.md) now
propagates invalidation and cleanup failure through loader callers. Patch 21
passed focused/adjacent tests, fifteen-patch replay and offline links; native
cache, MMIO and DMA-quiescence proof remain outstanding.

[Reserved-memory publication](../dcp-reserved-record-development-2026-09-06.md)
adds complete IOMMU records and correct reservation error returns in patch 22.
137 focused and 4,880 adjacent checks, three defect controls, sixteen-patch
replay and production object compilation pass. Pinned Linux source confirms
locked DART attachment may overwrite unrepresented boot mappings. Target
region/SID membership, coherent FDT publication and ordered activation remain
open; display hardware nodes stay disabled. No installed or hardware changes.

[Upstream loader integration](../upstream-loader-integration-2026-09-06.md)
now brings the previously separate upstream PIODMA-alias and USB2 reset fixes
into the combined development loader (patches 23/24). Linux patch 14 emits the
canonical alias. 593 alias/dispatch cases, 26 USB PHY cases, adjacent ownership,
DT/clock tests, strict replay and full offline loader links pass. The J514s DTB
changes only the alias; J516s is byte-identical. One alias warning is retired,
but two development DT warnings above baseline and one existing Rust warning
remain. No T6030 reservation branch, enabled display node, selected builder or
installed change is added. Fresh mapping membership and ordered activation
remain prerequisites, not facts inferred from compilation.

[Startup wire-contract correction](../dcp-startup-abi-development-2026-09-06.md)
uses exact-target IDA evidence to fix A406 swap-start and A472 power-state
layouts in Linux/Python, plus Linux's wrong power-saving method tag. Older
profiles retain their layouts. 99 actual-C cases, Python schema/serialization
tests, five predecessor mismatches, replay and a full W=1/-Werror DRM-module
build pass. This closes identified wire-layout defects, not all startup or
callback contracts, native error policy, retained mappings or panel acceptance.
Display nodes and builder selection remain unchanged.

[Swap-completion callback correction](../dcp-completion-abi-development-2026-09-06.md)
uses firmware field accesses and packet construction to fix D589 Linux/Python
decoding and the Python manager's parsed-blob failure. Linux patch 16 requires
exact target input/output and outer lengths; Python patch 26 checks manager
inputs before state changes. 135 C startup/completion cases, 3807 transport
cases, Python/adjacent tests, strict replay and full DRM module linkage pass.
Older schemas remain unchanged and review is rechecked. Frame-sync/hotplug
metadata handling, the wider callback audit, retained mappings and native
acceptance remain open. No display node, selected builder or installed state
changes.

## Uniform software gate and handoff

[Frame-sync and hotplug metadata](../dcp-metadata-development-2026-09-06.md)
now have firmware/host-backed target layouts and value-preserving replies.
Linux 17 / Python 27 pass focused sanitizer/manager tests, predecessor
controls, replay and module linkage. This supersedes the two callback-layout
gaps above, not brightness/tiling policy, display activation or native proof.

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
