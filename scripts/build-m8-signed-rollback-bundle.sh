#!/usr/bin/env bash
# Build signed current and rollback repositories without executing a transaction.
# shellcheck disable=SC1091
set -Eeuo pipefail
PATH=/usr/bin
export PATH

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
[[ $# -eq 10 && $1 == --current-input && $3 == --rollback-input && $5 == --gnupg-home && $7 == --signer && $9 == --out ]] || {
    printf 'usage: %s --current-input ABS --rollback-input ABS --gnupg-home ABS --signer FULL_FINGERPRINT --out ABS\n' "$0" >&2
    exit 64
}
current_input=$2
rollback_input=$4
gnupg_home=$6
signer=$(printf '%s' "$8" | tr '[:lower:]' '[:upper:]')
out=${10}
evidence_abs_dir "$current_input"
evidence_abs_dir "$rollback_input"
evidence_abs_dir "$gnupg_home"
[[ $signer =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || evidence_die 'signer must be a full fingerprint'
[[ $(command -v vercmp) == /usr/bin/vercmp ]] || evidence_die 'trusted /usr/bin/vercmp is required'
evidence_path_under "$out" "$output_root"
output_parent=$(dirname -- "$out")
[[ -d $output_parent && ! -L $output_parent ]] || evidence_die "output parent must already exist: $output_parent"
[[ ! -e $out && ! -L $out ]] || evidence_die "output already exists: $out"
current_input=$(cd -P -- "$current_input" && pwd -P)
rollback_input=$(cd -P -- "$rollback_input" && pwd -P)
gnupg_home=$(cd -P -- "$gnupg_home" && pwd -P)
output_parent=$(cd -P -- "$output_parent" && pwd -P)
out="$output_parent/$(basename -- "$out")"
[[ $current_input != "$rollback_input" ]] || evidence_die 'current and rollback inputs must differ'
[[ $gnupg_home != "$output_parent" && $gnupg_home != "$output_parent"/* && $output_parent != "$gnupg_home"/* ]] || evidence_die 'signer home and output must be disjoint'

"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$current_input" >/dev/null
"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$rollback_input" >/dev/null
while IFS=$'\t' read -r package current_version _ current_hash current_artifact extra; do
    [[ -z $package ]] && continue
    [[ -z ${extra:-} ]] || evidence_die "invalid current package row: $package"
    rollback_row=$(awk -F '\t' -v package="$package" '$1 == package {print $2 "\t" $4 "\t" $5; found++} END {if (found != 1) exit 1}' "$rollback_input/packages.tsv") || evidence_die "rollback package missing: $package"
    IFS=$'\t' read -r rollback_version rollback_hash rollback_artifact <<<"$rollback_row"
    [[ $(vercmp "$current_version" "$rollback_version") -gt 0 ]] || evidence_die "current version is not newer than rollback: $package"
    [[ $current_hash != "$rollback_hash" && $current_artifact != "$rollback_artifact" ]] || evidence_die "current and rollback artifacts are not distinct: $package"
done < <(tail -n +2 "$current_input/packages.tsv")

output_base=$(basename -- "$out")
stage=$(mktemp -d "$output_parent/.${output_base}.stage.XXXXXX") || evidence_die "cannot create output stage: $out"
chmod 700 "$stage"
cleanup() { [[ -z ${stage:-} || ! -e $stage ]] || rm -rf -- "$stage"; }
trap cleanup EXIT
SOFTWARE_OUTPUT_ROOT="$stage" "$project_root/scripts/build-m8-signed-repo.sh" \
    --input-dir "$current_input" --gnupg-home "$gnupg_home" --signer "$signer" --out "$stage/current" >/dev/null
SOFTWARE_OUTPUT_ROOT="$stage" "$project_root/scripts/build-m8-signed-repo.sh" \
    --input-dir "$rollback_input" --gnupg-home "$gnupg_home" --signer "$signer" --out "$stage/rollback" >/dev/null
(umask 077; {
    printf 'format=1\nartifact_class=m8-signed-development-rollback-bundle\narchitecture=aarch64\n'
    printf 'development_only=true\ncanonical=false\npublished=false\ninstalled=false\nbooted=false\nhardware_acceptance=false\nprivate_key_included=false\n'
    printf 'bundle_manifest_signed=false\npackage_sets_signed=true\npackage_set_count=2\npackages_per_set=8\n'
    printf 'current_repository_sha256=%s\n' "$(evidence_sha256 "$stage/current/SHA256SUMS")"
    printf 'rollback_repository_sha256=%s\n' "$(evidence_sha256 "$stage/rollback/SHA256SUMS")"
    printf 'signer_fingerprint=%s\nversion_relation=current-newer-than-rollback\ntransaction=not-executed\n' "$signer"
    printf 'purpose=local-signed-rollback-tooling-only\n'
} >"$stage/manifest.txt")
evidence_write_sums "$stage" "$stage/SHA256SUMS"
"$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$stage" --expected-signer "$signer" >/dev/null
evidence_atomic_publish_directory "$stage" "$out"
[[ -d $out && ! -L $out && ! -e $stage && ! -L $stage ]] || evidence_die 'published output is not exactly the verified stage'
stage=
printf 'signed-rollback-bundle=%s signer=%s transaction=not-executed hardware_acceptance=false\n' "$out" "$signer"
