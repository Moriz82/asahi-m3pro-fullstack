#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly caller_attestation="${M1_EXECUTE_ATTESTATION-}"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
source "${project_root}/scripts/lib/milestone1-evidence.sh"
source "${project_root}/scripts/lib/evidence.sh"
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
[[ "${1:-}" == --execute && $# -eq 5 && "$2" == --expected-target-identity-sha256 &&
   "$3" =~ ^[0-9a-f]{64}$ && "$4" == --expected-target-bundle-sha256 && "$5" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Refusing tether execution. Require --execute --expected-target-identity-sha256 HEX --expected-target-bundle-sha256 HEX and review.\n' >&2
    exit 2
}
readonly expected_target="$3" expected_bundle="$5"
[[ "$caller_attestation" == "$required_attestation" ]] || {
    printf 'Set M1_EXECUTE_ATTESTATION=%s explicitly before invocation.\n' "$required_attestation" >&2
    exit 2
}
command -v python3 >/dev/null || { printf 'Missing python3 for device validation.\n' >&2; exit 1; }
m1n1_device="$(validate_m1n1_device "$M1N1DEVICE")" || exit 1
readonly m1n1_device
controller_id="$(m1_host_identity_sha256 controller)" || exit 1
readonly controller_id
test -n "$M1_M1N1_SOURCE_DIR" && test -f "$M1_M1N1_SOURCE_DIR/$M1_M1N1_TOOL_RELATIVE" || {
    printf 'Pinned m1n1 source/tool is missing.\n' >&2; exit 2;
}
test "$(git -C "$M1_M1N1_SOURCE_DIR" rev-parse HEAD)" = "$M1N1_COMMIT"
test -z "$(git -C "$M1_M1N1_SOURCE_DIR" status --porcelain --untracked-files=all)"
"${project_root}/scripts/verify-milestone0.sh"
preflight_dir="$(resolve_versioned_run "${output_root}/preflight" latest 'M1 preflight')" || exit 1
readonly preflight_dir

m0_run_dir="$(resolve_versioned_run "${m0_root}/linux-full" latest 'M0 Linux')" || exit 1
m1_initramfs_run_dir="$(resolve_versioned_run "${output_root}/initramfs" latest 'M1 initramfs')" || exit 1
readonly m0_run_dir m1_initramfs_run_dir
readonly image="${m0_run_dir}/Image"
readonly dtb="${m0_run_dir}/dtbs/apple/t6030-j514s.dtb"
readonly initramfs="${m1_initramfs_run_dir}/${M1_INITRAMFS_NAME}"
readonly tool="${M1_M1N1_SOURCE_DIR}/${M1_M1N1_TOOL_RELATIVE}"
"${project_root}/scripts/verify-linux-full.sh" "$m0_run_dir"
"${project_root}/scripts/verify-milestone1-initramfs.sh" "$m1_initramfs_run_dir" "$m0_run_dir"
binding="$(m1_artifact_binding "$m0_run_dir" "$m1_initramfs_run_dir")" || exit 1
readonly binding
tool_sha="$(evidence_sha256 "$tool")" || exit 1
readonly tool_sha
m1_verify_controller_preflight "$preflight_dir" "$expected_target" "$expected_bundle" "$controller_id" \
    "$m1n1_device" "$tool_sha" "$binding" "$(date -u +%s)"
readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly stage="${output_root}/sessions/.${run_id}.tmp"
readonly destination="${output_root}/sessions/${run_id}"
readonly execution="${stage}/execution"
mkdir -p "${output_root}/sessions"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" ]]; then
    printf 'Refusing colliding Milestone 1 session publication path.\n' >&2
    exit 1
fi
mkdir -m 0700 "$stage"
mkdir "$execution"
cp -R "$preflight_dir" "$execution/preflight"
# Check the retained copy, current local bindings, and ages immediately before
# invocation. Expected target anchors must come from the caller, never the copy.
[[ "$(m1_host_identity_sha256 controller)" == "$controller_id" ]]
[[ "$(validate_m1n1_device "$M1N1DEVICE")" == "$m1n1_device" ]]
[[ "$(evidence_sha256 "$tool")" == "$tool_sha" ]]
[[ "$(m1_artifact_binding "$m0_run_dir" "$m1_initramfs_run_dir")" == "$binding" ]]
test "$(git -C "$M1_M1N1_SOURCE_DIR" rev-parse HEAD)" = "$M1N1_COMMIT"
test -z "$(git -C "$M1_M1N1_SOURCE_DIR" status --porcelain --untracked-files=all)"
execution_started_epoch="$(date -u +%s)"
readonly execution_started_epoch
m1_verify_controller_preflight "$execution/preflight" "$expected_target" "$expected_bundle" "$controller_id" \
    "$m1n1_device" "$tool_sha" "$binding" "$execution_started_epoch"
provenance="$(m1_execution_identity "$execution/preflight" "$execution_started_epoch")" || exit 1
printf -v command_line 'M1N1DEVICE=%q python3 %q --compression %q %q %q %q' \
    "$m1n1_device" "$tool" "$M1_COMPRESSION" "$image" "$dtb" "$initramfs"
printf -v identity '%s\n%s\nexecution_id=%s\ntool=%s\ndevice=%s\ncompression=%s\nstorage_policy=ram-only\ncommand=%s' \
    "$binding" "$provenance" "$run_id" "$tool" "$m1n1_device" "$M1_COMPRESSION" "$command_line"
readonly identity
printf 'format=2\nstatus=started\n%s\n' "$identity" >"$execution/manifest.txt"
cd "$M1_M1N1_SOURCE_DIR"
if run_with_tee "$execution/host.log" env M1N1DEVICE="$m1n1_device" python3 "$tool" --compression "$M1_COMPRESSION" "$image" "$dtb" "$initramfs"; then :; fi
tether_status="$M1_PIPE_PRODUCER_STATUS"
tee_status="$M1_PIPE_TEE_STATUS"
if ((tether_status != 0 || tee_status != 0)); then
    execution_status=1
else
    execution_status=0
fi
m1_write_execution_evidence "$stage" "$identity" "$tether_status" "$tee_status"
evidence_atomic_publish_directory "$stage" "$destination"
printf 'milestone1.session=%s\n' "$destination"
exit "$execution_status"
