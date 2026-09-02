#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
readonly evidence="${1:-${project_root}/out/milestone0/boot-payload/latest}"

test -d "$evidence"
for required in SHA256SUMS "$BOOT_PAYLOAD" file.txt linux-dtb-manifest.txt m1n1-manifest.txt m1n1.macho manifest.txt t6030-j514s.dtb u-boot-manifest.txt u-boot-nodtb.bin; do
    test -s "${evidence}/${required}" || {
        printf 'Missing evidence file: %s\n' "${evidence}/${required}" >&2
        exit 1
    }
done

(
    cd "$evidence"
    shasum -a 256 -c SHA256SUMS
)

manifest_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "${evidence}/manifest.txt"
}

grep -Fx 'target=Mac15,6/J514s/T6030' "${evidence}/manifest.txt" >/dev/null
grep -Fx 'status=build-verified-not-hardware-booted' "${evidence}/manifest.txt" >/dev/null
grep -Fx 'layout=m1n1.macho+t6030-j514s.dtb+u-boot-nodtb.bin' \
    "${evidence}/manifest.txt" >/dev/null
grep -Fx "payload=${BOOT_PAYLOAD}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "m1n1_commit=${M1N1_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "linux_commit=${LINUX_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "u_boot_commit=${UBOOT_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Eq "${BOOT_PAYLOAD}:.*Mach-O 64-bit arm64" "${evidence}/file.txt"

readonly m1n1_size="$(wc -c < "${evidence}/m1n1.macho" | tr -d ' ')"
readonly dtb_size="$(wc -c < "${evidence}/t6030-j514s.dtb" | tr -d ' ')"
readonly uboot_size="$(wc -c < "${evidence}/u-boot-nodtb.bin" | tr -d ' ')"
readonly total_size="$(wc -c < "${evidence}/${BOOT_PAYLOAD}" | tr -d ' ')"

test "$(manifest_value m1n1_offset)" -eq 0
test "$(manifest_value m1n1_size)" -eq "$m1n1_size"
test "$(manifest_value dtb_offset)" -eq "$m1n1_size"
test "$(manifest_value dtb_size)" -eq "$dtb_size"
test "$(manifest_value u_boot_offset)" -eq "$((m1n1_size + dtb_size))"
test "$(manifest_value u_boot_size)" -eq "$uboot_size"
test "$(manifest_value total_size)" -eq "$total_size"
test "$total_size" -eq "$((m1n1_size + dtb_size + uboot_size))"

dd if="${evidence}/${BOOT_PAYLOAD}" bs=1 count="$m1n1_size" 2>/dev/null \
    | cmp "${evidence}/m1n1.macho" -
dd if="${evidence}/${BOOT_PAYLOAD}" bs=1 skip="$m1n1_size" count="$dtb_size" 2>/dev/null \
    | cmp "${evidence}/t6030-j514s.dtb" -
dd if="${evidence}/${BOOT_PAYLOAD}" bs=1 skip="$((m1n1_size + dtb_size))" 2>/dev/null \
    | cmp "${evidence}/u-boot-nodtb.bin" -

printf 'boot-payload.baseline=verified\n'
