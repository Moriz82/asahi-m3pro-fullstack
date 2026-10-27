# T6030 GPU acceleration candidate, 2026-10-22

Development-only, offline source candidate for the Apple M3 Pro (T6030) G15
GPU on J514s (`Mac15,6`, 14") and J516s (`Mac15,7`, 16"). It records the real
GPU silicon identity read from macOS, a disabled device-tree GPU-node
candidate shared by both boards, and a G15 driver hardware-configuration
candidate whose reverse-engineered values are explicit placeholders.

Nothing executed on the GPU. No builder selects the candidate. No installed
DTB, module, image, firmware, storage or boot policy changed.
`hardware_acceptance=false`.

**Passing builds, device-tree compilation, patch replay and offline tests are
not hardware support.** At most they show that source is well formed, carries
the right identity and fails closed. They do not show that the M3 Pro GPU
boots firmware, renders, passes conformance or survives stress under Linux.

## Boundary: proven here versus gated

This section governs every other statement in this note. Where a later
sentence appears to say more, this section wins.

### Software-proven or software-provable here

| Claim | How it is checked | Recorded in this note |
| --- | --- | --- |
| Profile identity values equal the live host | Read-only `ioreg` query; see reproduction | **Yes**, 2026-10-22: every compared value equal |
| Driver templates are the pinned M4 sources | SHA-256 of `driver.rs`, `gpu.rs`, `hw/mod.rs` against `config/milestone4-source-files.sha256` | **Yes**: all three digests match |
| Pinned tree still lacks T6030 GPU support | `scripts/check-m4-source-readiness.sh` exits 2, `gate=blocked-target-gpu-driver-and-topology` | Unchanged gate; **not re-run** (no pinned source volume or M0 evidence in this checkout) |
| A patched tree cannot pass the pinned gate | Tampered-fixture case in `tests/m4-source-readiness-self-test.sh` | Existing test; **not re-run** here |
| Candidate patches apply in order | Strict `git am` replay against pinned Linux `77cb8f24c2381a8abb7272d7bbdec548d6426a8a` (base; `d8082213…` differs only by the disjoint `patches/linux/0001` schema-lint commit) | **Yes**, 2026-10-23: `verify-m4-gpu-source-candidate.sh --static` → `patch_replay=git-am-clean`, `patch_replay_patches=6` |
| J514s and J516s DTBs compile with the node | Full-board `clang -E` + `dtc` build of `t6030-j514s.dtb` and `t6030-j516s.dtb` on the patched tree | **Yes**, 2026-10-23: both built, `baseline_warnings=7 patched_warnings=7 new_warnings=0`, GPU node present and `status=disabled` on both boards |
| Candidate Rust compiles | Asahi DRM driver build against the pinned tree with `CONFIG_DRM_ASAHI_G15_CANDIDATE=y` | **Yes**, 2026-10-23: `RUSTC [M] drivers/gpu/drm/asahi/asahi.o` links (14.7 MB) with the G15 candidate enabled; both board DTBs build. Proof-only toolchain (current Arch clang/LLVM, rustc pinned 1.93.1, bindgen 0.72.1), not the canonical hash-pinned builder; `asahi.o` is the module object, no `.ko`/modpost, no GPU execution. See [evidence/m4-gpu-compile-proof-2026-10-23.md](evidence/m4-gpu-compile-proof-2026-10-23.md) |
| Every RE-gated item is still a placeholder | Gate audit of every sentinel + adversarial self-test that rejects any concrete value | **Yes**, 2026-10-23: `re_gated_placeholders_checked=72`, `forbidden_success_tokens=absent`; `m4-gpu-candidate-self-test.sh` rejects 124 fabrication fixtures (exit 0) |

A result marked **No** is a required check, not a pass. Until its command
output is attached, that property is unproven.

### Hardware- or RE-gated: cannot be proven in this environment

1. **AGX firmware identity.** `apple,firmware-version`, `apple,firmware-compat`
   and `apple,firmware-abi` for the firmware that the Linux boot stub actually
   loads, and the matching versioned `fw/` structure layouts. Those include
   InitData, HwDataA/B, Globals, channels, events and job structures.
2. **DVFS.** Every operating point: frequency, one voltage per cluster and
   power. The ADT-supplied power tunables and leakage coefficients are also
   gated.
3. **Full HwConfig register initialization.** The `GpuCore` firmware enum
   value, `uat_oas`, preemption-buffer sizes, clustering metadata sizes,
   tiling control, HwConfigA/HwConfigB (`da`/`db`), HwDataShared1/2/3 tables
   and curves, Globals fields, `sram_k`, `unk_coef_a`/`unk_coef_b`,
   `global_tab`, `has_csafr`, temperature-sensor masks, firmware I/O
   mappings, and SRAM base/size.
4. **Target resources.** The GPU ASC/SGX register windows and the AGX
   mailbox address and interrupts are not captured here; they must come from
   the registered board ADT. GPU power-domain sequencing, G15 ID-register
   decoding and the loader-populated reserved memory (UAT TTBs, page tables,
   handoff, `hw-cal-a`, `hw-cal-b`, `globals`) need target evidence.
5. **Execution on the GPU under Linux.** The unproven steps run from firmware
   boot and UAT handoff through command submission, fences, faults and
   reset/recovery. They continue to rendering, OpenGL/Vulkan conformance,
   suspend under load and 24-hour stress. There is **no Linux installation on
   this machine** ([native retirement](native-retirement-2026-09-26.md),
   2026-09-26). The official Asahi M3 matrix listed the M3 Pro GPU as **TBA**
   at the [2026-09-03 audit](upstream-support-2026-09-03.md), and the
   repository has no newer check.
6. **Userspace.** No G15 / `usc_gen` 3 shader-compiler or Mesa driver support
   is part of this candidate.

None of these items is inferred from M1/M2 values or from struct-update
inheritance. A compiled module or a DT that compiles does not supply them
either.

## Silicon profile (device-derived)

Source: `config/milestone4-gpu-silicon-profile.tsv`, `format=1`, SHA-256
`54ccc320a331cccb2944f85c280b461d3f763790e52be7529901d2f903a09485`. It was
captured read-only from the macOS IORegistry on a live M3 Pro host
(`host_model=Mac15,7`) on 2026-10-22. It contains identity only, not a
firmware ABI.

| Key | Value | IORegistry provenance |
| --- | --- | --- |
| `ioclass` | `AGXAcceleratorG15X` | AGXAccelerator `IOClass` |
| `gpu_gen` | 15 | `GPUConfigurationVariable.gpu_gen` |
| `gpu_variant` | S | `GPUConfigurationVariable.gpu_var` |
| `usc_gen` | 3 | `GPUConfigurationVariable.usc_gen` |
| `num_cores_physical` | 20 | `GPUConfigurationVariable.num_cores` |
| `num_frags_physical` | 20 | `GPUConfigurationVariable.num_frags` |
| `num_gps` | 8 | `GPUConfigurationVariable.num_gps` |
| `num_mgpus` | 2 | `GPUConfigurationVariable.num_mgpus` |
| `core_mask_list` | `0x1ff,0x1ff` | `GPUConfigurationVariable.core_mask_list` |
| `gpu_core_count_active` | 18 | `gpu-core-count`; two cores fused off |
| `firmware_bundle` | G15 RTBuddy | `AGXFirmwareKextG15RTBuddy` |
| `chip_id` | `0x6030` | SoC identity (T6030) |

The same file lists nine `re-gated` keys with value `UNKNOWN`: firmware
version, firmware ABI, DVFS table, `unk_coef_a`, `unk_coef_b`, `da`/`db`,
HwDataShared tables, preemption sizes and temperature-sensor mask. They stay
`UNKNOWN` here.

The identity was re-checked read-only on 2026-10-22. `sysctl hw.model`
returned `Mac15,7`, under macOS 27.0.1 (26A434). The IODeviceTree root
reported `target-type` J516s and `compatible` `J516sAP`, `Mac15,7`. Its
`chip-id` bytes `30600000` decode little-endian to `0x6030`. The
AGXAccelerator entry returned `IOClass` `AGXAcceleratorG15X` and
`gpu-core-count` 18. `GPUConfigurationVariable` returned `gpu_gen` 15,
`gpu_var` S, `usc_gen` 3, `num_cores` 20, `num_frags` 20, `num_gps` 8 and
`num_mgpus` 2.
`core_mask_list` printed in decimal as `(511,511)`, which is `0x1ff,0x1ff`.
The IORegistry class names include `AGXFirmwareKextG15RTBuddy`. The query also
prints fields that the profile does not carry; none is used. No GPU MMIO,
kernel memory, firmware image or performance table was read.

Interpretation, used only where the driver needs per-cluster maxima:

- The two-entry mask list and `num_mgpus` 2 give two GPU clusters. That
  matches the driver's two-cluster T6020 model.
- Dividing the physical totals by two gives 10 cores, 10 fragment units and
  4 GPs per cluster. Each `0x1ff` mask enables 9 of 10 cores per cluster:
  2 × 9 = 18 active, which agrees with `gpu-core-count`.
- This split is an interpretation, not a register read. At probe the driver
  reads cluster and core counts from SGX ID registers. The G15 decoding of
  those registers is unverified (gated item 4).

Masks and active-core count are per-unit binning values, not SoC constants.
J514s units are also sold in a lower-core-count M3 Pro bin. The candidate
must not hard-code `0x1ff`, 18 or a mask list; the driver reads them at
runtime.

The repository's existing gates name `Mac15,6`/J514s, but this profile's
host reports `Mac15,7`/J516s. Both boards use T6030, so SoC-level identity
(`gpu_gen`, variant, `usc_gen`, physical counts, `num_mgpus`, chip, firmware
family) applies to both. No live J514s capture is recorded here. The earlier
display work used the `j514sap` ADT. GPU work needs the ADT of the board
actually used for bring-up, which is `j516sap` for this host.

The internal disk (`disk0`, read-only `diskutil list`) has only three
partitions: Apple ISC, the 494.4 GB macOS APFS container and Recovery. There
is no Linux root or EFI partition, which is consistent with the retirement
record.

The running macOS version does not set the firmware ABI. The Linux driver
talks to the AGX firmware loaded for the Linux boot stub. The installer
selection recorded in the
[DCP ABI checkpoint](dcp-abi-development-2026-09-06.md) is the
14.8.3 / 23J220 package. The host's 27.0.1 firmware is not
automatically that version, so its version triple must not be copied into
`apple,firmware-*`.

Two earlier records may contain relevant data. Neither is in this public
checkout, and neither was consulted or imported:

- A private Mac15,6 (25G227) SGX IORegistry capture with 14-state performance
  tables ([transfer record](linux-development-transfer-2026-09-10.md)).
- The archived R16 native records, which report GPU firmware initialization
  and one control-queue retirement, but not rendering
  ([retirement record](native-retirement-2026-09-26.md)).

IORegistry performance states are not by themselves a validated Linux OPP
table. Any value from either source must go through
[RE trust](reverse-engineering-trust.md) registration and review before use.

## Device-tree GPU-node candidate (J514s and J516s)

The pinned tree has no GPU node, AGX mailbox, `ps_gfx` consumer or
`apple,firmware-abi` declaration ([M4](milestones/04-gpu.md)).

The session-local T6030 template has these relevant features:

- `pmgr_gfx` at `0x290e80000`, with its child domains in `t6030-pmgr.dtsi`.
- An empty `reserved-memory` node.
- No GPU or AGX mailbox node.

The J514s and J516s board files differ only in model/compatible strings,
touch firmware, Wi-Fi/Bluetooth board type, audio chassis and sound model.
Neither has a GPU delta.

The templates are the base `gpu:` node in `t600x-die0.dtsi` (line 735, with
`agx_mbox` at line 787) and the T6022 `&gpu` override in `t6022.dtsi`
(line 380).

The candidate node belongs in `t6030.dtsi`, or in a GPU fragment that only
`t6030.dtsi` includes, so J514s and J516s inherit the same node. It is
`status = "disabled"`, like the disabled DCP development nodes. No per-board
`&gpu` override is proposed: chassis-specific power tunables would come from
each board's own ADT, and neither ADT is captured here. Because the node is
shared, both board DTBs change, unlike the J514s-only display fragment.

| Property | Candidate rule | Source and status |
| --- | --- | --- |
| `compatible` | `"apple,agx-t6030", "apple,agx-g15x", "apple,agx-g15s"` | Naming candidate from `AGXAcceleratorG15X`, `gpu_gen` 15 and variant S, after the T6022 list. Needs an `apple,agx` binding update; no dt-schema pass is claimed |
| `reg`, `reg-names` | `"asc"`, `"sgx"` | ADT-gated placeholders. The T600x template windows (`0x406400000`, `0x404000000`) must not be copied |
| `mboxes`, `agx_mbox` | `"apple,t6030-asc-mailbox", "apple,asc-mailbox-v4"`; four named IRQs | Compatible follows existing T6030 mailboxes. Address and AIC IRQ numbers are ADT-gated |
| `power-domains` | `<&ps_gfx>` | The label must be confirmed in pinned `t6030-pmgr.dtsi`. GPU power sequencing is unproven |
| `memory-region`, names | `ttbs`, `pagetables`, `handoff`, `hw-cal-a`, `hw-cal-b`, `globals` | Loader-populated. m1n1 T6030 GPU setup is outside this candidate |
| `apple,firmware-abi`, `-version`, `-compat` | Omitted or named sentinel, with `TODO(re)` | RE-gated. `<0 0 0>` is the T600x template's literal ABI value, so it cannot serve as a sentinel |
| `operating-points-v2`, `gpu_opp` | No invented rows | RE-gated: `opp-hz`, two-entry `opp-microvolt`, `opp-microwatt` |
| `apple,*` power tunables, leakage coefficients | Absent until extracted | ADT/RE-gated. T6000/T6022 values are not copied; leakage arrays need two entries |

DT has no checked notion of a placeholder. Text-based readiness checks also
have a limit. The pinned gate greps the source fragments for
`apple,firmware-abi`, `agx_mbox` and `ps_gfx`, and a comment or sentinel would
satisfy those patterns. A readiness check for a candidate tree must inspect
compiled DTB properties and reject every sentinel and missing value. While any
gated item remains, it must report `m4_source_ready=false` and
`hardware_acceptance=false`.

## Driver G15 / t603x hardware-configuration candidate

Facts from the pinned `hw/mod.rs`:

- `GpuGen` has only `G13 = 13` and `G14 = 14`, and is marked part of the
  UABI.
- `GpuCore` is marked part of the firmware ABI and ends at `G14D = 18`.
- `HwConfig` has no T6030 configuration.

The pinned `driver.rs` OF table stops at `apple,agx-t6022`. Probe selects a
`GpuManager` from the generation, variant and `apple,firmware-compat` triple.
Only the 12.3, 12.4 and 13.5 firmware arms exist; any other combination logs
`Unsupported GPU/firmware combination` and returns `ENODEV`.

The candidate adds `GpuGen::G15 = 15` and a `hw/t603x.rs` with
`HWCONFIG_T6030`, matched by `apple,agx-t6030`. A new `GpuGen` value is a UABI
change that userspace must also learn; it is not coordinated upstream. A
`t603x` module name does not satisfy the pinned gate's `t6030` token pattern
in `hw/mod.rs`. That gate does not evaluate patched trees anyway.

| `HwConfig` field | Candidate value | Status |
| --- | --- | --- |
| `chip_id` | `0x6030` | Device-derived |
| `gpu_gen` | `GpuGen::G15` | Device-derived (`gpu_gen` 15) |
| `gpu_variant` | `GpuVariant::S` | Device-derived; existing enum value |
| `gpu_core` | `GpuCore::G15S`, sentinel value | RE-gated firmware enum. `G14D = 18` does not imply the next number |
| `max_num_clusters` | 2 | Derived: `num_mgpus` 2, two-entry mask list |
| `max_num_cores`, `max_num_frags` | 10, 10 | Derived: 20 / 2 |
| `max_num_gps` | 4 | Derived: 8 / 2 |
| `num_dies`, `base_clock_hz` | Not set from a template | Not in profile. The template models one die; confirm both from the target |
| `uat_oas`, `io_mappings`, `sram_base`, `sram_size` | Sentinels | RE/ADT-gated |
| `preempt1_size`, `preempt2_size`, `preempt3_size`, `compute_preempt1_size` | Sentinels | RE-gated |
| `clustering`, `render.tiling_control` | Sentinels | RE-gated |
| `da` (HwConfigA), `db` (HwConfigB) | Sentinels | RE-gated |
| `shared1_*`, `shared2_*`, `shared3_*` | Sentinels | RE-gated HwDataShared tables and curves |
| `idle_off_standby_timer_default`, `unk_hws2_4`, `unk_hws2_24`, `global_unk_54`, `global_tab` | Sentinels | RE-gated |
| `sram_k`, `unk_coef_a`, `unk_coef_b` | Sentinels | RE-gated |
| `has_csafr` | Sentinel | RE-gated |
| `fast_sensor_mask`, `fast_sensor_mask_alt`, `fast_die0_sensor_present` | Sentinels | RE-gated temperature-sensor masks |

Rules for the candidate source:

- Each RE-gated field uses a named constant with this comment:
  `// TODO(re): extract from macOS AGX firmware trace on T6030; NOT a working value`.
  It is never a plausible number.
- `HWCONFIG_T6030` does not use struct-update syntax from a G13/G14
  configuration. `t602x.rs` builds T6021 and T6020 from `HWCONFIG_T6022`,
  which is itself marked `TODO: Tentative`, so inheriting would silently
  import M2 values.
- `usc_gen` 3 has no `HwConfig` field. It identifies the shader-core
  generation for userspace and is recorded for that side only.
- No G15 `GpuManager` is instantiated, because the G15 `fw/` layouts are
  RE-gated. With any compat triple, probe ends in the existing `ENODEV` arm.
  With the property omitted, it fails at the property read instead.

**Failing at dispatch is not side-effect free.** In the pinned `driver.rs`,
probe runs these calls before it reads `apple,firmware-compat` (line 179):

1. `dma_set_mask_and_coherent(DmaMask::try_new(cfg.uat_oas)?)`, line 167.
2. `Resources::new`, line 169.
3. `init_mmio()`, line 172.
4. `start_cpu()`, line 175.

So GPU MMIO is initialized and the GPU coprocessor is started before either
failure. The generation/variant cross-check in `gpu.rs` (line 853) also runs
later. The disabled node is therefore the safety boundary.

A `uat_oas` sentinel outside the range that `DmaMask::try_new` accepts would
stop probe before MMIO. That must be confirmed against the pinned kernel and
covered by a test before anyone relies on it. Any future enablement first
needs a probe-entry check that rejects RE-gated sentinels.

## Path to real proof

1. **Reuse first.** Re-audit the official Asahi M3 matrix, `linux-asahi`,
   `asahi-wip` GPU topics and Asahi Mesa, as
   [the evidence boundary](reverse-engineering-evidence.md) requires. If
   official G15 support exists, consume it and retire this candidate.
2. **Register lawful inputs.** Register two inputs with
   `scripts/register-re-input.sh`:
   - the exact AGX firmware from the boot-stub package the installer selects;
   - the board ADT (`j516sap` for this host; `j514sap` for a J514s unit).

   Then obtain a reviewed `config/re-trust-ledger.tsv` entry. The ledger is
   header-only today.
3. **Trace on T6030 under the m1n1 hypervisor.** In a separately approved
   hardware session with fresh recovery checks, run macOS with matching GPU
   firmware as an m1n1 HV guest. Use m1n1's AGX tracer; confirm its presence
   in pinned m1n1 `60e53e7078c5cb7efce32d64bf50829e9401e44f`. Extract the
   following:
   - the firmware version and ABI triple and the G15 `fw/` structure layouts;
   - InitData, HwDataA/B and Globals values: `da`/`db`, shared tables, curves,
     coefficients, `sram_k`, preemption sizes, tiling control, clustering
     sizes, I/O mappings and temperature-sensor masks;
   - DVFS states and ADT power properties.

   IDA or Binary Ninja analysis may corroborate the trace but cannot replace
   it. Review sanitized traces. Get two-person review for power, DVFS and
   thermal values.
4. **Replace placeholders.** Replace one placeholder at a time, each with
   provenance and a test that rejects the remaining sentinels. Take DT
   resources from the board's own ADT. Add m1n1 T6030 GPU loader support for
   reserved memory, calibration blobs and OPP population. Keep the node
   disabled until the probe-entry check exists.
5. **Bring up Linux natively.** Reinstall without reusing old identifiers,
   credentials or boot commands
   ([retirement record](native-retirement-2026-09-26.md)). Boot the GPU
   firmware first under the m1n1 hypervisor with tracing, then natively. Pair
   that with G15 Mesa userspace.
6. **Pass the M4 human gate.** Supply evidence through
   `scripts/collect-m4-gpu.sh` and `scripts/verify-m4-gpu.sh`:
   - an Apple/AGX renderer with no software renderer, and clean kernel fault
     logs;
   - real OpenGL/Vulkan conformance runs;
   - at least 86,400 stress seconds;
   - reset/recovery, suspend under load and fault injection;
   - two-person review.

   Only that human-reviewed native evidence can change hardware acceptance.
   Nothing in this note can.

## Reproduction

Read-only identity check, from the repository root on the macOS host:

```bash
sysctl -n hw.model
ioreg -p IODeviceTree -l -w0 |
  grep -m3 -E '"(chip-id|target-type|compatible)" = '
ioreg -r -c AGXAccelerator -d 1 -l |
  grep -E '"IOClass"|"gpu-core-count"|"GPUConfigurationVariable"'
ioreg -l | grep -oE 'AGXFirmwareKext[A-Za-z0-9]*' | sort -u
diskutil list disk0
shasum -a 256 config/milestone4-gpu-silicon-profile.tsv
```

The candidate was derived from session-local template copies, which are not
committed:

| Template | SHA-256 | Relation to repository pins |
| --- | --- | --- |
| `drivers/gpu/drm/asahi/driver.rs` | `7a81fbdbd582edff0d30346576d98d842a18977489300ac395928aab8b589a36` | Equals M4 contract |
| `drivers/gpu/drm/asahi/gpu.rs` | `180e48d6ad53349baa59ef34142bc10550fdde1494c86f631866470c9462717d` | Equals M4 contract |
| `drivers/gpu/drm/asahi/hw/mod.rs` | `a95fceff7e41563a7aa0b2365c6e39488e2d4f828c0a20bc2b888b0cb4b1185f` | Equals M4 contract |
| `drivers/gpu/drm/asahi/hw/t602x.rs` | `d540d56a0f9dcc6c71a96828715c5e52dc906b5469e1f5a4323e58990044af60` | Not in any contract |
| `t600x-die0.dtsi` | `81d6804485f7364911c49a407716ed99c1cf80c499e4831c6119d9e0ff4631d8` | Not in any contract |
| `t6022.dtsi` | `70d46fa0f2c2fed2fe98a3550efd1f7629981e7a0129e48c11bcf4ceb7594e4b` | Not in any contract |
| `t6030.dtsi` | `bd832666638df82cd69d7149596c79bdfc52aecb79cf10ea723ffb96c4a10c19` | **Differs** from M2 pin `202e562d…` |
| `t6030-j514s.dts` | `a6122a494fa08d5afdc9d5b4a1bcae2d37a5087040c773f86a602afd7bf41fe9` | **Differs** from M2 pin `5e64f77a…` |
| `t6030-j516s.dts` | `226f58e0762ecece1c05c4ea35516e1d0ffaa4708b4b4da6147d474a8d1a3995` | Not in any contract |

The DT templates come from a different Asahi tree whose commit was not
recorded: its `t6030.dtsi` has 2,073 lines, against the 1,536-line pinned
description in the [upstream checkpoint](upstream-support-2026-09-03.md).
Before any DTB result is claimed, the node must be rebased onto and validated
against pinned `t6030.dtsi`, `t6030-pmgr.dtsi` and `t603x-j514-j516.dtsi`.

## Remaining blockers and next safe work

Every gated item in the boundary section remains open. No firmware, ABI,
DVFS, register, thermal or MMIO value was invented, and none was copied from
an M1/M2 configuration.

Next safe work is offline:

- the reuse audit;
- lawful-input registration;
- a pinned-tree rebase;
- the required build/DT/sentinel checks, with their exact output attached.

Any trace, boot or GPU execution needs a separately approved hardware session
and native Linux. This note does not retire the pinned M4 gate, the
`software-plan-only` M4 bundle status or the native gate.
