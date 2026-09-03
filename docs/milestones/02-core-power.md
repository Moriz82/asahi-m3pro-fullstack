# Milestone 2: core platform and power

The collector validates supplied, structured identity, kernel, thermal/power,
and suspend/resume records for `Mac15,6` / `J514s` / `T6030`. It requires clean
logs and at least 20 successful records in each cycle table. It writes
`collection_status=software-plan-only` and `hardware_acceptance=false`.

This is not native execution or hardware acceptance. Human-only future gates
are clean boot and stress traces, AIC/DART/PMGR/SMC and peripheral audits,
thermal and idle measurements, timeout and fault handling, 20 native
suspend/resume cycles, two-person review, and recovery proof.

## Pinned source contract

The pinned downstream Linux tree already contains the J514s/T6030 device-tree
wiring and configured drivers for AIC, DART, PMGR, SMC, SPI, I2C, GPIO, SPMI,
RTC, watchdog, NVMe, PCIe, CPU frequency/idle, suspend, and SMC thermal
telemetry. `config/milestone2-source-files.sha256` binds those source files to
the post-patch M0 source-tree commit. `scripts/verify-m2-source-contract.sh`
also verifies the checksummed, versioned M0 Linux evidence and its merged
configuration. The full M0 verifier remains the canonical M0 validity gate.

Run the verifier read-only inside the pinned Arch image with the source volume
mounted at `/workspace` and the project mounted at `/project`:

```bash
./scripts/verify-m2-source-contract.sh \
  --source-dir /workspace/src/linux \
  --m0-evidence /project/out/milestone0/linux-full/latest
```

The contracted target fragments expose SMC hardware-monitor/fan sensors but
contain no `thermal-zones` or cooling-map policy. The verifier records this as
an explicit gap. Static source/config coverage does not prove runtime function,
safe thermal behavior, suspend/resume, or hardware acceptance. Linux 7.3's
initial mainline T6030/J514s device tree is therefore not a replacement for the
current downstream coverage.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
