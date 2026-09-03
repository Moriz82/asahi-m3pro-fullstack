#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
readonly evidence="${1:-${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0/u-boot/latest}"
readonly patch_file="${project_root}/patches/u-boot/${UBOOT_PATCH_SERIES}"

test -d "$evidence"
test -f "$patch_file" && test ! -L "$patch_file"
test "$(sha256sum "$patch_file" | awk '{print $1}')" = "$UBOOT_PATCH_SERIES_SHA256"
for required in SHA256SUMS build.log config file.txt manifest.txt packages.txt supported-atc-phys.txt supported-socs.txt u-boot u-boot-nodtb.bin; do
    test -s "${evidence}/${required}" || {
        printf 'Missing evidence file: %s\n' "${evidence}/${required}" >&2
        exit 1
    }
done

(
    cd "$evidence"
    shasum -a 256 -c SHA256SUMS
)

grep -Fx "target=Mac15,6/J514s/T6030" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_commit=${UBOOT_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_tree_commit=${UBOOT_SOURCE_TREE_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_ref=${UBOOT_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_url=${UBOOT_UPSTREAM_URL}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_ref=${UBOOT_UPSTREAM_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_commit=${UBOOT_UPSTREAM_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "patch_series=${UBOOT_PATCH_SERIES}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "patch_series_sha256=${UBOOT_PATCH_SERIES_SHA256}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "defconfig=${UBOOT_DEFCONFIG}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "t6030_memory_map=true" "${evidence}/manifest.txt" >/dev/null
grep -Fx "t8122_atc_phy_match=true" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_clean=true" "${evidence}/manifest.txt" >/dev/null
grep -Eq '^workspace_filesystem=(ext2/ext3|ext2|ext3|ext4|xfs|btrfs|overlayfs)$' \
    "${evidence}/manifest.txt"
grep -Eq '^container_image_id=sha256:[0-9a-f]{64}$' "${evidence}/manifest.txt"
grep -Fx "debian_snapshot=${DEBIAN_SNAPSHOT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "rustup_version=${RUSTUP_VERSION}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "rustup_init_sha256=${RUSTUP_INIT_SHA256}" "${evidence}/manifest.txt" >/dev/null
grep -Eq '^CONFIG_ARCH_APPLE=y$' "${evidence}/config"
grep -Eq '^CONFIG_OF_BOARD=y$' "${evidence}/config"
grep -Eq '^CONFIG_OF_HAS_PRIOR_STAGE=y$' "${evidence}/config"
grep -Eq '^CONFIG_OF_OMIT_DTB=y$' "${evidence}/config"
grep -Eq '^CONFIG_NVME_APPLE=y$' "${evidence}/config"
grep -Fx 'apple,t6030' "${evidence}/supported-socs.txt" >/dev/null
grep -Fx 'apple,t8122-atcphy' "${evidence}/supported-atc-phys.txt" >/dev/null
grep -Eq 'u-boot:.*ELF 64-bit.*ARM aarch64' "${evidence}/file.txt"
test "$(wc -c < "${evidence}/u-boot-nodtb.bin" | tr -d " ")" -gt 200000

printf 'u-boot.baseline=verified\n'
