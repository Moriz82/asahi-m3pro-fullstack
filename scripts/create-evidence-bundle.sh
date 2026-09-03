#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 7 && $1 == --milestone && $2 =~ ^M[234]$ && $3 == --dry-run && $4 == --input-dir && $6 == --out ]] || {
    printf 'usage: %s --milestone M2|M3|M4 --dry-run --input-dir ABS --out ABS\n' "$0" >&2; exit 64;
}
milestone=$2; input=$5; out=$7
evidence_abs_dir "$input"
mkdir -p -m 700 -- "$MILESTONE_EVIDENCE_ROOT"
evidence_abs_dir "$MILESTONE_EVIDENCE_ROOT"
evidence_path_under "$out" "$MILESTONE_EVIDENCE_ROOT"
evidence_new_dir "$out"
mkdir -m 700 -- "$out/inputs" "$out/analysis"
required=(identity.txt kernel.log)
case $milestone in
    M2) required+=(power-thermal.tsv suspend-resume.tsv);;
    M3) required+=(dcp.log display-modes.tsv brightness.tsv suspend-resume.tsv);;
    M4) required+=(renderer.txt conformance.tsv stress.tsv reset-recovery.txt);;
esac
for file in "${required[@]}"; do
    source_file="$input/$file"
    evidence_abs_regular "$source_file"
done
while IFS= read -r -d '' link; do evidence_die "symlink is not allowed: $link"; done < <(find -P "$input" -type l -print0)
while IFS= read -r -d '' source_file; do
    [[ ! -L $source_file ]] || evidence_die "symlink is not allowed: $source_file"
    rel=${source_file#"$input"/}
    case $rel in
        analysis/*) target="$out/analysis/${rel#analysis/}";;
        *) target="$out/inputs/$rel";;
    esac
    [[ ! -e $target && ! -L $target ]] || evidence_die "duplicate destination: $target"
    parent=$(dirname -- "$target")
    mkdir -p -m 700 -- "$parent"
    cp -p -- "$source_file" "$target"
done < <(find -P "$input" -type f -print0 | sort -z)
(umask 077; {
    printf 'milestone=%s\n' "$milestone"
    printf 'target_model=Mac15,6\nboard=J514s\nsoc=T6030\n'
    printf 'collection_status=software-plan-only\nhardware_acceptance=false\n'
    printf 'input_count=%s\n' "${#required[@]}"
} >"$out/manifest.txt")
(umask 077; {
    printf 'mode=software-plan-only\n'
    printf 'This dry-run packages supplied static files only.\n'
    printf 'No native boot, hardware command, firmware load, compositor, GPU, or conformance execution is performed.\n'
    printf 'Future acceptance requires human-authorized native execution, review, fault and recovery evidence.\n'
} >"$out/collection-plan.txt")
evidence_write_sums "$out" "$out/SHA256SUMS"
printf 'bundle=%s\n' "$out"
