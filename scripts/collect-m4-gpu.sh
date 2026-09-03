#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 5 && $1 == --dry-run && $2 == --input-dir && $4 == --out ]] || { printf 'usage: %s --dry-run --input-dir ABS --out ABS\n' "$0" >&2; exit 64; }
input=$3
out=$5
evidence_abs_dir "$input"
evidence_path_under "$out" "$MILESTONE_EVIDENCE_ROOT"
evidence_validate_m4 "$input"
stage=$(mktemp -d "${TMPDIR:-/tmp}/m4-evidence.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir -m 700 -- "$stage/analysis"
for f in identity.txt kernel.log renderer.txt conformance.tsv stress.tsv reset-recovery.txt; do cp -p -- "$input/$f" "$stage/$f"; done
"$project_root/scripts/analyze-kernel-log.sh" --input "$input/kernel.log" --report "$stage/analysis/kernel-log.txt"
"$project_root/scripts/create-evidence-bundle.sh" --milestone M4 --dry-run --input-dir "$stage" --out "$out"
