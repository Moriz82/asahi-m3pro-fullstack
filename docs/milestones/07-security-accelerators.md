# Milestone 7: security boundaries and accelerators

M7 packages a reviewed threat-model contract. Collectors accept only explicit
input paths, copy files, and write checksums; they never access SEP, Touch ID,
keys, firmware, PMU, ANE, DMA, or recovery controls.

The contract covers SEP/Touch ID boundaries, key isolation, PMU and ANE,
DMA/firmware trust and rollback, reset, suspend, and multi-user threats. Each
threat has a reviewer, evidence, telemetry, and a structured status. Negative
tests and recovery rows are mandatory, and data loss must be explicitly `no`.
Unsupported capabilities are recorded with a hardware-specific reason and do
not count as acceptance.

`macos-security.tsv` is an exact four-key record: `sip=enabled`,
`filevault=enabled`, `boot_policy=unchanged`, and
`raw_biometric_export=false`. Case/spacing variants, disabled SIP/FileVault,
CSR bypass, biometric/fingerprint template/data/export language, and negative
tests whose actual result is granted/allowed/exported/success are rejected.

Raw biometric/template material, key export, firmware trust bypass, or any
macOS security reduction is rejected. Static verification always reports
`hardware_acceptance=false`; only a separately reviewed, authorized native
execution could change that conclusion.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
