# Development-only T6030 AGX GPU device-tree candidate

**Unverified source candidate. `hardware_acceptance=false`.** This series does
not make the M3 Pro GPU probe, start firmware or render. It passes no OpenGL or
Vulkan conformance test, establishes nothing about the hardware and is not M4
evidence. No M3-family (G15) GPU support exists in the pinned driver, the
pinned binding or m1n1.

Apply `series` in order to Linux `77cb8f24c2381a8abb7272d7bbdec548d6426a8a` or
its schema-only patched tree `d8082213fc5a3a64c8b9464a7d5c82d13b1ea115`.
`patches/linux/0001` changes only bindings and `asahi.config`, so both bases
take the series unchanged. Apply only to a disposable export, never the
canonical checkout or a source volume owned by a build. This series is **not
selected by any canonical or development boot builder**. The patches are
mail-formatted (`git format-patch --zero-commit`), and this README serves as the
cover letter.

## Patches

Patch 01 adds `arch/arm64/boot/dts/apple/t6030-gpu.dtsi`, modelled on the
`gpu`/`agx_mbox` nodes of `t600x-die0.dtsi`, `t602x-die0.dtsi` and
`t8112.dtsi`:

- A base `gpu: gpu@0` node with `compatible = "apple,agx-g15s"`,
  `reg-names = "asc", "sgx"` and `mboxes = <&agx_mbox>`. It also has
  `power-domains = <&ps_gfx>`, the six `uat_*`/`gpu_hw_cal_*`/`gpu_globals`
  memory regions with the binding's names, the three firmware triples and
  `operating-points-v2 = <&gpu_opp>`.
- An `agx_mbox: mbox@deadbeef` node that follows the four existing T6030 ASC
  mailboxes (SMC, AOP, MTP, ANS): `"apple,t6030-asc-mailbox",
  "apple,asc-mailbox-v4"`, `interrupt-parent = <&aic>` and AIC3 three-cell
  `<AIC_IRQ n IRQ_TYPE_LEVEL_HIGH>` specifiers named send-empty, send-not-empty,
  recv-empty and recv-not-empty.
- Six reserved-memory placeholders and a one-entry sentinel `gpu_opp` table.

The two device nodes and all six reserved-memory nodes are `status = "disabled"`.
Nothing includes the file yet, so patch 01 changes no DTB.

Patch 02 appends `#include "t6030-gpu.dtsi"` to `t6030.dtsi`, after
`t6030-pmgr.dtsi`. That file defines `ps_gfx` at `pmgr_gfx` (`0x290e80000`)
offset `0x110`, whose parents are the always-on `ps_gpx` and `ps_afr`. Both
`t6030-j514s.dts` (14-inch) and `t6030-j516s.dts` (16-inch) already include
`t6030.dtsi`, so both boards gain the same disabled nodes and neither board file
changes. This is deliberately unlike DCP patch 11, which wired a J514s-only
display topology. The GPU is SoC-level hardware.

Patch 03 adds the per-SoC override to `t6030.dtsi`, mirroring the pinned
`t6020.dtsi`:

```dts
&gpu {
	compatible = "apple,agx-t6030", "apple,agx-g15x", "apple,agx-g15s";
};
```

## Compatible strings

Each string comes from a `device-derived` row of
`config/milestone4-gpu-silicon-profile.tsv`:

| String | Profile source | Pinned precedent | Confidence |
| --- | --- | --- | --- |
| `apple,agx-t6030` | `chip_id 0x6030` | `driver.rs` keys every HwConfig on `apple,agx-<soc>`; `t6020.dtsi` | Form is certain. No driver entry exists. |
| `apple,agx-g15x` | `ioclass AGXAcceleratorG15X` | `apple,agx-g14x` in `t6020/t6021/t6022.dtsi` | **Inferred.** Nothing in the pinned tree ties `g14x` to the `AGXAcceleratorG14X` IOClass. `t6000.dtsi` uses `apple,agx-g13x` alone, without a variant string. |
| `apple,agx-g15s` | `gpu_gen 15`, `gpu_variant S` | `apple,agx-g13s`/`-g14s` base strings | Follows the generation-plus-variant pattern. |

The pinned `Documentation/devicetree/bindings/gpu/apple,agx.yaml` enumerates
only `g13g/g13s/g14g/g14s` and `c|d` + `s` pairs. It describes none of the pinned
T6020–T6022 lists and no G15 string, so dt-schema validation is not claimed. If
upstream adopts different G15 names, follow upstream. Dropping the family
string, as `t6000.dtsi` does, was considered and not chosen because the closest
analogue, the M2 Pro `t6020.dtsi`, keeps it.

## Gated values

Every unknown is a named macro at the top of `t6030-gpu.dtsi`, each preceded by
its own `TODO(...)` line ending `NOT a working value`. All sentinels are zero,
matching the existing "loader fills this" convention for `<0 0 0>` triples,
except the mailbox `reg` base. That is the poison word `0xdeadbeef` with size
zero, which the repository gate accepts as a sentinel. It exists only so that
`agx_mbox` has a unit address distinct from `gpu@0` (see the ADT-gated notes
below). None is a plausible hardware value.

**RE-gated** (`RE_GATED_*`, `TODO(re)`). These must be extracted from a trace of
Apple's GPU firmware or macOS AGX driver on T6030, which is not available here.
Every `re-gated` row of the silicon profile stays UNKNOWN:

| Profile row | Lands in | This series |
| --- | --- | --- |
| `apple_firmware_version` (UNKNOWN) | `apple,firmware-version`, `apple,firmware-compat` | `RE_GATED_T6030_AGX_FIRMWARE_VERSION`, `RE_GATED_T6030_AGX_FIRMWARE_COMPAT`, TODO(re) |
| `apple_firmware_abi` (UNKNOWN) | `apple,firmware-abi` | `RE_GATED_T6030_AGX_FIRMWARE_ABI`, TODO(re) |
| `gpu_opp_dvfs_table` (UNKNOWN) | `gpu_opp` | `RE_GATED_T6030_AGX_OPP_HZ`, `_OPP_MICROVOLT`, `_OPP_MICROWATT`, TODO(re) |
| `hwconfig_unk_coef_a` (UNKNOWN) | driver HwConfig | not in this DT series, TODO(re) |
| `hwconfig_unk_coef_b` (UNKNOWN) | driver HwConfig | not in this DT series, TODO(re) |
| `hwconfig_da_db` (UNKNOWN) | driver HwConfigA/HwConfigB | not in this DT series, TODO(re) |
| `hwdata_shared_tables` (UNKNOWN) | driver HwDataShared1/2/3 | not in this DT series, TODO(re) |
| `preempt_buffer_sizes` (UNKNOWN) | driver HwConfig | not in this DT series, TODO(re) |
| `temp_sensor_mask` (UNKNOWN) | driver HwConfig sensor masks | not in this DT series, TODO(re) |

`apple,firmware-compat` is read in `driver.rs` probe. It is a firmware triple of
the same RE-gated kind. The number of performance states is also unknown.
Upstream `opp00` with `opp-hz = 0` is a real off state, but this `opp00` is only
a sentinel. No M1 or M2 frequency, voltage or power is copied. `opp-microvolt`
has two cells. That width is inferred from `core_mask_list` (two entries),
matching the `t6020`/`t6000` `GPU_REPEAT` precedent, and is not itself a
profile value. Whether G15 firmware consumes one voltage per cluster, as the
G13/G14 model does, is RE-gated.

**ADT-gated** (`ADT_GATED_*`, `TODO(adt)`). These are derivable from the target
Apple Device Tree but are absent from this environment and from the silicon
profile:

| Macro | Property | ADT source |
| --- | --- | --- |
| `ADT_GATED_T6030_AGX_ASC_REG` | `gpu` `reg` "asc" | `/arm-io/gfx-asc` |
| `ADT_GATED_T6030_AGX_SGX_REG` | `gpu` `reg` "sgx" | `/arm-io/sgx` |
| `ADT_GATED_T6030_AGX_MBOX_REG` | `agx_mbox` `reg` | gfx-asc mailbox window |
| `ADT_GATED_T6030_AGX_IRQ_*` (four) | `agx_mbox` `interrupts` | gfx-asc mailbox IRQs |

The `pmgr_gfx` address does not determine these windows. On T8103/T8112,
`ps_gfx` is in the main PMGR at `0x23b700000` while the GPU windows are at
`0x206400000`/`0x204000000`. T600x/T602x use `0x406400000`/`0x404000000`. Every
pinned AGX node puts the mailbox at asc + `0x8000`/`0x4000` and uses `0x40000`
(asc) and `0x1000000` (sgx) sizes. Treat those as hypotheses to check against
the ADT, not as T6030 values. The unit addresses are therefore sentinels until
the ADT bases replace them: `gpu@0` follows its zero `reg`, and
`mbox@deadbeef` follows the poison mailbox `reg`. Sharing `@0`, as the first
revision did, is a dtc `unique_unit_address` warning in a plain full-board
build. A unit address that differs from the `reg` base, such as `mbox@1` over a
zero `reg`, swaps that for a `simple_bus_reg` warning. `0xdeadbeef` is not a
mailbox address and must not be read as one.

**Deliberately absent.** The power and thermal tuning that `PwrConfig::load`
reads is absent: `apple,perf-*`, `apple,ppm-*`, `apple,pwr-*`,
`apple,avg-power-*`, `apple,fast-die0-*`, `apple,min-sram-microvolt`,
`apple,power-sample-period`, `apple,core-leak-coef` and `apple,sram-leak-coef`.
Several are mandatory, so a future driver fails closed instead of running on
M1/M2 numbers. Whether G15 uses CS/AFR tables (`apple,cs-opp`, `apple,afr-opp`)
is unknown. `ps_gfx` depending on `ps_afr` does not establish firmware use.

**Reserved memory.** The pinned T602x/T8112 trees keep `uat_*` enabled with
`reg = <0 0 0 0>`. Here all six placeholders are disabled and have no `reg`.
Upstream m1n1's `dt_set_resvmem()` sets both `reg` and `status = "okay"` when it
fills a region. Until then, nothing is reserved. Omitting `reg` also avoids
three W=1 `unit_address_vs_reg` warnings.

## Driver, loader and gate state

- The pinned `driver.rs` OF table covers T8103 through T6022. `hw/mod.rs`
  `GpuGen` has only G13/G14. Nothing binds to these nodes.
- Upstream m1n1 `7cde7d1a784d851ebfee5579fa363c38b14150c0` (2026-10-19) was
  inspected read-only. Its `dt_set_gpu()` has no T6030 case: it prints
  `ADT: GPU: unsupported chip!` and returns before touching the FDT. The repo pin
  `60e53e7` was not available locally to confirm the same. The series
  deliberately omits the `gpu` alias that m1n1 uses to find and fill the node.
- `scripts/check-m4-source-readiness.sh` is unchanged. Patches 02/03 modify
  `t6030.dtsi`, which `config/milestone2-source-files.sha256` hash-pins. On a
  patched fixture, the gate stops at
  `M2 source hash mismatch: arch/arm64/boot/dts/apple/t6030.dtsi` with exit 1.
  An unpatched fixture passes the hash checks and stops only at the missing M0
  evidence. No contract is updated, so `m4_source_ready` cannot become true from
  this series.
- The gate's static greps scan only `t6030-j514s.dts`, `t6030.dtsi`,
  `t6030-pmgr.dtsi` and `t603x-j514-j516.dtsi`. With this series and
  `patches/linux-gpu-development-driver/` applied, `target_gpu_node` is true
  (patch 03's `&gpu` compatible in `t6030.dtsi`). `target_gpu_mailbox`,
  `target_gpu_power_domain` and `target_gpu_firmware_abi` stay false, because
  `agx_mbox`, `power-domains` and `apple,firmware-abi` live in the unscanned
  `t6030-gpu.dtsi`. That is deliberate: moving sentinel-valued properties into
  scanned files would only make the greps count placeholders.
- The gate's `target_gpu_firmware_abi` check only greps for a property name. If
  the gate is ever extended to scan `t6030-gpu.dtsi`, it must reject any
  `RE_GATED_*`/`ADT_GATED_*` sentinel, a disabled GPU node and an all-zero
  firmware triple, rather than count their presence.

## Validation performed (2026-10-22, macOS, outside kbuild)

- **Patch application.** `git am --whitespace=error-all` of `series`, followed
  by the driver series, applies cleanly to a full checkout reset to `77cb8f24`.
  The `t6030.dtsi` preimage blob is `efa9e577`.
- **DTB builds.** Both board DTBs were rebuilt for this revision with Homebrew
  `DTC 1.8.1` and the `scripts/Makefile.dtbs` `cmd_dtc` cpp and warning flags at
  the default, W=1 and W=12 levels. As a control, both unpatched DTBs reproduce
  the checksums the first revision recorded with the pinned tree's own
  `scripts/dtc` (`DTC 1.7.2-g53373d13`). J514s matches the recorded M0 checksum
  `3a1e59f7…` from `docs/pmgr-error-policy-2026-09-05.md`.

| DTB SHA-256 | Base | After 01 | After 02 | After 03 |
| --- | --- | --- | --- | --- |
| J514s | `3a1e59f79d84…` | unchanged | `ab9e76637345…` | `97c56a84e93f…` |
| J516s | `66bb436db29a…` | unchanged | `ea2da1a77fe5…` | `562db36ee879…` |

- **Decoded DTBs.** Each board gains exactly ten nodes: `/opp-table-gpu`, its
  `opp00`, six `/reserved-memory` children, `/soc/gpu@0` and
  `/soc/mbox@deadbeef`. In label-preserving `dtc -O dts -s` output, no existing
  line is removed except renumbered `phandle` values, and `ps_gfx` gains a
  phandle. Patch 03 changes only the `gpu@0` compatible.
- **DTC warnings.** A plain full-board `dtc` build with every default check
  reports the same seven warnings per board as the unpatched tree, with
  identical text, so the series adds none. The first revision's `gpu@0`/`mbox@0`
  pair added an eighth (`unique_unit_address`). With the kbuild flags, the
  default level has zero warnings and W=1 (7) and W=12 (11) are byte-identical
  before and after on both boards.
- **Stacked on the DCP series.** The first revision (`mbox@0`) was also stacked
  on the DT hunks of DCP patches 11, 12 and 14 (`git apply --include`). J514s
  kept the same nine W=1 warnings and gained the same ten nodes, and J516s
  matched the standalone result. That stack was not re-run for this revision.
- **Not performed.** No kbuild or full kernel build, `dtbs_check`/dt-schema, m1n1
  boot, driver probe or hardware run was done.

Reproduce the DTB step from a patched disposable export, with `scripts/dtc/dtc`
built for the host:

```bash
cd /absolute/disposable/export
for b in t6030-j514s t6030-j516s; do
  cc -E -nostdinc -I scripts/dtc/include-prefixes -undef -D__DTS__ \
    -x assembler-with-cpp -o "$OUT/$b.dts.tmp" "arch/arm64/boot/dts/apple/$b.dts"
  scripts/dtc/dtc -o "$OUT/$b.dtb" -b 0 -i arch/arm64/boot/dts/apple \
    -i scripts/dtc/include-prefixes -Wno-unique_unit_address \
    -Wunique_unit_address_if_enabled "$OUT/$b.dts.tmp"
done
```

## Remaining blockers and next safe work

1. Translate `/arm-io/gfx-asc` and `/arm-io/sgx` resources and the mailbox IRQs
   from the saved target ADTs, as the display topology was. Check that J514s and
   J516s agree, and add DT tests that reject mutated windows and IRQ order.
2. Use reviewed macOS AGX tracing on T6030 to establish the G15 RTBuddy firmware
   version, ABI and compat triples, the DVFS states, CS/AFR use and all driver
   HwConfig tables.
3. Driver: `GpuGen::G15` is a UABI change. A T6030 HwConfig module, an
   `apple,agx-t6030` OF entry and a firmware-ABI manager belong in a separate
   series.
4. Loader: add a T6030 case to m1n1 `dt_set_gpu()`, and only then add the `gpu`
   alias and drop `status = "disabled"`.
5. Binding: add G15 strings to `apple,agx.yaml` under review.
6. Gate: extend the M4 gate with sentinel rejection and a reviewed contract
   update before any of this counts toward `m4_source_ready`.
