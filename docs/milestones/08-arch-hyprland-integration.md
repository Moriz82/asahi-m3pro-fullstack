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

Arch Linux ARM uses a different trust model: its official policy requires
package signatures but intentionally leaves repository databases unsigned.
`verify-m8-archlinuxarm-package-signatures.sh` therefore pins the published
build-system fingerprint, verifies the keyring package and each required
Hyprland-side package, and records the upstream database policy without
inventing a nonexistent database signature.

`config/milestone8-full-platform-packages.tsv` joins those verified inputs into
one explicit 23-package development contract: the two local M0 kernel packages,
five Arch Linux ARM desktop packages, and 16 Asahi ALARM platform packages.
`build-m8-full-platform-candidate.sh` copies only byte-identical source
artifacts, preserves all 21 available upstream package signatures, catalogs the
four lifecycle files contained in signed packages, binds every source-evidence
digest, and publishes through an atomic no-replace rename. It deliberately does
not create or sign a pacman repository:

```sh
SOFTWARE_OUTPUT_ROOT=/absolute/output-root \
./scripts/build-m8-full-platform-candidate.sh \
  --core-input /absolute/eight-package-input \
  --m0-packages /absolute/m0-linux-package-evidence \
  --asahi-evidence /absolute/asahi-signed-evidence \
  --arch-evidence /absolute/archlinuxarm-signed-evidence \
  --out /absolute/output-root/candidate

./scripts/verify-m8-full-platform-candidate.sh \
  --candidate /absolute/output-root/candidate \
  --core-input /absolute/eight-package-input \
  --m0-packages /absolute/m0-linux-package-evidence \
  --asahi-evidence /absolute/asahi-signed-evidence \
  --arch-evidence /absolute/archlinuxarm-signed-evidence
```

The verifier rechecks both upstream trust paths, the M0 checksum closure, exact
package identity and byte provenance, the full file inventory, lifecycle-file
hashes, and all nested checksums. The artifact stays
`repository_signed=false`, `installation_authorized=false`, `installed=false`,
and `hardware_acceptance=false`. In particular, preserving an upstream
`.INSTALL` file or pacman hook is evidence about package content, not permission
to execute it.

`build-m8-signed-repo.sh` is a separate development-only path for the eight
locally supplied closure packages. Run it in the pinned Arch Linux ARM image,
give it an external GnuPG home and a full fingerprint, and keep that key home
outside both the package input and output roots:

```sh
SOFTWARE_OUTPUT_ROOT=/absolute/output-root \
./scripts/build-m8-signed-repo.sh \
  --input-dir /absolute/package-input \
  --gnupg-home /external/signing-home \
  --signer FULL_FINGERPRINT \
  --out /absolute/output-root/repository

./scripts/verify-m8-signed-repo.sh \
  --repo /absolute/output-root/repository \
  --expected-signer FULL_FINGERPRINT
```

The builder signs every package, creates and signs `repo-add` database and
files archives, exports only the minimal public certificate, verifies the
staged repository, and publishes it with an atomic no-replace rename. The
verifier needs no private key or writable keyring. It binds the repository to
the caller-supplied full fingerprint, verifies all detached and embedded
signatures, checks exact metadata and file inventories, rejects secret-key
packets, and reuses the package-closure verifier. Run
`tests/m8-signed-repo-self-test.sh` inside the pinned image for positive,
public-key-only, tamper, key-substitution, secret-key, inventory, and builder
failure cases.

The separate eight-package signed repository remains `canonical=false`, `published=false`,
`installed=false`, and `hardware_acceptance=false`. It includes only the
current eight-package static closure, not the full platform package set or a
second set of rollback package versions. It therefore closes signing-tooling
coverage only; it does not satisfy the Milestone 8 exit.

`build-m8-signed-rollback-bundle.sh` reuses that primitive for two complete
eight-package sets. It requires every current package version to be strictly
newer than its rollback version according to Arch `vercmp`, signs and verifies
both repositories with the same externally held key, and binds their checksum
manifests in one atomically published bundle. Its outer manifest is explicitly
unsigned and reports `transaction=not-executed`; trust still comes from the
caller-supplied full fingerprint and the signatures inside each repository.
`verify-m8-signed-rollback-bundle.sh` rechecks both repositories, their package
sets, version direction, coverage equality, exact inventory, and nested
checksums without the private key. The fixture-only negative suite is
`tests/m8-signed-rollback-bundle-self-test.sh`.

The bundle proves the signing and rollback-set tooling path only. It is not one
combined pacman database, does not contain real prior-version artifacts yet,
and does not execute an update or rollback. Those remain separate gaps from
the existing static snapshot simulator and native Milestone 8 acceptance.
The point-in-time authoritative-source check and the no-fabrication decision
are recorded in `docs/milestones/08-package-availability-audit.md`.

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
