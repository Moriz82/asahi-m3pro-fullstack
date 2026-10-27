# Development-only T6030/G15 Asahi GPU driver candidate

Apply `series` in order to Linux `d8082213fc5a3a64c8b9464a7d5c82d13b1ea115`
(`LINUX_SOURCE_TREE_COMMIT`). The three existing files it changes are
byte-identical in `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`. The series shares
no file with `patches/linux-dcp-development/` or the device-tree series in
`patches/linux-gpu-development/`. Do not apply in the canonical checkout or a
source volume owned by a build. This series is **not selected by any canonical
or development boot builder**.

This is a build/source candidate only. It does not make the M3 Pro GPU render.
It does not claim any conformance result, and nothing in it has been validated
on hardware: `hardware_acceptance=false`. Neither upstream nor Asahi has G15
(M3-family) GPU support; this is local scaffolding toward it.

Everything is behind the new `CONFIG_DRM_ASAHI_G15_CANDIDATE` (default `n`,
`depends on EXPERT`). With it unset, all new code is compiled out and the driver
matches and probes exactly as before. Only source line numbers shift, and with
them the `line!()`-derived device-table symbol name. With it set,
`"apple,agx-t6030"` binds, and probe returns `-ENODEV` for every G15
configuration. It does so before setting the DMA mask, initializing MMIO or
starting the GPU coprocessor.

| Patch | Change |
| --- | --- |
| 01 | `hw/mod.rs`: `GpuGen::G15 = 15`, `GpuCore::G15S` with an RE-gated zero discriminant, gated `mod t603x`. New `hw/t603x.rs` with `HWCONFIG_T6030`. |
| 02 | `driver.rs`: gated `"apple,agx-t6030"` OF entry and the G15 probe refusal. The existing table entries are unchanged. `hw/mod.rs`: gated `pub(crate) use t603x::HWCONFIG_T6030;` re-export, which the OF entry names as `hw::HWCONFIG_T6030`. |
| 03 | `Kconfig`: `DRM_ASAHI_G15_CANDIDATE`. It is added last, so the symbol exists only once the code it enables is complete. No Makefile change is needed. |

`"apple,agx-g15x"` is not matched. The table binds only SoC-specific
compatibles (there is no `"apple,agx-g14x"` entry either), and a family match
would bind the T6030 configuration to other G15X SoCs. `GpuVariant::S` already
exists; no new variant is added. `GpuGen` is part of the UABI. Its `G15` value
exists only under the gate, and no G15 device completes probe, so userspace
cannot observe it.

The mbox `From` lines carry git's all-zero commit ID, because the commits exist
only in a disposable scratch tree. There is intentionally no `Signed-off-by`.
The pinned tree's `Documentation/process/coding-assistants.rst` forbids AI
agents adding one, so the human submitter must certify the DCO. Each patch
carries `Assisted-by: Claude:claude-opus-5-5` in that document's format, plus
this session's `Co-Authored-By` trailer.

## Device-derived identity

Only these values come from `config/milestone4-gpu-silicon-profile.tsv`, which
was read from the macOS IORegistry on a live Mac15,7. The one exception is
`num_dies`, which is **inferred**, not device-derived: the profile has no die
count.

| `HwConfig` field | Value | Source |
| --- | --- | --- |
| `chip_id` | `0x6030` | `chip_id` |
| `gpu_gen` | `GpuGen::G15` (15) | `gpu_gen` |
| `gpu_variant` | `GpuVariant::S` | `gpu_variant` |
| `gpu_core` | `GpuCore::G15S` (name only) | `ioclass` `AGXAcceleratorG15X`, variant S |
| `num_dies` | 1 | **Inferred**, not in the profile: single-die SoC (the pinned `t6030.dtsi` has no die1 nodes) |
| `max_num_clusters` | 2 | `num_mgpus` |
| `max_num_cores` | 10 | `num_cores_physical` 20 / 2 |
| `max_num_frags` | 10 | `num_frags_physical` 20 / 2 |
| `max_num_gps` | 4 | `num_gps` 8 / 2 |

Compile-time asserts check that `core_mask_list` (`0x1ff,0x1ff`) has one mask
per cluster and fits 10 cores per cluster. They also check that the masks total
`gpu_core_count_active` (18). The masks show that `num_cores` counts every
cluster. Treating `num_frags` and `num_gps` the same way is an assumption,
marked `TODO(hw)`. `usc_gen` 3 and the G15 RTBuddy bundle have no `HwConfig`
field and are only documented.

## RE-gated placeholders

Every firmware-facing value is a named `RE_GATED_*` constant. Each one holds
zero or an empty table and carries its own
`TODO(re): extract from macOS AGX firmware trace on T6030; NOT a working value`
label, so no nonzero value can pass for a tuned one. CS/AFR presence is a
`bool`, so it uses the named fail-closed placeholder `HAS_CSAFR_RE_GATED`
instead. Nothing is copied from `t600x`, `t602x` or `t8112`. All items below
are TODO(re).

| Item | Placeholder | Still needed (UNKNOWN until traced) |
| --- | --- | --- |
| `GpuCore::G15S` firmware core type ID | `GPU_CORE_G15S_RE_GATED` (0) | firmware trace, TODO(re) |
| `base_clock_hz` | `RE_GATED_U32` | not in the profile; confirm the T6030 timebase, TODO(re) |
| `uat_oas` | `RE_GATED_U32` | not in the profile; UAT output address size, TODO(re) |
| `preempt1_size`, `preempt2_size`, `preempt3_size`, `compute_preempt1_size` | `RE_GATED_USIZE` | `preempt_buffer_sizes` (UNKNOWN) |
| `clustering` (`meta1_blocksize` to `max_splits`) | `Some(..)` of `RE_GATED_USIZE` | firmware trace: whether G15 uses it, and the sizes, TODO(re) |
| `render.tiling_control` | `RE_GATED_U32` | firmware trace, TODO(re) |
| `da.unk_87c`, `da.unk_8cc`, `da.unk_e24` | `RE_GATED_I32`, `RE_GATED_U32` | `hwconfig_da_db` (UNKNOWN) |
| `db.unk_454`, `unk_4e0`, `unk_534`, `unk_ab8`, `unk_abc`, `unk_b30` | `RE_GATED_U32`, `RE_GATED_U64` | `hwconfig_da_db` (UNKNOWN) |
| `shared1_tab`, `shared1_a4` | `RE_GATED_I32_TABLE`, `RE_GATED_U32` | `hwdata_shared_tables` (UNKNOWN) |
| `shared2_tab`, `shared2_unk_508` | `RE_GATED_I32_TABLE`, `RE_GATED_U32` | `hwdata_shared_tables` (UNKNOWN) |
| `shared2_curves` (`t1_coef`, `t2`, `t3_coefs`, `t3_scales`) | `RE_GATED_U32`, `RE_GATED_I16_TABLE`, `RE_GATED_U32_TABLE` | `hwdata_shared_tables` (UNKNOWN) |
| `shared3_unk`, `shared3_tab` | `RE_GATED_U32`, `RE_GATED_U32_TABLE` | `hwdata_shared_tables` (UNKNOWN) |
| `idle_off_standby_timer_default`, `unk_hws2_4`, `unk_hws2_24`, `global_unk_54` | `RE_GATED_U32`, `[RE_GATED_F32; 8]`, `RE_GATED_U16` | firmware globals trace, TODO(re) |
| `sram_k` | `RE_GATED_F32` | firmware trace, TODO(re) |
| `unk_coef_a` | `RE_GATED_COEFS` | `hwconfig_unk_coef_a` (UNKNOWN) |
| `unk_coef_b` | `RE_GATED_COEFS` | `hwconfig_unk_coef_b` (UNKNOWN) |
| `global_tab` | `Some(RE_GATED_U8_TABLE)` | firmware trace, TODO(re) |
| `has_csafr` | `HAS_CSAFR_RE_GATED` = `true`: fails closed, not a determination | firmware/ADT trace, TODO(re) |
| `fast_sensor_mask`, `fast_sensor_mask_alt`, `fast_die0_sensor_present` | `RE_GATED_U64`, `RE_GATED_U32` | `temp_sensor_mask` (UNKNOWN) |
| `io_mappings` | `RE_GATED_IO_MAPPINGS` (empty) | firmware trace: bases, sizes, slot order, TODO(re) |
| `sram_base`, `sram_size` | `Some(RE_GATED_USIZE)` | firmware trace, TODO(re) |

The following stay gated and are **not represented** by this series:

- **G15 firmware ABI.** There is no `apple,firmware-compat` value, versioned
  firmware structure or `GpuManager` for G15, and no G15 arm in the probe
  dispatch. TODO(re).
- **G15 register decoding in `regs.rs`.** This covers the SGX `ID_VERSION`
  generation and variant encoding and the core-mask and fault register layouts.
  Unknown generations stay rejected. `get_fault_info()` chooses the register
  layout by `GpuCore` ordering, which is unvalidated for G15. TODO(re).
- **Device-tree values** belong to `patches/linux-gpu-development/`:
  - `apple_firmware_version` (UNKNOWN): `apple,firmware-version`.
  - `apple_firmware_abi` (UNKNOWN): `apple,firmware-abi`.
  - `gpu_opp_dvfs_table` (UNKNOWN): the DVFS operating points.
  - Leakage coefficients and power tunables, TODO(re).
- **Bindings.** The `"apple,agx-g15x"` family match and the `apple,agx.yaml`
  binding are not added.

## Verification

Every check here ran on the host and is static. Nothing was built for or run on
the target.

- **Replay.** `git am --whitespace=error-all` applies 01–03 cleanly to a full
  checkout reset to `77cb8f24`, after `patches/linux-gpu-development/`. The
  resulting files hash to:
  `Kconfig` `958f7ae1bab38874ca04e6d476ba0cdafc8904758069e28ce1bee0738fe0925c`,
  `driver.rs` `205c1742d9c2f16e6837cb34500fb916efc2e239fa2a717abb7b837a3c27d4d3`,
  `hw/mod.rs` `f2931c98079afd3bba0eda91e9db552a6500b3a0f57ba9b2ff73081363fdf5f8`
  and `hw/t603x.rs`
  `b61abffcd7baffda0934c4fc8493ade49e1c133e8e32a1ae875187b2cadc8974`.
  `Makefile` and `gpu.rs` are unchanged.
- **Repository gate.** `scripts/verify-m4-gpu-source-candidate.sh --static`
  ran over this series together with `patches/linux-gpu-development/`. It
  reports `tooling_valid=true`, `re_gated_placeholders_checked=51`,
  `forbidden_success_tokens=absent` and `hardware_acceptance=false`, and exits
  2 (`gate=blocked-for-native-execution`), as designed.
- **Formatting.** `rustfmt --edition 2021 --check` (rustc 1.95.0), using the
  pinned `.rustfmt.toml`, passes for `hw/t603x.rs`, `hw/mod.rs` and `driver.rs`.
- **checkpatch.** `scripts/checkpatch.pl --no-tree --strict` reports no code
  findings. Each patch shows the intentional missing-`Signed-off-by` error and
  two warnings about the `Co-Authored-By` spelling. Patch 01 also shows the
  informational MAINTAINERS note; the pinned MAINTAINERS has no
  `drivers/gpu/drm/asahi/` entry.
- **Type-check harness.** This was a disposable harness and is not committed.
  It ran on the previous revision, which named `hw::t603x::HWCONFIG_T6030`
  directly, and was **not re-run** after the `hw/mod.rs` re-export was added. A
  standalone `#![deny(warnings)]` model of the re-export (gated module, gated
  `pub(crate) use`, table entry naming `hw::HWCONFIG_T6030`) builds on rustc
  1.95.0 with the gate off and on, with no unused-import warning.
  It combines a stub `kernel` crate (including the pinned `of_device_table!`
  macro, copied verbatim), the real patched `hw/` module, and the exact
  OF-table and probe-prologue text extracted from `driver.rs`. The `float` and
  `fw::types` macro layout mirrors the real crate. It ran on rustc 1.91.1 and
  1.95.0 for every commit, with the gate off and on; the pinned minimum is
  1.85.0.
  - **Gate off:** for every commit, warnings match the unpatched base exactly,
    and the OF table keeps its 8 entries.
  - **Gate on, after 02 and 03:** warnings match the base exactly. There are 9
    entries. The T6030 entry returns `-ENODEV` before the DMA-mask line; the
    other 8 pass through. Every RE-gated field reads back as zero or empty.
  - **Patch 01 alone with the gate forced on:** it leaves dead code. That state
    is unreachable, because the Kconfig symbol exists only from 03.
  - **Mutations:** four mutated identity constants (a core mask, the active
    count, the GP count and the mask count) each fail the compile-time asserts.

**Not done:** no kernel or `W=1` module build; no clippy, rustdoc or bindgen
run; no `dt-schema` check; no device-tree change; no M0 or M4 evidence; no
boot; no hardware.

## Effect on the M4 gate

`config/milestone4-source-files.sha256` pins the unpatched bytes. A tree with
this series applied fails that contract by design: `Kconfig`, `driver.rs` and
`hw/mod.rs` hash differently, so `scripts/check-m4-source-readiness.sh` stops
before reporting readiness. This series does not update the contract.

Grepping that script's six static predicates over a checkout with this series
and `patches/linux-gpu-development/` applied gives:

| Predicate | Value | Why |
| --- | --- | --- |
| `target_t6030_device_match` | true | `"apple,agx-t6030"` OF entry in `driver.rs` |
| `target_t6030_hw_config` | true | `hw/mod.rs` names `"apple,agx-t6030"` in the comment on the gated `HWCONFIG_T6030` re-export. The module itself is named `t603x`, and `HWCONFIG_T6030` alone does not match the case-sensitive `t6030` pattern. |
| `target_gpu_node` | true | DT patch 03's `&gpu` compatible in `t6030.dtsi` |
| `target_gpu_mailbox` | false | `agx_mbox` is in `t6030-gpu.dtsi`, which the gate does not scan |
| `target_gpu_power_domain` | false | same file |
| `target_gpu_firmware_abi` | false | same file. Its value is an RE-gated all-zero sentinel. |

The script never reaches these predicates on a patched tree, because the
contract check above fails first. If it did, it would still report
`m4_source_ready=false` and `gate=blocked-target-gpu-driver-and-topology`. A
static match is not evidence of a working GPU.
