#!/usr/bin/env bash
# Verify Arch Linux ARM package signatures without changing a host keyring.
# shellcheck disable=SC1091
set -Eeuo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
default_snapshot="$project_root/config/milestone8-archlinuxarm-signing.env"
default_required="$project_root/config/milestone8-archlinuxarm-required-packages.txt"
[[ $# -eq 8 && $1 == --input-dir && $3 == --package-manifest && $5 == --packages-dir && $7 == --signatures-dir ]] || {
    printf 'usage: %s --input-dir ABS --package-manifest ABS --packages-dir ABS --signatures-dir ABS\n' "$0" >&2
    exit 64
}
input=$2
package_manifest=$4
packages_dir=$6
signatures_dir=$8
snapshot=${M8_ARCH_SIGNING_SNAPSHOT:-$default_snapshot}
required=${M8_ARCH_SIGNING_REQUIRED_PACKAGES:-$default_required}
for dir in "$input" "$packages_dir" "$signatures_dir"; do evidence_abs_dir "$dir"; done
for file in "$snapshot" "$required" "$package_manifest"; do evidence_abs_regular "$file"; done
command -v bsdtar >/dev/null || evidence_die 'bsdtar is required'
command -v base64 >/dev/null || evidence_die 'base64 is required'
command -v gpgv >/dev/null || evidence_die 'gpgv is required'
command -v od >/dev/null || evidence_die 'od is required'

for key in format keyring_package keyring_package_sha256 keyring_signature keyring_signature_sha256 keyring_member signer_fingerprint database_signature_policy hardware_acceptance; do
    evidence_kv "$snapshot" "$key" >/dev/null
done
[[ $(evidence_kv "$snapshot" format) == 1 ]] || evidence_die 'invalid Arch Linux ARM signing format'
[[ $(evidence_kv "$snapshot" database_signature_policy) == unsigned-by-upstream-design ]] || evidence_die 'unexpected database signature policy'
[[ $(evidence_kv "$snapshot" hardware_acceptance) == false ]] || evidence_die 'signature evidence cannot assert hardware acceptance'
fingerprint=$(evidence_kv "$snapshot" signer_fingerprint)
[[ $fingerprint =~ ^[0-9A-F]{40}$ ]] || evidence_die 'invalid Arch Linux ARM signer fingerprint'

keyring_package=$(evidence_kv "$snapshot" keyring_package)
keyring_signature=$(evidence_kv "$snapshot" keyring_signature)
for name in "$keyring_package" "$keyring_signature"; do
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || evidence_die "unsafe keyring filename: $name"
    evidence_abs_regular "$input/$name"
done
for binding in "$keyring_package:keyring_package_sha256" "$keyring_signature:keyring_signature_sha256"; do
    name=${binding%%:*}
    hash_key=${binding#*:}
    expected=$(evidence_kv "$snapshot" "$hash_key")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || evidence_die "invalid keyring hash: $hash_key"
    evidence_hash_file "$input/$name" "$expected"
done

keyring_member=$(evidence_kv "$snapshot" keyring_member)
[[ $keyring_member == usr/share/pacman/keyrings/*.gpg && $keyring_member != *..* ]] || evidence_die 'unsafe keyring member'
[[ $(bsdtar -tf "$input/$keyring_package" | grep -Fxc -- "$keyring_member") -eq 1 ]] || evidence_die 'keyring member missing or duplicated'
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m8-alarm-sign.XXXXXX")
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
verify_package_identity() {
    local archive=$1 expected_package=$2 expected_version=$3 expected_arch=$4 list pkginfo_path pkginfo key value magic
    magic=$(LC_ALL=C od -An -tx1 -N6 "$archive" | tr -d '[:space:]')
    case $archive in
        *.pkg.tar.zst) [[ ${magic:0:8} == 28b52ffd ]] || evidence_die "archive compression does not match .zst suffix: $archive";;
        *.pkg.tar.xz) [[ $magic == fd377a585a00 ]] || evidence_die "archive compression does not match .xz suffix: $archive";;
        *) evidence_die "unsupported package archive suffix: $archive";;
    esac
    list=$(bsdtar -tf "$archive") || evidence_die "invalid package archive: $archive"
    pkginfo_path=$(printf '%s\n' "$list" | awk 'substr($0,1,2)== "./" {$0=substr($0,3)} $0==".PKGINFO" {n++; p=$0} END {if(n != 1) exit 1; print p}') || evidence_die "archive must contain exactly one .PKGINFO: $archive"
    pkginfo="$tmp/package.pkginfo"
    bsdtar -xOf "$archive" "$pkginfo_path" >"$pkginfo" 2>/dev/null || \
        bsdtar -xOf "$archive" "./$pkginfo_path" >"$pkginfo" || evidence_die "cannot extract .PKGINFO: $archive"
    for key in pkgname pkgver arch; do
        value=$(awk -F ' = ' -v wanted="$key" '$1 == wanted {n++; v=$2} END {if(n != 1) exit 1; print v}' "$pkginfo") || evidence_die "invalid $key in .PKGINFO: $archive"
        case $key in
            pkgname) [[ $value == "$expected_package" ]] || evidence_die "embedded package name mismatch: $archive";;
            pkgver) [[ $value == "$expected_version" ]] || evidence_die "embedded package version mismatch: $archive";;
            arch) [[ $value == "$expected_arch" ]] || evidence_die "embedded package architecture mismatch: $archive";;
        esac
    done
}

[[ $(head -n 1 "$package_manifest") == $'package\tversion\tarchitecture\tsha256\tartifact' ]] || evidence_die 'invalid package manifest header'
[[ -s $required ]] || evidence_die 'empty required package list'
if grep -Evq '^[a-z0-9][a-z0-9@._+-]*$' "$required"; then evidence_die 'invalid required package name'; fi
LC_ALL=C sort -c "$required" || evidence_die 'required package list is not sorted'
required_count=$(awk 'END {print NR}' "$required")
[[ $(LC_ALL=C sort -u "$required" | awk 'END {print NR}') == "$required_count" ]] || evidence_die 'duplicate required package'

expected_signatures="$tmp/signatures.inventory"
: >"$expected_signatures"
while IFS= read -r package || [[ -n $package ]]; do
    row=$(awk -F '\t' -v package="$package" 'NR > 1 && $1 == package {print; found++} END {if (found != 1) exit 1}' "$package_manifest") || evidence_die "package missing or duplicated: $package"
    IFS=$'\t' read -r name version architecture hash artifact extra <<<"$row"
    [[ -z ${extra:-} && $name == "$package" ]] || evidence_die "invalid package row: $package"
    [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]] || evidence_die "unsafe package version: $package"
    [[ $architecture == aarch64 || $architecture == any ]] || evidence_die "wrong package architecture: $package"
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || evidence_die "invalid package hash: $package"
    [[ $artifact =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.pkg\.tar\.(xz|zst)$ ]] || evidence_die "unsafe package artifact: $package"
    evidence_abs_regular "$packages_dir/$artifact"
    evidence_abs_regular "$signatures_dir/$artifact.sig"
    evidence_hash_file "$packages_dir/$artifact" "$hash"
    verify_signature "$signatures_dir/$artifact.sig" "$packages_dir/$artifact"
    verify_package_identity "$packages_dir/$artifact" "$package" "$version" "$architecture"
    printf '%s.sig\n' "$artifact" >>"$expected_signatures"
done <"$required"
LC_ALL=C sort -o "$expected_signatures" "$expected_signatures"
(cd "$signatures_dir" && find -P . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort) | cmp - "$expected_signatures" || evidence_die 'signature directory inventory mismatch'

printf 'M8=archlinuxarm-package-signatures-verified packages=%s signer=%s database_signature_policy=unsigned-by-upstream-design hardware_acceptance=false\n' "$required_count" "$fingerprint"
