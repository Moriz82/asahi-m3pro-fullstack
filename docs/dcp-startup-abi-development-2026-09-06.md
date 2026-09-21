# T6030 startup wire-contract corrections

## Result

Static analysis of the exact J514s/T6030 23J220 DCP firmware found three
startup-contract defects in the development Linux driver; two also affect the
Python controller. Linux development patch 15 and Python development patch 25
correct them without enabling hardware or changing any selected boot builder.

| Call | Firmware evidence | Correction |
| --- | --- | --- |
| A406 swap-start | Wrapper `0x13f468`: 32-bit in/out ID at byte 0, by-value 64-bit client at byte 4, null flag at byte 12; reply status at byte 4 | Linux request/reply become 16/8 bytes instead of 24/24. Python's former 20/20 client-only schema becomes the same 16/8 contract. |
| A472 power-state | Wrapper `0x1421f4`: 64-bit input at byte 0, booleans at bytes 8/9/10, output-pointer null flag at byte 11; reply status at byte 4 | Both clients include all three boolean inputs and move the null flag from byte 9 to 11. Total request/reply remain 12/8 bytes. |
| Power-saving method | A448 maps to `0x140fe4`, consuming one 32-bit input and returning one status; A443 maps to `0x140d08`, a different two-output getter | Linux method-table tag changes A443 to A448, agreeing with the pinned upstream Python table. |

The A4xx lookup is `0x13ebf0`. Full decompilation and A406/A472 disassembly are
saved in `startup-proof/ida-evidence.json`. The decoded firmware's SHA-256 is
`fc54724dcdfcaa8c285c5171258dccd85d5c0713bdc111935d8c667d52107883`.
Acquisition provenance is in [the original ABI report](dcp-abi-development-2026-09-06.md).
Offsets and access widths are observed; interpreting the opaque client as a
handle follows the call's by-value use. No meaning is invented for the two
additional boolean controls. Their current Linux call-site defaults remain zero.

The wrong Linux tag exists in the
[inspected upstream WIP source](https://github.com/AsahiLinux/linux/blob/52f0b76aaae7b9a1cc2100f4a9b33257b450d5c0/drivers/gpu/drm/apple/iomfb_v14_7.c).
The correct A448 association is already in the
[pinned m1n1 schema](https://github.com/AsahiLinux/m1n1/blob/60e53e7078c5cb7efce32d64bf50829e9401e44f/proxyclient/m1n1/fw/dcp/ipc.py).
This is source/binary agreement, not observed panel or power behavior.

## Compatibility and caller scope

Linux's affected declarations are versioned through its existing template
mechanism. All startup, modeset, power-off and shutdown type references use the
versioned declarations. Existing 12.3/13.3 layouts and request defaults remain
unchanged. No return-status policy, timeout, DMA ownership or enablement changes
are part of this patch.

Python patch 25 follows patches 01/04/05/06/07/09 in a separate proxyclient
export. It is not silently added to the linked C loader. The new layouts apply
only to `V14_7`; older and hypothetical later versions retain their previous
schemas. A read-only review caught the initially broad comparison; the corrected
exact-version scope and hypothetical-future regression pass re-review.

For a later independently approved controller integration, the V14.7 Python
call shapes are `swap_start(swap_id=ByRef(...), client=<u64 handle>)` and
`setPowerState(<u64>, <bool>, <bool>, ByRef(...), <bool>)`. Do not substitute a
cached host address for the opaque handle or guess nonzero boolean policies.
The existing `experiments/dcp.py` is not a target-ready procedure and remains
unvalidated. Its old calls do not supply the new arguments. No experiment was run.

The generic Python serializer cannot emit a null `InOutPtr` through `Method.call`:
it raises `KeyError` before transport. Tests preserve and expose that existing
limitation rather than changing every RPC. Null output-only pointers and normal
in/out reference updates are exercised. C wire tests cover both null-flag values.

## Verification

- Real C declarations, per-version method tables and complete thunk macros run
  with a fake `dcp_push`: 21 cases each for 12.3/13.3 and 57 for 14.7, 99 total.
  ASan/UBSan and `-Wall -Wextra -Werror` pass on macOS and AArch64 Linux.
- Three independent predecessor controls reproduce swap size, power null-offset
  and method-tag mismatches; this is not a synthetic mutation of the old source.
- Actual Python schemas and `Method.call` pass seven test methods for each of
  V12_3/V13_5/V14_7 on both hosts, with optimized Python. Two predecessor layout
  assertions fail independently. Three additional test-only V14_8 checks preserve
  the former schemas on both current and predecessor clients; no future support.
- Existing 3,743 transport cases, 275 clock cases, bandwidth, register-mapping,
  null-flag and Python DCP regression suites pass. Recorded ADT/clock inputs are
  included in the separate adjacent-input run; synthetic defaults are not the
  only evidence. Test matrices are software checks, not hardware scenarios.
- Fifteen Linux patches and seven Python patches replay from their exact pins.
  Linux source/replay: 1,417 entries, four symlinks, manifest
  `d1f01a392102ceb9c385ba974a5c517512d144bf53d7098fe878c92df2cd7adb`.
  Scoped proxyclient source/final replay: 228 files, manifest
  `575ce90d26517184a7fdfd0f689575446269bbd29ce3db45e426b8399359b3cd`.
- Full Apple DRM module links with `W=1 KCFLAGS=-Werror`, no diagnostics, against
  the retained development kernel output. Module SHA-256:
  `88792831bb40328f7bca35025e8034ed6a012e2066ee6364fcc5f0b9f2ffa1c7`.

The first module invocation selected an absent cross-prefixed linker. Its failed
log is retained; using the container's existing native AArch64 GCC/binutils
completed the link. No compiler installation or warning suppression was needed.
An initial replay compared a full repository export with a proxyclient-only
export; the corrected final replay explicitly selects matching paths. Preliminary
`startup-client-replay/` is superseded by `startup-client-final-replay/`.

The module build holds the authoritative source-volume lock exclusively. The
existing kernel source/output stay read-only; only module output in disposable
Linux `/tmp` is built. Executor:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`,
network disabled. No full kernel/M0 build or reproducibility promotion occurred.

Run the focused checks from the repository root:

```sh
python3 -B tests/dcp-startup-abi-self-test.py \
  out/isolated/dcp-source-audit-20260906/startup-linux-replay/drivers/gpu/drm/apple
python3 -O -B tests/m1n1-dcp-startup-self-test.py \
  out/isolated/dcp-source-audit-20260906/startup-client-final-replay/proxyclient V14_7
```

`out/isolated/dcp-source-audit-20260906/startup-proof/` holds logs and the module.
`startup-closure.json` binds exact commands, source/firmware/evidence hashes and
historical before-edit bindings. Earlier sealed closures are unchanged.

## Remaining gates

These corrections do not establish all startup methods or typed callback sizes,
firmware error/status handling, fresh retained mappings, ordered activation,
panel sequencing, DMA/cache correctness, USB/SSH, recovery or sustained hardware
acceptance. The shared serializer and unvalidated experimental caller remain
explicit debt. Continue independent offline protocol work; require fresh
boot/observer/recovery checks and new approval before a native experiment.
No device reads, target execution, installation, disk or boot-policy changes,
display enablement or boot occurred.
