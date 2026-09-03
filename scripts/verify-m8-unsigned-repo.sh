#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/m8-coverage.sh"
coverage_contract="$project_root/config/milestone8-platform-coverage.tsv"
[[ $# -eq 2 && $1 == --repo ]] || { printf 'usage: %s --repo ABS\n' "$0" >&2; exit 64; }
repo=$2; evidence_abs_dir "$repo"; evidence_abs_regular "$coverage_contract"
for file in manifest.txt repo.db coverage.tsv packages.tsv SHA256SUMS; do evidence_abs_regular "$repo/$file"; done
m8_validate_platform_coverage "$repo/coverage.tsv" "$coverage_contract"
[[ $(evidence_kv "$repo/manifest.txt" format) == 1 ]] || evidence_die 'invalid repo format'
[[ $(evidence_kv "$repo/manifest.txt" purpose) == static-unsigned-preview-only ]] || evidence_die 'repo purpose is not preview-only'
for key in signed published installed booted hardware_acceptance; do [[ $(evidence_kv "$repo/manifest.txt" "$key") == false ]] || evidence_die "$key must be false"; done
[[ $(evidence_kv "$repo/manifest.txt" platform_coverage) == static-plan-incomplete ]] || evidence_die 'platform coverage is not an incomplete static plan'
[[ $(evidence_kv "$repo/manifest.txt" platform_coverage_sha256) == "$(evidence_sha256 "$repo/coverage.tsv")" ]] || evidence_die 'manifest platform coverage hash mismatch'
[[ $(evidence_kv "$repo/manifest.txt" package_manifest_sha256) == "$(evidence_sha256 "$repo/packages.tsv")" ]] || evidence_die 'manifest package hash mismatch'
"$project_root/scripts/verify-m8-package-closure.sh" --repo "$repo"
expected=$(mktemp); trap 'rm -f "$expected"' EXIT
{ printf 'format=1\nrepo_name=asahi-m8-local-preview\narchitecture=aarch64\n'; tail -n +2 "$repo/packages.tsv" | LC_ALL=C sort -t $'\t' -k1,1; } > "$expected"
cmp -s "$expected" "$repo/repo.db" || evidence_die 'repo metadata changed or non-deterministic'
evidence_verify_sums "$repo" "$repo/SHA256SUMS"
printf 'M8=unsigned-repo-verified repo=%s\n' "$repo"
