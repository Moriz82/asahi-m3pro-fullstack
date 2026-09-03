#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
m0_validate_output_root "$project_root"
readonly evidence="${1:-${MILESTONE0_OUTPUT_ROOT}/milestone0/linux-dtb/latest}"

test -d "$evidence"
for required in SHA256SUMS build.log compatible.txt config dtc.log file.txt manifest.txt model.txt packages.txt t6030-j514s.dtb t6030-j514s.dts; do
    test -e "${evidence}/${required}" || {
        printf 'Missing evidence file: %s\n' "${evidence}/${required}" >&2
        exit 1
    }
done

(
    cd "$evidence"
    shasum -a 256 -c SHA256SUMS
)

grep -Fx "target=Mac15,6/J514s/T6030" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_commit=${LINUX_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_ref=${LINUX_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_url=${LINUX_UPSTREAM_URL}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_ref=${LINUX_UPSTREAM_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_commit=${LINUX_UPSTREAM_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "defconfig=${LINUX_DEFCONFIG}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "dtb_target=${LINUX_DTB}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_clean=true" "${evidence}/manifest.txt" >/dev/null
grep -Eq '^workspace_filesystem=(ext2/ext3|ext2|ext3|ext4|xfs|btrfs|overlayfs)$' \
    "${evidence}/manifest.txt"
grep -Eq '^container_image_id=sha256:[0-9a-f]{64}$' "${evidence}/manifest.txt"
grep -Fx "debian_snapshot=${DEBIAN_SNAPSHOT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "rustup_version=${RUSTUP_VERSION}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "rustup_init_sha256=${RUSTUP_INIT_SHA256}" "${evidence}/manifest.txt" >/dev/null
grep -Eq '^CONFIG_ARCH_APPLE=y$' "${evidence}/config"
grep -Fx 'apple,j514s apple,t6030 apple,arm-platform' "${evidence}/compatible.txt" >/dev/null
grep -Fx 'Apple MacBook Pro (14-inch, M3 Pro, Nov 2023)' "${evidence}/model.txt" >/dev/null
grep -Eq 't6030-j514s\.dtb: Device Tree Blob version 17' "${evidence}/file.txt"
grep -F 'compatible = "apple,j514s", "apple,t6030", "apple,arm-platform";' \
    "${evidence}/t6030-j514s.dts" >/dev/null
test "$(wc -c < "${evidence}/t6030-j514s.dtb" | tr -d " ")" -gt 60000

printf 'linux-dtb.baseline=verified\n'
