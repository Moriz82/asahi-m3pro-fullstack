#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
m0_validate_output_root "$project_root"
readonly evidence="${1:-${MILESTONE0_OUTPUT_ROOT}/milestone0/m1n1/latest}"

test -d "$evidence"
for required in SHA256SUMS build.log file.txt m1n1.bin m1n1.macho manifest.txt packages.txt submodules.txt; do
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
grep -Fx "source_commit=${M1N1_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_ref=${M1N1_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_url=${M1N1_UPSTREAM_URL}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_ref=${M1N1_UPSTREAM_REF}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "upstream_commit=${M1N1_UPSTREAM_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "artwork_commit=${M1N1_ARTWORK_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "source_clean=true" "${evidence}/manifest.txt" >/dev/null
grep -Eq '^source_date_epoch=[0-9]+$' "${evidence}/manifest.txt"
grep -Eq '^workspace_filesystem=(ext2/ext3|ext2|ext3|ext4|xfs|btrfs|overlayfs)$' \
    "${evidence}/manifest.txt"
grep -Eq '^container_image_id=sha256:[0-9a-f]{64}$' "${evidence}/manifest.txt"
grep -Fx "debian_snapshot=${DEBIAN_SNAPSHOT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "rustup_version=${RUSTUP_VERSION}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "rustup_init_sha256=${RUSTUP_INIT_SHA256}" "${evidence}/manifest.txt" >/dev/null
grep -Eq '^rustc=rustc 1\.93\.1 ' "${evidence}/manifest.txt"
grep -Eq 'm1n1\.macho:.*Mach-O 64-bit arm64' "${evidence}/file.txt"
test "$(wc -c < "${evidence}/m1n1.macho" | tr -d " ")" -gt 100000
test "$(wc -c < "${evidence}/m1n1.bin" | tr -d " ")" -gt 100000

printf 'm1n1.baseline=verified\n'
