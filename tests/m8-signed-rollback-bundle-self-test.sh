#!/usr/bin/env bash
# Exercise signed current/rollback package sets inside the pinned Arch image.
# shellcheck disable=SC1091
set -Eeuo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
test_root=${TEST_OUTPUT_ROOT:-/tmp}
tmp=$(mktemp -d "$test_root/m8-signed-rollback.XXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
expect_fail() {
    if "$@" >/dev/null 2>&1; then
        printf 'unexpected success: %s\n' "$*" >&2
        exit 1
    fi
}
update_hash() {
    local manifest=$1 key=$2 file=$3 hash
    hash=$(evidence_sha256 "$file")
    awk -F= -v key="$key" -v hash="$hash" 'BEGIN {OFS="="} $1 == key {$0=key "=" hash} {print}' \
        "$manifest" >"$manifest.new"
    mv -- "$manifest.new" "$manifest"
}

mkdir -m 700 -- "$tmp/key" "$tmp/output"
gpg --no-options --homedir "$tmp/key" --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'M8 rollback self-test <m8-rollback.invalid>' ed25519 sign 1d >/dev/null 2>&1
signer=$(gpg --no-options --homedir "$tmp/key" --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" {print toupper($10); exit}')
[[ $signer =~ ^[0-9A-F]{40}$ ]] || evidence_die 'test key generation failed'
current="$project_root/tests/fixtures/m8/package-input-candidate"
rollback="$project_root/tests/fixtures/m8/package-input"
bundle="$tmp/output/bundle"
env SOFTWARE_OUTPUT_ROOT="$tmp/output" "$project_root/scripts/build-m8-signed-rollback-bundle.sh" \
    --current-input "$current" --rollback-input "$rollback" --gnupg-home "$tmp/key" \
    --signer "$signer" --out "$bundle" >/dev/null
"$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$bundle" --expected-signer "$signer" >/dev/null

rm -rf -- "$tmp/key"
"$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$bundle" --expected-signer "$signer" >/dev/null
expect_fail "$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$bundle" \
    --expected-signer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
expect_fail "$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$bundle" \
    --expected-signer "${signer:0:16}"

tamper="$tmp/output/tamper"
cp -R -- "$bundle" "$tamper"
artifact=$(awk -F '\t' 'NR == 2 {print $5}' "$tamper/current/packages.tsv")
printf 'tamper\n' >>"$tamper/current/$artifact"
artifact_hash=$(evidence_sha256 "$tamper/current/$artifact")
awk -F '\t' -v hash="$artifact_hash" 'BEGIN {OFS="\t"} NR == 2 {$4=hash} {print}' \
    "$tamper/current/packages.tsv" >"$tamper/current/packages.tsv.new"
mv -- "$tamper/current/packages.tsv.new" "$tamper/current/packages.tsv"
update_hash "$tamper/current/manifest.txt" package_manifest_sha256 "$tamper/current/packages.tsv"
evidence_write_sums "$tamper/current" "$tamper/current/SHA256SUMS"
update_hash "$tamper/manifest.txt" current_repository_sha256 "$tamper/current/SHA256SUMS"
evidence_write_sums "$tamper" "$tamper/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$tamper" --expected-signer "$signer"

reversed="$tmp/output/reversed"
cp -R -- "$bundle" "$reversed"
mv -- "$reversed/current" "$reversed/swap"
mv -- "$reversed/rollback" "$reversed/current"
mv -- "$reversed/swap" "$reversed/rollback"
update_hash "$reversed/manifest.txt" current_repository_sha256 "$reversed/current/SHA256SUMS"
update_hash "$reversed/manifest.txt" rollback_repository_sha256 "$reversed/rollback/SHA256SUMS"
evidence_write_sums "$reversed" "$reversed/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$reversed" --expected-signer "$signer"

extra="$tmp/output/extra"
cp -R -- "$bundle" "$extra"
printf 'extra\n' >"$extra/extra"
evidence_write_sums "$extra" "$extra/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-signed-rollback-bundle.sh" --bundle "$extra" --expected-signer "$signer"

mkdir -m 700 -- "$tmp/key-two"
gpg --no-options --homedir "$tmp/key-two" --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'M8 rollback second key <m8-rollback-two.invalid>' ed25519 sign 1d >/dev/null 2>&1
signer_two=$(gpg --no-options --homedir "$tmp/key-two" --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" {print toupper($10); exit}')
failed_out="$tmp/output/failed"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/output" "$project_root/scripts/build-m8-signed-rollback-bundle.sh" \
    --current-input "$rollback" --rollback-input "$current" --gnupg-home "$tmp/key-two" \
    --signer "$signer_two" --out "$failed_out"
[[ ! -e $failed_out && ! -L $failed_out ]] || evidence_die 'failed rollback builder left output'

nested_key="$tmp/output/nested-key"
cp -R -- "$tmp/key-two" "$nested_key"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/output" "$project_root/scripts/build-m8-signed-rollback-bundle.sh" \
    --current-input "$current" --rollback-input "$rollback" --gnupg-home "$nested_key" \
    --signer "$signer_two" --out "$failed_out"
[[ ! -e $failed_out && ! -L $failed_out ]] || evidence_die 'nested key home produced output'

existing="$tmp/output/existing"
mkdir -m 700 -- "$existing"
printf 'preserve\n' >"$existing/marker"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/output" "$project_root/scripts/build-m8-signed-rollback-bundle.sh" \
    --current-input "$current" --rollback-input "$rollback" --gnupg-home "$tmp/key-two" \
    --signer "$signer_two" --out "$existing"
[[ $(cat "$existing/marker") == preserve ]] || evidence_die 'existing destination changed'

printf 'M8 signed rollback bundle self-tests passed\n'
