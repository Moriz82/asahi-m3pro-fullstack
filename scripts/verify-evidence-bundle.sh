#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 6 && $1 == --bundle && $3 == --expect-milestone && $5 == --expect-status ]] || {
    printf 'usage: %s --bundle ABS --expect-milestone Mx --expect-status software-plan-only\n' "$0" >&2; exit 64;
}
bundle=$2
expected_m=$4
expected_s=$6
[[ $expected_m =~ ^M[234]$ && $expected_s == software-plan-only ]] || evidence_die 'invalid expected values'
evidence_abs_dir "$bundle"
evidence_path_under "$bundle" "$MILESTONE_EVIDENCE_ROOT"
for file in manifest.txt collection-plan.txt SHA256SUMS; do evidence_abs_regular "$bundle/$file"; done
[[ $(evidence_kv "$bundle/manifest.txt" milestone) == "$expected_m" ]] || evidence_die 'milestone mismatch'
[[ $(evidence_kv "$bundle/manifest.txt" collection_status) == "$expected_s" ]] || evidence_die 'status mismatch'
[[ $(evidence_kv "$bundle/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance is not false'
if grep -Eiq 'boot[[:space:]_-]*(passed|verified|success)|support[[:space:]_-]*(passed|verified|complete)|hardware_acceptance[[:space:]]*=[[:space:]]*(true|yes)|conformance[[:space:]]*=[[:space:]]*(pass|passed|true)' "$bundle/manifest.txt" "$bundle/collection-plan.txt"; then evidence_die 'acceptance claim found'; fi
while IFS= read -r -d '' file; do
    rel=${file#"$bundle"/}
    case $rel in manifest.txt|collection-plan.txt|SHA256SUMS|inputs/*|analysis/*) ;; *) evidence_die "extra bundle member: $rel";; esac
done < <(find -P "$bundle" -type f -print0)
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$bundle" -type l -print0)
while IFS= read -r -d '' dir; do
    rel=${dir#"$bundle"/}
    case $rel in "$bundle"|inputs|analysis|inputs/*|analysis/*) ;; *) evidence_die "extra bundle directory: $rel";; esac
done < <(find -P "$bundle" -type d -print0)
evidence_verify_sums "$bundle" "$bundle/SHA256SUMS"
printf 'bundle=verified:%s\n' "$bundle"
