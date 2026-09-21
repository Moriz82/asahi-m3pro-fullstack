# Development DART invalidation and DMA ownership

## Status and scope

Patch `21-dart-lifecycle-retained-dma.patch` follows patch 20 in the disposable
native-loader series. It changes 19 production files across DART, RTKit, IOVA,
DCP/display, USB, handoff/proxy callers and two Python helpers. No builder selects
it. No installed file, disk, firmware, boot policy or target hardware changed.

This is an offline software checkpoint, not boot approval or hardware support.
The previously reviewed `out.zip` establishes a Linux guest boot under m1n1 HV,
not direct-native Linux or full laptop acceptance.

## Contracts and ownership

- DART backends now check invalidation completion. Failure latches a fault and
  anchors the owner, including failed constructors. Published page tables stay
  allocated; later mapping, translation and release operations reject the owner.
- `dart_map` and `rtkit_map` return zero for success, minus one for an ordinary
  failure, and `DART_ERR_UNCERTAIN` (minus three) when publication may have been
  observed. The uncertain result retains backing memory and reserved IOVA.
  `rtkit_alloc_buffer` can return false while publishing an owned descriptor;
  callers must retain that descriptor for checked cleanup.
- `dart_unmap`, `dart_free_l2`, `dart_shutdown`, `iovad_shutdown`,
  `usb_dwc3_shutdown` and `usb_iodev_shutdown` return checked boolean results.
  Failure is never authorization to free or reuse remaining resources.
- Explicit per-handle records replace heap-membership ownership inference.
  A borrowed handle cannot free another handle's root/child tables. Owned child
  tables are unlinked before checked invalidation and free. An unsuccessful
  invalidation retains even an already-unlinked page through its owner record.
- USB retains failed constructors. Endpoint-command, halt/reset, unmap and DART
  cleanup failures retain DMA buffers. Active synchronous I/O/event frames and
  recursive shutdown cannot free their own device. Registration is removed only
  after successful cleanup; the VUART alias is cleared before device free.
- Native handoff checks DART faults and display/NVMe/USB cleanup before exception,
  framebuffer and MMU teardown. A pending USB callback shutdown can retry after
  the frame exits. Failed constructors without an iodev still block handoff.
  Completed USB shutdowns stay completed, so a surviving proxy transport is not
  guaranteed after partial shutdown. HV checks faults without shutting down its
  active USB transport. Kboot cleanup and C proxy replies propagate failures.
- Python `dart_init` now sends `(base, sid, keep_pts, dart_type)` to match the C
  four-argument request; the former third argument incorrectly occupied the
  keep-table slot. SEP helpers reject failed initialization/map/unmap and retain
  already allocated shared memory rather than replacing its owner.

## Validation

The focused additions comprise 132 cases: 42 actual DART/RTKit cases, 39 actual
USB/ringbuffer cases, 43 C/Python caller cases, and eight added DCP/handoff/IOVA
cases. These include healthy controls and allocation failures, not 132 distinct
hardware defects. Twenty-four DART and eighteen USB predecessor failure cases
reproduce against the sealed patch-20 replay.

USB testing also exposed four signed `1 << 31` register constants; they now use
`1U << 31`. The predecessor USB control disables only UBSan's shift-base check
to isolate ownership failures. Current-source USB tests retain full ASan/UBSan.

Fresh replay also passes the affected existing suites: DART poll/search (584),
constructor (3,582), retained levels (457), retained mappings (4,059), DCP
configuration (138), endpoint clients (32), RTKit buffers (299), RTKit power
(420), SART (252), AFK lifecycle (126), AFK rings (130,257), EPIC (4,313), storage
lifecycle (52), and storage callers/cache (20). Current IOVA suite totals
12,285 and DCP/display/RTKit-owner/handoff suite totals 48, including the added
cases above. Counts are parameterized software checks, not hardware coverage.
Six adapted fixture suites also pass unchanged predecessor behavior.

All C fixtures use assertions and ASan/UBSan with leak detection on AArch64
Linux, except the exact-ADT configuration fixture runs with macOS Clang and
its existing platform leak-detection setting. No device operations are real.
Python caller tests execute selected actual AST method bodies with owned fakes.
USB registry, kboot cleanup and proxy tests execute extracted actual C bodies.
No new dependencies or test framework were added.

Read-only review found two integration issues: sharing one DART between USB
owners with different register bases, and a pre-cleanup USB fault gate that
prevented a callback-deferred shutdown retry. Both were fixed, tested and
re-reviewed with no remaining material finding.

Fifteen loader patches replay from m1n1
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. Source and replay contain 510 identical
file/link entries, including five symlinks. Tree SHA256:
`56ae003fcbc84cd498996e4884012d43d98abb92bbfe64adaed56d83bc813289`.
The manifest compares symlink text; ordinary recursive diff alone cannot verify
the exported artwork links. Historical closures remain unchanged and 1,085
historical hashes are rechecked using preserved fixture/readme snapshots.

The fresh replay links ELF, raw ELF, Mach-O and raw binary with both Rust lockfiles
unchanged. One existing `rust/src/usb4.rs` unused-import warning remains. Production
C uses `-Werror`. The first full compile linked, but its capture command checked
the wrong lockfile path; it was not accepted as final artifact evidence. The
corrected replay build and capture passed.

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-dart-lifecycle-p21 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

Executor image:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Network and rootfs writes are disabled; source and sealed dependencies are
read-only inputs copied into disposable tmpfs. No M0/Linux build or source-volume
mount was used. Final evidence selection and exact commands are in
`out/isolated/dcp-source-audit-20260906/dart-lifecycle-closure.json` and
`compile-dart-lifecycle/`. Preliminary logs are not selected as final evidence.

## Remaining limits and next safe step

Fault quarantine is intentionally sticky: there is no software force-free or
recovery API. A hardware reset and physical quiescence remain separate proof.
These tests do not establish native MMIO write acceptance, cache/DMA ordering,
TLB timing, valid target RAM, locked-register behavior or visible scanout.
Shared DART handles have no loan/refcount protocol; the owner must outlive its
borrowers. The existing locked/missing-root behavior is not resolved here.
USB frame guards cover synchronous reentry, not a new multicore ownership model.
Raw privileged proxy/reboot commands are not sandboxed by the handoff gate.

Next: validate the target-specific retained display/stream configuration and
boot-candidate integration against the pinned evidence. Keep this patch series
development-only until those gates and a complete candidate review pass. Native
display, USB/SSH, sustained liveness, storage and recovery acceptance still need
separately authorized physical testing; offline checks cannot replace it.
