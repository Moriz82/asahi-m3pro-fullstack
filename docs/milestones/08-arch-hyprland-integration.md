# Milestone 8: Arch/Hyprland integration preview

Milestone 8 defines a deterministic, native-oriented package closure for the
Mac15,6/J514s/T6030 target. The required package list is in
`config/milestone8-required-packages.txt`; each supplied artifact is described
by `packages.tsv`; every artifact must be a real zstd- or xz-compressed Arch
package archive with a matching suffix and exactly one `.PKGINFO` containing
matching `pkgname`, `pkgver`, and `arch` fields:

```
package<TAB>version<TAB>architecture<TAB>sha256<TAB>artifact
```

The tools build an unsigned local preview repository from already supplied
artifacts. They do not download, install, sign, publish, boot, alter the host,
or assert that Arch packages are currently available. The preview repository
is deterministic evidence and is not a pacman repository for direct use.

`verify-m8-upstream-signed-snapshot.sh` separately validates a hash-pinned
Asahi ALARM repository database and its keyring package offline. It derives a
binary verification key from the packaged armored key, verifies both detached
signatures with `gpgv`, requires the externally published full fingerprint,
and checks that signed metadata contains the required Apple-platform package
families. This proves repository provenance and availability only. It does not
make the local preview signed, prove package installation, or prove J514s
hardware support.
With `--packages-dir`, it additionally checks each required package hash from
the signed database and verifies the package's detached signature. Omitting
that option is explicitly reported as `artifacts=metadata-only`.

The closure follows the current target stack: Asahi ALARM provides its Apple
GPU userspace as `mesa`, and current Hyprland uses `aquamarine` as its rendering
backend. The older `mesa-asahi-edge` and `wlroots` package requirements are not
part of this contract. `hyprpaper` is optional desktop decoration, so it is not
required for the minimal tested compositor closure. Fixture versions exercise
the verifier and update/rollback model; they are not an availability promise.

`config/milestone8-platform-coverage.tsv` is the fixed coverage contract. It
names every stack responsibility and keeps the native gate blocked:

| layer | static status | missing evidence or boundary |
| --- | --- | --- |
| boot-chain | not-provided | native boot and recovery proof |
| device-trees | not-provided | target DTB bring-up proof |
| firmware-tooling | not-provided | firmware extraction and trust proof |
| audio-routing | not-provided | PipeWire/WirePlumber route proof |
| speaker-safety | not-provided | J514 DSP and amplifier safety proof |
| platform-services | not-provided | service, suspend, and power proof |
| desktop-session | not-provided | Hyprland session and input/display proof |
| package-rollback | static-snapshot | static repository and rollback evidence only |

Every row has `gate=blocked-pending-evidence` and
`hardware_acceptance=false`. The package-rollback row is a copied directory
snapshot, not a real package transaction. No row is a support or completion
claim.

`verify-m8-package-closure.sh` fails closed on missing or extra packages,
wrong architecture, missing or mismatched artifacts, duplicate metadata,
forbidden VM/software-rendering tokens, unsafe or escaping symlinks, unsafe
paths, non-file device members, package installation metadata, `.INSTALL`
files, and pacman lifecycle hook paths under `usr/share/libalpm/hooks/` or
`etc/pacman.d/hooks/`. Lexically contained relative symlinks and rooted absolute
symlinks that resolve to members of the same package are accepted because real
Arch packages require both; traversal through `..`, unresolved absolute targets,
and forbidden target paths remain rejected. Archive-member
validation requires `bsdtar`. Forbidden archive paths are matched as complete
path components, so generic kernel interfaces such as `qemu_fw_cfg.h` and
`virtio.h`, and unused Mesa modules such as `swrast_dri.so` or
`virtio_gpu_dri.so`, do not falsely identify a package as VM-specific.
Executable paths still reject forbidden-name prefixes such as
`qemu-system-aarch64`. Package names, artifact names, identity/description,
runtime dependencies, provided capabilities, and repository metadata retain
case-insensitive substring checks. Inert build dependencies and negative
`replaces`/`conflict` metadata are not treated as installed capabilities; real
Asahi Mesa uses those fields to displace `vulkan-swrast`. Package contents
establish closure, not the active GPU path; the native M4 renderer gate must
independently prove an Apple/AGX renderer and reject software rendering.
`build-m8-unsigned-repo.sh`
copies verified inputs and the byte-identical coverage contract into a new
output directory and writes unsigned manifest/checksum metadata only.

`simulate-m8-update-rollback.sh` models candidate update and rollback as
static directory snapshots. It never mutates source repositories and records
hashes for the before, candidate, and restored states. Both simulation and
verification require a caller-supplied, read-only external anchor containing
the pinned before-snapshot digest; the anchor must remain outside the output
bundle. The anchor is the trust boundary: the bundle's own regenerated
checksums are not self-tamper-proof.
`verify-m8-update-rollback.sh` requires the restored state to be byte-identical
to the before state, including platform coverage, and rejects altered metadata,
real-transaction status, lifecycle hooks, symlinks, forbidden tokens, and
unsafe actions, even if inner and outer checksums are regenerated without the
matching external pin.

This milestone is software-plan-only: `hardware_acceptance=false`. It does not
claim native Linux support, a bootable Hyprland desktop, package availability,
GPU acceleration, or a Milestone 8 hardware exit. Native installation,
firmware, storage, boot, and compositor acceptance remain human-authorized
future gates after backup/DFU/recovery readiness is proven.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
