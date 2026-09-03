#!/usr/bin/env bash
# Verify one hash-pinned upstream Asahi ALARM repository snapshot offline.
# shellcheck disable=SC1091
set -Eeuo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
default_snapshot="$project_root/config/milestone8-upstream-signed-snapshot.env"
default_required="$project_root/config/milestone8-upstream-required-packages.txt"

[[ $# -eq 2 || $# -eq 4 ]] || {
    printf 'usage: %s --input-dir ABS [--packages-dir ABS]\n' "$0" >&2
    exit 64
}
[[ $1 == --input-dir ]] || { printf 'first option must be --input-dir\n' >&2; exit 64; }
input=$2
packages_dir=
if [[ $# -eq 4 ]]; then
    [[ $3 == --packages-dir ]] || { printf 'second option must be --packages-dir\n' >&2; exit 64; }
    packages_dir=$4
fi
snapshot=${M8_SIGNED_SNAPSHOT:-$default_snapshot}
required=${M8_SIGNED_REQUIRED_PACKAGES:-$default_required}
evidence_abs_dir "$input"
[[ -z $packages_dir ]] || evidence_abs_dir "$packages_dir"
evidence_abs_regular "$snapshot"
evidence_abs_regular "$required"
command -v bsdtar >/dev/null || evidence_die 'bsdtar is required'
command -v base64 >/dev/null || evidence_die 'base64 is required'
command -v gpgv >/dev/null || evidence_die 'gpgv is required'

for key in format release_tag keyring_package keyring_package_sha256 keyring_signature keyring_signature_sha256 keyring_member repository_database repository_database_sha256 repository_signature repository_signature_sha256 signer_fingerprint hardware_acceptance; do
    evidence_kv "$snapshot" "$key" >/dev/null
done
[[ $(evidence_kv "$snapshot" format) == 1 ]] || evidence_die 'invalid signed snapshot format'
[[ $(evidence_kv "$snapshot" hardware_acceptance) == false ]] || evidence_die 'signed snapshot cannot assert hardware acceptance'
fingerprint=$(evidence_kv "$snapshot" signer_fingerprint)
[[ $fingerprint =~ ^[0-9A-F]{40}$ ]] || evidence_die 'invalid signer fingerprint'

keyring_package=$(evidence_kv "$snapshot" keyring_package)
keyring_signature=$(evidence_kv "$snapshot" keyring_signature)
repository_database=$(evidence_kv "$snapshot" repository_database)
repository_signature=$(evidence_kv "$snapshot" repository_signature)
for name in "$keyring_package" "$keyring_signature" "$repository_database" "$repository_signature"; do
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || evidence_die "unsafe snapshot filename: $name"
    evidence_abs_regular "$input/$name"
done
for binding in \
    "$keyring_package:keyring_package_sha256" \
    "$keyring_signature:keyring_signature_sha256" \
    "$repository_database:repository_database_sha256" \
    "$repository_signature:repository_signature_sha256"; do
    name=${binding%%:*}
    hash_key=${binding#*:}
    expected=$(evidence_kv "$snapshot" "$hash_key")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || evidence_die "invalid snapshot hash: $hash_key"
    evidence_hash_file "$input/$name" "$expected"
done

keyring_member=$(evidence_kv "$snapshot" keyring_member)
[[ $keyring_member == usr/share/pacman/keyrings/*.gpg && $keyring_member != *..* ]] || evidence_die 'unsafe keyring member'
[[ $(bsdtar -tf "$input/$keyring_package" | grep -Fxc -- "$keyring_member") -eq 1 ]] || evidence_die 'keyring member missing or duplicated'
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m8-signed.XXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
bsdtar -xOf "$input/$keyring_package" "$keyring_member" >"$tmp/keyring.asc"
awk '
    /^-----BEGIN PGP PUBLIC KEY BLOCK-----$/ { inside=1; next }
    /^-----END PGP PUBLIC KEY BLOCK-----$/ { exit }
    inside && /^$/ { payload=1; next }
    inside && payload && $0 !~ /^=/ { printf "%s", $0 }
' "$tmp/keyring.asc" | base64 -d >"$tmp/keyring.gpg"
[[ -s $tmp/keyring.gpg ]] || evidence_die 'keyring dearmor failed'

verify_signature() {
    local signature=$1 payload=$2 status
    status=$(gpgv --status-fd 1 --keyring "$tmp/keyring.gpg" "$signature" "$payload" 2>&1) || {
        printf '%s\n' "$status" >&2
        evidence_die "signature verification failed: $payload"
        return 1
    }
    grep -F "[GNUPG:] VALIDSIG $fingerprint " <<<"$status" >/dev/null || evidence_die "unexpected signer: $payload"
}
verify_signature "$input/$keyring_signature" "$input/$keyring_package"
verify_signature "$input/$repository_signature" "$input/$repository_database"

if grep -Evq '^[a-z0-9][a-z0-9@._+-]*$' "$required"; then evidence_die 'invalid required package name'; fi
[[ $(LC_ALL=C sort -u "$required" | wc -l | tr -d '[:space:]') == $(wc -l <"$required" | tr -d '[:space:]') ]] || evidence_die 'duplicate required package'
LC_ALL=C sort -c "$required" || evidence_die 'required package list is not sorted'
bsdtar -tf "$input/$repository_database" >"$tmp/database.inventory"
if grep -Eq '(^/|(^|/)\.\.?(/|$))' "$tmp/database.inventory"; then evidence_die 'unsafe repository database path'; fi

printf 'package\tversion\tarchitecture\tsha256\tartifact\n' >"$tmp/packages.tsv"
repo_field() {
    local file=$1 marker=$2
    awk -v marker="%${marker}%" '$0 == marker { getline; print; found++ } END { if (found != 1) exit 1 }' "$file"
}
while IFS= read -r package; do
    candidates="$tmp/${package}.candidates"
    members="$tmp/${package}.members"
    awk -v prefix="$package-" 'index($0, prefix) == 1 && $0 ~ /\/desc$/ {print}' "$tmp/database.inventory" >"$candidates"
    : >"$members"
    while IFS= read -r candidate; do
        candidate_desc="$tmp/${package}.candidate.desc"
        bsdtar -xOf "$input/$repository_database" "$candidate" >"$candidate_desc"
        candidate_name=$(repo_field "$candidate_desc" NAME 2>/dev/null || true)
        [[ $candidate_name != "$package" ]] || printf '%s\n' "$candidate" >>"$members"
    done <"$candidates"
    [[ $(wc -l <"$members" | tr -d '[:space:]') == 1 ]] || evidence_die "required package missing or duplicated: $package"
    member=$(<"$members")
    desc="$tmp/${package}.desc"
    bsdtar -xOf "$input/$repository_database" "$member" >"$desc"
    name=$(repo_field "$desc" NAME) || evidence_die "invalid NAME metadata: $package"
    version=$(repo_field "$desc" VERSION) || evidence_die "invalid VERSION metadata: $package"
    architecture=$(repo_field "$desc" ARCH) || evidence_die "invalid ARCH metadata: $package"
    hash=$(repo_field "$desc" SHA256SUM) || evidence_die "invalid SHA256SUM metadata: $package"
    artifact=$(repo_field "$desc" FILENAME) || evidence_die "invalid FILENAME metadata: $package"
    [[ $name == "$package" ]] || evidence_die "repository package name mismatch: $package"
    [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]] || evidence_die "unsafe repository version: $package"
    [[ $architecture == aarch64 || $architecture == any ]] || evidence_die "wrong repository architecture: $package"
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || evidence_die "invalid repository package hash: $package"
    [[ $artifact =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.pkg\.tar\.(xz|zst)$ ]] || evidence_die "unsafe repository artifact: $package"
    if [[ -n $packages_dir ]]; then
        evidence_abs_regular "$packages_dir/$artifact"
        evidence_abs_regular "$packages_dir/$artifact.sig"
        evidence_hash_file "$packages_dir/$artifact" "$hash"
        verify_signature "$packages_dir/$artifact.sig" "$packages_dir/$artifact"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$package" "$version" "$architecture" "$hash" "$artifact" >>"$tmp/packages.tsv"
done <"$required"

[[ -n $packages_dir ]] && artifacts=verified || artifacts=metadata-only
printf 'M8=upstream-signed-snapshot-verified packages=%s artifacts=%s signer=%s hardware_acceptance=false\n' "$(wc -l <"$required" | tr -d '[:space:]')" "$artifacts" "$fingerprint"
