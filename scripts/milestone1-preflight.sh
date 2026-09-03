#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
source "${project_root}/scripts/lib/atomic-symlink.sh"
readonly output_root="${MILESTONE1_OUTPUT_ROOT:-${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone1}"

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

usage() { printf 'Usage: %s [--dfu-rehearsed] [--sample-restore-verified] [--self-test]\n' "$0"; }
self_test=false
dfu=false
restore=false
while (($#)); do
    case "$1" in
        --dfu-rehearsed) dfu=true ;;
        --sample-restore-verified) restore=true ;;
        --self-test) self_test=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
    shift
done

if "$self_test"; then
    [[ "$dfu" == false && "$restore" == false ]]
    [[ "$M1_PREFLIGHT_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]]
    grep -Fq 'check-native-readiness.sh' "${project_root}/config/milestone1.env"
    readonly pipe_test_log="$(mktemp)"
    run_with_tee "$pipe_test_log" true
    if run_with_tee "$pipe_test_log" sh -c 'exit 7'; then exit 1; fi
    M1_SELF_TEST_TEE_FAILURE=true
    if run_with_tee "$pipe_test_log" true; then exit 1; fi
    M1_SELF_TEST_TEE_FAILURE=false
    fake_regular="$(mktemp)"
    fake_link="${fake_regular}.link"
    ln -s "$fake_regular" "$fake_link"
    ! validate_m1n1_device "$fake_regular"
    ! validate_m1n1_device "$fake_link"
    ! validate_m1n1_device /dev/disk0
    ! validate_m1n1_device /dev/null
    rm -f "$fake_link" "$fake_regular"
    rm -f "$pipe_test_log"
    publication_test="$(mktemp -d)"
    mkdir "$publication_test/one" "$publication_test/two"
    atomic_symlink_replace one "$publication_test/latest" "$publication_test/.latest.one.tmp"
    atomic_symlink_replace two "$publication_test/latest" "$publication_test/.latest.two.tmp"
    [[ "$(readlink "$publication_test/latest")" == two ]]
    rm -rf "$publication_test"
    printf 'milestone1-preflight self-test passed\n'
    exit 0
fi

[[ "$dfu" == true && "$restore" == true ]] || {
    printf 'Both explicit attestations are required; no readiness check was run.\n' >&2
    exit 2
}
command -v python3 >/dev/null || { printf 'Missing python3 for device validation.\n' >&2; exit 1; }
readonly m1n1_device="$(validate_m1n1_device "$M1N1DEVICE")"
test -x "$M1_READINESS_SCRIPT" || { printf 'Missing readiness script: %s\n' "$M1_READINESS_SCRIPT" >&2; exit 1; }
"${project_root}/scripts/verify-milestone0.sh"
"${project_root}/scripts/verify-milestone1-initramfs.sh"

readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly stage="${output_root}/preflight/.${run_id}.tmp"
readonly destination="${output_root}/preflight/${run_id}"
readonly latest="${output_root}/preflight/latest"
readonly latest_tmp="${output_root}/preflight/.latest.${run_id}.tmp"
mkdir -p "${output_root}/preflight"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" || -e "$latest_tmp" || -L "$latest_tmp" ]] ||
    [[ -e "$latest" && ! -L "$latest" ]]; then
    printf 'Refusing colliding Milestone 1 preflight publication path.\n' >&2
    exit 1
fi
mkdir "$stage"
if ! run_with_tee "$stage/readiness.log" "$M1_READINESS_SCRIPT" --dfu-rehearsed --sample-restore-verified; then
    printf 'format=1\nstatus=blocked\nproducer_exit=%s\ntee_exit=%s\n' \
        "$M1_PIPE_PRODUCER_STATUS" "$M1_PIPE_TEE_STATUS" >"$stage/manifest.txt"
    mv "$stage" "$destination"
    atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
    printf 'milestone1.preflight=blocked\n' >&2
    exit 2
fi
readonly readiness_status="$M1_PIPE_PRODUCER_STATUS"
readonly tee_status="$M1_PIPE_TEE_STATUS"
readonly completed_epoch="$(date -u +%s)"
{
    printf 'format=1\nstatus=passed\ncompleted_epoch=%s\n' "$completed_epoch"
    printf 'dfu_rehearsed=true\nsample_restore_verified=true\n'
    printf 'producer_exit=%s\ntee_exit=%s\npipe_status=%s,%s\n' "$readiness_status" "$tee_status" "$readiness_status" "$tee_status"
    printf 'readiness_script=%s\ndevice=%s\n' "$M1_READINESS_SCRIPT" "$m1n1_device"
    printf 'readiness_sha256=%s\n' "$(shasum -a 256 "$stage/readiness.log" | awk '{print $1}')"
    printf 'expires_after_seconds=%s\n' "$M1_PREFLIGHT_MAX_AGE_SECONDS"
} >"$stage/manifest.txt"
shasum -a 256 "$stage/readiness.log" "$stage/manifest.txt" >"$stage/SHA256SUMS"
mv "$stage" "$destination"
atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
printf 'milestone1.preflight=passed path=%s\n' "$destination"
