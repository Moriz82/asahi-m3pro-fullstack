#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"; source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 2 && $1 == --bundle ]] || { printf 'usage: %s --bundle ABS\n' "$0" >&2; exit 64; }
bundle=$2; evidence_abs_dir "$bundle"; evidence_path_under "$bundle" "$MILESTONE_EVIDENCE_ROOT"
for file in manifest.txt collection-plan.txt SHA256SUMS; do evidence_abs_regular "$bundle/$file"; done
[[ $(evidence_kv "$bundle/manifest.txt" milestone) == M5 ]] || evidence_die 'milestone mismatch'
[[ $(evidence_kv "$bundle/manifest.txt" collection_status) == software-plan-only ]] || evidence_die 'collection status mismatch'
[[ $(evidence_kv "$bundle/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must be false'
if grep -Eiq 'support[[:space:]_-]*(passed|verified|complete)|hardware_acceptance[[:space:]]*=[[:space:]]*(true|yes)|conformance[[:space:]]*=[[:space:]]*(pass|passed|true)' "$bundle/manifest.txt" "$bundle/collection-plan.txt"; then evidence_die 'acceptance claim found'; fi
for file in identity.txt kernel.log iommu.log inventory.tsv ports.tsv modes.tsv stress.tsv; do evidence_abs_regular "$bundle/inputs/$file"; done
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$bundle" -type l -print0)
evidence_verify_sums "$bundle" "$bundle/SHA256SUMS"
verify_parent=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/.m5-verify.XXXXXX"); verify_out="$verify_parent/out"; trap 'rm -rf -- "$verify_parent"' EXIT; "$project_root/scripts/collect-m5-ports.sh" --dry-run --input-dir "$bundle/inputs" --out "$verify_out" >/dev/null 2>&1 || evidence_die 'bundle port contract invalid'
printf 'M5=verified-software-plan-only\n'
