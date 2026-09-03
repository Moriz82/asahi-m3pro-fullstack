#!/usr/bin/env bash
# Canonical Milestone 8 platform coverage contract checks.
m8_validate_platform_coverage() {
    local file=$1 contract=${2:-${M8_PLATFORM_COVERAGE_CONTRACT:-}} header layer status gate hardware extra index=0
    [[ -n $contract ]] || evidence_die 'M8 platform coverage contract is not configured'
    evidence_abs_regular "$file"; evidence_abs_regular "$contract"
    cmp -s "$file" "$contract" || evidence_die 'M8 platform coverage differs from checked-in contract'
    header=$(head -n 1 "$file")
    [[ $header == $'layer	status	gate	hardware_acceptance' ]] || evidence_die 'invalid M8 platform coverage header'
    local -a expected=(boot-chain device-trees firmware-tooling audio-routing speaker-safety platform-services desktop-session package-rollback)
    while IFS=$'\t' read -r layer status gate hardware extra; do
        [[ -z ${extra:-} && ${expected[index]:-} == "$layer" ]] || evidence_die 'M8 platform coverage order/schema is invalid'
        [[ $status == not-provided || ( $layer == package-rollback && $status == static-snapshot ) ]] || evidence_die "invalid M8 coverage status: $layer"
        [[ $gate == blocked-pending-evidence && $hardware == false ]] || evidence_die "unsafe M8 coverage state: $layer"
        index=$((index + 1))
    done < <(tail -n +2 "$file")
    [[ $index == ${#expected[@]} ]] || evidence_die 'M8 platform coverage must contain exactly eight layers'
}
