#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
readonly m0_root="${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0"

manifest_value() {
    local key="$1" file="$2"
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

if [[ "${1:-}" == --self-test ]]; then
    [[ "$M1_REQUIRED_BOOT_COUNT" == 20 ]]
    grep -Fq 'execution/manifest.txt' "$0"
    grep -Fq 'shasum -a 256 -c SHA256SUMS' "$0"
    printf 'assemble-milestone1-session self-test passed\n'
    exit 0
fi
[[ $# -eq 2 ]] || { printf 'Usage: %s SESSIONS_ROOT SESSION_OUTPUT\n' "$0" >&2; exit 64; }
readonly source_root="$1"
readonly output_root="$2"
test -d "$source_root" && test ! -L "$source_root"
test ! -e "$output_root" || { printf 'Refusing to overwrite existing session: %s\n' "$output_root" >&2; exit 2; }
readonly source_real="$(cd "$source_root" && pwd -P)"
readonly m0_run_dir="$(cd "${m0_root}/linux-full/latest" && pwd -P)"
readonly m0_run_id="$(basename "$m0_run_dir")"
readonly m0_manifest_sha256="$(shasum -a 256 "$m0_run_dir/manifest.txt" | awk '{print $1}')"
readonly image_sha256="$(shasum -a 256 "$m0_run_dir/Image" | awk '{print $1}')"
readonly dtb_sha256="$(shasum -a 256 "$m0_run_dir/dtbs/apple/t6030-j514s.dtb" | awk '{print $1}')"

children=()
for child in "$source_real"/*; do
    [[ -d "$child" && ! -L "$child" ]] || continue
    [[ "$(basename "$child")" != *..* ]] || { printf 'Unsafe run directory name.\n' >&2; exit 1; }
    children+=("$child")
done
(( ${#children[@]} == M1_REQUIRED_BOOT_COUNT )) || {
    printf 'Expected exactly %s session run directories; found %s.\n' "$M1_REQUIRED_BOOT_COUNT" "${#children[@]}" >&2
    exit 1
}
for required in watchdog panic reboot macos-return dfu; do
    test -f "$source_real/evidence-${required}.txt" && test ! -L "$source_real/evidence-${required}.txt"
done

readonly first_execution="${children[0]}/execution"
test -d "$first_execution" && test ! -L "$first_execution"
readonly first_manifest="${first_execution}/manifest.txt"
baseline_value() { manifest_value "$1" "$first_manifest"; }
for key in source_commit m0_run_id m0_manifest_sha256 image_sha256 dtb_sha256 initramfs_sha256 tool device command; do
    test -n "$(baseline_value "$key")"
done
[[ "$(baseline_value source_commit)" == "$M1N1_COMMIT" && "$(baseline_value m0_run_id)" == "$m0_run_id" ]]
[[ "$(baseline_value m0_manifest_sha256)" == "$m0_manifest_sha256" && "$(baseline_value image_sha256)" == "$image_sha256" && "$(baseline_value dtb_sha256)" == "$dtb_sha256" ]]
[[ "$(baseline_value command)" == *'--compression none '* && "$(baseline_value command)" != *'root='* ]]

readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly stage="${output_root%/}.tmp.${run_id}"
trap 'rm -rf "$stage"' EXIT
if [[ -e "$stage" || -L "$stage" ]]; then
    printf 'Refusing colliding Milestone 1 assembly stage.\n' >&2
    exit 1
fi
mkdir "$stage"
for index in "${!children[@]}"; do
    child="${children[$index]}"
    execution="$child/execution"
    test -d "$execution" && test ! -L "$execution"
    for required in manifest.txt SHA256SUMS host.log serial.log; do
        test -f "$execution/$required" && test ! -L "$execution/$required" && test -s "$execution/$required"
    done
    # The enclosing files are emitted by milestone1-execute. Validate their
    # checksum and execution binding before flattening this run for the verifier.
    for required in manifest.txt SHA256SUMS records.tsv; do
        test -f "$child/$required" && test ! -L "$child/$required" && test -s "$child/$required"
    done
    (cd "$child" && shasum -a 256 -c SHA256SUMS)
    for checksum_path in records.tsv manifest.txt execution/SHA256SUMS execution/manifest.txt execution/host.log execution/serial.log; do
        grep -F "  $checksum_path" "$child/SHA256SUMS" >/dev/null
    done
    execution_manifest_sha256="$(shasum -a 256 "$execution/manifest.txt" | awk '{print $1}')"
    grep -Fx 'status=completed' "$child/manifest.txt" >/dev/null
    grep -Fx "execution_sha256=$execution_manifest_sha256" "$child/manifest.txt" >/dev/null
    grep -Fx $'1\tsuccess\texecution\tserial.log' "$child/records.tsv" >/dev/null
    for key in source_commit m0_run_id m0_manifest_sha256 image_sha256 dtb_sha256 initramfs_sha256 tool device command; do
        grep -Fx "$key=$(baseline_value "$key")" "$child/manifest.txt" >/dev/null
    done
    (cd "$execution" && shasum -a 256 -c SHA256SUMS)
    for checksum_path in manifest.txt host.log serial.log; do
        grep -F "  $checksum_path" "$execution/SHA256SUMS" >/dev/null
    done
    for line in 'status=completed' 'producer_exit=0' 'tee_exit=0' 'pipe_status=0,0' 'storage_policy=ram-only'; do
        grep -Fx "$line" "$execution/manifest.txt" >/dev/null
    done
    for key in source_commit m0_run_id m0_manifest_sha256 image_sha256 dtb_sha256 initramfs_sha256 tool device command; do
        grep -Fx "$key=$(baseline_value "$key")" "$execution/manifest.txt" >/dev/null
    done
    install -d "$stage/run-$((index + 1))"
    for required in manifest.txt SHA256SUMS host.log serial.log; do
        install -m 0644 "$execution/$required" "$stage/run-$((index + 1))/$required"
    done
    printf '%s\tsuccess\trun-%s\tserial.log\n' "$((index + 1))" "$((index + 1))" >>"$stage/records.tsv"
done
for required in watchdog panic reboot macos-return dfu; do
    install -m 0644 "$source_real/evidence-${required}.txt" "$stage/evidence-${required}.txt"
    grep -Fx 'observed=true' "$stage/evidence-${required}.txt" >/dev/null
    grep -Fx 'recorded_by=operator' "$stage/evidence-${required}.txt" >/dev/null
    grep -Fx 'source=serial-log' "$stage/evidence-${required}.txt" >/dev/null
done
{
    printf 'format=1\nstatus=complete\nstorage_policy=ram-only\nevidence_policy=checksummed-execution-and-serial\n'
    printf 'source_commit=%s\nm0_run_id=%s\nm0_manifest_sha256=%s\nimage_sha256=%s\ndtb_sha256=%s\n' "$M1N1_COMMIT" "$m0_run_id" "$m0_manifest_sha256" "$image_sha256" "$dtb_sha256"
    printf 'initramfs_sha256=%s\ntool=%s\ndevice=%s\ncommand=%s\n' "$(baseline_value initramfs_sha256)" "$(baseline_value tool)" "$(baseline_value device)" "$(baseline_value command)"
} >"$stage/manifest.txt"
(cd "$stage" && shasum -a 256 records.tsv manifest.txt evidence-*.txt >SHA256SUMS)
mkdir -p "$(dirname "$output_root")"
mv "$stage" "$output_root"
trap - EXIT
"${project_root}/scripts/verify-milestone1-session.sh" "$output_root"
printf 'milestone1.session=%s\n' "$output_root"
