# T6030 / G15 GPU reverse-engineering progress — 2026-10-23

Progress toward filling the M4 GPU candidate's reverse-engineering-gated fields.
This records **methodology and structural findings only**. Per this project's
policy, raw Apple-internal values (firmware ABI words, `HwConfig` tuning
constants) are held in a private RE store outside this public tree; the public
candidate keeps its sentinels until values are recovered *and* validated on
hardware. Nothing here was executed on a GPU. `hardware_acceptance=false`.

## RE pipeline (built and working)
1. Firmware source: the macOS restore image matching this host exactly
   (`Mac15,7` / 27.0.1 / 26A434), downloaded from Apple's CDN and SHA-1 verified.
2. AGX firmware: the standalone `Firmware/agx/armfw_g15s.im4p` (M3 Pro, variant S)
   extracted and unwrapped to a raw RTKit arm64 Mach-O (two steppings, `a0`/`b0`).
3. GPU kernel driver: `com.apple.AGXG15S` (version **360.34.5**) extracted from
   the `Mac15,6_7` kernelcache with `ipsw` (no AEA decryption required — the
   kernelcache route is in the clear) and analysed in IDA.

## Structural findings (verified; public-safe)
- M3 Pro GPU is the **G15** generation, variant **S** (`AGXAcceleratorG15X`,
  `AGXG15SDevice`). The G15X family has three variants: **G15S** (M3 Pro),
  **G15C** (M3 Max), **G15D** (M3 Ultra); base M3 is G15G. Both J514s (14") and
  J516s (16") are G15S, so one hw-config/firmware covers both display sizes.
- The driver derives active-core count by **population count of the per-cluster
  core-enable mask** (matches the host's `core_mask_list = 0x1ff,0x1ff` → 18 of
  20 physical cores).
- `num_cores`, `gpu-core-count`, `gpu-num-perf-states`, `perf-states-sram` are
  read from the **Apple Device Tree (ADT)** — i.e. they are platform-provided,
  like a device-tree property, not baked into the driver.
- The GPU **DVFS / operating-point table** is supplied by the host to the
  firmware (the firmware reads it from host init-data), confirming it belongs in
  the device tree / ADT path, not in the firmware blob.
- Companion versions: `IOGPUFamily` 162.11, `IOMobileGraphicsFamily-DCP` 343.0.0.

## Recovered privately (held outside this tree)
- The G15S firmware identity and the host↔firmware init-data **interface/ABI
  magic** (the 64-bit word the Linux driver's init-data must match).
- The G15X core-type ID scheme and config-structure offsets.

## Remaining to recover (precisely scoped)
The numeric `HwConfig` tuning constants — `HwConfigA`/`HwConfigB` (`da`/`db`),
`HwDataShared1/2/3` tables, `unk_coef_a`/`unk_coef_b`, `sram_k`, preemption-buffer
sizes, temperature-sensor masks — live in `AGXG15S`. Extracting them correctly
requires resolving the kernelcache's arm64e chained-fixup / PAC pointers in the
**full rebased kernelcache** (the standalone-extracted kext does not map its
`__DATA_CONST` pointer tables reliably). The exact `coreID`↔`S/C/D` table order
is in the same bucket and is deliberately **not asserted** here.

## Hard boundary (unchanged)
Even with every value recovered, the driver cannot be *hardware-proven* in this
environment: there is no Linux installation on this machine and the GPU cannot be
executed, and the M3 Pro GPU remains `TBA` upstream. Recovered values feed the
candidate only through the honesty gate, and `hardware_acceptance` stays `false`
until a real native bring-up validates them. See
[gpu-t6030-acceleration-candidate-2026-10-22.md](gpu-t6030-acceleration-candidate-2026-10-22.md).
