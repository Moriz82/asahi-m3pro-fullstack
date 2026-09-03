# Software-only evidence schema

Milestone evidence is a deterministic, static bundle. A bundle contains only
`manifest.txt`, `collection-plan.txt`, `inputs/`, `analysis/`, and
`SHA256SUMS`. The manifest uses fixed `key=value` records, including
`milestone=M2|M3|M4`, `target_model=Mac15,6`, `board=J514s`, `soc=T6030`,
`collection_status=software-plan-only`, and `hardware_acceptance=false`.

`inputs/` contains the required supplied records for the milestone. `analysis/`
contains deterministic reports, including hashes of analyzed logs. Every file
except `SHA256SUMS` has one SHA-256 record. Paths are relative, regular, and
non-symlinked. Existing output directories are never reused.

This schema is evidence that a human supplied a structured plan or observation.
It is not evidence of a native boot, driver support, hardware acceptance,
conformance, or release readiness. The scripts run no native boot, firmware,
GPU, compositor, or hardware command.
