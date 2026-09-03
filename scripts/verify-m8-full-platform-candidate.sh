#!/usr/bin/env bash
# Verify an M8 full-platform development candidate against its immutable sources.
# shellcheck disable=SC1091
set -Eeuo pipefail
PATH=/usr/bin
export PATH

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/m8-coverage.sh"
source "$project_root/scripts/lib/m8-full-platform.sh"
contract="$project_root/config/milestone8-full-platform-packages.tsv"
coverage_contract="$project_root/config/milestone8-platform-coverage.tsv"

[[ $# -eq 10 && $1 == --candidate && $3 == --core-input && $5 == --m0-packages && $7 == --asahi-evidence && $9 == --arch-evidence ]] || {
    printf 'usage: %s --candidate ABS --core-input ABS --m0-packages ABS --asahi-evidence ABS --arch-evidence ABS\n' "$0" >&2
    exit 64
}
candidate=$2
core_input=$4
m0_packages=$6
asahi_evidence=$8
arch_evidence=${10}
for dir in "$candidate" "$core_input" "$m0_packages" "$asahi_evidence" "$arch_evidence"; do evidence_abs_dir "$dir"; done
for file in "$contract" "$coverage_contract" "$core_input/packages.tsv" "$m0_packages/SHA256SUMS" "$asahi_evidence/SHA256SUMS" "$arch_evidence/SHA256SUMS"; do evidence_abs_regular "$file"; done
for command in awk bsdtar cmp find sort; do
    [[ $(command -v "$command") == "/usr/bin/$command" ]] || evidence_die "trusted /usr/bin/$command is required"
done
m8_full_validate_contract "$contract"

for file in SHA256SUMS coverage.tsv lifecycle.tsv manifest.txt package-contract.tsv packages.tsv sources.tsv; do evidence_abs_regular "$candidate/$file"; done
for dir in packages origin-signatures; do evidence_abs_dir "$candidate/$dir"; done
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$candidate" -type l -print0)
expected_root=$(mktemp)
actual_root=$(mktemp)
expected_packages=$(mktemp)
expected_signatures=$(mktemp)
recomputed_lifecycle=$(mktemp)
asahi_source_manifest=$(mktemp)
cleanup() { rm -f -- "$expected_root" "$actual_root" "$expected_packages" "$expected_signatures" "$recomputed_lifecycle" "$asahi_source_manifest"; }
trap cleanup EXIT
printf '%s\n' SHA256SUMS coverage.tsv lifecycle.tsv manifest.txt origin-signatures package-contract.tsv packages packages.tsv sources.tsv | LC_ALL=C sort >"$expected_root"
(cd "$candidate" && find -P . -mindepth 1 -maxdepth 1 -print | sed 's#^\./##' | LC_ALL=C sort) >"$actual_root"
cmp -s -- "$expected_root" "$actual_root" || evidence_die 'candidate root inventory mismatch'
[[ -z $(find -P "$candidate/packages" "$candidate/origin-signatures" -mindepth 1 -type d -print -quit) ]] || evidence_die 'nested candidate directory is not allowed'
evidence_verify_sums "$candidate" "$candidate/SHA256SUMS"
cmp -s -- "$candidate/package-contract.tsv" "$contract" || evidence_die 'candidate package contract differs from checked-in contract'
m8_validate_platform_coverage "$candidate/coverage.tsv" "$coverage_contract"

manifest_keys='format artifact_class architecture development_only canonical repository_generated repository_signed published installed booted hardware_acceptance installation_authorized contains_lifecycle_hooks platform_coverage package_count local_m0_package_count asahi_alarm_package_count archlinuxarm_package_count origin_signature_count lifecycle_file_count package_contract_sha256 package_manifest_sha256 source_manifest_sha256 lifecycle_manifest_sha256 platform_coverage_sha256 core_manifest_sha256 m0_packages_sha256 asahi_evidence_sha256 arch_evidence_sha256 purpose'
for key in $manifest_keys; do evidence_kv "$candidate/manifest.txt" "$key" >/dev/null; done
[[ $(awk -F= 'NF && $1 !~ /^#/ {n++} END {print n + 0}' "$candidate/manifest.txt") -eq 30 ]] || evidence_die 'candidate manifest key inventory mismatch'
[[ $(evidence_kv "$candidate/manifest.txt" format) == 1 ]] || evidence_die 'invalid candidate format'
[[ $(evidence_kv "$candidate/manifest.txt" artifact_class) == m8-full-platform-development-candidate ]] || evidence_die 'invalid artifact class'
[[ $(evidence_kv "$candidate/manifest.txt" architecture) == aarch64 ]] || evidence_die 'invalid candidate architecture'
for key in development_only contains_lifecycle_hooks; do [[ $(evidence_kv "$candidate/manifest.txt" "$key") == true ]] || evidence_die "$key must be true"; done
for key in canonical repository_generated repository_signed published installed booted hardware_acceptance installation_authorized; do [[ $(evidence_kv "$candidate/manifest.txt" "$key") == false ]] || evidence_die "$key must be false"; done
[[ $(evidence_kv "$candidate/manifest.txt" platform_coverage) == static-plan-incomplete ]] || evidence_die 'platform coverage must remain incomplete'
[[ $(evidence_kv "$candidate/manifest.txt" purpose) == compose-verified-full-platform-package-candidate-only ]] || evidence_die 'invalid candidate purpose'
for binding in \
    package_contract_sha256:package-contract.tsv \
    package_manifest_sha256:packages.tsv \
    source_manifest_sha256:sources.tsv \
    lifecycle_manifest_sha256:lifecycle.tsv \
    platform_coverage_sha256:coverage.tsv; do
    key=${binding%%:*}; file=${binding#*:}
    [[ $(evidence_kv "$candidate/manifest.txt" "$key") == "$(evidence_sha256 "$candidate/$file")" ]] || evidence_die "candidate manifest hash mismatch: $key"
done
[[ $(evidence_kv "$candidate/manifest.txt" core_manifest_sha256) == "$(evidence_sha256 "$core_input/packages.tsv")" ]] || evidence_die 'core manifest binding mismatch'
[[ $(evidence_kv "$candidate/manifest.txt" m0_packages_sha256) == "$(evidence_sha256 "$m0_packages/SHA256SUMS")" ]] || evidence_die 'M0 evidence binding mismatch'
[[ $(evidence_kv "$candidate/manifest.txt" asahi_evidence_sha256) == "$(evidence_sha256 "$asahi_evidence/SHA256SUMS")" ]] || evidence_die 'Asahi evidence binding mismatch'
[[ $(evidence_kv "$candidate/manifest.txt" arch_evidence_sha256) == "$(evidence_sha256 "$arch_evidence/SHA256SUMS")" ]] || evidence_die 'Arch evidence binding mismatch'
[[ $(head -n 1 "$candidate/packages.tsv") == $'package\tversion\tarchitecture\tsha256\tartifact' ]] || evidence_die 'invalid candidate package manifest header'
[[ $(head -n 1 "$candidate/sources.tsv") == $'package\tsource\tartifact_sha256\torigin_signature\torigin_signature_sha256' ]] || evidence_die 'invalid candidate source manifest header'

evidence_verify_sums "$m0_packages" "$m0_packages/SHA256SUMS"
evidence_verify_sums "$asahi_evidence" "$asahi_evidence/SHA256SUMS"
evidence_verify_sums "$arch_evidence" "$arch_evidence/SHA256SUMS"
"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$core_input" >/dev/null
"$project_root/scripts/verify-m8-upstream-signed-snapshot.sh" --input-dir "$asahi_evidence/input" --packages-dir "$asahi_evidence/packages" >/dev/null
"$project_root/scripts/verify-m8-archlinuxarm-package-signatures.sh" \
    --input-dir "$arch_evidence/input" \
    --package-manifest "$core_input/packages.tsv" \
    --packages-dir "$core_input" \
    --signatures-dir "$arch_evidence/signatures" >/dev/null
m8_full_write_directory_manifest "$asahi_evidence/packages" "$asahi_source_manifest"

package_count=0
local_count=0
arch_count=0
asahi_count=0
signature_count=0
: >"$expected_packages"
: >"$expected_signatures"
while IFS=$'\t' read -r package _role source extra; do
    [[ -z ${extra:-} ]] || evidence_die "invalid full-platform contract row: $package"
    row=$(m8_full_manifest_row "$candidate/packages.tsv" "$package")
    IFS=$'\t' read -r found version architecture hash artifact row_extra <<<"$row"
    [[ -z ${row_extra:-} && $found == "$package" && $version =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]] || evidence_die "invalid candidate package row: $package"
    [[ $architecture == aarch64 || $architecture == any ]] || evidence_die "wrong candidate package architecture: $package"
    [[ $hash =~ ^[0-9a-f]{64}$ && $artifact =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.pkg\.tar\.(xz|zst)$ ]] || evidence_die "unsafe candidate package row: $package"
    [[ $(tail -n +2 "$candidate/packages.tsv" | awk -F '\t' -v a="$artifact" '$5 == a {n++} END {print n + 0}') -eq 1 ]] || evidence_die "duplicate candidate artifact: $artifact"
    source_row=$(m8_full_manifest_row "$candidate/sources.tsv" "$package")
    IFS=$'\t' read -r source_package declared_source source_hash signature signature_hash source_extra <<<"$source_row"
    [[ -z ${source_extra:-} && $source_package == "$package" && $declared_source == "$source" && $source_hash == "$hash" ]] || evidence_die "candidate source binding mismatch: $package"
    candidate_file="$candidate/packages/$artifact"
    evidence_abs_regular "$candidate_file"
    [[ $(evidence_sha256 "$candidate_file") == "$hash" ]] || evidence_die "candidate package hash mismatch: $package"
    IFS=$'\t' read -r embedded_name embedded_version embedded_arch embedded_extra <<<"$(m8_full_package_record "$candidate_file")"
    [[ -z ${embedded_extra:-} && $embedded_name == "$package" && $embedded_version == "$version" && $embedded_arch == "$architecture" ]] || evidence_die "candidate embedded identity mismatch: $package"
    m8_full_validate_archive_paths "$candidate_file"
    if [[ $source == local-m0 || $source == archlinuxarm ]]; then
        core_row=$(m8_full_manifest_row "$core_input/packages.tsv" "$package")
        IFS=$'\t' read -r _ core_version core_arch core_hash core_artifact core_extra <<<"$core_row"
        [[ -z ${core_extra:-} && $version == "$core_version" && $architecture == "$core_arch" && $hash == "$core_hash" && $artifact == "$core_artifact" ]] || evidence_die "candidate differs from core manifest: $package"
        cmp -s -- "$candidate_file" "$core_input/$artifact" || evidence_die "candidate differs from core package: $package"
        if [[ $source == local-m0 ]]; then
            cmp -s -- "$candidate_file" "$m0_packages/$artifact" || evidence_die "candidate differs from M0 output: $package"
            [[ $signature == - && $signature_hash == - ]] || evidence_die "local M0 package must not claim origin signature: $package"
            local_count=$((local_count + 1))
        else
            external_signature="$arch_evidence/signatures/$artifact.sig"
            arch_count=$((arch_count + 1))
        fi
    else
        asahi_row=$(m8_full_manifest_row "$asahi_source_manifest" "$package")
        IFS=$'\t' read -r _ asahi_version asahi_arch asahi_hash asahi_artifact asahi_extra <<<"$asahi_row"
        [[ -z ${asahi_extra:-} && $version == "$asahi_version" && $architecture == "$asahi_arch" && $hash == "$asahi_hash" && $artifact == "$asahi_artifact" ]] || evidence_die "candidate differs from Asahi manifest: $package"
        source_file="$asahi_evidence/packages/$asahi_artifact"
        cmp -s -- "$candidate_file" "$source_file" || evidence_die "candidate differs from Asahi package: $package"
        external_signature="$source_file.sig"
        asahi_count=$((asahi_count + 1))
        if [[ $package == mesa ]]; then cmp -s -- "$candidate_file" "$core_input/$artifact" || evidence_die 'candidate Mesa differs from core package'; fi
    fi
    if [[ $source != local-m0 ]]; then
        [[ $signature == "$artifact.sig" && $signature_hash =~ ^[0-9a-f]{64}$ ]] || evidence_die "invalid origin signature binding: $package"
        evidence_abs_regular "$candidate/origin-signatures/$signature"
        evidence_abs_regular "$external_signature"
        [[ $(evidence_sha256 "$candidate/origin-signatures/$signature") == "$signature_hash" ]] || evidence_die "origin signature hash mismatch: $package"
        cmp -s -- "$candidate/origin-signatures/$signature" "$external_signature" || evidence_die "origin signature differs from source evidence: $package"
        printf '%s\n' "$signature" >>"$expected_signatures"
        signature_count=$((signature_count + 1))
    fi
    printf '%s\n' "$artifact" >>"$expected_packages"
    package_count=$((package_count + 1))
done < <(m8_full_contract_rows "$contract")

LC_ALL=C sort -o "$expected_packages" "$expected_packages"
LC_ALL=C sort -o "$expected_signatures" "$expected_signatures"
(cd "$candidate/packages" && find -P . -mindepth 1 -maxdepth 1 -type f -print | sed 's#^\./##' | LC_ALL=C sort) | cmp -s -- - "$expected_packages" || evidence_die 'candidate package inventory mismatch'
(cd "$candidate/origin-signatures" && find -P . -mindepth 1 -maxdepth 1 -type f -print | sed 's#^\./##' | LC_ALL=C sort) | cmp -s -- - "$expected_signatures" || evidence_die 'candidate signature inventory mismatch'
[[ $package_count -eq 23 && $local_count -eq 2 && $arch_count -eq 5 && $asahi_count -eq 16 && $signature_count -eq 21 ]] || evidence_die "candidate package split mismatch: $package_count/$local_count/$arch_count/$asahi_count/$signature_count"
[[ $(tail -n +2 "$candidate/packages.tsv" | awk 'END {print NR + 0}') -eq 23 ]] || evidence_die 'candidate package manifest row count mismatch'
[[ $(tail -n +2 "$candidate/sources.tsv" | awk 'END {print NR + 0}') -eq 23 ]] || evidence_die 'candidate source manifest row count mismatch'

m8_full_write_lifecycle_manifest "$candidate/packages.tsv" "$candidate/packages" "$recomputed_lifecycle"
cmp -s -- "$candidate/lifecycle.tsv" "$recomputed_lifecycle" || evidence_die 'candidate lifecycle manifest mismatch'
lifecycle_count=$(tail -n +2 "$candidate/lifecycle.tsv" | awk 'END {print NR + 0}')
[[ $lifecycle_count -eq 4 ]] || evidence_die "unexpected candidate lifecycle count: $lifecycle_count"
for binding in package_count:23 local_m0_package_count:2 asahi_alarm_package_count:16 archlinuxarm_package_count:5 origin_signature_count:21 lifecycle_file_count:4; do
    key=${binding%%:*}; value=${binding#*:}
    [[ $(evidence_kv "$candidate/manifest.txt" "$key") == "$value" ]] || evidence_die "candidate manifest count mismatch: $key"
done
printf 'M8=full-platform-candidate-verified packages=23 origin_signatures=21 lifecycle=4 repository_signed=false installed=false hardware_acceptance=false\n'
