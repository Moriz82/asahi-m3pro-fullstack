#!/usr/bin/env bash
# Verify two signed package sets and their rollback version relationship.
# shellcheck disable=SC1091
set -Eeuo pipefail
PATH=/usr/bin
export PATH

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 4 && $1 == --bundle && $3 == --expected-signer ]] || {
    printf 'usage: %s --bundle ABS --expected-signer FULL_FINGERPRINT\n' "$0" >&2
    exit 64
}
bundle=$2
expected_signer=$(printf '%s' "$4" | tr '[:lower:]' '[:upper:]')
evidence_abs_dir "$bundle"
[[ $expected_signer =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || evidence_die 'expected signer must be a full fingerprint'
[[ $(command -v vercmp) == /usr/bin/vercmp ]] || evidence_die 'trusted /usr/bin/vercmp is required'
manifest="$bundle/manifest.txt"
evidence_abs_regular "$manifest"
evidence_abs_regular "$bundle/SHA256SUMS"
for track in current rollback; do evidence_abs_dir "$bundle/$track"; done

tmp=$(mktemp -d /tmp/m8-signed-rollback-verify.XXXXXX)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
cat >"$tmp/manifest.keys.expected" <<'EOF'
architecture
artifact_class
booted
bundle_manifest_signed
canonical
current_repository_sha256
development_only
format
hardware_acceptance
installed
package_set_count
package_sets_signed
packages_per_set
private_key_included
published
purpose
rollback_repository_sha256
signer_fingerprint
transaction
version_relation
EOF
awk -F= '!/^[[:space:]]*(#|$)/ {print $1}' "$manifest" | LC_ALL=C sort >"$tmp/manifest.keys.actual"
cmp -s "$tmp/manifest.keys.expected" "$tmp/manifest.keys.actual" || evidence_die 'signed rollback manifest keys changed'
while IFS= read -r key; do evidence_kv "$manifest" "$key" >/dev/null; done <"$tmp/manifest.keys.expected"
[[ $(evidence_kv "$manifest" format) == 1 ]] || evidence_die 'invalid signed rollback format'
[[ $(evidence_kv "$manifest" artifact_class) == m8-signed-development-rollback-bundle ]] || evidence_die 'unexpected artifact class'
[[ $(evidence_kv "$manifest" architecture) == aarch64 ]] || evidence_die 'unexpected architecture'
[[ $(evidence_kv "$manifest" development_only) == true ]] || evidence_die 'bundle is not development-only'
[[ $(evidence_kv "$manifest" package_sets_signed) == true ]] || evidence_die 'package sets are not signed'
for key in canonical published installed booted hardware_acceptance private_key_included bundle_manifest_signed; do
    [[ $(evidence_kv "$manifest" "$key") == false ]] || evidence_die "$key must be false"
done
[[ $(evidence_kv "$manifest" package_set_count) == 2 ]] || evidence_die 'unexpected package-set count'
[[ $(evidence_kv "$manifest" packages_per_set) == 8 ]] || evidence_die 'unexpected packages-per-set count'
[[ $(evidence_kv "$manifest" signer_fingerprint) == "$expected_signer" ]] || evidence_die 'manifest signer does not match external expectation'
[[ $(evidence_kv "$manifest" version_relation) == current-newer-than-rollback ]] || evidence_die 'unexpected version relationship'
[[ $(evidence_kv "$manifest" transaction) == not-executed ]] || evidence_die 'bundle must not claim an executed transaction'
[[ $(evidence_kv "$manifest" purpose) == local-signed-rollback-tooling-only ]] || evidence_die 'unexpected bundle purpose'
[[ $(evidence_kv "$manifest" current_repository_sha256) == "$(evidence_sha256 "$bundle/current/SHA256SUMS")" ]] || evidence_die 'current repository hash mismatch'
[[ $(evidence_kv "$manifest" rollback_repository_sha256) == "$(evidence_sha256 "$bundle/rollback/SHA256SUMS")" ]] || evidence_die 'rollback repository hash mismatch'

for track in current rollback; do
    "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$bundle/$track" --expected-signer "$expected_signer" >/dev/null
done
cmp -s "$bundle/current/coverage.tsv" "$bundle/rollback/coverage.tsv" || evidence_die 'package-set coverage differs'
while IFS=$'\t' read -r package current_version _ current_hash current_artifact extra; do
    [[ -z $package ]] && continue
    [[ -z ${extra:-} ]] || evidence_die "invalid current package row: $package"
    rollback_row=$(awk -F '\t' -v package="$package" '$1 == package {print $2 "\t" $4 "\t" $5; found++} END {if (found != 1) exit 1}' "$bundle/rollback/packages.tsv") || evidence_die "rollback package missing: $package"
    IFS=$'\t' read -r rollback_version rollback_hash rollback_artifact <<<"$rollback_row"
    [[ $(vercmp "$current_version" "$rollback_version") -gt 0 ]] || evidence_die "current version is not newer than rollback: $package"
    [[ $current_hash != "$rollback_hash" && $current_artifact != "$rollback_artifact" ]] || evidence_die "current and rollback artifacts are not distinct: $package"
done < <(tail -n +2 "$bundle/current/packages.tsv")

printf '%s\n' SHA256SUMS current manifest.txt rollback | LC_ALL=C sort >"$tmp/inventory.expected"
(cd "$bundle" && find -P . -mindepth 1 -maxdepth 1 -print | sed 's#^\./##' | LC_ALL=C sort) >"$tmp/inventory.actual"
cmp -s "$tmp/inventory.expected" "$tmp/inventory.actual" || evidence_die 'signed rollback bundle inventory mismatch'
evidence_verify_sums "$bundle" "$bundle/SHA256SUMS"
printf 'M8=signed-rollback-bundle-verified packages=16 signer=%s transaction=not-executed hardware_acceptance=false\n' "$expected_signer"
