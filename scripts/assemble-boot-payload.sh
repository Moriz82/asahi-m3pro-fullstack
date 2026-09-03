#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/atomic-symlink.sh"
source "${project_root}/scripts/lib/evidence.sh"
m0_validate_output_root "$project_root"
readonly output_base="$MILESTONE0_OUTPUT_ROOT"

readonly m1n1_candidate="${1:-${output_base}/milestone0/m1n1/latest}"
readonly linux_candidate="${2:-${output_base}/milestone0/linux-dtb/latest}"
readonly uboot_candidate="${3:-${output_base}/milestone0/u-boot/latest}"
m1n1_evidence="$(cd "$m1n1_candidate" && pwd -P)" || { printf 'Missing m1n1 evidence.\n' >&2; exit 1; }
linux_evidence="$(cd "$linux_candidate" && pwd -P)" || { printf 'Missing Linux DTB evidence.\n' >&2; exit 1; }
uboot_evidence="$(cd "$uboot_candidate" && pwd -P)" || { printf 'Missing U-Boot evidence.\n' >&2; exit 1; }
readonly m1n1_evidence linux_evidence uboot_evidence

readonly m1n1_run_id="$(basename -- "$m1n1_evidence")"
readonly linux_dtb_run_id="$(basename -- "$linux_evidence")"
readonly uboot_run_id="$(basename -- "$uboot_evidence")"
[[ "$m1n1_run_id" =~ ^[A-Za-z0-9._-]+$ && "$linux_dtb_run_id" =~ ^[A-Za-z0-9._-]+$ && "$uboot_run_id" =~ ^[A-Za-z0-9._-]+$ ]]
readonly m1n1_manifest_sha256="$(evidence_sha256 "$m1n1_evidence/manifest.txt")"
readonly linux_dtb_manifest_sha256="$(evidence_sha256 "$linux_evidence/manifest.txt")"
readonly uboot_manifest_sha256="$(evidence_sha256 "$uboot_evidence/manifest.txt")"

"${project_root}/scripts/verify-m1n1.sh" "$m1n1_evidence"
"${project_root}/scripts/verify-linux-dtb.sh" "$linux_evidence"
"${project_root}/scripts/verify-u-boot.sh" "$uboot_evidence"

readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly output_root="${output_base}/milestone0/boot-payload"
readonly stage="${output_root}/.${run_id}.tmp"
readonly destination="${output_root}/${run_id}"
readonly latest="${output_root}/latest"
readonly latest_tmp="${output_root}/.latest.${run_id}.tmp"
mkdir -p "$output_root"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" || -e "$latest_tmp" || -L "$latest_tmp" ]] ||
    [[ -e "$latest" && ! -L "$latest" ]]; then
    printf 'Refusing colliding boot-payload publication path for run %s\n' "$run_id" >&2
    exit 1
fi
mkdir "$stage"

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
    printf 'm1n1_source_run_id=%s\n' "$m1n1_run_id"
    printf 'm1n1_source_manifest_sha256=%s\n' "$m1n1_manifest_sha256"
    printf 'linux_dtb_source_run_id=%s\n' "$linux_dtb_run_id"
    printf 'linux_dtb_source_manifest_sha256=%s\n' "$linux_dtb_manifest_sha256"
    printf 'u_boot_source_run_id=%s\n' "$uboot_run_id"
    printf 'u_boot_source_manifest_sha256=%s\n' "$uboot_manifest_sha256"
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

cmp "$m1n1_evidence/m1n1.macho" "$stage/m1n1.macho"
cmp "$linux_evidence/t6030-j514s.dtb" "$stage/t6030-j514s.dtb"
cmp "$uboot_evidence/u-boot-nodtb.bin" "$stage/u-boot-nodtb.bin"
cmp "$m1n1_evidence/manifest.txt" "$stage/m1n1-manifest.txt"
cmp "$linux_evidence/manifest.txt" "$stage/linux-dtb-manifest.txt"
cmp "$uboot_evidence/manifest.txt" "$stage/u-boot-manifest.txt"

if [[ ${M0_PAYLOAD_VERIFY_FORCE_FAILURE:-0} == 1 ]]; then
    printf 'forced payload verification failure (test hook)\n' >&2
    exit 1
fi
"${project_root}/scripts/verify-boot-payload.sh" "$stage" \
    --m1n1-source "$m1n1_evidence" --linux-dtb-source "$linux_evidence" \
    --u-boot-source "$uboot_evidence"
mv "$stage" "$destination"
atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
printf 'boot-payload.baseline=%s\n' "$destination"
