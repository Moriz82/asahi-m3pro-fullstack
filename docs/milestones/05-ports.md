# Milestone 5: ports, USB, display links, and docks

The M5 collector accepts an explicit input directory and creates a checksummed
`software-plan-only` evidence bundle. It does not enumerate hardware, toggle
power, drive a port, or run a dock test.

`identity.txt` identifies `Mac15,6`, `J514s`, and `T6030`; `kernel.log` and
`iommu.log` are free of panic, lockdep, IOMMU/DART, SError, and similar fault
records. `inventory.tsv` declares `magsafe`, three USB-C ports, `hdmi`, `sdxc`,
and `headphone`. Each needs its own structured test record. Each USB-C port
needs `normal` and `flipped` records for USB2 data, USB3 data, charging,
USB-PD, and role switching. Every physical-port record, including fixed
MagSafe/HDMI/SDXC/headphone records, must be `observed`.

`modes.tsv` binds advertised DP modes to every USB-C port and both supported
orientations; HDMI is bound to its physical port with orientation `n/a`, and
all advertised rows must be observed. `stress.tsv` requires
sustained Thunderbolt I/O, hotplug, unplug under load, suspend/resume, and
over-current/recovery. Thunderbolt rows bind a storage and network device to
every USB-C port and orientation, include duration, byte count, strict equal
`source_sha256`/`destination_sha256` values, zero errors, no data loss, and
hotplug/suspend association. Opaque integrity tokens are rejected. Every record has a unique ID, telemetry, and evidence;
bare `pass`, placeholders, software fallbacks, missing modes, and missing
ports/orientations are rejected.

Static verification always reports `hardware_acceptance=false`; native port,
PD, display, dock, fault-injection, data-integrity, and recovery acceptance
remain human-authorized gates.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
