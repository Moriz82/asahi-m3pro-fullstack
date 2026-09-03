#!/usr/bin/env bash
# Build one local signed M8 development repository with an external signing key.
# shellcheck disable=SC1091
set -Eeuo pipefail
PATH=/usr/bin
export PATH

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/m8-coverage.sh"
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
coverage_contract="$project_root/config/milestone8-platform-coverage.tsv"
[[ $# -eq 8 && $1 == --input-dir && $3 == --gnupg-home && $5 == --signer && $7 == --out ]] || {
    printf 'usage: %s --input-dir ABS --gnupg-home ABS --signer FULL_FINGERPRINT --out ABS\n' "$0" >&2
    exit 64
}
input=$2
gnupg_home=$4
signer=$(printf '%s' "$6" | tr '[:lower:]' '[:upper:]')
out=$8
evidence_abs_dir "$input"
evidence_abs_dir "$gnupg_home"
evidence_abs_regular "$coverage_contract"
[[ $signer =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || evidence_die 'signer must be a full fingerprint'
evidence_path_under "$out" "$output_root"
[[ $out == /* ]] || evidence_die "path is not absolute: $out"
output_parent=$(dirname -- "$out")
[[ -d $output_parent && ! -L $output_parent ]] || evidence_die "output parent must already exist: $output_parent"
[[ ! -e $out && ! -L $out ]] || evidence_die "output already exists: $out"
input=$(cd -P -- "$input" && pwd -P)
gnupg_home=$(cd -P -- "$gnupg_home" && pwd -P)
output_parent=$(cd -P -- "$output_parent" && pwd -P)
out="$output_parent/$(basename -- "$out")"
[[ $gnupg_home != "$input" && $gnupg_home != "$input"/* && $input != "$gnupg_home"/* ]] || evidence_die 'signer home and package input must be disjoint'
[[ $gnupg_home != "$output_parent" && $gnupg_home != "$output_parent"/* && $output_parent != "$gnupg_home"/* ]] || evidence_die 'signer home and output must be disjoint'
for command in base64 bsdtar gpg gpgv python3 repo-add; do
    [[ $(command -v "$command") == "/usr/bin/$command" ]] || evidence_die "trusted /usr/bin/$command is required"
done

"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$input" >/dev/null
secret_status=$(gpg --no-options --homedir "$gnupg_home" --batch --with-colons --list-secret-keys "$signer!" 2>/dev/null) || evidence_die 'requested signing key is unavailable'
awk -F: -v signer="$signer" '$1 == "fpr" && toupper($10) == signer {found++} END {exit !(found >= 1)}' <<<"$secret_status" || evidence_die 'secret signing key fingerprint mismatch'

output_base=$(basename -- "$out")
stage=$(mktemp -d "$output_parent/.${output_base}.stage.XXXXXX") || evidence_die "cannot create output stage: $out"
chmod 700 "$stage"
cleanup() { [[ -z ${stage:-} || ! -e $stage ]] || rm -rf -- "$stage"; }
trap cleanup EXIT
cp -p -- "$input/packages.tsv" "$stage/packages.tsv"
package_files=()
while IFS=$'\t' read -r package _ _ _ artifact extra; do
    [[ -z $package ]] && continue
    [[ -z ${extra:-} ]] || evidence_die 'invalid package metadata'
    source_file="$input/$artifact"
    [[ -f $source_file ]] || source_file="$input/packages/$artifact"
    evidence_abs_regular "$source_file"
    cp -p -- "$source_file" "$stage/$artifact"
    package_files+=("$stage/$artifact")
done < <(tail -n +2 "$input/packages.tsv")
[[ ${#package_files[@]} -eq 8 ]] || evidence_die 'signed repository requires exactly eight packages'
"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$stage" >/dev/null
cp -p -- "$coverage_contract" "$stage/coverage.tsv"

gpg --no-options --homedir "$gnupg_home" --batch --export-options export-minimal --export "$signer" >"$stage/signing-key.gpg"
[[ -s $stage/signing-key.gpg ]] || evidence_die 'public signing key export failed'
for package_file in "${package_files[@]}"; do
    gpg --no-options --homedir "$gnupg_home" --batch --yes --no-armor --detach-sign --local-user "$signer!" --output "$package_file.sig" "$package_file"
done

(
    cd "$stage"
    env -i HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=/usr/bin TMPDIR=/tmp \
        repo-add --nocolor --include-sigs asahi-m8-development.db.tar.gz "${package_files[@]}" >/dev/null
)
for metadata in asahi-m8-development.db.tar.gz asahi-m8-development.files.tar.gz; do
    evidence_abs_regular "$stage/$metadata"
    gpg --no-options --homedir "$gnupg_home" --batch --yes --no-armor --detach-sign --local-user "$signer!" --output "$stage/$metadata.sig" "$stage/$metadata"
done
rm -f -- "$stage/asahi-m8-development.db" "$stage/asahi-m8-development.files"
mv -- "$stage/asahi-m8-development.db.tar.gz" "$stage/asahi-m8-development.db"
mv -- "$stage/asahi-m8-development.db.tar.gz.sig" "$stage/asahi-m8-development.db.sig"
mv -- "$stage/asahi-m8-development.files.tar.gz" "$stage/asahi-m8-development.files"
mv -- "$stage/asahi-m8-development.files.tar.gz.sig" "$stage/asahi-m8-development.files.sig"

tool_gpg=$(gpg --version | sed -n '1p')
tool_repo_add=$(repo-add --version | sed -n '1p')
(umask 077; {
    printf 'format=1\nrepo_name=asahi-m8-development\narchitecture=aarch64\n'
    printf 'development_only=true\ncanonical=false\nsigned=true\npublished=false\ninstalled=false\nbooted=false\nhardware_acceptance=false\nprivate_key_included=false\n'
    printf 'platform_coverage=static-plan-incomplete\nplatform_coverage_sha256=%s\n' "$(evidence_sha256 "$stage/coverage.tsv")"
    printf 'package_manifest_sha256=%s\npackage_count=8\n' "$(evidence_sha256 "$stage/packages.tsv")"
    printf 'signer_fingerprint=%s\nsigning_key_sha256=%s\n' "$signer" "$(evidence_sha256 "$stage/signing-key.gpg")"
    printf 'database_sha256=%s\nfiles_database_sha256=%s\n' "$(evidence_sha256 "$stage/asahi-m8-development.db")" "$(evidence_sha256 "$stage/asahi-m8-development.files")"
    printf 'tool_gpg=%s\ntool_repo_add=%s\npurpose=local-signed-test-repository-only\n' "$tool_gpg" "$tool_repo_add"
} >"$stage/manifest.txt")
evidence_write_sums "$stage" "$stage/SHA256SUMS"
"$project_root/scripts/verify-m8-signed-repo.sh" --repo "$stage" --expected-signer "$signer" >/dev/null
evidence_atomic_publish_directory "$stage" "$out"
[[ -d $out && ! -L $out && ! -e $stage && ! -L $stage ]] || evidence_die 'published output is not exactly the verified stage'
stage=
printf 'signed-repo=%s signer=%s published=false hardware_acceptance=false\n' "$out" "$signer"
