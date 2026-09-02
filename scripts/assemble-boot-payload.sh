#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"

readonly m1n1_evidence="${1:-${project_root}/out/milestone0/m1n1/latest}"
readonly linux_evidence="${2:-${project_root}/out/milestone0/linux-dtb/latest}"
readonly uboot_evidence="${3:-${project_root}/out/milestone0/u-boot/latest}"

"${project_root}/scripts/verify-m1n1.sh" "$m1n1_evidence"
"${project_root}/scripts/verify-linux-dtb.sh" "$linux_evidence"
"${project_root}/scripts/verify-u-boot.sh" "$uboot_evidence"

readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)"
readonly output_root="${project_root}/out/milestone0/boot-payload"
readonly stage="${output_root}/.${run_id}.tmp"
readonly destination="${output_root}/${run_id}"
mkdir -p "$stage"

install -m 0644 "${m1n1_evidence}/m1n1.macho" "${stage}/m1n1.macho"
install -m 0644 "${linux_evidence}/t6030-j514s.dtb" "${stage}/t6030-j514s.dtb"
install -m 0644 "${uboot_evidence}/u-boot-nodtb.bin" "${stage}/u-boot-nodtb.bin"
install -m 0644 "${m1n1_evidence}/manifest.txt" "${stage}/m1n1-manifest.txt"
install -m 0644 "${linux_evidence}/manifest.txt" "${stage}/linux-dtb-manifest.txt"
install -m 0644 "${uboot_evidence}/manifest.txt" "${stage}/u-boot-manifest.txt"

cat "${stage}/m1n1.macho" "${stage}/t6030-j514s.dtb" \
    "${stage}/u-boot-nodtb.bin" > "${stage}/${BOOT_PAYLOAD}"

readonly m1n1_size="$(wc -c < "${stage}/m1n1.macho" | tr -d ' ')"
readonly dtb_size="$(wc -c < "${stage}/t6030-j514s.dtb" | tr -d ' ')"
readonly uboot_size="$(wc -c < "${stage}/u-boot-nodtb.bin" | tr -d ' ')"
readonly dtb_offset="$m1n1_size"
readonly uboot_offset="$((m1n1_size + dtb_size))"
readonly total_size="$((m1n1_size + dtb_size + uboot_size))"

{
    printf 'format=1\n'
    printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'target=Mac15,6/J514s/T6030\n'
    printf 'component=boot-payload\n'
    printf 'status=build-verified-not-hardware-booted\n'
    printf 'payload=%s\n' "$BOOT_PAYLOAD"
    printf 'layout=m1n1.macho+t6030-j514s.dtb+u-boot-nodtb.bin\n'
    printf 'm1n1_commit=%s\n' "$(sed -n 's/^source_commit=//p' "${stage}/m1n1-manifest.txt")"
    printf 'linux_commit=%s\n' "$(sed -n 's/^source_commit=//p' "${stage}/linux-dtb-manifest.txt")"
    printf 'u_boot_commit=%s\n' "$(sed -n 's/^source_commit=//p' "${stage}/u-boot-manifest.txt")"
    printf 'm1n1_offset=0\n'
    printf 'm1n1_size=%s\n' "$m1n1_size"
    printf 'dtb_offset=%s\n' "$dtb_offset"
    printf 'dtb_size=%s\n' "$dtb_size"
    printf 'u_boot_offset=%s\n' "$uboot_offset"
    printf 'u_boot_size=%s\n' "$uboot_size"
    printf 'total_size=%s\n' "$total_size"
} > "${stage}/manifest.txt"

file "${stage}/${BOOT_PAYLOAD}" > "${stage}/file.txt"
(
    cd "$stage"
    shasum -a 256 \
        "$BOOT_PAYLOAD" file.txt linux-dtb-manifest.txt m1n1-manifest.txt \
        m1n1.macho manifest.txt t6030-j514s.dtb u-boot-manifest.txt \
        u-boot-nodtb.bin > SHA256SUMS
)

mv "$stage" "$destination"
ln -sfn "$run_id" "${output_root}/latest"
"${project_root}/scripts/verify-boot-payload.sh" "$destination"
printf 'boot-payload.baseline=%s\n' "$destination"
