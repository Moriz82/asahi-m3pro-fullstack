#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P); source "$project_root/config/milestones.env"; source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 2 && $1 == --bundle ]] || { printf 'usage: %s --bundle ABS\n' "$0" >&2; exit 64; }
bundle=$2; evidence_abs_dir "$bundle"; evidence_path_under "$bundle" "$MILESTONE_EVIDENCE_ROOT"
for file in manifest.txt collection-plan.txt SHA256SUMS; do evidence_abs_regular "$bundle/$file"; done
[[ $(evidence_kv "$bundle/manifest.txt" milestone) == M7 ]] || evidence_die 'milestone mismatch'; [[ $(evidence_kv "$bundle/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must be false'
[[ $(evidence_kv "$bundle/manifest.txt" collection_status) == software-plan-only ]] || evidence_die 'collection status mismatch'
for file in identity.txt kernel.log macos-security.tsv threat-model.tsv security-boundaries.tsv accelerators.tsv negative-tests.tsv recovery.tsv; do evidence_abs_regular "$bundle/inputs/$file"; done
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$bundle" -type l -print0)
evidence_verify_sums "$bundle" "$bundle/SHA256SUMS"
verify_parent=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/.m7-verify.XXXXXX"); verify_out="$verify_parent/out"; trap 'rm -rf -- "$verify_parent"' EXIT; "$project_root/scripts/collect-m7-security.sh" --dry-run --input-dir "$bundle/inputs" --out "$verify_out" >/dev/null 2>&1 || evidence_die 'bundle security contract invalid'
printf 'M7=verified-software-plan-only\n'
