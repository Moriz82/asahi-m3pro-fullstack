#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/scripts/lib/u-boot-config-overlay.sh"
m0_load_u_boot_config
u_boot_derive_patch_policy
u_boot_require_patch_file "$project_root"
allow_noncanonical_candidate=false
if [[ "${1-}" == --allow-noncanonical-candidate ]]; then
    allow_noncanonical_candidate=true
    shift
fi
[[ $# -le 1 ]] || {
    printf 'usage: %s [--allow-noncanonical-candidate] [EVIDENCE]\n' "$0" >&2
    exit 64
}
readonly allow_noncanonical_candidate
readonly evidence="${1:-${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0/u-boot/latest}"

test -d "$evidence"
required_files=(SHA256SUMS build.log config file.txt manifest.txt packages.txt supported-atc-phys.txt supported-socs.txt u-boot u-boot-nodtb.bin)
if [[ "$UBOOT_PATCH_POLICY" == upstream-integrated ]]; then
    [[ "$allow_noncanonical_candidate" == true ]] || {
        printf 'Candidate U-Boot evidence requires explicit noncanonical verification.\n' >&2
        exit 1
    }
    for value in UBOOT_UPSTREAM_TAG_OBJECT UBOOT_UPSTREAM_TAG_SIGNER UBOOT_UPSTREAM_TAG_SIGNATURE_STATUS UBOOT_REQUIRED_ANCESTOR_COMMITS; do
        test -n "${!value:-}" || {
            printf 'Missing upstream-integrated configuration value: %s\n' "$value" >&2
            exit 1
        }
    done
    [[ "$UBOOT_UPSTREAM_TAG_OBJECT" =~ ^[0-9a-f]{40}$ ]]
    [[ "$UBOOT_UPSTREAM_TAG_SIGNER" =~ ^[0-9A-F]{40}$ ]]
    [[ "$UBOOT_UPSTREAM_TAG_SIGNATURE_STATUS" == blocked-expired-key ]]
    [[ "$UBOOT_REQUIRED_ANCESTOR_COMMITS" =~ ^[0-9a-f]{40}[[:space:]][0-9a-f]{40}[[:space:]][0-9a-f]{40}$ ]]
    required_files+=(upstream-required-ancestors.txt upstream-tag.txt)
fi
for required in "${required_files[@]}"; do
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
grep -Fx 'component=u-boot' "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_url=${UBOOT_URL}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_commit=${UBOOT_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_tree_commit=${UBOOT_SOURCE_TREE_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_ref=${UBOOT_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_url=${UBOOT_UPSTREAM_URL}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_ref=${UBOOT_UPSTREAM_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_commit=${UBOOT_UPSTREAM_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "patch_series=${UBOOT_PATCH_SERIES}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "patch_series_sha256=${UBOOT_PATCH_SERIES_SHA256}" "${evidence}/manifest.txt" >/dev/null
if [[ "$UBOOT_PATCH_POLICY" == upstream-integrated ]]; then
    grep -Fx 'patch_policy=upstream-integrated' "${evidence}/manifest.txt" >/dev/null
    grep -Fx "upstream_tag_object=${UBOOT_UPSTREAM_TAG_OBJECT}" "${evidence}/manifest.txt" >/dev/null
    grep -Fx "upstream_tag_object_sha256=$(sha256sum "${evidence}/upstream-tag.txt" | awk '{print $1}')" \
        "${evidence}/manifest.txt" >/dev/null
    grep -Fx "expected_signer=${UBOOT_UPSTREAM_TAG_SIGNER}" "${evidence}/manifest.txt" >/dev/null
    grep -Fx "signature_status=${UBOOT_UPSTREAM_TAG_SIGNATURE_STATUS}" "${evidence}/manifest.txt" >/dev/null
    grep -Fx "required_ancestor_commits=${UBOOT_REQUIRED_ANCESTOR_COMMITS}" "${evidence}/manifest.txt" >/dev/null
    grep -Fx 'pmgr_auto_enable_early_return=true' "${evidence}/manifest.txt" >/dev/null
    grep -Fx 'hardware_acceptance=false' "${evidence}/manifest.txt" >/dev/null
    grep -Fx 'canonical_promotion=false' "${evidence}/manifest.txt" >/dev/null
    test "$(git hash-object -t tag "${evidence}/upstream-tag.txt")" = "$UBOOT_UPSTREAM_TAG_OBJECT"
    grep -Fx "object ${UBOOT_UPSTREAM_COMMIT}" "${evidence}/upstream-tag.txt" >/dev/null
    grep -Fx 'type commit' "${evidence}/upstream-tag.txt" >/dev/null
    grep -Fx "tag ${UBOOT_UPSTREAM_REF}" "${evidence}/upstream-tag.txt" >/dev/null
    printf '%s\n' $UBOOT_REQUIRED_ANCESTOR_COMMITS | cmp -s - "${evidence}/upstream-required-ancestors.txt"
fi
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

if [[ "$UBOOT_PATCH_POLICY" == upstream-integrated ]]; then
    printf 'u-boot.candidate=verified\n'
else
    printf 'u-boot.baseline=verified\n'
fi
