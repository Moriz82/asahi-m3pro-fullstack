#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P); source "$project_root/config/milestones.env"; source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 2 && $1 == --bundle ]] || { printf 'usage: %s --bundle ABS\n' "$0" >&2; exit 64; }
bundle=$2; evidence_abs_dir "$bundle"; evidence_path_under "$bundle" "$MILESTONE_EVIDENCE_ROOT"
calibration_allowlist="$project_root/config/milestone6-speaker-calibrations.tsv"; evidence_abs_regular "$calibration_allowlist"
graph_allowlist="$project_root/config/milestone6-speaker-dsp-graphs.tsv"; evidence_abs_regular "$graph_allowlist"
for file in manifest.txt collection-plan.txt SHA256SUMS; do evidence_abs_regular "$bundle/$file"; done
[[ $(evidence_kv "$bundle/manifest.txt" milestone) == M6 ]] || evidence_die 'milestone mismatch'; [[ $(evidence_kv "$bundle/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must be false'
[[ $(evidence_kv "$bundle/manifest.txt" collection_status) == software-plan-only ]] || evidence_die 'collection status mismatch'
[[ $(evidence_kv "$bundle/manifest.txt" speaker_calibration_allowlist_sha256) == "$(evidence_sha256 "$calibration_allowlist")" ]] || evidence_die 'speaker calibration allowlist binding mismatch'
[[ $(evidence_kv "$bundle/manifest.txt" speaker_dsp_graph_allowlist_sha256) == "$(evidence_sha256 "$graph_allowlist")" ]] || evidence_die 'speaker DSP graph allowlist binding mismatch'
for file in identity.txt kernel.log camera.tsv audio.tsv codecs.tsv speaker-safety.tsv; do evidence_abs_regular "$bundle/inputs/$file"; done
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$bundle" -type l -print0)
evidence_verify_sums "$bundle" "$bundle/SHA256SUMS"
verify_parent=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/.m6-verify.XXXXXX"); verify_out="$verify_parent/out"; trap 'rm -rf -- "$verify_parent"' EXIT; "$project_root/scripts/collect-m6-media-audio.sh" --dry-run --input-dir "$bundle/inputs" --out "$verify_out" >/dev/null 2>&1 || evidence_die 'bundle structure or media contract invalid'
printf 'M6=verified-software-plan-only\n'
