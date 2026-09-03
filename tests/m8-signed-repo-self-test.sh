#!/usr/bin/env bash
# Exercise the signed M8 development repository inside the pinned Arch image.
# shellcheck disable=SC1091
set -Eeuo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
test_root=${TEST_OUTPUT_ROOT:-/tmp}
tmp=$(mktemp -d "$test_root/m8-signed-repo.XXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

expect_fail() {
    if "$@" >/dev/null 2>&1; then
        printf 'unexpected success: %s\n' "$*" >&2
        exit 1
    fi
}
update_manifest_hash() {
    local repo=$1 key=$2 file=$3 hash
    hash=$(evidence_sha256 "$file")
    awk -F= -v key="$key" -v hash="$hash" 'BEGIN {OFS="="} $1 == key {$0=key "=" hash} {print}' \
        "$repo/manifest.txt" >"$repo/manifest.txt.new"
    mv -- "$repo/manifest.txt.new" "$repo/manifest.txt"
}
refresh_sums() {
    evidence_write_sums "$1" "$1/SHA256SUMS"
}
make_key() {
    local home=$1 identity=$2
    mkdir -m 700 -- "$home"
    gpg --no-options --homedir "$home" --batch --pinentry-mode loopback --passphrase '' \
        --quick-gen-key "$identity" ed25519 sign 1d >/dev/null 2>&1
    gpg --no-options --homedir "$home" --batch --with-colons --list-secret-keys "$identity" |
        awk -F: '$1 == "fpr" {print toupper($10); exit}'
}

mkdir -m 700 -- "$tmp/keys" "$tmp/repos"
key_one_home="$tmp/keys/one"
key_two_home="$tmp/keys/two"
key_one=$(make_key "$key_one_home" 'M8 self-test one <m8-one.invalid>')
key_two=$(make_key "$key_two_home" 'M8 self-test two <m8-two.invalid>')
[[ $key_one =~ ^[0-9A-F]{40}$ && $key_two =~ ^[0-9A-F]{40}$ && $key_one != "$key_two" ]] || evidence_die 'test key generation failed'

fixture="$project_root/tests/fixtures/m8/package-input"
repo="$tmp/repos/repo"
env SOFTWARE_OUTPUT_ROOT="$tmp/repos" "$project_root/scripts/build-m8-signed-repo.sh" \
    --input-dir "$fixture" --gnupg-home "$key_one_home" --signer "$key_one" --out "$repo" >/dev/null
"$project_root/scripts/verify-m8-signed-repo.sh" --repo "$repo" --expected-signer "$key_one" >/dev/null

# The published repository must remain verifiable after the private key is gone.
secret_bundle="$tmp/secret-key.gpg"
gpg --no-options --homedir "$key_one_home" --batch --export-secret-keys "$key_one" >"$secret_bundle"
rm -rf -- "$key_one_home"
"$project_root/scripts/verify-m8-signed-repo.sh" --repo "$repo" --expected-signer "$key_one" >/dev/null
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$repo" --expected-signer "$key_two"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$repo" --expected-signer "${key_one:0:16}"

package_tamper="$tmp/repos/package-tamper"
cp -R -- "$repo" "$package_tamper"
artifact=$(awk -F '\t' 'NR == 2 {print $5}' "$package_tamper/packages.tsv")
printf 'tamper\n' >>"$package_tamper/$artifact"
artifact_hash=$(evidence_sha256 "$package_tamper/$artifact")
awk -F '\t' -v hash="$artifact_hash" 'BEGIN {OFS="\t"} NR == 2 {$4=hash} {print}' \
    "$package_tamper/packages.tsv" >"$package_tamper/packages.tsv.new"
mv -- "$package_tamper/packages.tsv.new" "$package_tamper/packages.tsv"
update_manifest_hash "$package_tamper" package_manifest_sha256 "$package_tamper/packages.tsv"
refresh_sums "$package_tamper"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$package_tamper" --expected-signer "$key_one"

database_tamper="$tmp/repos/database-tamper"
cp -R -- "$repo" "$database_tamper"
printf 'tamper\n' >>"$database_tamper/asahi-m8-development.db"
update_manifest_hash "$database_tamper" database_sha256 "$database_tamper/asahi-m8-development.db"
refresh_sums "$database_tamper"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$database_tamper" --expected-signer "$key_one"

files_tamper="$tmp/repos/files-tamper"
cp -R -- "$repo" "$files_tamper"
printf 'tamper\n' >>"$files_tamper/asahi-m8-development.files"
update_manifest_hash "$files_tamper" files_database_sha256 "$files_tamper/asahi-m8-development.files"
refresh_sums "$files_tamper"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$files_tamper" --expected-signer "$key_one"

wrong_key="$tmp/repos/wrong-key"
cp -R -- "$repo" "$wrong_key"
gpg --no-options --homedir "$key_two_home" --batch --export-options export-minimal --export "$key_two" >"$wrong_key/signing-key.gpg"
update_manifest_hash "$wrong_key" signing_key_sha256 "$wrong_key/signing-key.gpg"
refresh_sums "$wrong_key"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$wrong_key" --expected-signer "$key_one"

secret_key="$tmp/repos/secret-key"
cp -R -- "$repo" "$secret_key"
cp -p -- "$secret_bundle" "$secret_key/signing-key.gpg"
update_manifest_hash "$secret_key" signing_key_sha256 "$secret_key/signing-key.gpg"
refresh_sums "$secret_key"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$secret_key" --expected-signer "$key_one"

missing="$tmp/repos/missing"
cp -R -- "$repo" "$missing"
rm -f -- "$missing/$artifact"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$missing" --expected-signer "$key_one"

extra="$tmp/repos/extra"
cp -R -- "$repo" "$extra"
printf 'extra\n' >"$extra/extra"
refresh_sums "$extra"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$extra" --expected-signer "$key_one"
rm -f -- "$extra/extra"
ln -s manifest.txt "$extra/extra"
expect_fail "$project_root/scripts/verify-m8-signed-repo.sh" --repo "$extra" --expected-signer "$key_one"

missing_key_home="$tmp/keys/missing"
mkdir -m 700 -- "$missing_key_home"
missing_key_out="$tmp/repos/missing-key"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/repos" "$project_root/scripts/build-m8-signed-repo.sh" \
    --input-dir "$fixture" --gnupg-home "$missing_key_home" --signer "$key_one" --out "$missing_key_out"
[[ ! -e $missing_key_out && ! -L $missing_key_out ]] || evidence_die 'failed builder left output'
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/repos" "$project_root/scripts/build-m8-signed-repo.sh" \
    --input-dir "$fixture" --gnupg-home "$key_two_home" --signer "${key_two:0:16}" --out "$missing_key_out"

existing="$tmp/repos/existing"
mkdir -m 700 -- "$existing"
printf 'preserve\n' >"$existing/marker"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/repos" "$project_root/scripts/build-m8-signed-repo.sh" \
    --input-dir "$fixture" --gnupg-home "$key_two_home" --signer "$key_two" --out "$existing"
[[ $(cat "$existing/marker") == preserve ]] || evidence_die 'existing destination changed'

printf 'M8 signed repository self-tests passed\n'
