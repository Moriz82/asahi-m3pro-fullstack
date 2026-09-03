#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly tmp="$(mktemp -d "${TMPDIR:-/tmp}/milestone-gate.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

run_gate() {
    local gate=$1 milestone=$2 output status
    if output=$("$gate" --milestone "$milestone" --dry-run 2>"$tmp/gate.err"); then
        status=0
    else
        status=$?
    fi
    [[ $status -eq 2 ]] || {
        printf 'expected blocked dry-run for %s, got %s\n' "$milestone" "$status" >&2
        return 1
    }
    printf '%s\n' "$output"
}

copied_project="$tmp/project"
mkdir -p "$copied_project/scripts" "$copied_project/config"
cp -- "$project_root/scripts/check-milestone-gate.sh" "$copied_project/scripts/"
cp -- "$project_root/config/milestones.env" "$copied_project/config/"
cp -- "$project_root/config/milestone-contracts.tsv" "$copied_project/config/"
copied_gate="$copied_project/scripts/check-milestone-gate.sh"
contract="$copied_project/config/milestone-contracts.tsv"
output=$(run_gate "$copied_gate" M0)
printf '%s\n' "$output" | grep -Fx 'expected-predecessor=none' >/dev/null
printf '%s\n' "$output" | grep -Fx 'tooling_valid=not-run' >/dev/null
printf '%s\n' "$output" | grep -Fx 'evidence_valid=not-provided' >/dev/null
printf '%s\n' "$output" | grep -Fx 'hardware_acceptance=false' >/dev/null
printf '%s\n' "$output" | grep -Fx 'gate=blocked-for-native-execution' >/dev/null

awk -F '\t' -v OFS='\t' '$1 == "M2" {$2 = "M7"} {print}' \
    "$contract" > "$tmp/contract.changed"
mv -- "$tmp/contract.changed" "$contract"
output=$(run_gate "$copied_gate" M2)
printf '%s\n' "$output" | grep -Fx 'expected-predecessor=M7' >/dev/null

awk -F '\t' -v OFS='\t' '$1 == "M2" {print; print} {print}' \
    "$contract" > "$tmp/contract.duplicate"
mv -- "$tmp/contract.duplicate" "$contract"
if "$copied_gate" --milestone M2 --dry-run >/dev/null 2>&1; then
    printf 'duplicate contract row was accepted\n' >&2
    exit 1
fi

if MILESTONE_CONTRACT_FILE="$tmp/ambient-contract.tsv" \
    "$project_root/scripts/check-milestone-gate.sh" \
    --milestone M2 --dry-run >"$tmp/ambient.out" 2>/dev/null; then
    ambient_status=0
else
    ambient_status=$?
fi
[[ $ambient_status -eq 2 ]]
grep -Fx 'expected-predecessor=M1' "$tmp/ambient.out" >/dev/null

printf 'milestone-gate-tests=passed\n'
