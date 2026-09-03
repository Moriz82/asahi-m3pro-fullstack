#!/usr/bin/env bash
# Verify a local signed M8 development repository without a private key.
# shellcheck disable=SC1091
set -Eeuo pipefail
PATH=/usr/bin
export PATH

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/m8-coverage.sh"
coverage_contract="$project_root/config/milestone8-platform-coverage.tsv"
[[ $# -eq 4 && $1 == --repo && $3 == --expected-signer ]] || {
    printf 'usage: %s --repo ABS --expected-signer FULL_FINGERPRINT\n' "$0" >&2
    exit 64
}
repo=$2
expected_signer=$(printf '%s' "$4" | tr '[:lower:]' '[:upper:]')
evidence_abs_dir "$repo"
[[ $expected_signer =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || evidence_die 'expected signer must be a full fingerprint'
for command in bsdtar base64 gpgv python3; do
    [[ $(command -v "$command") == "/usr/bin/$command" ]] || evidence_die "trusted /usr/bin/$command is required"
done

manifest="$repo/manifest.txt"
packages="$repo/packages.tsv"
public_key="$repo/signing-key.gpg"
database="$repo/asahi-m8-development.db"
database_signature="$database.sig"
files_database="$repo/asahi-m8-development.files"
files_signature="$files_database.sig"
for file in "$manifest" "$packages" "$public_key" "$database" "$database_signature" "$files_database" "$files_signature" "$repo/coverage.tsv" "$repo/SHA256SUMS"; do
    evidence_abs_regular "$file"
done

tmp=$(mktemp -d /tmp/m8-signed-verify.XXXXXX)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
cat >"$tmp/manifest.keys.expected" <<'EOF'
architecture
booted
canonical
database_sha256
development_only
files_database_sha256
format
hardware_acceptance
installed
package_count
package_manifest_sha256
platform_coverage
platform_coverage_sha256
private_key_included
published
purpose
repo_name
signed
signer_fingerprint
signing_key_sha256
tool_gpg
tool_repo_add
EOF
awk -F= '!/^[[:space:]]*(#|$)/ {print $1}' "$manifest" | LC_ALL=C sort >"$tmp/manifest.keys.actual"
cmp -s "$tmp/manifest.keys.expected" "$tmp/manifest.keys.actual" || evidence_die 'signed repository manifest keys changed'
while IFS= read -r key; do evidence_kv "$manifest" "$key" >/dev/null; done <"$tmp/manifest.keys.expected"
[[ $(evidence_kv "$manifest" format) == 1 ]] || evidence_die 'invalid signed repository format'
[[ $(evidence_kv "$manifest" repo_name) == asahi-m8-development ]] || evidence_die 'unexpected repository name'
[[ $(evidence_kv "$manifest" architecture) == aarch64 ]] || evidence_die 'unexpected repository architecture'
[[ $(evidence_kv "$manifest" development_only) == true ]] || evidence_die 'repository is not development-only'
[[ $(evidence_kv "$manifest" signed) == true ]] || evidence_die 'repository is not signed'
for key in canonical published installed booted hardware_acceptance private_key_included; do
    [[ $(evidence_kv "$manifest" "$key") == false ]] || evidence_die "$key must be false"
done
[[ $(evidence_kv "$manifest" platform_coverage) == static-plan-incomplete ]] || evidence_die 'platform coverage is not incomplete'
[[ $(evidence_kv "$manifest" purpose) == local-signed-test-repository-only ]] || evidence_die 'unexpected signed repository purpose'
[[ $(evidence_kv "$manifest" signer_fingerprint) == "$expected_signer" ]] || evidence_die 'manifest signer does not match external expectation'
[[ $(evidence_kv "$manifest" package_count) == 8 ]] || evidence_die 'unexpected package count'
[[ $(evidence_kv "$manifest" package_manifest_sha256) == "$(evidence_sha256 "$packages")" ]] || evidence_die 'package manifest hash mismatch'
[[ $(evidence_kv "$manifest" platform_coverage_sha256) == "$(evidence_sha256 "$repo/coverage.tsv")" ]] || evidence_die 'coverage hash mismatch'
[[ $(evidence_kv "$manifest" signing_key_sha256) == "$(evidence_sha256 "$public_key")" ]] || evidence_die 'public key hash mismatch'
[[ $(evidence_kv "$manifest" database_sha256) == "$(evidence_sha256 "$database")" ]] || evidence_die 'repository database hash mismatch'
[[ $(evidence_kv "$manifest" files_database_sha256) == "$(evidence_sha256 "$files_database")" ]] || evidence_die 'files database hash mismatch'
m8_validate_platform_coverage "$repo/coverage.tsv" "$coverage_contract"

python3 - "$public_key" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
offset = 0
primary = 0
secret = 0
packets = 0
while offset < len(data):
    first = data[offset]
    offset += 1
    if first & 0x80 == 0:
        raise SystemExit("invalid OpenPGP packet header")
    if first & 0x40:
        tag = first & 0x3F
        if offset >= len(data):
            raise SystemExit("truncated OpenPGP length")
        length_octet = data[offset]
        offset += 1
        if length_octet < 192:
            length = length_octet
        elif length_octet < 224:
            if offset >= len(data):
                raise SystemExit("truncated OpenPGP length")
            length = ((length_octet - 192) << 8) + data[offset] + 192
            offset += 1
        elif length_octet == 255:
            if offset + 4 > len(data):
                raise SystemExit("truncated OpenPGP length")
            length = int.from_bytes(data[offset:offset + 4], "big")
            offset += 4
        else:
            raise SystemExit("partial OpenPGP lengths are not accepted")
    else:
        tag = (first >> 2) & 0x0F
        length_type = first & 0x03
        length_bytes = (1, 2, 4, 0)[length_type]
        if length_bytes == 0:
            length = len(data) - offset
        else:
            if offset + length_bytes > len(data):
                raise SystemExit("truncated OpenPGP length")
            length = int.from_bytes(data[offset:offset + length_bytes], "big")
            offset += length_bytes
    if offset + length > len(data):
        raise SystemExit("truncated OpenPGP packet")
    if tag == 6:
        primary += 1
    if tag in (5, 7):
        secret += 1
    packets += 1
    offset += length
if packets == 0 or primary != 1 or secret != 0:
    raise SystemExit("public key bundle must contain one primary certificate and no secret packets")
PY

verify_signature() {
    local signature=$1 payload=$2 status
    status=$(gpgv --status-fd 1 --keyring "$public_key" "$signature" "$payload" 2>&1) || {
        printf '%s\n' "$status" >&2
        evidence_die "signature verification failed: $payload"
        return 1
    }
    ! grep -Eq '\[GNUPG:\] (EXPKEYSIG|EXPSIG|REVKEYSIG|BADSIG|ERRSIG|NO_PUBKEY)' <<<"$status" || evidence_die "unacceptable signature status: $payload"
    awk -v expected="$expected_signer" '
        $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
            valid++
            if (($3 == expected || $NF == expected) && $10 ~ /^(8|9|10|11)$/) matched++
        }
        END { exit !(valid == 1 && matched == 1) }
    ' <<<"$status" || evidence_die "signature signer or digest mismatch: $payload"
}
verify_signature "$database_signature" "$database"
verify_signature "$files_signature" "$files_database"

[[ $(head -n 1 "$packages") == $'package\tversion\tarchitecture\tsha256\tartifact' ]] || evidence_die 'invalid package manifest header'
projection="$tmp/projection"
mkdir -m 700 "$projection"
cp -p -- "$packages" "$projection/packages.tsv"
expected_inventory="$tmp/repository.inventory.expected"
expected_db="$tmp/database.inventory.expected"
expected_files="$tmp/files.inventory.expected"
printf '%s\n' SHA256SUMS asahi-m8-development.db asahi-m8-development.db.sig asahi-m8-development.files asahi-m8-development.files.sig coverage.tsv manifest.txt packages.tsv signing-key.gpg >"$expected_inventory"
: >"$expected_db"
: >"$expected_files"
rows=0
repo_field() {
    local file=$1 marker=$2
    awk -v marker="%${marker}%" '$0 == marker {getline; print; found++} END {if (found != 1) exit 1}' "$file"
}
while IFS=$'\t' read -r package version architecture hash artifact extra; do
    [[ -z $package ]] && continue
    [[ -z ${extra:-} && $package =~ ^[a-z0-9][a-z0-9+._-]*$ ]] || evidence_die "invalid package row: $package"
    [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9+._:-]*$ ]] || evidence_die "invalid package version: $package"
    [[ $architecture == aarch64 ]] || evidence_die "invalid package architecture: $package"
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || evidence_die "invalid package hash: $package"
    [[ $artifact =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.pkg\.tar\.(xz|zst)$ ]] || evidence_die "unsafe package artifact: $package"
    package_file="$repo/$artifact"
    signature_file="$package_file.sig"
    evidence_abs_regular "$package_file"
    evidence_abs_regular "$signature_file"
    cp -p -- "$package_file" "$projection/$artifact"
    verify_signature "$signature_file" "$package_file"
    printf '%s\n%s.sig\n' "$artifact" "$artifact" >>"$expected_inventory"
    member="$package-$version"
    printf '%s/\n%s/desc\n' "$member" "$member" >>"$expected_db"
    printf '%s/\n%s/desc\n%s/files\n' "$member" "$member" "$member" >>"$expected_files"
    db_desc="$tmp/$package.db.desc"
    files_desc="$tmp/$package.files.desc"
    files_list="$tmp/$package.files"
    bsdtar -xOf "$database" "$member/desc" >"$db_desc" || evidence_die "missing database record: $package"
    bsdtar -xOf "$files_database" "$member/desc" >"$files_desc" || evidence_die "missing files database record: $package"
    cmp -s "$db_desc" "$files_desc" || evidence_die "database records differ: $package"
    bsdtar -xOf "$files_database" "$member/files" >"$files_list" || evidence_die "missing file list: $package"
    [[ $(head -n 1 "$files_list") == %FILES% ]] || evidence_die "invalid file list: $package"
    awk '
        /^%[A-Z]+%$/ {next}
        {
            path=$0
            if (path == "./") next
            if (path ~ /^\// || path ~ /\\/) bad=1
            sub(/^\.\//, "", path)
            count=split(path, part, "/")
            for (i=1; i<=count; i++) if (part[i] == "." || part[i] == "..") bad=1
        }
        END {exit bad}
    ' "$files_list" || evidence_die "unsafe file-list path: $package"
    [[ $(repo_field "$db_desc" NAME) == "$package" ]] || evidence_die "database package mismatch: $package"
    [[ $(repo_field "$db_desc" VERSION) == "$version" ]] || evidence_die "database version mismatch: $package"
    [[ $(repo_field "$db_desc" ARCH) == "$architecture" ]] || evidence_die "database architecture mismatch: $package"
    [[ $(repo_field "$db_desc" FILENAME) == "$artifact" ]] || evidence_die "database filename mismatch: $package"
    [[ $(repo_field "$db_desc" CSIZE) == "$(wc -c <"$package_file" | tr -d '[:space:]')" ]] || evidence_die "database size mismatch: $package"
    [[ $(repo_field "$db_desc" SHA256SUM) == "$hash" ]] || evidence_die "database hash mismatch: $package"
    embedded_signature=$(repo_field "$db_desc" PGPSIG) || evidence_die "missing embedded signature: $package"
    [[ $embedded_signature == "$(base64 <"$signature_file" | tr -d '\r\n')" ]] || evidence_die "embedded signature mismatch: $package"
    rows=$((rows + 1))
done < <(tail -n +2 "$packages")
[[ $rows -eq 8 ]] || evidence_die "signed repository package count is $rows; expected 8"

"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$projection" >/dev/null
bsdtar -tf "$database" | LC_ALL=C sort >"$tmp/database.inventory.actual"
bsdtar -tf "$files_database" | LC_ALL=C sort >"$tmp/files.inventory.actual"
LC_ALL=C sort -o "$expected_db" "$expected_db"
LC_ALL=C sort -o "$expected_files" "$expected_files"
cmp -s "$expected_db" "$tmp/database.inventory.actual" || evidence_die 'repository database inventory mismatch'
cmp -s "$expected_files" "$tmp/files.inventory.actual" || evidence_die 'files database inventory mismatch'
LC_ALL=C sort -o "$expected_inventory" "$expected_inventory"
(cd "$repo" && find -P . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort) >"$tmp/repository.inventory.actual"
cmp -s "$expected_inventory" "$tmp/repository.inventory.actual" || evidence_die 'signed repository inventory mismatch'
evidence_verify_sums "$repo" "$repo/SHA256SUMS"

printf 'M8=signed-development-repo-verified packages=8 signer=%s published=false hardware_acceptance=false\n' "$expected_signer"
