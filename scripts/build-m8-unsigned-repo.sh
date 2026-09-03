#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/m8-coverage.sh"
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
coverage_contract="$project_root/config/milestone8-platform-coverage.tsv"
[[ $# -eq 4 && $1 == --input-dir && $3 == --out ]] || { printf 'usage: %s --input-dir ABS --out ABS\n' "$0" >&2; exit 64; }
input=$2; out=$4
evidence_abs_dir "$input"
evidence_abs_regular "$coverage_contract"
m8_validate_platform_coverage "$coverage_contract" "$coverage_contract"
evidence_path_under "$out" "$output_root"
[[ $out == /* ]] || evidence_die "path is not absolute: $out"
output_parent=$(dirname -- "$out")
[[ -d $output_parent && ! -L $output_parent ]] || evidence_die "output parent must already exist: $output_parent"
[[ ! -e $out && ! -L $out ]] || evidence_die "output already exists: $out"
command -v python3 >/dev/null 2>&1 || evidence_die 'python3 is required for atomic output publication'

"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$input"
# Keep the requested output untouched until every input and staged artifact has
# passed the full repo verifier. The stage is same-parent so final rename is an
# atomic claim of the previously absent requested path.
output_base=$(basename -- "$out")
stage=$(mktemp -d "$output_parent/.${output_base}.stage.XXXXXX") || evidence_die "cannot create output stage: $out"
chmod 700 "$stage"
cleanup() { [[ -z ${stage:-} || ! -e $stage ]] || rm -rf -- "$stage"; }
trap cleanup EXIT
mkdir -m 700 -- "$stage/packages"; cp -p -- "$input/packages.tsv" "$stage/packages.tsv"; cp -p -- "$coverage_contract" "$stage/coverage.tsv"
while IFS=$'\t' read -r package _ _ _ artifact extra; do
    [[ -z $package ]] && continue
    [[ -z ${extra:-} ]] || evidence_die 'invalid package metadata'
    source="$input/$artifact"; [[ -f $source ]] || source="$input/packages/$artifact"
    evidence_abs_regular "$source"; cp -p -- "$source" "$stage/packages/$artifact"
done < <(tail -n +2 "$input/packages.tsv")
(umask 077; {
    printf 'format=1\nrepo_name=asahi-m8-local-preview\narchitecture=aarch64\n'
    printf 'signed=false\npublished=false\ninstalled=false\nbooted=false\nhardware_acceptance=false\nplatform_coverage=static-plan-incomplete\nplatform_coverage_sha256=%s\n' "$(evidence_sha256 "$stage/coverage.tsv")"
    printf 'package_manifest_sha256=%s\n' "$(evidence_sha256 "$stage/packages.tsv")"
    printf 'purpose=static-unsigned-preview-only\n'
} > "$stage/manifest.txt")
(umask 077; {
    printf 'format=1\nrepo_name=asahi-m8-local-preview\narchitecture=aarch64\n'
    tail -n +2 "$stage/packages.tsv" | LC_ALL=C sort -t $'\t' -k1,1
} > "$stage/repo.db")
evidence_write_sums "$stage" "$stage/SHA256SUMS"
"$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$stage" >/dev/null
evidence_atomic_publish_directory "$stage" "$out"
[[ -d $out && ! -L $out && ! -e $stage && ! -L $stage ]] || evidence_die 'published output is not exactly the verified stage'
stage=
printf 'repo=%s\n' "$out"
