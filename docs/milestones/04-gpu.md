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

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
