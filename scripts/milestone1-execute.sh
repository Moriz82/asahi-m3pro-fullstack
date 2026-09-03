#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly caller_attestation="${M1_EXECUTE_ATTESTATION-}"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
readonly output_root="${MILESTONE1_OUTPUT_ROOT:-${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone1}"
readonly required_attestation="$M1_REQUIRED_EXECUTE_ATTESTATION"
readonly m0_root="${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0"

validate_m1n1_device() {
    local candidate="$1" canonical
    [[ "$candidate" = /dev/cu.* || "$candidate" = /dev/tty.* ]] || {
        printf 'M1N1DEVICE is outside the macOS serial-device allowlist.\n' >&2
        return 1
    }
    [[ -c "$candidate" && ! -b "$candidate" && ! -L "$candidate" ]] || {
        printf 'M1N1DEVICE must be a non-symlink character device.\n' >&2
        return 1
    }
    canonical="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate")" || return 1
    [[ "$canonical" = "$candidate" ]] || {
        printf 'M1N1DEVICE must already be canonical.\n' >&2
        return 1
    }
    printf '%s\n' "$canonical"
}

M1_SELF_TEST_TEE_FAILURE=false
tee_to_log() {
    if [[ "$M1_SELF_TEST_TEE_FAILURE" == true ]]; then
        cat >/dev/null
        return 8
    fi
    tee "$1"
}

run_with_tee() {
    local log_file="$1"
    shift
    local -a pipe_status
    set +e
    "$@" 2>&1 | tee_to_log "$log_file"
    pipe_status=("${PIPESTATUS[@]}")
    set -e
    M1_PIPE_PRODUCER_STATUS="${pipe_status[0]:-255}"
    M1_PIPE_TEE_STATUS="${pipe_status[1]:-255}"
    ((M1_PIPE_PRODUCER_STATUS == 0 && M1_PIPE_TEE_STATUS == 0))
}

resolve_versioned_run() {
    local runs_root="$1" pointer="$2" label="$3" root_real candidate base
    root_real="$(cd "$runs_root" && pwd -P)" || return 1
    [[ -L "$runs_root/$pointer" ]] || { printf 'Missing %s pointer.\n' "$label" >&2; return 1; }
    candidate="$(cd "$runs_root/$pointer" && pwd -P)" || return 1
    base="$(basename "$candidate")"
    [[ "$(dirname "$candidate")" == "$root_real" ]] || { printf 'Unsafe %s run binding.\n' "$label" >&2; return 1; }
    [[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$base" != "$pointer" ]] || return 1
    printf '%s\n' "$candidate"
}

if [[ "${1:-}" == --self-test ]]; then
    [[ "$required_attestation" == I_UNDERSTAND_CONTROLLED_TETHER ]]
    [[ "$caller_attestation" != "$required_attestation" ]]
    grep -Fq 'PIPESTATUS[@]' "$0"
    M1_SELF_TEST_TEE_FAILURE=true
    if run_with_tee "$(mktemp)" true; then exit 1; fi
    M1_SELF_TEST_TEE_FAILURE=false
    grep -Fq 'execution_status=1' "$0"
    grep -Fq -- '--execute' "${project_root}/scripts/milestone1-execute.sh"
    pointer_test="$(mktemp -d)"
    mkdir "$pointer_test/one" "$pointer_test/two"
    ln -s one "$pointer_test/latest"
    resolved_run="$(resolve_versioned_run "$pointer_test" latest test)"
    rm "$pointer_test/latest"
    ln -s two "$pointer_test/latest"
    [[ "$(basename "$resolved_run")" == one && "$(basename "$(resolve_versioned_run "$pointer_test" latest test)")" == two ]]
    rm -rf "$pointer_test"
    printf 'milestone1-execute self-test passed; execution remains gated\n'
    exit 0
fi
[[ "${1:-}" == --execute && $# -eq 1 ]] || {
    printf 'Refusing tether execution. Use --execute only after review.\n' >&2
    exit 2
}
[[ "$caller_attestation" == "$required_attestation" ]] || {
    printf 'Set M1_EXECUTE_ATTESTATION=%s explicitly before invocation.\n' "$required_attestation" >&2
    exit 2
}
command -v python3 >/dev/null || { printf 'Missing python3 for device validation.\n' >&2; exit 1; }
readonly m1n1_device="$(validate_m1n1_device "$M1N1DEVICE")"
test -n "$M1_M1N1_SOURCE_DIR" && test -f "$M1_M1N1_SOURCE_DIR/$M1_M1N1_TOOL_RELATIVE" || {
    printf 'Pinned m1n1 source/tool is missing.\n' >&2; exit 2;
}
test "$(git -C "$M1_M1N1_SOURCE_DIR" rev-parse HEAD)" = "$M1N1_COMMIT"
test -z "$(git -C "$M1_M1N1_SOURCE_DIR" status --porcelain --untracked-files=all)"
"${project_root}/scripts/verify-milestone0.sh"
readonly preflight_dir="${output_root}/preflight/latest"
readonly preflight="${preflight_dir}/manifest.txt"
test -s "$preflight" && test -s "$preflight_dir/SHA256SUMS"
(cd "$preflight_dir" && shasum -a 256 -c SHA256SUMS)
grep -Fx status=passed "$preflight" >/dev/null
grep -Fx dfu_rehearsed=true "$preflight" >/dev/null
grep -Fx sample_restore_verified=true "$preflight" >/dev/null
readonly completed_epoch="$(awk -F= '$1=="completed_epoch" {print $2}' "$preflight")"
readonly now="$(date -u +%s)"
[[ "$completed_epoch" =~ ^[0-9]+$ ]] && ((now >= completed_epoch))
((now - completed_epoch <= M1_PREFLIGHT_MAX_AGE_SECONDS)) || {
    printf 'Preflight is stale; run it again with both attestations.\n' >&2
    exit 2
}

m0_run_dir="$(resolve_versioned_run "${m0_root}/linux-full" latest 'M0 Linux')" || exit 1
m1_initramfs_run_dir="$(resolve_versioned_run "${output_root}/initramfs" latest 'M1 initramfs')" || exit 1
readonly m0_run_dir m1_initramfs_run_dir
readonly image="${m0_run_dir}/Image"
readonly dtb="${m0_run_dir}/dtbs/apple/t6030-j514s.dtb"
readonly initramfs="${m1_initramfs_run_dir}/${M1_INITRAMFS_NAME}"
readonly tool="${M1_M1N1_SOURCE_DIR}/${M1_M1N1_TOOL_RELATIVE}"
"${project_root}/scripts/verify-linux-full.sh" "$m0_run_dir"
"${project_root}/scripts/verify-milestone1-initramfs.sh" "$m1_initramfs_run_dir" "$m0_run_dir"
readonly m0_run_id="$(basename "$m0_run_dir")"
readonly m0_manifest_sha256="$(shasum -a 256 "$m0_run_dir/manifest.txt" | awk '{print $1}')"
readonly image_sha256="$(shasum -a 256 "$image" | awk '{print $1}')"
readonly dtb_sha256="$(shasum -a 256 "$dtb" | awk '{print $1}')"
readonly initramfs_sha256="$(shasum -a 256 "$initramfs" | awk '{print $1}')"
readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly stage="${output_root}/sessions/.${run_id}.tmp"
readonly destination="${output_root}/sessions/${run_id}"
readonly execution="${stage}/execution"
mkdir -p "${output_root}/sessions"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" ]]; then
    printf 'Refusing colliding Milestone 1 session publication path.\n' >&2
    exit 1
fi
mkdir "$stage"
mkdir "$execution"
printf -v command_line 'M1N1DEVICE=%q python3 %q --compression %q %q %q %q' \
    "$m1n1_device" "$tool" "$M1_COMPRESSION" "$image" "$dtb" "$initramfs"
{
    printf 'format=1\nstatus=started\nsource_commit=%s\n' "$M1N1_COMMIT"
    printf 'm0_run_id=%s\nm0_manifest_sha256=%s\nimage_sha256=%s\ndtb_sha256=%s\n' "$m0_run_id" "$m0_manifest_sha256" "$image_sha256" "$dtb_sha256"
    printf 'initramfs_sha256=%s\ndevice=%s\ncompression=%s\nstorage_policy=ram-only\n' "$initramfs_sha256" "$m1n1_device" "$M1_COMPRESSION"
    printf 'command=%s\n' "$command_line"
} >"$execution/manifest.txt"
cd "$M1_M1N1_SOURCE_DIR"
if run_with_tee "$execution/host.log" env M1N1DEVICE="$m1n1_device" python3 "$tool" --compression "$M1_COMPRESSION" "$image" "$dtb" "$initramfs"; then :; fi
tether_status="$M1_PIPE_PRODUCER_STATUS"
tee_status="$M1_PIPE_TEE_STATUS"
if ((tether_status != 0 || tee_status != 0)); then
    execution_status=1
else
    execution_status=0
fi
cp "$execution/host.log" "$execution/serial.log"
printf 'producer_exit=%s\ntee_exit=%s\npipe_status=%s,%s\nexit=%s\nstatus=%s\n' \
    "$tether_status" "$tee_status" "$tether_status" "$tee_status" "$execution_status" \
    "$([[ $execution_status -eq 0 ]] && printf completed || printf failed)" >>"$execution/manifest.txt"
shasum -a 256 "$execution/host.log" "$execution/serial.log" "$execution/manifest.txt" >"$execution/SHA256SUMS"
printf '1\t%s\texecution\tserial.log\n' "$([[ $execution_status -eq 0 ]] && printf success || printf failed)" >"$stage/records.tsv"
{
    printf 'format=1\nstatus=%s\nsource_commit=%s\ntool=%s\ndevice=%s\ncommand=%s\n' "$([[ $execution_status -eq 0 ]] && printf completed || printf failed)" "$M1N1_COMMIT" "$tool" "$m1n1_device" "$command_line"
    printf 'm0_run_id=%s\nm0_manifest_sha256=%s\nimage_sha256=%s\ndtb_sha256=%s\n' "$m0_run_id" "$m0_manifest_sha256" "$image_sha256" "$dtb_sha256"
    printf 'initramfs_sha256=%s\nexecution_sha256=%s\ntool=%s\ndevice=%s\ncommand=%s\nstorage_policy=ram-only\nevidence_policy=checksummed-execution-and-serial\n' "$initramfs_sha256" "$(shasum -a 256 "$execution/manifest.txt" | awk '{print $1}')" "$tool" "$m1n1_device" "$command_line"
} >"$stage/manifest.txt"
(cd "$stage" && shasum -a 256 records.tsv manifest.txt execution/SHA256SUMS execution/manifest.txt execution/host.log execution/serial.log >SHA256SUMS)
mv "$stage" "$destination"
printf 'milestone1.session=%s\n' "$destination"
exit "$execution_status"
