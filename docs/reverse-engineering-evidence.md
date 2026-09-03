# Reverse-engineering evidence boundary

Reverse engineering is a last-mile activity, not the first source of platform
support. Before opening a binary, recheck the current upstream Linux tree,
official Asahi feature matrix and progress reports, and the relevant
`linux-asahi` or Asahi topic branches. Prefer integrating and validating that
work. Start new analysis only when the exact `Mac15,6` / `J514s` / `T6030`
gap remains after that audit, and record why the public implementation is
absent or insufficient.

`register-re-input.sh` accepts one absolute regular non-symlink input, a
credential-free HTTPS origin, one lawful basis (`public-licensed`,
`user-owned-authorized`, or `public-device-observation`), and one-line
authority and operator fields. It hashes the input before and after copying it
to `out/re/<sha256>`, then writes a mode-read-only manifest, policy, and hash
file. `verify-re-input.sh` detects later tampering.

The registration manifest also records the input SHA-256, byte size and regular
file type, source origin, lawful basis, authority, operator, UTC registration
timestamp, registration ID, registration method, and an explicit
`provenance_trusted=false` state. A manifest and its `SHA256SUMS` file are
self-authored integrity data and cannot establish provenance trust.

Verification uses only the repository-fixed `config/re-trust-ledger.tsv` and
the verifier's pinned digest. Caller-supplied ledger paths or digests are
rejected. A reviewed ledger entry must contain
`registration_id|input_sha256|manifest_sha256`. The production ledger is
header-only, so verification reports
`provenance_trusted=false` and a blocked gate even when file integrity passes.

The result is tamper-evident, not immutable against the same local user. The
tools do not invoke IDA or Binary Ninja. Human reviewers must make disposable
copies in `workspace/ida` or `workspace/binary-ninja` only. Databases and
decompiler output stay inside those workspaces, and access is loopback-only.
Reject private, leaked, confidential, or unreviewed firmware and documents.

Reverse engineering does not by itself establish support. A human-owned
provenance register, lawful-source review, sanitized trace review, two-person
review for high-risk blocks, fault and recovery tests, rollback instructions,
and native hardware evidence remain future gates.
