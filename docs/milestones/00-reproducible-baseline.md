# Milestone 0: reproducible baseline

M0 verifies the pinned m1n1, U-Boot, Linux, package, DTB, and assembled-payload
artifacts. It is software tooling evidence only; it does not establish native
boot support.

## Uniform software gate and handoff

The canonical handoff is created only after `scripts/verify-milestone0.sh`
passes. It records `tooling_valid=true`, `evidence_valid=true`,
`hardware_acceptance=false`, and a checksummed copied component snapshot plus
manifest inventory for `Mac15,6` / `J514s` / `T6030`. The native gate remains
blocked.

The Linux full stage retains both the raw DTB/DTBO output and the kernel's
normalized `dtbs-list`. It also runs native `make INSTALL_DTBS_PATH=... dtbs_install`
into a separate tree. The installed inventory must exactly equal that
normalized list; the raw inventory is the complete built-DTB/DTBO superset
and must contain every installed path. All inventories use safe relative
`.dtb`/`.dtbo` paths, include the J514s target, and installed files must be
byte-equal to their raw counterparts. Package verification consumes the
installed tree, while the raw tree remains available for provenance and
comparison.

UAPI headers are generated into a fresh `headers_install` root on the
case-sensitive ext4 Docker volume. The published evidence contains only a
deterministic GNU `headers.tar` whose members are rooted at `usr/include`, plus
`headers.inventory`, a sorted list of regular members. The archive uses sorted
names, source-epoch mtimes, and numeric root owner/group; verifiers reject any
legacy APFS `headers/` directory, unsafe member, or non-file/non-directory
member. Linux full and package verification extract the archive only inside
the pinned Linux builder and compare the API package's case-sensitive
`usr/include` tree byte-for-byte.

`scripts/build-milestone0.sh` forces a clean full-kernel object tree, while a
direct `scripts/build-linux-full.sh` invocation is incremental unless
`CLEAN_BUILD=1` is supplied. Linux-full and package builders write only to a
host-allocated hidden stage. The host verifies that stage before moving it to
its final run-ID directory and atomically updating `latest`; a failed stage is
never selected. Resume and package operations use the same nonblocking lock on
the Linux source volume, so they cannot inspect or package a concurrently
changing build tree.

Package construction derives `<archive>.closure` from each pre-archive package
staging tree rather than from the archive listing. The sorted records bind each
path to its regular-file, directory, or symlink type and bind every symlink
target. Package verification rejects missing, extra, duplicate, unsafe, or
special members and requires an exact archive/closure match before extraction;
the existing byte-level kernel, module, DTB, UAPI-header, and debug checks then
run on that closed member set.

Linux-full evidence omits `modules_install`'s non-runtime `build` and `source`
links and must contain neither symlinks nor empty directories. This keeps
canonical M0 handoffs portable and prevents absolute container-workspace paths
or undeclared directory-only members from entering a bundle.

Verification freezes the physical directories selected by all six `latest`
links (`m1n1`, `u-boot`, `linux-dtb`, `linux-full`, `linux-packages`, and
`boot-payload`) and fails if any pointer changes while the gate is running.
The assembled payload records each source run ID and manifest SHA-256, and the
payload verifier can compare all copied inputs and manifests against those
frozen source directories.

`scripts/rebuild-milestone0.sh` performs its byte comparisons against those
frozen directories, never a moving `latest` path. Its reproducibility claim is
scoped to the release-artifact closure: boot binaries and payload inputs, the
kernel image/vmlinux/System.map/config, complete raw and installed DTB trees,
the complete raw module tree, the deterministic UAPI header archive, and all
four package archives with their closure/inventory reports. Run-specific
manifests are compared only on stable provenance keys; timestamped or
parallel-build diagnostic logs and checksum envelopes containing run IDs are
verified within each run but are not claimed to be byte-identical across runs.
A M0 handoff preserves the original physical run-ID directories under
`source/m0/<component>/<run-id>`.
`source/m0/component-map.tsv` binds each component to that path and its
manifest SHA-256; the map and each resolved snapshot are checked before the
handoff is accepted.
