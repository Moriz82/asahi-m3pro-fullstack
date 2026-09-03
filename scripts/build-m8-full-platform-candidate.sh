#!/usr/bin/env bash
# Build a provenance-bound, non-installable M8 full-platform package candidate.
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
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}

[[ $# -eq 10 && $1 == --core-input && $3 == --m0-packages && $5 == --asahi-evidence && $7 == --arch-evidence && $9 == --out ]] || {
    printf 'usage: %s --core-input ABS --m0-packages ABS --asahi-evidence ABS --arch-evidence ABS --out ABS\n' "$0" >&2
    exit 64
}
core_input=$2
m0_packages=$4
asahi_evidence=$6
arch_evidence=$8
out=${10}

for dir in "$core_input" "$m0_packages" "$asahi_evidence" "$arch_evidence"; do evidence_abs_dir "$dir"; done
for file in "$contract" "$coverage_contract" "$core_input/packages.tsv" "$m0_packages/SHA256SUMS" "$asahi_evidence/SHA256SUMS" "$arch_evidence/SHA256SUMS"; do evidence_abs_regular "$file"; done
m8_full_validate_contract "$contract"
evidence_path_under "$out" "$output_root"
[[ $out == /* ]] || evidence_die "path is not absolute: $out"
output_parent=$(dirname -- "$out")
[[ -d $output_parent && ! -L $output_parent ]] || evidence_die "output parent must already exist: $output_parent"
[[ ! -e $out && ! -L $out ]] || evidence_die "output already exists: $out"
for command in awk bsdtar cmp cp find python3 sort; do
    [[ $(command -v "$command") == "/usr/bin/$command" ]] || evidence_die "trusted /usr/bin/$command is required"
done

core_input=$(cd -P -- "$core_input" && pwd -P)
m0_packages=$(cd -P -- "$m0_packages" && pwd -P)
asahi_evidence=$(cd -P -- "$asahi_evidence" && pwd -P)
arch_evidence=$(cd -P -- "$arch_evidence" && pwd -P)
output_parent=$(cd -P -- "$output_parent" && pwd -P)
out="$output_parent/$(basename -- "$out")"

output_base=$(basename -- "$out")
stage=$(mktemp -d "$output_parent/.${output_base}.stage.XXXXXX") || evidence_die "cannot create output stage: $out"
chmod 700 "$stage"
cleanup() { [[ -z ${stage:-} || ! -e $stage ]] || rm -rf -- "$stage"; }
trap cleanup EXIT
mkdir -m 700 -- "$stage/packages" "$stage/origin-signatures"
cp -p -- "$contract" "$stage/package-contract.tsv"
cp -p -- "$coverage_contract" "$stage/coverage.tsv"
printf 'package\tversion\tarchitecture\tsha256\tartifact\n' >"$stage/packages.tsv"
printf 'package\tsource\tartifact_sha256\torigin_signature\torigin_signature_sha256\n' >"$stage/sources.tsv"
m8_full_write_directory_manifest "$asahi_evidence/packages" "$stage/.asahi-source-packages.tsv"

while IFS=$'\t' read -r package _role source extra; do
    [[ -z ${extra:-} ]] || evidence_die "invalid full-platform contract row: $package"
    source_file=
    signature_file=
    if [[ $source == local-m0 || $source == archlinuxarm ]]; then
        row=$(m8_full_manifest_row "$core_input/packages.tsv" "$package")
        IFS=$'\t' read -r found version architecture hash artifact row_extra <<<"$row"
        [[ -z ${row_extra:-} && $found == "$package" ]] || evidence_die "invalid core package row: $package"
        source_file="$core_input/$artifact"
        if [[ $source == local-m0 ]]; then
            evidence_abs_regular "$m0_packages/$artifact"
            cmp -s -- "$source_file" "$m0_packages/$artifact" || evidence_die "core package differs from M0 output: $package"
            source_file="$m0_packages/$artifact"
        else
            signature_file="$arch_evidence/signatures/$artifact.sig"
        fi
    else
        row=$(m8_full_manifest_row "$stage/.asahi-source-packages.tsv" "$package")
        IFS=$'\t' read -r found version architecture hash artifact row_extra <<<"$row"
        [[ -z ${row_extra:-} && $found == "$package" ]] || evidence_die "invalid Asahi package row: $package"
        source_file="$asahi_evidence/packages/$artifact"
        signature_file="$source_file.sig"
        if [[ $package == mesa ]]; then
            row=$(m8_full_manifest_row "$core_input/packages.tsv" mesa)
            IFS=$'\t' read -r _ _ _ core_hash core_artifact row_extra <<<"$row"
            [[ -z ${row_extra:-} && $hash == "$core_hash" ]] || evidence_die 'Asahi Mesa differs from core package closure'
            cmp -s -- "$source_file" "$core_input/$core_artifact" || evidence_die 'Asahi Mesa bytes differ from core package closure'
        fi
    fi
    [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]] || evidence_die "unsafe package version: $package"
    [[ $architecture == aarch64 || $architecture == any ]] || evidence_die "wrong package architecture: $package"
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || evidence_die "invalid package hash: $package"
    [[ $artifact =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.pkg\.tar\.(xz|zst)$ ]] || evidence_die "unsafe package artifact: $package"
    evidence_abs_regular "$source_file"
    [[ $(evidence_sha256 "$source_file") == "$hash" ]] || evidence_die "source package hash mismatch: $package"
    [[ $(m8_full_package_field "$source_file" pkgname) == "$package" ]] || evidence_die "embedded package name mismatch: $package"
    m8_full_validate_archive_paths "$source_file"
    cp -p -- "$source_file" "$stage/packages/$artifact"
    printf '%s\t%s\t%s\t%s\t%s\n' "$package" "$version" "$architecture" "$hash" "$artifact" >>"$stage/packages.tsv"
    if [[ -n $signature_file ]]; then
        evidence_abs_regular "$signature_file"
        signature="$artifact.sig"
        signature_hash=$(evidence_sha256 "$signature_file")
        cp -p -- "$signature_file" "$stage/origin-signatures/$signature"
    else
        signature=-
        signature_hash=-
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$package" "$source" "$hash" "$signature" "$signature_hash" >>"$stage/sources.tsv"
done < <(m8_full_contract_rows "$contract")
rm -f -- "$stage/.asahi-source-packages.tsv"

m8_full_write_lifecycle_manifest "$stage/packages.tsv" "$stage/packages" "$stage/lifecycle.tsv"
lifecycle_count=$(tail -n +2 "$stage/lifecycle.tsv" | awk 'END {print NR + 0}')
[[ $lifecycle_count -eq 4 ]] || evidence_die "unexpected lifecycle file count: $lifecycle_count"

(umask 077; {
    printf 'format=1\nartifact_class=m8-full-platform-development-candidate\narchitecture=aarch64\n'
    printf 'development_only=true\ncanonical=false\nrepository_generated=false\nrepository_signed=false\npublished=false\ninstalled=false\nbooted=false\nhardware_acceptance=false\ninstallation_authorized=false\ncontains_lifecycle_hooks=true\n'
    printf 'platform_coverage=static-plan-incomplete\npackage_count=23\nlocal_m0_package_count=2\nasahi_alarm_package_count=16\narchlinuxarm_package_count=5\norigin_signature_count=21\nlifecycle_file_count=%s\n' "$lifecycle_count"
    printf 'package_contract_sha256=%s\npackage_manifest_sha256=%s\nsource_manifest_sha256=%s\nlifecycle_manifest_sha256=%s\nplatform_coverage_sha256=%s\n' \
        "$(evidence_sha256 "$stage/package-contract.tsv")" "$(evidence_sha256 "$stage/packages.tsv")" "$(evidence_sha256 "$stage/sources.tsv")" "$(evidence_sha256 "$stage/lifecycle.tsv")" "$(evidence_sha256 "$stage/coverage.tsv")"
    printf 'core_manifest_sha256=%s\nm0_packages_sha256=%s\nasahi_evidence_sha256=%s\narch_evidence_sha256=%s\n' \
        "$(evidence_sha256 "$core_input/packages.tsv")" "$(evidence_sha256 "$m0_packages/SHA256SUMS")" "$(evidence_sha256 "$asahi_evidence/SHA256SUMS")" "$(evidence_sha256 "$arch_evidence/SHA256SUMS")"
    printf 'purpose=compose-verified-full-platform-package-candidate-only\n'
} >"$stage/manifest.txt")
evidence_write_sums "$stage" "$stage/SHA256SUMS"
"$project_root/scripts/verify-m8-full-platform-candidate.sh" \
    --candidate "$stage" \
    --core-input "$core_input" \
    --m0-packages "$m0_packages" \
    --asahi-evidence "$asahi_evidence" \
    --arch-evidence "$arch_evidence" >/dev/null
evidence_atomic_publish_directory "$stage" "$out"
[[ -d $out && ! -L $out && ! -e $stage && ! -L $stage ]] || evidence_die 'published output is not exactly the verified stage'
stage=
printf 'full-platform-candidate=%s packages=23 origin_signatures=21 installed=false hardware_acceptance=false\n' "$out"
