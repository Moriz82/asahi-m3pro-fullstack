#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
forbidden_file="$project_root/config/milestone8-forbidden-vm-tokens.txt"
atomic_publish_directory() {
    local source=$1 destination=$2
    python3 - "$source" "$destination" <<'PY'
import ctypes
import os
import platform
import sys

source, destination = (os.fsencode(value) for value in sys.argv[1:3])
libc = ctypes.CDLL(None, use_errno=True)
at_fdcwd = -100

if sys.platform == "darwin":
    function = getattr(libc, "renameatx_np", None)
    if function is None:
        print("atomic no-replace publish is unavailable: renameatx_np", file=sys.stderr)
        raise SystemExit(1)
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(at_fdcwd, source, at_fdcwd, destination, 0x00000004)  # RENAME_EXCL
else:
    function = getattr(libc, "renameat2", None)
    if function is not None:
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        result = function(at_fdcwd, source, at_fdcwd, destination, 0x1)  # RENAME_NOREPLACE
    else:
        syscall_number = {"x86_64": 316, "amd64": 316, "aarch64": 276, "arm64": 276}.get(platform.machine().lower())
        if syscall_number is None:
            print("atomic no-replace publish is unavailable on this Linux architecture", file=sys.stderr)
            raise SystemExit(1)
        function = libc.syscall
        function.restype = ctypes.c_long
        result = function(syscall_number, at_fdcwd, source, at_fdcwd, destination, 0x1)  # RENAME_NOREPLACE

if result != 0:
    error = ctypes.get_errno()
    print(f"atomic no-replace publish failed: [{error}] {os.strerror(error)}", file=sys.stderr)
    raise SystemExit(1)
PY
}
scan_forbidden_metadata() {
    local file=$1 token
    while IFS= read -r token || [[ -n $token ]]; do
        [[ -z $token || $token == \#* ]] && continue
        if grep -aFqi -- "$token" "$file"; then evidence_die "forbidden token '$token' in $file"; fi
    done < "$forbidden_file"
}
[[ $# -eq 8 && $1 == --repo && $3 == --candidate && $5 == --anchor && $7 == --out ]] || { printf 'usage: %s --repo ABS --candidate ABS --anchor ABS --out ABS\n' "$0" >&2; exit 64; }
before=$2; candidate=$4; anchor=$6; out=$8
evidence_abs_dir "$before"
evidence_abs_dir "$candidate"
evidence_path_under "$out" "$output_root"
[[ $out == /* ]] || evidence_die "path is not absolute: $out"
output_parent=$(dirname -- "$out")
[[ -d $output_parent && ! -L $output_parent ]] || evidence_die "output parent must already exist: $output_parent"
[[ ! -e $out && ! -L $out ]] || evidence_die "output already exists: $out"
command -v python3 >/dev/null 2>&1 || evidence_die 'python3 is required for atomic output publication'
evidence_abs_regular "$anchor"
evidence_abs_regular "$forbidden_file"; scan_forbidden_metadata "$anchor"
[[ $anchor != "$out" && $anchor != "$out"/* ]] || evidence_die 'external anchor must be outside output bundle'
evidence_readonly "$anchor"
[[ $(evidence_kv "$anchor" format) == 1 ]] || evidence_die 'invalid external anchor format'
[[ $(evidence_kv "$anchor" anchor_type) == external-source-snapshot ]] || evidence_die 'invalid external anchor type'
[[ $(evidence_kv "$anchor" source_snapshot_sha256) == "$(evidence_sha256 "$before/SHA256SUMS")" ]] || evidence_die 'external anchor does not pin source snapshot'
"$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$before" >/dev/null
"$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$candidate" >/dev/null
output_base=$(basename -- "$out")
stage=$(mktemp -d "$output_parent/.${output_base}.stage.XXXXXX") || evidence_die "cannot create output stage: $out"
chmod 700 "$stage"
cleanup() { [[ -z ${stage:-} || ! -e $stage ]] || rm -rf -- "$stage"; }
trap cleanup EXIT
for state in before candidate rollback; do
    mkdir -p -- "$stage/$state/packages"
    chmod 700 "$stage/$state" "$stage/$state/packages"
done
copy_repo() {
    local source=$1 destination=$2 file
    cp -p -- "$source/manifest.txt" "$source/repo.db" "$source/packages.tsv" "$source/coverage.tsv" "$source/SHA256SUMS" "$destination/"
    while IFS= read -r -d '' file; do cp -p -- "$file" "$destination/packages/$(basename "$file")"; done < <(find -P "$source/packages" -type f -print0 | sort -z)
}
copy_repo "$before" "$stage/before"; copy_repo "$candidate" "$stage/candidate"; copy_repo "$before" "$stage/rollback"
before_hash=$(evidence_sha256 "$stage/before/SHA256SUMS"); candidate_hash=$(evidence_sha256 "$stage/candidate/SHA256SUMS"); rollback_hash=$(evidence_sha256 "$stage/rollback/SHA256SUMS")
before_coverage_hash=$(evidence_sha256 "$stage/before/coverage.tsv"); candidate_coverage_hash=$(evidence_sha256 "$stage/candidate/coverage.tsv"); rollback_coverage_hash=$(evidence_sha256 "$stage/rollback/coverage.tsv")
(umask 077; {
    printf 'format=1\nstatus=static-snapshot\nhardware_acceptance=false\n'
    printf 'source_before_sha256=%s\nsource_candidate_sha256=%s\nsource_rollback_sha256=%s\n' "$before_hash" "$candidate_hash" "$rollback_hash"
    printf 'coverage_before_sha256=%s\ncoverage_candidate_sha256=%s\ncoverage_rollback_sha256=%s\n' "$before_coverage_hash" "$candidate_coverage_hash" "$rollback_coverage_hash"
    printf 'external_anchor_sha256=%s\n' "$(evidence_sha256 "$anchor")"
    printf 'update=static-snapshot\nrollback=static-snapshot\nreversible=true\nmutated_source=false\n'
} > "$stage/transaction.txt")
(umask 077; {
    printf 'transaction\toperation\tstate\tmanifest_sha256\tcoverage_sha256\tstatus\treversible\n'
    printf '1\tbefore\tbefore\t%s\t%s\tobserved\tyes\n' "$before_hash" "$before_coverage_hash"
    printf '2\tupdate\tcandidate\t%s\t%s\tplanned\tyes\n' "$candidate_hash" "$candidate_coverage_hash"
    printf '3\trollback\trollback\t%s\t%s\tobserved\tyes\n' "$rollback_hash" "$rollback_coverage_hash"
} > "$stage/transactions.tsv")
evidence_write_sums "$stage" "$stage/SHA256SUMS"
"$project_root/scripts/verify-m8-update-rollback.sh" --evidence "$stage" --anchor "$anchor" >/dev/null
atomic_publish_directory "$stage" "$out"
[[ -d $out && ! -L $out && ! -e $stage && ! -L $stage ]] || evidence_die 'published output is not exactly the verified stage'
stage=
printf 'rollback-evidence=%s\n' "$out"
