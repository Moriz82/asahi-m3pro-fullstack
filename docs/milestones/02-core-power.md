# Milestone 2: core platform and power

The collector validates supplied, structured identity, kernel, thermal/power,
and suspend/resume records for `Mac15,6` / `J514s` / `T6030`. It requires clean
logs and at least 20 successful records in each cycle table. It writes
`collection_status=software-plan-only` and `hardware_acceptance=false`.

This is not native execution or hardware acceptance. Human-only future gates
are clean boot and stress traces, AIC/DART/PMGR/SMC and peripheral audits,
thermal and idle measurements, timeout and fault handling, 20 native
suspend/resume cycles, two-person review, and recovery proof.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
