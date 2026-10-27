<!--
Proposed replacement for the "## Pinned source state" section of
docs/milestones/04-gpu.md. Merge by hand. The first three paragraphs are the
current section, unchanged; everything after them is new. Do not merge this
comment.
-->

## Pinned source state

The pinned post-patch Linux tree contains and configures the Rust Asahi DRM
driver, including generic command submission, fault handling, crash dumps, and
firmware recovery code. Its device-match table and hardware configuration cover
T8103, T8112, T6000/T6001/T6002, and T6020/T6021/T6022. They contain no T6030
entry. The J514s/T6030 device-tree closure also has no GPU node, AGX mailbox,
GPU power-domain wiring, or GPU firmware-ABI declaration. Existing M1/M2 GPU
support is not evidence for the M3 Pro GPU.

`scripts/check-m4-source-readiness.sh` binds the generic GPU sources to a
five-file SHA-256 contract and reuses the M2 target-source and M0 evidence
contracts. With the current pin it exits 2 and reports
`gate=blocked-target-gpu-driver-and-topology`. This is static source evidence
only; it never probes the GPU or changes hardware acceptance.

The software-plan evidence gate requires one structured `renderer=` record,
exactly one OpenGL and Vulkan plan row with a non-claiming status, and unique
`reset=` and `recovery=` states limited to `planned`, `not-run`, or `blocked`.
These checks reject misleading success claims but still do not validate a GPU.

The [T6030 GPU acceleration candidate](../gpu-t6030-acceleration-candidate-2026-10-22.md)
(2026-10-22) records device-derived identity in
`config/milestone4-gpu-silicon-profile.tsv`. The values were captured
read-only from the macOS IORegistry on a live M3 Pro host:

- `AGXAcceleratorG15X`, `gpu_gen` 15, variant S, `usc_gen` 3;
- 20 physical and 18 active cores in two clusters, with core masks
  `0x1ff,0x1ff`;
- G15 RTBuddy firmware and chip `0x6030`.

That is GPU identity only. The human-only firmware-ABI identification gate
above remains open. The note also describes two development-only candidates:

- a disabled GPU node in `t6030.dtsi`, shared by J514s and J516s;
- a G15 `HwConfig` for the driver.

Across the two candidates, these values are explicit RE-gated placeholders,
not working values:

- firmware version, compat and ABI;
- the DVFS table;
- the HwConfigA/B and HwDataShared values and coefficients;
- the preemption sizes and temperature-sensor masks;
- the MMIO and interrupt resources.

The candidates cannot probe, render or pass conformance. They do not change
the pin, the five-file contract or this gate, which still exits 2. Patched
trees fail the gate's hash contract by design. Builds, DT compilation and
offline tests of the candidate are not hardware support.

Replacing the placeholders requires an m1n1 hypervisor firmware trace on
T6030. Rendering, conformance and stress evidence additionally require a
native Linux installation; the last one was retired on 2026-09-26. The
official M3 matrix still listed the GPU as TBA at the 2026-09-03 audit.
`hardware_acceptance=false`.
