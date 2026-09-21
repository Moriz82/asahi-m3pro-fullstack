#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
source "${project_root}/scripts/lib/atomic-symlink.sh"
source "${project_root}/scripts/lib/evidence.sh"
source "${project_root}/scripts/lib/milestone1-evidence.sh"
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

usage() {
    printf 'Usage: %s --target-readiness --dfu-rehearsed --sample-restore-verified\n' "$0"
    printf '   or: %s --controller-preflight --target-readiness-dir ABS --expected-target-identity-sha256 HEX --expected-target-bundle-sha256 HEX\n' "$0"
}
self_test=false
dfu=false
restore=false
mode=""
target_dir=""
expected_target=""
expected_bundle=""
while (($#)); do
    case "$1" in
        --target-readiness|--controller-preflight)
            [[ -z "$mode" ]] || { usage >&2; exit 64; }
            mode="$1" ;;
        --target-readiness-dir|--expected-target-identity-sha256|--expected-target-bundle-sha256)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage >&2; exit 64; }
            case "$1" in
                --target-readiness-dir) [[ -z "$target_dir" ]] || exit 64; target_dir="$2" ;;
                --expected-target-identity-sha256) [[ -z "$expected_target" ]] || exit 64; expected_target="$2" ;;
                --expected-target-bundle-sha256) [[ -z "$expected_bundle" ]] || exit 64; expected_bundle="$2" ;;
            esac
            shift ;;
        --dfu-rehearsed) dfu=true ;;
        --sample-restore-verified) restore=true ;;
        --self-test) self_test=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
    shift
done

if "$self_test"; then
    [[ "$dfu" == false && "$restore" == false && -z "$mode$target_dir$expected_target$expected_bundle" ]]
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

case "$mode" in
    --target-readiness)
        [[ "$dfu" == true && "$restore" == true && -z "$target_dir$expected_target$expected_bundle" ]] || {
            printf 'Target readiness requires both explicit attestations and no controller arguments.\n' >&2; exit 2;
        }
        bucket=target-readiness ;;
    --controller-preflight)
        [[ "$dfu" == false && "$restore" == false && "$target_dir" == /* &&
           "$expected_target" =~ ^[0-9a-f]{64}$ && "$expected_bundle" =~ ^[0-9a-f]{64}$ ]] || {
            printf 'Controller preflight requires an absolute transfer path and both independent target anchors.\n' >&2; exit 2;
        }
        bucket=preflight ;;
    *) usage >&2; exit 64 ;;
esac
command -v python3 >/dev/null || { printf 'Missing python3.\n' >&2; exit 1; }

if [[ "$mode" == --controller-preflight ]]; then
    m1n1_device="$(validate_m1n1_device "$M1N1DEVICE")" || exit 1
    controller_id="$(m1_host_identity_sha256 controller)" || exit 1
    test -n "$M1_M1N1_SOURCE_DIR" && test -f "$M1_M1N1_SOURCE_DIR/$M1_M1N1_TOOL_RELATIVE"
    test "$(git -C "$M1_M1N1_SOURCE_DIR" rev-parse HEAD)" = "$M1N1_COMMIT"
    test -z "$(git -C "$M1_M1N1_SOURCE_DIR" status --porcelain --untracked-files=all)"
    tool_sha="$(evidence_sha256 "$M1_M1N1_SOURCE_DIR/$M1_M1N1_TOOL_RELATIVE")"
    "${project_root}/scripts/verify-milestone0.sh"
    m0_run_dir="$(resolve_versioned_run "${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0/linux-full" latest 'M0 Linux')" || exit 1
    m1_initramfs_run_dir="$(resolve_versioned_run "${output_root}/initramfs" latest 'M1 initramfs')" || exit 1
    "${project_root}/scripts/verify-linux-full.sh" "$m0_run_dir"
    "${project_root}/scripts/verify-milestone1-initramfs.sh" "$m1_initramfs_run_dir" "$m0_run_dir"
    binding="$(m1_artifact_binding "$m0_run_dir" "$m1_initramfs_run_dir")" || exit 1
else
    target_id="$(m1_host_identity_sha256 target)" || exit 1
    test -x "$M1_READINESS_SCRIPT" && test ! -L "$M1_READINESS_SCRIPT"
    [[ "$(evidence_sha256 "$M1_READINESS_SCRIPT")" == "$M1_READINESS_SCRIPT_SHA256" ]] || {
        printf 'Readiness script differs from reviewed pin.\n' >&2; exit 1;
    }
fi

readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly stage="${output_root}/${bucket}/.${run_id}.tmp"
readonly destination="${output_root}/${bucket}/${run_id}"
readonly latest="${output_root}/${bucket}/latest"
readonly latest_tmp="${output_root}/${bucket}/.latest.${run_id}.tmp"
mkdir -p "${output_root}/${bucket}"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" || -e "$latest_tmp" || -L "$latest_tmp" ]] ||
    [[ -e "$latest" && ! -L "$latest" ]]; then
    printf 'Refusing colliding Milestone 1 preflight publication path.\n' >&2; exit 1
fi
mkdir -m 0700 "$stage"
trap 'rm -rf "$stage"' EXIT
if [[ "$mode" == --target-readiness ]]; then
    if ! run_with_tee "$stage/readiness.log" "$M1_READINESS_SCRIPT" --dfu-rehearsed --sample-restore-verified; then
        printf 'format=2\nkind=target-readiness\nstatus=blocked\nproducer_exit=%s\ntee_exit=%s\n' \
            "$M1_PIPE_PRODUCER_STATUS" "$M1_PIPE_TEE_STATUS" >"$stage/manifest.txt"
        evidence_atomic_publish_directory "$stage" "$destination"
        # Failed reports are audit-only; never replace a successful pointer.
        printf 'milestone1.target-readiness=blocked path=%s\n' "$destination" >&2
        exit 2
    fi
    [[ "$(evidence_sha256 "$M1_READINESS_SCRIPT")" == "$M1_READINESS_SCRIPT_SHA256" ]]
    [[ "$(m1_host_identity_sha256 target)" == "$target_id" ]]
    completed_epoch="$(date -u +%s)"
    m1_write_target_readiness "$stage" "$target_id" "$completed_epoch"
    target_digest="$(m1_target_readiness_digest "$stage")"
    m1_verify_target_readiness "$stage" "$target_id" "$target_digest" "$completed_epoch"
else
    completed_epoch="$(date -u +%s)"
    m1_write_controller_preflight "$stage" "$target_dir" "$expected_target" "$expected_bundle" \
        "$controller_id" "$m1n1_device" "$tool_sha" "$binding" "$completed_epoch"
    m1_verify_controller_preflight "$stage" "$expected_target" "$expected_bundle" "$controller_id" \
        "$m1n1_device" "$tool_sha" "$binding" "$(date -u +%s)"
fi
evidence_atomic_publish_directory "$stage" "$destination"
atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
trap - EXIT
printf 'milestone1.%s=passed path=%s\n' "$bucket" "$destination"
if [[ "$mode" == --target-readiness ]]; then
    printf 'target_identity_sha256=%s\ntarget_readiness_bundle_sha256=%s\n' "$target_id" "$target_digest"
    printf 'Retain these anchors independently of the transferred bundle. Checksums alone do not authenticate origin.\n'
fi
