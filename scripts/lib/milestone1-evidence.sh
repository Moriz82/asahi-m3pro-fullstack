#!/usr/bin/env bash
# Offline-testable M1 record production. No device access or tether invocation.

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

m1_artifact_binding() {
    local linux_run=$1 initramfs_run=$2 file hash key
    printf 'source_commit=%s\nm0_run_id=%s\n' "$M1N1_COMMIT" "$(basename "$linux_run")"
    for key in m0_manifest_sha256 image_sha256 dtb_sha256 initramfs_sha256; do
        case "$key" in
            m0_manifest_sha256) file="$linux_run/manifest.txt" ;;
            image_sha256) file="$linux_run/Image" ;;
            dtb_sha256) file="$linux_run/dtbs/apple/t6030-j514s.dtb" ;;
            initramfs_sha256) file="$initramfs_run/$M1_INITRAMFS_NAME" ;;
        esac
        hash=$(shasum -a 256 "$file") || return 1
        printf '%s=%s\n' "$key" "${hash%% *}"
    done
}

m1_provenance() {
    python3 "${project_root}/scripts/lib/milestone1-provenance.py" \
        "$M1_TARGET_MODEL" "$M1_TARGET_BOARD" "$M1_READINESS_SCRIPT_SHA256" \
        "$M1_TARGET_READINESS_MAX_AGE_SECONDS" "$M1_PREFLIGHT_MAX_AGE_SECONDS" "$@"
}

m1_host_identity_sha256() { m1_provenance host-identity "$@"; }
m1_write_target_readiness() { m1_provenance target-write "$@"; }
m1_verify_target_readiness() { m1_provenance target-verify "$@"; }
m1_target_readiness_digest() { m1_provenance target-digest "$@"; }
m1_write_controller_preflight() { m1_provenance controller-write "$@"; }
m1_verify_controller_preflight() { m1_provenance controller-verify "$@"; }
m1_controller_preflight_digest() { m1_provenance controller-digest "$@"; }
m1_execution_identity() { m1_provenance execution-identity "$@"; }

m1_checksum_tree() {
    (cd "$1" && find . -type f ! -path ./SHA256SUMS -print | LC_ALL=C sort |
        while IFS= read -r file; do shasum -a 256 "${file#./}" || exit 1; done >SHA256SUMS)
}

m1_write_execution_evidence() {
    local stage=$1 identity=$2 producer_status=$3 tee_status=$4 status=failed result=failed exit_status=1
    local execution="$stage/execution" manifest_hash
    if ((producer_status == 0 && tee_status == 0)); then status=completed; result=success; exit_status=0; fi
    cp "$execution/host.log" "$execution/serial.log" || return 1
    {
        printf 'format=2\n%s\nstatus=%s\n' "$identity" "$status"
        printf 'producer_exit=%s\ntee_exit=%s\npipe_status=%s,%s\nexit=%s\n' \
            "$producer_status" "$tee_status" "$producer_status" "$tee_status" "$exit_status"
    } >"$execution/manifest.txt"
    m1_checksum_tree "$execution" || return 1
    manifest_hash=$(shasum -a 256 "$execution/manifest.txt") || return 1
    printf '1\t%s\texecution\tserial.log\n' "$result" >"$stage/records.tsv"
    {
        printf 'format=2\n%s\nstatus=%s\n' "$identity" "$status"
        printf 'execution_sha256=%s\nevidence_policy=checksummed-execution-and-serial\n' "${manifest_hash%% *}"
    } >"$stage/manifest.txt"
    m1_checksum_tree "$stage"
}
