# Reverse-engineering trust boundary

Reverse engineering is an optional, disposable aid for opaque firmware, ABI,
register, and protocol questions. A missing lawful input means do nothing:
the tooling must not discover, fetch, or analyze an unregistered image.

Registration records integrity and provenance metadata only; registration is
not trust, authorization, support, or a hardware result. A repository-reviewed
ledger entry is required before analysis. The ledger is an integrity-checked
review record and is not a substitute for legal authorization.

IDA and Binary Ninja databases, caches, and decompiler output stay in
disposable workspaces. Neither tool is required for a milestone gate, and no
gate may infer support from a database or decompiler result. Keep all output
checksummed and report it as evidence only after human review.
