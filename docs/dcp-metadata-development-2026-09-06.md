# DCP frame-sync and hotplug metadata checkpoint

Development patches Linux 17 / Python 27 fix two exact J514s/T6030 23J220
callback contracts. No boot builder selects them; no display node, installed
image, disk, firmware or target hardware changed.

## Evidence and behavior

| Callback | Request / reply | Verified fields and reply policy |
| --- | --- | --- |
| D006 frame-sync | 60 / 56 bytes | Eleven u32 values, eleven update flags, one reserved byte; null flag at 56. Preserve values/reserved byte, clear received update flags. |
| D576 hotplug | 88 / 76 bytes | u64 connection, 75-byte opaque record, boolean at 83, null flag at 84. Preserve the record; zero reply padding. |

IDA firmware senders: D006 `0x1dafac`, D576 `0x13e8b8`.
Host D006 wrapper `0xfffffe0009acb3b8` copies 56 bytes; handler
`0xfffffe0009ab9f90` publishes eleven properties and clears their flags.
Host property names are read from `0xfffffe000be391b8`.
Host D576 wrapper `0xfffffe000ab71d4c` copies its in/out record;
conversion `0xfffffe000ab7452c` copies exactly 75 bytes, and the pre/post/
finalize conversions are no-ops. The shim decompilation has a local-variable
allocation warning; it is not proof of complete tiling behavior.

Linux logs frame-sync metadata but implements no brightness policy.
Python mirrors named properties in its existing local property dictionary.
Neither reproduces macOS brightness notifications or proves brightness control.
Linux keeps its existing connector/modeset policy, including ignored internal
display events, while preserving their replies. Python does not model tiling.

Both target callbacks validate exact input/output sizes before dispatch state.
Linux additionally requires exact outer lengths 128 / 176. Null records return
zero-filled replies without consuming metadata. Target-only Python defaults
fix null serialization; generic pointer serialization remains unchanged.
Older layouts are preserved. Review caught widened non-target Python hotplug
acceptance; the final handler rejects extra arguments outside V14_7, including
null records. Hypothetical V14_8 testing is preservation, not support.

## Validation

- 5,640 actual-C metadata cases: 514 / 517 / 4,609 for 12.3 / 13.3 / 14.7.
  All 2,048 target update masks, both null states, reserved/input preservation,
  output canaries and hotplug connector/modeset combinations are covered.
- 3,903 transport cases, including 96 new metadata envelope/size/dispatch
  cases. Rejections preserve memory, channels, handler count and ACK count.
- Eight Python test methods per profile on macOS/AArch64 Linux. Actual target
  manager executes every update mask; independent packets cover fields, nulls,
  malformed lengths, side effects and callback nesting.
- Eleven new predecessor faults reproduced. Existing startup/completion,
  bandwidth, clock, register mapping, null-flag and relevant Python tests pass.
- C ASan/UBSan, optimized Python, strict 17-patch Linux / 9-patch Python replay.
  Full Apple DRM module links under the source-volume lock with
  `ARCH=arm64 W=1 KCFLAGS=-Werror`; no warnings/errors. No full Linux/M0 rebuild.
  Module SHA256: `f09188995835743e6276845193892db5e2bb7d5c633862cf849bebe01e9b17b8`.

Evidence root: `out/isolated/dcp-source-audit-20260906/metadata-proof/`.
Exact commands and saved IDA output are there; `metadata-closure.json` binds
this checkpoint. Final exports: `metadata-linux-final-replay` and
`metadata-client-verified`. The earlier `metadata-client-final-replay`
predates the review guard and is not the final client.

## Remaining work and efficient next step

No native display, USB/SSH, recovery, DMA/cache or sustained device acceptance
is established. Retained region/SID membership, ordered display activation,
remaining callback/status contracts and Python channel error/lifetime policy
are still incomplete. These two fixes do not imply full M3 hardware support.

Next: rank boot-critical gaps and work the highest-impact one, using affected
tests only. Do not repeat historical audit chains, full matrices, routine agent
reviews or module builds for documentation/Python-only changes. Keep one short
handoff and exact test evidence. Native experiments require fresh gates and
explicit approval; do not boot.
