# M3 Pro downstream Linux platform

Downstream development workspace for the `Mac15,6` / `J514s` / `T6030`
target. Native Mac installation is not part of this preliminary Milestone 0A
boot-chain baseline.

The first reproducible baseline builds pinned `m1n1`, U-Boot, and Linux fork
commits inside a Docker named volume. Docker Desktop stores that volume on a
case-sensitive Linux filesystem. Source and intermediate objects stay in the
volume; hashed artifacts and evidence are written to ignored `out/`
directories.

## Build and verify

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

## Current stop condition

Milestone 0A stops after clean pinned boot-chain artifacts pass verification.
It is intentionally narrower than the full Milestone 0 in the development
plan: there is no full kernel `Image`, module/package build, `dtbs_check`, or
hardware boot result yet. The
Linux tree contains the `apple,j514s` / `apple,t6030` device tree. U-Boot's
Apple platform accepts the board tree from m1n1 at runtime, so the verified
Linux DTB is included ahead of `u-boot-nodtb.bin`; no duplicate U-Boot DTS is
introduced. The pinned `asahi-releng` U-Boot commit includes the upstream
T6030 memory map and the verifier checks that support in the compiled binary.
This is not a successful hardware-boot claim. Building a full kernel, Mesa,
Arch packaging, and any native boot remain separate gated slices.
