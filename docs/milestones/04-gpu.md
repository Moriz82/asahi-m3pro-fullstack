# Milestone 4: GPU acceleration

The collector validates an Apple/AGX renderer declaration without a software
renderer, clean kernel fault logs, structured non-conformance-claim records,
at least 86,400 supplied stress seconds, and reset/recovery text. It performs
no compositor, GPU, firmware, or conformance command and records
`hardware_acceptance=false`.

Human-only future gates include identifying the T6030 GPU and firmware ABI,
power and memory behavior, command submission and synchronization, robust
timeouts, reset and isolation, DRM and Mesa implementation, OpenGL/Vulkan
conformance, suspend under load, fault injection, corruption checks, and
24-hour native compositor/compute stress with two-person review. Software
rendering or an unverified conformance claim cannot pass the milestone.

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

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
