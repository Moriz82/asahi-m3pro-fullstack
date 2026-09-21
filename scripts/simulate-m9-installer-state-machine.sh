#!/usr/bin/env bash
# Simulate allowlisted installer/release states as records only.
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
M9_PROJECT_ROOT=$project_root
source "$project_root/scripts/lib/m9-canonical.sh"
m9_require_m1_anchor_args "$@"
shift 4
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
allowlist="$project_root/config/milestone9-action-allowlist.txt"; denylist="$project_root/config/milestone9-action-denylist.txt"; states="$project_root/config/milestone9-state-transitions.tsv"
usage() { printf 'usage: %s --expected-target-identity-sha256 HEX --target-readiness-anchors ABS --release-inputs ABS --release-anchor ABS --plan ABS --plan-anchor ABS --transitions ABS --out ABS\n' "$0" >&2; exit 64; }
[[ $# -eq 12 && $1 == --release-inputs && $3 == --release-anchor && $5 == --plan && $7 == --plan-anchor && $9 == --transitions && ${11} == --out ]] || usage
release=$2; release_anchor=$4; plan=$6; plan_anchor=$8; transitions=${10}; out=${12}
for dir in "$release" "$plan"; do evidence_abs_dir "$dir"; done
for file in "$release/manifest.txt" "$release/SHA256SUMS" "$release/release-inputs.tsv" "$release_anchor" "$transitions" "$allowlist" "$denylist" "$states"; do evidence_abs_regular "$file"; done
evidence_path_under "$out" "$output_root"
[[ ! -e "$out" && ! -L "$out" ]] || evidence_die 'simulation output already exists'
out_parent=$(dirname -- "$out")
evidence_abs_dir "$out_parent"
[[ $release_anchor != "$release" && $release_anchor != "$release"/* && $release_anchor != "$plan" && $release_anchor != "$plan"/* && $release_anchor != "$out" && $release_anchor != "$out"/* && $release_anchor != "$output_root" && $release_anchor != "$output_root"/* && $plan_anchor != "$release" && $plan_anchor != "$release"/* && $plan_anchor != "$plan" && $plan_anchor != "$plan"/* && $plan_anchor != "$out" && $plan_anchor != "$out"/* && $plan_anchor != "$output_root" && $plan_anchor != "$output_root"/* ]] || evidence_die 'anchors must be outside release, plan, and output trees'
[[ $(evidence_kv "$release_anchor" anchor_trust) == untrusted-declarative ]] || evidence_die 'release anchor is not a configured signed authority'
evidence_verify_sums "$release" "$release/SHA256SUMS"
[[ $(evidence_kv "$release/manifest.txt" target_model) == Mac15,6 && $(evidence_kv "$release/manifest.txt" target_board) == J514s && $(evidence_kv "$release/manifest.txt" target_soc) == T6030 ]] || evidence_die 'release target mismatch'
[[ $(evidence_kv "$release/manifest.txt" release_gate) == blocked && $(evidence_kv "$release/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'release must remain blocked'
[[ $(evidence_kv "$release/manifest.txt" external_anchor_sha256) == "$(evidence_sha256 "$release_anchor")" ]] || evidence_die 'release anchor mismatch'
[[ $(evidence_kv "$release/manifest.txt" release_input_set_sha256) == "$(evidence_sha256 "$release/release-inputs.tsv")" ]] || evidence_die 'release-input set changed'
m9_validate_canonical_release_binding "$release" "$release_anchor" "$M9_EXPECTED_TARGET" "$M9_TARGET_ANCHORS"
while IFS= read -r -d '' member; do
    rel=${member#"$release"/}
    case $rel in
        identity.txt|release-inputs.tsv|manifest.txt|policy.txt|SHA256SUMS|canonical-handoff-map.tsv|manifests/M[0-8]/manifest.txt|handoffs/M[0-8]/*) ;;
        *) evidence_die "unexpected release evidence member: $rel";;
    esac
done < <(find -P "$release" -type f -print0)
while IFS=$'\t' read -r milestone rel expected_hash hw native backup dfu dedicated extra; do
    [[ -z ${extra:-} ]] || evidence_die 'invalid release-input row'
    [[ $(evidence_sha256 "$release/manifests/$milestone/manifest.txt") == "$expected_hash" ]] || evidence_die "release manifest changed: $milestone"
done < <(tail -n +2 "$release/release-inputs.tsv")
bash "$project_root/scripts/verify-m9-recovery-plan.sh" --expected-target-identity-sha256 "$M9_EXPECTED_TARGET" --target-readiness-anchors "$M9_TARGET_ANCHORS" --plan "$plan" --release-inputs "$release" --release-anchor "$release_anchor" --anchor "$plan_anchor" >/dev/null
allow=(); deny=()
while IFS= read -r line || [[ -n $line ]]; do [[ -z $line || $line == \#* ]] && continue; [[ $line != *$'\t'* && $line != *' '* ]] || evidence_die 'invalid allowlist row'; allow+=("$line"); done < "$allowlist"
while IFS= read -r line || [[ -n $line ]]; do [[ -z $line || $line == \#* ]] && continue; [[ $line != *$'\t'* && $line != *' '* ]] || evidence_die 'invalid denylist row'; deny+=("$line"); done < "$denylist"
((${#allow[@]} > 0 && ${#deny[@]} > 0)) || evidence_die 'allow/deny list is empty'
for action in "${allow[@]}"; do for blocked in "${deny[@]}"; do [[ $action != "$blocked" ]] || evidence_die "action appears in both lists: $action"; done; done
scan_denied() { local value=$1 blocked; for blocked in "${deny[@]}"; do [[ $value != "$blocked" && $value != *"$blocked"* ]] || evidence_die "denied action/token: $blocked"; done; }
header=$(head -n 1 "$transitions"); [[ $header == $'sequence\tfrom_state\taction\tto_state\trequired_evidence' ]] || evidence_die 'invalid transition header'
config_header=$(head -n 1 "$states"); [[ $config_header == $'from_state\taction\tto_state\trequired_evidence' ]] || evidence_die 'invalid state-transition configuration'
previous=new; sequence=0; count=0; seen='|'
while IFS=$'\t' read -r number from action to required extra; do
    [[ -z ${extra:-} ]] || evidence_die 'extra transition column'
    [[ $number =~ ^[0-9]+$ ]] || evidence_die 'transition sequence is not numeric'
    sequence=$((sequence + 1)); [[ $number == "$sequence" ]] || evidence_die 'transition sequence is duplicate or out of order'
    [[ $from == "$previous" ]] || evidence_die 'transition starts from the wrong state'
    [[ $seen != *"|$from|$action|$to|"* ]] || evidence_die 'duplicate transition'
    scan_denied "$from"; scan_denied "$action"; scan_denied "$to"; scan_denied "$required"
    local_match=$(awk -F '\t' -v f="$from" -v a="$action" -v t="$to" -v r="$required" 'NR > 1 && $1 == f && $2 == a && $3 == t && $4 == r {n++} END {print n + 0}' "$states")
    [[ $local_match == 1 ]] || evidence_die 'transition is not allowlisted'
    printf '%s\n' "${allow[@]}" | grep -Fx -- "$action" >/dev/null || evidence_die 'unknown action'
    previous=$to; seen="${seen}|$from|$action|$to|"; count=$((count + 1))
done < <(tail -n +2 "$transitions")
((count >= 6)) || evidence_die 'transition trace is incomplete'
[[ $previous == dfu-evidence-recorded ]] || evidence_die 'recovery and DFU evidence states are required'
stage=$(mktemp -d "$out_parent/.m9-simulation.XXXXXX")
chmod 700 "$stage"
cleanup_simulation() { rm -rf -- "${stage:-}"; }
trap cleanup_simulation EXIT
(umask 077; {
    printf 'format=1\nstatus=complete\nexecution=blocked\nhardware_acceptance=false\nactuation=false\n'
    printf 'initial_state=new\nfinal_state=%s\ntransition_count=%s\nrelease_gate=blocked\n' "$previous" "$count"
    printf 'release_inputs_sha256=%s\nrecovery_plan_sha256=%s\n' "$(evidence_sha256 "$release/manifest.txt")" "$(evidence_sha256 "$plan/plan.txt")"
} > "$stage/simulation.txt")
cp -p -- "$transitions" "$stage/transitions.tsv"
(umask 077; printf 'mode=static-state-simulation\nrecord_scope=blocked-planned-observed\n' > "$stage/policy.txt")
evidence_write_sums "$stage" "$stage/SHA256SUMS"
"$project_root/scripts/verify-m9-simulation.sh" --simulation "$stage" --release-sha256 "$(evidence_sha256 "$release/manifest.txt")" --plan-sha256 "$(evidence_sha256 "$plan/plan.txt")" >/dev/null
evidence_atomic_publish_directory "$stage" "$out"
[[ -d $out && ! -L $out && ! -e $stage && ! -L $stage ]] || evidence_die 'published simulation is not exactly the verified stage'
stage=
printf 'M9=state-simulation-verified execution=blocked evidence=%s\n' "$out"
