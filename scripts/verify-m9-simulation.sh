#!/usr/bin/env bash
# Independently verify a static M9 simulation against caller-supplied digests.
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
allowlist="$project_root/config/milestone9-action-allowlist.txt"; denylist="$project_root/config/milestone9-action-denylist.txt"; states="$project_root/config/milestone9-state-transitions.tsv"
usage() { printf 'usage: %s --simulation ABS --release-sha256 HEX --plan-sha256 HEX\n' "$0" >&2; exit 64; }
[[ $# -eq 6 && $1 == --simulation && $3 == --release-sha256 && $5 == --plan-sha256 ]] || usage
simulation=$2; expected_release=$4; expected_plan=$6
evidence_abs_dir "$simulation"; evidence_abs_regular "$simulation/SHA256SUMS"; evidence_abs_regular "$allowlist"; evidence_abs_regular "$denylist"; evidence_abs_regular "$states"
[[ $expected_release =~ ^[[:xdigit:]]{64}$ && $expected_plan =~ ^[[:xdigit:]]{64}$ ]] || evidence_die 'expected digest must be exactly 64 hexadecimal characters'
for file in simulation.txt transitions.tsv policy.txt SHA256SUMS; do evidence_abs_regular "$simulation/$file"; done
while IFS= read -r -d '' link; do evidence_die "simulation symlink: $link"; done < <(find -P "$simulation" -type l -print0)
while IFS= read -r -d '' dir; do evidence_die "simulation path contains directory: ${dir#"$simulation"/}"; done < <(find -P "$simulation" -mindepth 1 -type d -print0)
while IFS= read -r -d '' member; do
    rel=${member#"$simulation"/}
    case $rel in simulation.txt|transitions.tsv|policy.txt|SHA256SUMS) ;; *) evidence_die "unexpected simulation member: $rel";; esac
done < <(find -P "$simulation" -type f -print0)
evidence_verify_sums "$simulation" "$simulation/SHA256SUMS"
[[ $(evidence_kv "$simulation/policy.txt" mode) == static-state-simulation ]] || evidence_die 'invalid simulation policy'
[[ $(evidence_kv "$simulation/simulation.txt" format) == 1 ]] || evidence_die 'invalid simulation format'
[[ $(evidence_kv "$simulation/simulation.txt" status) == complete && $(evidence_kv "$simulation/simulation.txt" execution) == blocked ]] || evidence_die 'simulation is not complete and blocked'
[[ $(evidence_kv "$simulation/simulation.txt" hardware_acceptance) == false && $(evidence_kv "$simulation/simulation.txt" actuation) == false && $(evidence_kv "$simulation/simulation.txt" release_gate) == blocked ]] || evidence_die 'simulation acceptance gate changed'
[[ $(evidence_kv "$simulation/simulation.txt" release_inputs_sha256) == "$expected_release" ]] || evidence_die 'release digest is not externally pinned'
[[ $(evidence_kv "$simulation/simulation.txt" recovery_plan_sha256) == "$expected_plan" ]] || evidence_die 'plan digest is not externally pinned'
allow=(); deny=()
while IFS= read -r line || [[ -n $line ]]; do [[ -z $line || $line == \#* ]] && continue; [[ $line != *$'\t'* && $line != *' '* ]] || evidence_die 'invalid allowlist row'; allow+=("$line"); done < "$allowlist"
while IFS= read -r line || [[ -n $line ]]; do [[ -z $line || $line == \#* ]] && continue; [[ $line != *$'\t'* && $line != *' '* ]] || evidence_die 'invalid denylist row'; deny+=("$line"); done < "$denylist"
scan_denied() { local value=$1 blocked; for blocked in "${deny[@]}"; do [[ $value != "$blocked" && $value != *"$blocked"* ]] || evidence_die "denied simulation token: $blocked"; done; }
header=$(head -n 1 "$simulation/transitions.tsv"); [[ $header == $'sequence\tfrom_state\taction\tto_state\trequired_evidence' ]] || evidence_die 'invalid transition header'
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
done < <(tail -n +2 "$simulation/transitions.tsv")
((count >= 6)) || evidence_die 'simulation transition trace is incomplete'
[[ $previous == dfu-evidence-recorded ]] || evidence_die 'simulation lacks recovery and DFU evidence states'
[[ $(evidence_kv "$simulation/simulation.txt" initial_state) == new && $(evidence_kv "$simulation/simulation.txt" final_state) == "$previous" ]] || evidence_die 'simulation state summary mismatch'
[[ $(evidence_kv "$simulation/simulation.txt" transition_count) == "$count" ]] || evidence_die 'simulation transition count mismatch'
if grep -Eiq 'diskutil|partition|apfs|bless|bputil|nvram|firmware|startup|reboot|native-install|execute-install|modify-container|existing-container|remove-macos|erase-macos|mount|umount|systemctl|chroot|ssh|curl|wget' "$simulation/simulation.txt" "$simulation/transitions.tsv" "$simulation/policy.txt"; then evidence_die 'unsafe simulation token'; fi
printf 'M9=simulation-verified simulation=%s execution=blocked\n' "$simulation"
