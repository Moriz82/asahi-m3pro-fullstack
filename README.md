# M3 Pro downstream Linux platform

Downstream development workspace for the `Mac15,6` / `J514s` / `T6030`
target. Native installation and persistent storage, firmware, boot-policy, or
startup-disk changes are explicitly out of scope. A controlled, non-persistent
tethered boot is in scope only through the Milestone 1 procedure after every
safety and evidence gate passes; its scripts do not make a hardware-success
claim on their own.

The reproducible baseline builds pinned `m1n1`, U-Boot, and Linux fork commits
inside Docker named volumes. Docker Desktop stores those volumes on a
case-sensitive Linux filesystem. Source and intermediate objects stay in the
volumes; hashed artifacts and evidence are written to ignored `out/`
directories.

## Upstream status checkpoint

The current Linux 7.3 claim is scoped in
[`docs/upstream-support-2026-09-03.md`](docs/upstream-support-2026-09-03.md).
Linux 7.3-rc1 contains initial upstream `T6030`/`J514s` device trees, not full
M3 Pro display or GPU support. Hardware work must begin by rechecking current
official Linux and Asahi sources and reusing supported code; reverse
engineering is reserved for a confirmed remaining gap.

Routine documentation and tooling changes use focused syntax, ShellCheck, and
self-tests only. Linux-affecting development uses an isolated output root and
never runs while another M0/Linux build owns the source-volume lock. A
canonical `build-milestone0.sh` plus `verify-milestone0.sh` is the promotion
gate. The clean `rebuild-milestone0.sh` byte comparison is reserved for a major
promotion or handoff.

## Milestone 0 build and verify

The complete reproducible sequence builds the boot chain, full arm64 Linux
`Image`/modules/DTBs, native `make pacman-pkg` aarch64 Arch packages, and the assembled
candidate payload, then runs every verifier:

```bash
./scripts/build-milestone0.sh
./scripts/verify-milestone0.sh
```

The full-kernel stage uses one pinned Arch Linux ARM-native builder for both
the evidence build and `make pacman-pkg`, plus pinned `defconfig` and the in-tree Asahi fragment,
then records config/provenance, source-cleanliness, warning/error inventories,
serialized full unfiltered `dt_binding_check`, parallel full unfiltered
`dtbs_check`, and a forced serialized J514s target check. It preserves raw
DTB/DTBO output, normalizes the kernel `dtbs-list`, and independently runs
native `make INSTALL_DTBS_PATH=... dtbs_install`; the installed tree must
exactly match the normalized kernel list and each installed file must match
the corresponding file in the complete raw DTB/DTBO superset. Packages are
checked against the installed tree, while raw DTBs remain in the evidence. The stage records
inventories and SHA-256 manifests. UAPI headers are produced by a fresh
`headers_install` run on the case-sensitive ext4 Docker volume and published
only as deterministic `headers.tar` (GNU tar sorted by name, source-epoch
mtime, numeric root ownership) with a sorted regular-member inventory rooted
at `usr/include`; no APFS `headers/` tree is accepted. `W=1` is diagnostic, not `Werror`; warnings are retained
and non-target upstream warnings are separately inventoried. The pinned
J514s/T6030 tree currently has known schema debt in WIP subsystems, so its exact
normalized diagnostic block is hash-pinned: any added, removed, reordered, or
changed target diagnostic fails verification. The recorded baseline is not a
hardware-support claim, and each subsystem milestone must retire its relevant
diagnostics before claiming completion. Failed attempts remain outside `latest` for diagnosis.
Linux-full evidence omits `modules_install`'s non-runtime build/source links
and is required to contain no symlinks or empty directories so M0 handoffs
remain portable.
Package provenance records the fork/upstream PKGBUILD commits, but does not
execute the mismatched 7.1.6 PKGBUILD.

The complete `build-milestone0.sh` sequence forces a clean full-kernel object
tree. Direct `build-linux-full.sh` runs remain incremental by default for
development; set `CLEAN_BUILD=1` when a clean direct run is required. The host
allocates each hidden stage and run ID, the container writes only that stage,
and the host verifies it before moving it to the final run directory and
atomically replacing `latest`. Resume and package operations take the same
nonblocking source-volume lock. Each package also carries a tree-derived
`<archive>.closure` inventory of every path, member type, and symlink target;
verification requires the archive to match that independent closure before
extracting it.

The pinned Asahi Linux commit remains the recorded source base. A hash-pinned,
mail-formatted downstream patch under `patches/linux/` fixes two Apple binding
schema diagnostics found by the unfiltered check. The build applies it as a
deterministic commit and records both the base and resulting source-tree commit;
the package build must use that exact clean patched tree.

For an isolated clean rebuild and reproducibility comparison, run:

```bash
./scripts/rebuild-milestone0.sh
```

`MILESTONE0_OUTPUT_ROOT=/absolute/path` and
`SOURCE_VOLUME_OVERRIDE=<exact Docker volume>` may be supplied for isolated
automation. The rebuild script creates and removes only its exact temporary
Docker volume; evidence remains under `out/isolated/rebuild-<run-id>/`.

## Milestone 1 controlled tether workflow

The fail-closed Milestone 1 entry point, prerequisites, dry run, execution
attestation, serial evidence, 20-run session assembly, and return-to-macOS/DFU
requirements are documented in
[`docs/milestones/01-controlled-tethered-boot.md`](docs/milestones/01-controlled-tethered-boot.md).
The execution path remains blocked while native readiness or Milestone 0
artifact verification is incomplete.

## Milestones 0–9 contract and handoffs

The ordered contract map is [config/milestone-contracts.tsv](config/milestone-contracts.tsv).
Milestones M0-M8 have a uniform software-only gate and can emit a canonical,
checksummed handoff only after their named verifier passes. M9 is terminal: it
consumes only those verified M0-M8 handoffs and never emits a new milestone
handoff:

| Milestone | Scope | Document |
| --- | --- | --- |
| M0 | reproducible baseline | [M0](docs/milestones/00-reproducible-baseline.md) |
| M1 | controlled tethered boot | [M1](docs/milestones/01-controlled-tethered-boot.md) |
| M2 | core power | [M2](docs/milestones/02-core-power.md) |
| M3 | display/DCP | [M3](docs/milestones/03-display-dcp.md) |
| M4 | GPU | [M4](docs/milestones/04-gpu.md) |
| M5 | ports | [M5](docs/milestones/05-ports.md) |
| M6 | media/audio | [M6](docs/milestones/06-media-camera-audio.md) |
| M7 | security/accelerators | [M7](docs/milestones/07-security-accelerators.md) |
| M8 | Arch/Hyprland integration | [M8](docs/milestones/08-arch-hyprland-integration.md) |
| M9 | installer/release safety | [M9](docs/milestones/09-installer-release.md) |

`tooling_valid=true` means the software checks ran; a gate dry run reports
`tooling_valid=not-run`, `evidence_valid=not-provided`, and exits 2 with the
native gate blocked. `evidence_valid=true` means the supplied evidence passed
its verifier; `hardware_acceptance=false` means native support is not claimed.
The aggregate static check emits `aggregate_tooling_valid=true` only after all
tooling, self-test, and blocked-gate checks pass. M9 is terminal and accepts
only verified canonical M0–M8 handoffs plus an external, read-only hash anchor.
Keep those nine inputs in a dedicated clean handoff root with exact directory
names `M0` through `M8`; timestamped archives and test outputs must stay in a
different root because M9 rejects every unexpected top-level member.

For a reproducible host-independent check, build `build/Containerfile.static`
and run `scripts/verify-all-software-tooling.sh --static` with the checkout
read-only and a writable disposable `/tmp` root. The test tmpfs is executable
because the adversarial fixtures create isolated fake tool shims; the checkout
and container root remain read-only. The CI workflow uses this same pinned
image and performs no host package installation.

## Historical Milestone 0A baseline

```bash
./scripts/build-m1n1.sh
./scripts/verify-m1n1.sh
./scripts/build-u-boot.sh
./scripts/verify-u-boot.sh
./scripts/build-linux-dtb.sh
./scripts/verify-linux-dtb.sh
./scripts/assemble-boot-payload.sh
./scripts/verify-boot-payload.sh
```

The builds produce `m1n1.macho`, `m1n1.bin`, `u-boot`,
`u-boot-nodtb.bin`, and the `t6030-j514s.dtb` for `Mac15,6`. Evidence includes
exact source and submodule commits, package and tool versions, the container
image ID, build logs, decoded device-tree properties, and SHA-256 checksums.
The assembly step follows U-Boot's Apple documentation and produces the
build-verified, hardware-unverified `u-boot-j514s-candidate.macho` in this
order:

```text
m1n1.macho + t6030-j514s.dtb + u-boot-nodtb.bin
```

These commands do not modify APFS containers, Apple boot policy, firmware,
FileVault, SIP, or the default startup system.

## Milestone 0A scope

Milestone 0A is historical and stops after clean pinned boot-chain artifacts
pass verification. It is intentionally narrower than the full Milestone 0 in
the development plan; it has no full kernel `Image`, module/package build,
`dtbs_check`, or hardware boot result. The
Linux tree contains the `apple,j514s` / `apple,t6030` device tree. U-Boot's
Apple platform accepts the board tree from m1n1 at runtime, so the verified
Linux DTB is included ahead of `u-boot-nodtb.bin`; no duplicate U-Boot DTS is
introduced. The pinned `asahi-releng` U-Boot commit includes the upstream
T6030 memory map and the verifier checks that support in the compiled binary.
Neither milestone is a successful hardware-boot claim. There is no native
installation, startup-disk change, firmware operation, or hardware validation
in these scripts.
