# NVMe/SMC ownership and normal boot handoff

Development-only m1n1 patch 19 follows loader patches
02/03/08/10/11/12/13/14/15/16/17/18 on
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. It includes C, Rust and the Python
gigalocker helper; the complete Python DCP development series is separate.
No builder selects this series. No boot, installed/canonical image, storage,
firmware, live MMIO/DMA or serial-device operation changed.

## Changes

- NVMe keeps partial initialization and failed cleanup reachable. Queue
  allocation failures clear descriptors; controller disable precedes publishing
  queue addresses. Shutdown checks controller stop/disable, RTKit sleep, named
  PMGR resets and RTKit buffer cleanup. Successful phases are remembered across
  retries; a real reset failure quarantines the owner. An absent alternative
  reset name has a distinct result (`PMGR_RESET_NOT_FOUND`, -2).
- A command frame prevents reentrant cleanup. Receive failures, timeouts,
  unexpected completion tags and failed NVMMU invalidation fault the owner;
  uncertain commands cannot reuse its queues. Tags are checked before using
  them for invalidation. Definite error completions do not publish read data.
- One driver-owned aligned 4 KiB staging buffer receives NVMe read DMA. Only a
  confirmed successful command copies it into the caller's buffer. Failed reads
  leave caller bytes unchanged; late DMA no longer targets memory that the Rust
  or proxy caller may release. This is ownership isolation, not proof of real
  cache ordering or device quiescence.
- Rust invalidates its read-cache tag before a miss and publishes a new tag only
  after success. Python refuses gigalocker loading after failed NVMe init.
  Chainload checks NVMe shutdown and releases a successfully loaded, nonempty
  Rust-owned image on failure, using its existing compatible C allocator.
- SMC retains its singleton through failed initialization/cleanup. Mailbox send
  and receive errors propagate; initialization and command loops check a
  one-second software deadline. Pending/uncertain requests are quarantined,
  not silently reused. Shared-memory writes validate the owner first. Active
  initialization/write frames prevent reentrant teardown.
- SMC teardown requires checked RTKit quiesce and free. HDMI initialization
  checks SMC initialization, both writes and cleanup before PHY work. DCP also
  rejects teardown when an SMC owner remains, including failed DCP init.
- Normal main/HV handoff checks NVMe shutdown; proxy replies expose failure.
  Main stays in its existing proxy when cleanup fails. The next-stage entry
  check precedes NVMe shutdown, preserving storage access while no payload is
  selected. An unused, uncalled shutdown helper that overwrote NVMe globals was
  removed; no active C/Rust/Python caller was found.

API changes are intentional: NVMe/SMC shutdown now return booleans; PMGR reset
distinguishes a missing name. Raw privileged proxy operations and explicit
reboot commands remain manual bypasses. This is not a universal reboot guard.

## Validation

79 new offline scenarios pass against the fresh replay:

- NVMe: 34, including ten allocation-failure stages, partial startup, controller
  enable/disable/shutdown errors, reset alternatives, power/free retry,
  receive/tag/invalidation failures, caller-buffer lifetime and 200 commands
  across completion-ring phase wrap.
- SMC: 17, including allocation/start/send/receive/power/free failures, wrong
  replies, notification floods, ID wrap and reentrant init/write shutdown.
- Existing caller bodies: PMGR 5, HDMI 6, chainload 6; actual Rust cache 1
  multi-step trace; actual Python helper 2.
- Existing DCP/handoff fixture gains 8 scenarios: SMC owner retention and main
  retry/entry ordering. Complete current suite: DCP owner 19, display 10,
  RTKit free 3, main handoff 9. HV/proxy checks are source contracts, not live
  hypervisor execution.

The C fixtures compile actual complete source or extracted production function
bodies against owned fake registers, memory, time and device dependencies.
They use AArch64 Linux ASan/UBSan, leak detection, assertions and `-Werror`.
Rust uses actual `nvme.rs` with fake filesystem/C interfaces and warnings denied;
Python executes the actual helper method. Only test-owned quarantined memory
is released when ending a fake device epoch; production has no forced-free path.

19 predecessor controls reproduce the defects: 14 NVMe/SMC controls, including
three unbounded SMC waits, plus 5 caller/cache controls. Review found an initial
main-loop ordering regression; a new test reproduced it before the fix, and
focused re-review closed it. Its source/log are retained separately from the
final build inputs.

152,418 existing neighboring checks pass: prior AFK/DCP/client lifecycle 191;
RTKit power 420; EPIC 4,313; AFK rings 130,257; IOVA 12,284; RTKit buffers 299;
retained levels 457; mappings 4,059; macOS DCP config 138. Together with the
79 additions, the final current-source run covers 152,497 cases. These are
software cases, not independent hardware trials or a coverage percentage.
The revised DCP/config fixtures also pass 33/138 predecessor cases.

```bash
for suite in storage-lifecycle storage-integration; do
  python3 /tests/m1n1-$suite-self-test.py /baseline --baseline
  python3 /tests/m1n1-$suite-self-test.py /source
done
python3 /tests/m1n1-dcp-lifecycle-self-test.py /baseline
for suite in afk-lifecycle dcp-lifecycle dcp-client rtkit-power epic afk-ring \
             iova rtkit-buffer dart-levels dcp-mapping; do
  python3 /tests/m1n1-$suite-self-test.py /source
done
```

Here `/baseline` is the sealed patch-18 replay and `/source` the fresh patch-19
replay. The config suite runs separately with existing pinned macOS inputs:

```bash
python3 -O -B tests/m1n1-dcp-config-self-test.py \
  out/isolated/dcp-source-audit-20260906/storage-loader-replay \
  out/isolated/dcp-source-audit-20260906/m1n1-dma-replay/proxyclient \
  out/isolated/dcp-source-audit-20260906/inputs/DeviceTree.j514sap.decoded
```

Thirteen loader patches replay to 510 identical file/link entries, including
five symlinks. Source/replay tree SHA256:
`c1b1c608d33c4f206be0f44cfbad574015138d834e7c3282a409b6e76ca8e9ac`.

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-storage-p19 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

Complete ELF, raw ELF, Mach-O and raw binary links pass with unchanged
Cargo.lock. Production C uses `-Werror`; one existing unused `crate::println`
warning in Rust `usb4.rs` remains. Build executor:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Networking/rootfs writes are disabled; source/tests/sealed dependencies are
read-only mounts copied into disposable `/tmp`. No M0/Linux build or
source-volume mount, dependency download, version change or new cache.

Evidence: `out/isolated/dcp-source-audit-20260906/storage-closure.json`,
`compile-storage/` and `storage-loader-{source,replay}`. The closure selects
exact final logs/artifacts; preview/redundant logs are not final build evidence.
Before-edit snapshots preserve historical documentation and fixture bindings.

## Remaining limits and next safe work

This closes the identified NVMe/SMC ignored-result, partial-owner and caller-DMA
lifetime defects. It does not prove physical controller stop, PMGR reset
completion, DMA/cache ordering or NVMMU behavior. A successful no-owner shutdown
means this code owns no resources, not that inherited firmware hardware stopped.
SMC shared-memory alignment is checked, not physical range/mapping provenance.
Protocol IDs can wrap; matching a reply is not complete stale-transaction proof.

SART/DART invalidation and release still have void/error-swallowing paths.
RTKit boot and other lower-level handlers may still lack whole-operation hard
deadlines. Single-caller flags are not multicore locks. Published SMC requests,
failed resets and uncertain power transitions may block handoff indefinitely;
safe independent recovery is required, not an automatic reset or forced free.
Target memory-region/stream ownership, panel sequencing and all physical
acceptance gates remain open. No development patch is selected by a boot builder.

Next: failure-aware SART/DART invalidation/release, then exact target integration.
The previously reviewed archive establishes one Linux guest under m1n1 HV,
not direct-native Linux or full hardware support. Before another boot: select
one objective and exact candidate, recheck recovery/partition/capture evidence,
then pause for explicit user approval. No zero-risk or single-debug-boot promise.
