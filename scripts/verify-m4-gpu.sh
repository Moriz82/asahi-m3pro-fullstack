#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 2 && $1 == --bundle ]] || { printf 'usage: %s --bundle ABS\n' "$0" >&2; exit 64; }
bundle=$2
"$project_root/scripts/verify-evidence-bundle.sh" --bundle "$bundle" --expect-milestone M4 --expect-status software-plan-only
evidence_validate_m4 "$bundle/inputs"
if [[ -f "$bundle/analysis/kernel-log.txt" ]]; then evidence_verify_analysis_report "$bundle/inputs/kernel.log" "$bundle/analysis/kernel-log.txt"; fi
[[ $(evidence_kv "$bundle/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must be false'
printf 'M4=verified-software-plan-only\n'
