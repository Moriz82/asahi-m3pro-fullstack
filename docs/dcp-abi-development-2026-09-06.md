# DCP ABI development checkpoint, 2026-09-06

## Outcome and boundary

IDA analysis of public Apple 23J220 firmware found an A407 wire-layout error
in both the inspected Linux WIP driver and m1n1's Python client. A407 submits
display surfaces. Both T6030 and T8122 handlers decode **six**, not five,
secondary surfaces. The Python client also reads reply status at the wrong
offset. Development-only corrections and regression tests are now available.

- `patches/linux-dcp-development/series`: seven unchanged upstream patches,
  followed by the local layout and pinned-kernel-API correction. Combined
  scope: 15 Apple DRM driver files; no device-tree changes.
- `patches/m1n1-dcp-development/01-a407-layout.patch`: Python V14.7 schema only.
- `tests/fixtures/dcp/abi-contract.c`: 26 compile-time ABI assertions.
- `tests/m1n1-dcp-abi-self-test.py`: five fake-transport/schema tests.
- `tests/dcp-null-flags-self-test.py`: five executable C cases covering both
  real initialization snippets, legacy versions and two negative controls.

The complete configured Apple DRM module compiles with `W=1`, without warnings
or errors. This is **not** a full kernel build or hardware acceptance. No patch
is selected by a canonical or development boot builder. No firmware, module,
controller bundle, installed image, boot policy or disk layout was changed.
Original framebuffer candidates 08/09 remain separate, unchanged artifacts.

## Inputs and provenance

Research artifacts are under `out/isolated/dcp-source-audit-20260906/`, called
`AUDIT` below. They are local development evidence, not canonical M0 evidence.

The [Asahi installer source](https://github.com/AsahiLinux/asahi-installer/blob/main/src/main.py)
identifies macOS 14.8.3 as the relevant boot package. The saved BuildManifest
reports 14.8.3 / 23J220; its J514sap identity has chip `0x6030`, board `0x04`.
This agrees with the prior installer's package selection. The recorded boot
firmware compatibility label is 14.7; these labels are not interchangeable
claims about running macOS versions.

Exact archive:
[Apple 23J220 OTA](https://updates.cdn-apple.com/2025FallFCS/patches/089-71124/49AD260A-D47F-4B5E-A793-30446187196E/com_apple_MobileAsset_MacSoftwareUpdate/f6d1ac9149f6a06401ff87fae5b262c420bfc5f7.zip).
Only selected ZIP members were fetched, using the existing installer URLCache,
standard ZIP CRC validation and normal TLS. The 13.6 GB archive was not fully
downloaded. No installer entry point was executed.

| Saved input | SHA-256 |
| --- | --- |
| `inputs/BuildManifest.plist` | `9928478d94e929eced64f432a4f707b6ac392eb603f549e3c83c771093a733dd` |
| `inputs/t6030dcp.im4p` | `6032f797c4e52263d6af1913d8adc240df483b680b27a33ece8b1ff7615f6fff` |
| decoded T6030 Mach-O | `fc54724dcdfcaa8c285c5171258dccd85d5c0713bdc111935d8c667d52107883` |
| `inputs/DeviceTree.j514sap.im4p` | `05a01fe2f5449971acb45bed978ac266af1cab3cc512f0cad8396f3058039380` |
| decoded J514s ADT | `4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478` |
| `control-t8122/t8122dcp.im4p` | `370795d9a1f40aa5ed180d8c8ca4382b8ac9c886c0492728170163e564734832` |
| decoded T8122 Mach-O | `ec94923381ed32f7e3685cdf04c5ef3db7dfbe2a86a46ae4cb33b79eb77a76f2` |

`acquisition.json` preserves the initial naive SHA-384 mismatches. The cause
was the manifest's IMG4 payload-type retagging: raw `dcpf` becomes `dcp2` for
`Ap,DCP2`, and `dtre` becomes `rdtr` for RestoreDeviceTree. Replacing only that
type field **in memory for hashing** matches the selected manifest digests.
Regular DeviceTree also matches. Details: `input-analysis.json` and
`control-t8122/acquisition.json`. Original input bytes were not modified.

These checks are integrity/provenance observations, **not Apple signature
verification**. Inputs are not promoted through the RE trust ledger. Firmware
and IDA databases stay in the disposable research directory, not source control
or the shared vault.

## Binary evidence

IDA auto-analysis and decompilation completed on both decoded binaries. The
Binary Ninja bridge did not respond; no Binary Ninja result is claimed.
Firmware was not executed.

| Binary | RPC callee | A4xx lookup | A407 wrapper |
| --- | --- | --- | --- |
| T6030 | `0x116274` | `0x13ebf0` | `0x13f500` |
| T8122 control | `0x11e558` | `0x146f80` | `0x147890` |

Both lookup functions map `0x41343037` (A407) to the listed wrapper. In T6030,
instructions at `0x13f610`/`0x13f614` step 556 bytes and compare against six.
Loads at `0x13f63c` through `0x13f688` corroborate trailing field offsets;
the status store at `0x13f6c4` is at reply offset five. T8122 independently
shows the same layout and status store at `0x147a54`.

Saved evidence: `workspace/ida/{method-lookup,a407-wrapper,a407-disassembly}.json`
and the control's `workspace/ida/t8122-control/{method-lookup,a407-wrapper}.json`.
The unrelated, truncated `dispatcher.json` is **not** complete-function proof
and was not used to establish this ABI.

| A407 request field | Byte offset | Size |
| --- | ---: | ---: |
| swap record | 0 | 1288 |
| primary surfaces | 1288 | 4 × 556 |
| primary IOVAs | 3512 | 4 × 8 |
| unknown u64 array | 3544 | 4 × 8 |
| secondary surfaces | 3576 | 6 × 556 |
| secondary IOVAs | 6912 | 6 × 8 |
| bool / double / u64 / bool | 6960 / 6961 / 6969 / 6977 | 1 / 8 / 8 / 1 |
| clear / input u32 | 6978 / 6982 | 4 / 4 |
| swap-null / primary-null | 6986 / 6987 | 1 / 4 |
| secondary-null | 6991 | 6 |
| output-bool-null / input-u32-null / output-u32-null | 6997 / 6998 / 6999 | 1 each |

Request total: 7000 bytes. Reply: output bool at zero, output u32 at one,
status at five; nine packed bytes aligned to 12. The Linux reply layout was
already correct. The Python client instead had an eight-byte reply with status
at one. Its input happened to total 7000 bytes despite incorrect offsets.

The correction replaces the guessed extension with actual secondary records,
preserves five slots for older firmware and uses `ARRAY_SIZE` in both kernel
null-initialization loops. The Python correction reuses existing pointer-null
generation instead of adding another marshalling layer. Experimental V14.7
callers must adapt to the corrected pointer arguments; this is not a silent
drop-in replacement for an already deployed controller.

## Source selection and validation

Linux base: `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`; retained schema-only
post-patch tree: `d8082213fc5a3a64c8b9464a7d5c82d13b1ea115`.
m1n1 client base: `60e53e7078c5cb7efce32d64bf50829e9401e44f`.
Upstream topic inspected at
[`52f0b76`](https://github.com/AsahiLinux/linux/tree/52f0b76aaae7b9a1cc2100f4a9b33257b450d5c0/drivers/gpu/drm/apple).
Relevant upstream work includes the
[WIP 14.7 ABI](https://github.com/AsahiLinux/linux/commit/20ea89d8dcfdfe36ad5367b69b53f83c67ec7744)
and [recent layout change](https://github.com/AsahiLinux/linux/commit/d04d611afff9adef16661f17cc1ad6f8f7e7d99f).
The entire topic branch was not substituted for the pinned kernel. Commit IDs
and original authors are retained in the first seven patch files.

Fresh isolated Linux and client exports replay all patches and match the tested
source. A private Git root was necessary: the first `git apply` from an export
inside the parent repository skipped paths despite exit zero. That attempt was
rejected, then all patches reapplied and actual output files compared.

| Check | Exact observed result | Evidence under AUDIT |
| --- | --- | --- |
| C ABI contract against upstream-only backport | 13 expected assertion failures | `compile-upstream/abi-contract.log` |
| C ABI contract after correction | all 26 assertions compile | `compile-corrected/abi-contract.log` |
| configured Apple DRM module | all objects, MODPOST and link pass; zero warnings/errors | `compile-corrected/module-build.log` |
| Python original / corrected / fresh replay | 3 failures + 1 error before; all 5 tests pass after and on replay | `m1n1-abi-{before,after,replay}.log` |
| actual C initialization snippets | 5 compiled/executed cases pass, including separately rejected five-slot mutants | `null-flags-tests.log` |
| legacy C layouts | 38 constants / 152 bytes identical | `legacy-layout/{original,corrected}.bin` |
| legacy Python layouts | all 168 V12.3 and 174 V13.5 method layouts identical | `legacy-client.json` |

The C snippet cases use host-owned memory, canaries and undefined-behavior
sanitization. They are not execution of the complete driver. Fake-transport
tests check real schema encoding/decoding, nonzero data, the sixth surface and
IOVA, reply outputs and rejection of an eight-byte reply. Legacy comparisons
prove the compared layouts, not all older-firmware behavior.

Module SHA-256:
`3b194031e5fe684c5b04b512f97878fc7e321af6906bedcb0d8d3acf24bfff13`.
Legacy C layout digest:
`d364125fd2baa727c0c31cf2c8e6854c288204e34f25ea22b01d5c77d575cded`.
The module is not installed or substituted into a candidate.

Local kernel patch 08 SHA-256:
`9dbf0d7b6a8187c54103d0a2f51b72a406118479e514f2187f5e8c726ed8021c`.
Python client patch SHA-256:
`985ebd65f24e3710ef707a3ce5cf2f5eae288a36b82e6efa653faa2b156bfb28`.

Build environment: Docker `desktop-linux`, image
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`,
source volume `asahi-offline-source-audit-20260904` mounted read-only.
The existing `/workspace/.milestone0-build.lock` was held exclusively with
`flock -xn 9`; no concurrent M0/Linux build. Prepared sources and kernel
objects were read-only. New module objects used isolated Linux `/tmp` output.
The retained config has `CONFIG_DRM_APPLE=m`, `CONFIG_DRM_APPLE_AUDIO=y`.

Exact inner build commands, with `/driver` bound to the isolated prepared Apple
driver directory (including the test-only `abi-contract.c` for the first):

```bash
make -C /workspace/src/linux O=/workspace/build/linux-development-framebuffer \
  M=/driver MO=/tmp/dcp-abi ARCH=arm64 W=1 -j1 abi-contract.o
make -C /workspace/src/linux O=/workspace/build/linux-development-framebuffer \
  M=/driver MO=/tmp/dcp-module ARCH=arm64 W=1 -j4 modules
```

Focused host tests, from the repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m1n1-dcp-abi-self-test.py \
  out/isolated/dcp-source-audit-20260906/replay-m1n1/proxyclient
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/dcp-null-flags-self-test.py \
  out/isolated/dcp-source-audit-20260906/replay-linux/drivers/gpu/drm/apple
```

One bounded independent source/ABI review found the missing executable
initialization test; the added positive and negative cases close that finding.
A subsequent concern that the flush snippet omitted `memset` was checked
against the real source and retracted. No remaining material finding in that
bounded review. This is not a full driver audit or two-person hardware-safety
signoff.

Final hygiene checks: both Python test sources parse; new tests/report have no
trailing whitespace; `git diff --check` passes. Gitleaks found no secrets in
the selected patches, tests, docs and curated handoff/index/project text. The
full static aggregate and full kernel build were not repeated for these
isolated changes.

## Remaining work and next safe step

The Apple ADT supplies static DCP/DISP resources, DART mapper IDs, interrupts and
clock/power references; five relevant nodes are saved in `input-analysis.json`.
Its `/chosen/carveout-memory-map` contains only name/phandle, not runtime values.
Do not invent carveout addresses, mailbox offsets or Linux display bindings.

The J514s Linux template still lacks DCP, mailbox, display-subsystem and DART
nodes/aliases. Merely adding T6030 to m1n1 `dt_set_display()` would not establish
those resources: reservation helpers return without work when the `dcp` alias
is absent. Separately, the existing framebuffer is excluded from usable RAM by
`dt_set_memory()`/`dt_set_fb()`; the unknown-compatible display warning alone is
not evidence that its scanout buffer was left available for allocation.

Next: source/binary review of target topology and remaining firmware callbacks,
then a reviewed runtime-data capture plan before any hardware-enable change.
Power sequencing, DART mappings, DMA lifetime, display reset/recovery, panel
modes, EDID/audio and suspend/resume remain unproven. The
[official M3 matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
still distinguishes per-feature work from full-chip support; this checkpoint
does not add GPU acceleration or retire known WIP diagnostics.

No new boot was attempted. The earlier archive proves one Linux guest boot
under m1n1 HV, not a direct native full-hardware Linux installation. All native,
recovery and release gates remain separate from these offline results.
