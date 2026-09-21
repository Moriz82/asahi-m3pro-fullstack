# RTKit power acknowledgements and bounded receive work

Development-only m1n1 patch 17 follows C patches 02/03/08/10/11/12/13/14/15/16
on `60e53e7078c5cb7efce32d64bf50829e9401e44f`. Production changes are limited
to `src/rtkit.c` and its public contract in `src/rtkit.h`. No builder selects
this series. No canonical pin/source, installed image, boot, firmware, storage
or hardware changed.

## Defects and changes

The existing `rtkit_sleep()` stored a boolean result in an integer, checked
only for a negative value, then always issued `asc_cpu_stop()` and returned
false. It could therefore stop the coprocessor after a failed handshake and
report failure after a successful one. The corrected function returns false
without stopping on handshake failure; success issues the existing CPU-stop
operation and returns true.

Power transitions now require newly observed AP and IOP ACK progress and the
expected states, rather than accepting cached values. Each ACK wait has a
one-second software deadline. `rtkit_recv()` yields after at most 16 mailbox
messages, including invalid/system traffic, so continuous traffic cannot
prevent the caller from checking its deadline. Excess traffic remains queued;
application packets still return one at a time.

Bounded mailbox drains run before the first request, between phases and after
the final ACK. This matters at receive-batch boundaries: review found that an
AP ACK at message 16 could leave an older IOP ACK at message 17, falsely
satisfying the next phase. The new reproducer failed before the drains and
passes after them. Final AP and IOP states are rechecked after draining.

A published AP request sets an uncertainty latch. Only complete success
clears it; later failures, crashes or timeouts cannot be retried on the same
owner, even with a late ACK queued. A failed first send is unpublished under
the inspected ASC send contract and remains retryable. A bounded pre-request
drain failure also sends nothing. No power path frees buffers or mappings.

The header states the caller obligation: application endpoints must already
be stopped because power transitions drain their messages. False does not
authorize freeing buffers, mappings or the RTKit owner. Replacing an uncertain
owner requires an independently established safe reset, not merely allocation
of a new software object.

## Exact validation

420 actual-RTKit C checks pass on AArch64 Linux with ASan/UBSan, leak detection,
assertions and warnings-as-errors. Only intentional multichar literals are
suppressed. The complete production C file is compiled unchanged into the
harness; ASC, time and memory boundaries are fake. Tests assert that power
operations perform no allocation, unmap or free and leave retained descriptors
and memory unchanged.

Coverage includes both targets, cached target states, delayed/wrong/early ACKs,
missing ACKs in either phase, send failures, crashes, uncertainty/retry rules,
counter wrap, prequeued stale traffic, all three continuous-traffic classes,
the message-16/17 hole, bad states/crashes after the final ACK, receive-budget
continuation and application packet ordering.

Nine predecessor controls reproduce four unbounded waits and five incorrect
outcomes. `compile-power/pre-drain-control.log` records the additional
midimplementation stale-tail assertion; `power-rtkit-before-drain.c` preserves
that exact preliminary source. Neither is a final installation input.
Focused review and re-review found no material issue in the final delta.

```bash
python3 /tests/m1n1-rtkit-power-self-test.py /baseline --baseline
python3 /tests/m1n1-rtkit-power-self-test.py /source
python3 /tests/m1n1-epic-self-test.py /source
python3 /tests/m1n1-afk-ring-self-test.py /source
python3 /tests/m1n1-iova-self-test.py /source
python3 /tests/m1n1-rtkit-buffer-self-test.py /source
python3 /tests/m1n1-dart-levels-self-test.py /source
python3 /tests/m1n1-dcp-mapping-self-test.py /source
```

151,669 neighboring checks pass: EPIC/parser 4,313; AFK ring 130,257; IOVA
12,284; RTKit buffers 299; retained levels 457; mapping 4,059. Eleven C patches
replay from the pin to 510 identical file/link entries, including five symlinks.
Source/replay tree SHA256:
`62c00fa8999478d1c8a1e8385cfea4bbf629e70fe7f7a32903378fc5125959f2`.

```bash
CARGO_NET_OFFLINE=true M1N1_VERSION_TAG=60e53e7-dev-power-p17 \
LC_ALL=C SOURCE_DATE_EPOCH=1788197968 \
make -j4 RELEASE=1 CARGO_FLAGS=--locked EXTRA_CFLAGS=-Werror
```

Executor: `sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Source/tests/sealed dependencies are read-only mounts; build copies are
disposable `/tmp` data. Networking is disabled and Cargo.lock stays identical.
No Linux source-volume mount, M0/kernel build, new dependency or cache.
ELF, raw ELF, Mach-O and raw binary link with no named undefined symbols.
RTKit power/receive and DCP/NVMe/SMC shutdown symbols are present. Production C
uses `-Werror`; the existing unused `crate::println` Rust warning remains.

Evidence: `out/isolated/dcp-source-audit-20260906/power-closure.json`,
`compile-power/`, `power-loader-{source,replay}` and existing sealed
`iova-cargo-input/`. Before-edit documentation snapshots preserve all prior
closure bindings. No artifact was installed or promoted to canonical M0.

## Still unsafe / next work

This is a prerequisite, not a completed teardown transaction. AFK endpoint
start/shutdown still has unbounded/error-swallowing paths. Endpoint wrappers,
DCP/display, NVMe and SMC ignore shutdown failures; RTKit free ignores failed
buffer unmaps. Those callers can still free live owners. They must retain
ownership on failure and block unsafe handoff/reinitialization. No native
integration should rely on this patch alone.

ACK counters prove newly observed progress, not transaction-ID correlation.
The protocol has no such ID here; an ACK arriving between an empty-mailbox
observation and request publication remains an ordering limitation. The
one-second values are software policy, not measured target latency. Deadlines
are checked between bounded receive batches, not around every handler, ASC
send, crashlog/parser access or hardware operation. CPU stop still only
clears the existing start bit; there is no physical stop-completion proof.
ACKs and host tests do not prove DMA quiescence, cache ordering, mapping/stream
policy, panel sequencing or native hardware support.
