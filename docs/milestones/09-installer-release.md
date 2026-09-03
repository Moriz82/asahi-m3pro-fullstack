# Milestone 9: installer and release safety model

Milestone 9 is a deterministic, static release model for the
Mac15,6/J514s/T6030 target. It records the inputs, review gates, and recovery
state transitions needed by a future operator. It does not install Linux,
modify APFS, change firmware or startup policy, reboot, mount a volume, or
execute any host command.

`validate-m9-release-inputs.sh` accepts only a repository-owned M0-M8 canonical
handoff root and an independent, read-only release anchor. Each handoff is
verified before its manifest, full checksum bundle, and anchor pin are copied
into the release. The anchor is deliberately outside the handoff and generated
output trees; regenerating a bundle's own checksums cannot create trust. A
caller-created or chmod-read-only anchor is only an untrusted declarative
integrity pin, never an independent signed authority. M9 has no configured
signed authority and therefore unconditionally keeps the generated release
gate `blocked` and `hardware_acceptance=false`. Genuine native-readiness,
backup/recovery, DFU, and dedicated-target evidence remains a future human
gate.

The command first copies the anchor and every canonical handoff to a private
staging tree, then verifies the copied snapshots and their external hash pins.
Only after those checks pass does it atomically publish a format-2
`release_input_set=canonical-milestone-handoffs` envelope containing the
standard release-input layout: `identity.txt`, `release-inputs.tsv`, and
`manifests/M0` through `manifests/M8`. It also retains the copied canonical
handoffs under `handoffs/M0` through `handoffs/M8` and writes an
anchor-bound `canonical-handoff-map.tsv`. Recovery-plan and state-simulation
verification require that canonical format unconditionally and recheck the
target identity, the exact ordered M0-M8 release-input rows, all false readiness
fields, the map, copied handoff checksums, and independent anchor. A legacy or
forged format-1 release, rehashed false-readiness record, or target-substituted
record cannot enter downstream planning or simulation. A deterministic
test-only pause point lets the self-tests schedule source mutation after a
copied file and prove that it does not change the accepted snapshot. The pause
touches only the private stage and never executes caller-supplied code.

Release, recovery-plan, and simulation builders publish only complete verified
staging directories through the shared OS-level atomic no-replace primitive.
An existing or concurrently claimed destination is preserved and the attempted
publication fails closed.

`simulate-m9-installer-state-machine.sh` consumes only a verified release-input
set, a declarative recovery plan, and a TSV transition trace. It accepts only
the transitions in `config/milestone9-state-transitions.tsv`, rejects unknown,
duplicate, out-of-order, unsafe, or path-escaping records, and emits a
checksummed simulation record. The record may describe staged install,
reinstall, update, rollback, removal, interrupted-install recovery, recovery,
and DFU evidence, but every operation remains `planned` or `observed`; no
execution state is ever created while the release gate is blocked.
`verify-m9-simulation.sh` independently checks the exact output inventory,
symlink/path safety, checksums, semantic trace, blocked state, and exact
caller-supplied release/plan digests. Regenerating `SHA256SUMS` cannot make a
changed state or trace valid.

`create-m9-recovery-plan.sh` and `verify-m9-recovery-plan.sh` produce and check
a declarative recovery plan. It explicitly preserves macOS and requires human
authority, backup proof, and DFU proof without storing secrets or raw commands.
Authority and operator metadata are restricted to short structured identifiers
without whitespace and are checked case-insensitively against the M9 denylist
before any output directory is created.
An external, read-only plan anchor pins the plan checksum for integrity only;
it is explicitly untrusted and cannot authorize execution. The recovery tools
reject mutable or self-authenticated evidence, unsafe actions, APFS/container
targets, macOS removal, missing recovery proof, symlinks, and path escapes.

This terminal milestone is software-plan-only: `hardware_acceptance=false`. It
consumes only verified M0-M8 handoffs and is not permission to perform native
installation or firmware/storage actions or a claim that Linux currently boots
on this hardware.

## Uniform software gate and handoff

The M0-M8 verifiers report `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the corresponding milestone verifier passes; M9 is the terminal consumer and
keeps the native gate blocked.

Handoff creation and verification assume their repository-owned roots remain
private (`0700`) and have no concurrent same-UID writer. The path checks reject
embedded symlinks and physical escapes, but shell pathname operations are not
an OS-level isolation boundary against a process that can rename checked paths.
