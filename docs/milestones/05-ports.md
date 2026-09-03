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

## Pinned source readiness

`scripts/check-m5-source-readiness.sh` binds the M2 target topology plus the
Apple DWC3/ATC PHY, SN201202x PD, USB4/Thunderbolt, UAS, and GL9755 SDHCI
drivers to the pinned source tree. It also requires the corresponding modules
from a checksummed M0 Linux artifact. The supplied source must be the clean Git
worktree root at the exact patched source commit; the canonical check runs
against the case-sensitive Docker source volume rather than the lossy macOS
checkout.

The current pinned tree has three USB-C controller/PHY/connector paths, dual
data and power roles, SN201202x PD nodes, a generic USB4/Thunderbolt source
path, and the board's PCIe GL9755 SDXC node. The isolated M5 development build
proves those configured sources compile; it is not native hardware evidence.
The U-Boot build reuses upstream commit `dbd2154cb0d3` as a hash-pinned patch
on the permitted fork baseline. That commit adds the `apple,t8122-atcphy`
match needed by the T6030 device-tree fallback; compiled U-Boot evidence must
contain the match. The fork base is tied to immutable upstream release tag
`asahi-v2026.04-2`, so movement of the mutable `asahi-releng` upstream branch
cannot silently change provenance.
The target still lacks contracted DP output wiring and HDMI controller/output
topology, so the source gate remains
`blocked-target-display-link-topology`. M3's missing target DCP topology is a
related prerequisite. IDA or Binary Ninja would not close this public-source
topology gap and are not used as substitute evidence.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
