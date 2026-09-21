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

## Offline log-gate coverage

`scripts/test-common-tools.sh` checks seven synthetic PMGR/DART error messages
against both the shared fault scanner and the kernel-log report generator, plus
nearby benign messages. The error text is bound to the pinned Linux PMGR and
DART source files by `config/milestone2-source-files.sha256`.
`scripts/test-m2-core-power.sh` also rejects a complete structured M2 fixture
containing those errors. Scanner failures and invalid log paths fail closed;
an analysis failure cannot publish a clean report.

This tests evidence handling, not execution of the Linux drivers, real fault
injection, thermal policy, or suspend/resume. The dated reproduction and final
results are in `out/isolated/m2-log-audit-20260905/`; see the
[offline audit](../offline-audit-2026-09-04.md#m2-log-gate-follow-up--2026-09-05).

## Executable driver-source tier

`tests/m2-driver-source-self-test.py` compiles selected **verbatim functions**
from pinned `pmgr-pwrstate.c` and `apple-dart.c`, including their real Linux
polling macros. `tests/m2-driver-self-test.c` substitutes kernel services with
scripted register reads, process-owned register arrays, virtual delays, and
lock accounting. It performs no physical MMIO, module loading, boot, or serial
access. The existing source-volume lock is held shared/nonblocking through
publication; sources and project are mounted read-only. No Linux build occurs.

Use the retained case-sensitive source volume and immutable AArch64 builder
in the exact command recorded in
`out/isolated/m2-driver-source-20260905/README.md`. Inside that isolated container:

```bash
python3 /project/tests/m2-driver-source-self-test.py \
  --source-dir /audit/linux --out /evidence/new-run
```

The output parent must already exist outside the source tree; the destination
must be new. The runner verifies the clean M0 post-patch source pin, M2 file
contract, and six exact Git blobs, then atomically publishes read-only local
evidence in the container's filesystem view: source/harness snapshots, ASan/UBSan runs, separate gcov results,
negative-control logs, and checksums. This is development evidence, not a
canonical M0/M2 handoff or authenticated/tamper-proof hardware evidence.
Docker bind-mount permission changes may not propagate to macOS; verify and
seal host-side modes separately, as recorded in the dated evidence README.

The latest 2026-09-05 run exercises 85 PMGR and 195 DART cases across 12 functions:
power-state register masks, auto-enable/external-clock rules, final poll errors,
reset ordering and lock balance; T8110 stream boundaries/bitmaps, command
timeouts, fault decoding/address assembly, and acknowledgement banks. T8110 is
the contracted T6030 fallback. T8020 cases are shared-driver regression controls,
not a proposed M3 backend. Six deliberate snippet mutations must fail their
intended assertions after compiling successfully: wrong PMGR field, swallowed
final error, propagated preliminary errno, premature abort, ignored DART timeout,
and wrong fault acknowledgement. Original source is never mutated.

Correction to the initial audit: the preliminary forced reset/disable timeout
is **not a proven driver bug**. Generic power-domain callers retain logical ON
after a negative callback and can skip power-on at resume. Returning the earlier
error after a successful final OFF transition would therefore create a state
mismatch. The current diagnostic-and-follow-through policy is coherent with
those callers; 18 new combinations enforce the final transition's return status.
The compiled and installed J514s DTBs also contain zero force properties across
160 PMGR nodes. This strengthens the fragment-only check but does not prove the
runtime-modified tree or hardware behavior. No kernel patch was applied. See the
[caller review and correction](../pmgr-error-policy-2026-09-05.md).

Coverage is deliberately bounded. `apple_pmgr_ps_set`, two IRQ handlers, and
four power/status functions reach 100% gcov blocks; others reach 82–94%.
Harness lock-assertion failure paths contribute uncovered blocks; reset-reset's
error return is unreachable while reset-assert always returns zero. Probe/remove,
regmap write failures, page-table/DMA correctness, real barriers/concurrency,
interrupt timing, hardware register behavior, thermal policy, and suspend/resume
remain untested by this harness. These percentages are not full-driver coverage.
In particular, DART acknowledgement writes are checked, but actual write-one-to-clear
side effects are not simulated.

`tests/m2-driver-runner-self-test.py` tests extraction drift, output safety,
actual shared/exclusive lock behavior, source hygiene, and subprocess failures
using private source-free fixtures. It runs in `scripts/test-m2-core-power.sh`
and the static aggregate; the aggregate explicitly marks the actual C/source
tier as **not run** because clean sources and an AArch64 compiler are required.
Latest source-tier evidence: `out/isolated/pmgr-timeout-review-20260905/`.
Earlier `m2-driver-source-20260905` records remain intact; their preliminary
"known gap" interpretation is superseded by the caller-aware review.

## Read-only firmware metadata tier

`out/isolated/m2-firmware-map-20260905/` retains a dated comparison between
whitelisted macOS IORegistry metadata and the compiled, checksummed J514s DTB.
The existing pinned m1n1 ADT decoder is reused without proxy or hardware setup.
All 75 captured region translations and all 160 Linux PMGR descriptor addresses
agree; 11 negative controls pass. Duplicate virtual names are retained by ID,
not silently merged. This is not a canonical milestone verifier or register trace.

The report keeps differences visible: 12 firmware-virtual DCS nodes exposed by
Linux, 22 parent-list differences, 13 critical/always-on differences, 19 omitted
nonvirtual firmware entries, and an SMC SRAM window not corroborated by the
captured metadata. These are review questions, not proven driver bugs or grounds
for speculative register/DT changes. The dated README explains decoding limits,
exact reproduction, and why address agreement cannot establish hardware safety.

The subsequent `out/isolated/smc-map-provenance-20260905/` source-history check
traces the SMC SRAM tuple to its upstream introduction. It also proves that the
entire initial PMGR file is unchanged except for four later audio external-clock
properties. The observed DCS/parent/always-on policies are not local regressions.
Keep them as M2 source/runtime review questions; do not turn an incomplete
metadata comparison into either a safety certificate or an invented M1 gate.
